// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! The Store: in-memory task graph folded from an append-only JSONL event log,
//! plus the queries (`membersOf`, `arcsOf`, `isArc`, `arcless`, `next`) and the
//! write/atomic-write helpers.
//!
//! Layout under the store dir (overridable — tests pass a tmp dir):
//!   <dir>/.tracker/snapshot.jsonl   optional full-state baseline (absent in v1)
//!   <dir>/.tracker/log.jsonl        the append-only event log
//!
//! Load = fold: replay snapshot (if any) then log, in file order, applying each
//! event. Append = open log, append one JSON line at end-of-file (O(1) via a
//! positional write at the current length). Compaction (stubbed) rewrites the
//! whole snapshot via write-temp + rename (atomic on the same filesystem).
//!
//! NOTE (Zig 0.16): the filesystem is `Io`-threaded. `Store` holds an `Io` and
//! an `Io.Dir` (the store dir) so tests can drive it against a `tmpDir` and
//! main.zig against a real cwd. No absolute paths are baked in.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const model = @import("model.zig");
const ulid = @import("ulid.zig");
const codec = @import("json_codec.zig");

const Ulid = model.Ulid;
const Task = model.Task;
const Event = model.Event;
const State = model.State;

/// Map key: the 26-byte ULID text (a fixed array auto-hashes cleanly, unlike a
/// wrapping struct in some Zig versions).
const Key = [ulid.len]u8;

fn key(u: Ulid) Key {
    return u.text;
}

/// Composite key for a (from, to) edge tombstone: concatenate both ULID texts.
fn edgeKey(from: Ulid, to: Ulid) [ulid.len * 2]u8 {
    var k: [ulid.len * 2]u8 = undefined;
    @memcpy(k[0..ulid.len], &from.text);
    @memcpy(k[ulid.len..], &to.text);
    return k;
}

pub const tracker_subdir = ".tracker";
pub const log_name = "log.jsonl";
pub const snapshot_name = "snapshot.jsonl";
pub const config_name = "config.json";
/// Git merge semantics for the store's three files, written by `trk init` INTO
/// `.tracker/` rather than the repo root. Two reasons it lives here and not
/// there: git resolves attributes per directory and the file nearest the path
/// WINS, so these pins cannot be overridden by a later root-level glob (a root
/// `*.jsonl merge=union` would otherwise silently capture the two baselines);
/// and `.tracker/` is a directory trk owns, so writing it needs no append-to-a-
/// foreign-file semantics and cannot clobber a project's own attributes.
/// Patterns are relative to this file's own directory, so it works whether or
/// not `.tracker/` sits at the repo root (`discover.findRoot` does not assume
/// it does).
pub const gitattributes_name = ".gitattributes";
pub const gitattributes_text =
    \\# Written by `trk init`. Kept INSIDE .tracker/ deliberately: git resolves
    \\# attributes per directory and the file nearest the path wins, so these
    \\# cannot be overridden by a broader pattern in a parent .gitattributes.
    \\#
    \\# The append-only event log: every line is an independent, idempotent event.
    \\# Union-merge so parallel-worktree appends combine instead of conflicting —
    \\# that is what lets a lane close its OWN tasks in its worktree and have the
    \\# events merge on integration. Merge-SAFE, not a general CRDT: it rests on
    \\# the fan-out invariant that each writer mutates only its own disjoint tasks.
    \\log.jsonl merge=union
    \\#
    \\# Whole-file baselines, written ONLY by a serialized, orchestrator-only
    \\# `compact` (read-modify-rename, not append). Two sides diverging here means
    \\# two compactions raced — a rule violation that must SURFACE as a conflict,
    \\# never be silently combined. snapshot.jsonl is replayed on every load, so a
    \\# union merge would interleave two baselines and duplicate/revert state;
    \\# quarantine.jsonl (the ghost-retirement spool) is never read back by trk, so
    \\# unioning it is merely wrong rather than corrupting — pinned for the same
    \\# reason and to keep the pair symmetric.
    \\snapshot.jsonl merge=text
    \\quarantine.jsonl merge=text
    \\#
    \\# The tombstone index: one append-only line per task `compact` physically
    \\# GC'd, so a citation of a compacted id still RESOLVES (`trk show`) instead
    \\# of reading as never-existed. Per-line independent and append-only exactly
    \\# like log.jsonl, so union — two branches that each carry a compact combine
    \\# their tombstones instead of one erasing the other's. A duplicate line is
    \\# harmless: the reader keys by id, last line wins.
    \\tombstones.jsonl merge=union
    \\
;

/// Ignore rule for the store's own ephemeral output, written by `trk init`
/// INTO `.tracker/` for the same reason `gitattributes_text` is: git resolves
/// ignores per directory too, so a pattern here is immune to a repo's root
/// `.gitignore` never mentioning it, and needs no git-root discovery since it
/// is relative to this file's own directory. Only `backup/` (see
/// `backup_subdir`) and a crash-orphaned atomic-write temp file are listed —
/// `log.jsonl`, `snapshot.jsonl`, `config.json`, `.gitattributes`,
/// `quarantine.jsonl` and `tombstones.jsonl` are all meant to be committed, so
/// none of them belongs here.
pub const gitignore_name = ".gitignore";
pub const gitignore_text =
    \\# Written by `trk init`. Kept INSIDE .tracker/ deliberately: git resolves
    \\# ignores per directory, so this is immune to a root .gitignore never
    \\# mentioning it. log.jsonl, snapshot.jsonl, config.json, .gitattributes,
    \\# quarantine.jsonl and tombstones.jsonl are all meant to be committed —
    \\# nothing here ignores them.
    \\#
    \\# compact's pre-rewrite backups (Config.backup_retain bounds how many it
    \\# keeps, but even one full log+snapshot copy is a permanent untracked
    \\# stray if `git status` never learns to skip it).
    \\backup/
    \\#
    \\# A crash between atomicWrite's temp-file write and its rename leaves a
    \\# `.<name>.tmp.<hex>` file behind (see Store.atomicWrite) — rare, but the
    \\# same untracked-forever shape as the backup dir above.
    \\.*.tmp.*
    \\
;

/// Where `compact` parks the log lines of ghost ids before it truncates the
/// log (see `Store.compact`). Append-only and never read back by trk — it is a
/// recovery spool for a human, not part of the fold. Pinned to the default text
/// merge driver alongside `snapshot.jsonl` (see `gitattributes_text`): it is a
/// whole-file rewrite by a serialized `compact`, so two sides diverging on it
/// means two compactions raced, which must surface rather than be combined.
/// (Unioning it would NOT resurrect anything — nothing replays this file; that
/// hazard belongs to `log.jsonl`.)
pub const quarantine_name = "quarantine.jsonl";

/// The TOMBSTONE INDEX: one line per task `compact` physically GC'd out of the
/// store (01M2M2K1J).
///
/// THE GAP IT CLOSES. `compact` is the only thing that destroys an id:
/// `serializeState` skips every `isCollectable` task (dropped/archived/ghost)
/// and every edge touching one, then the log is truncated. After that the id is
/// in NO file under `.tracker/` — so `trk show <id>` answers "no task matches",
/// which is byte-identical to the answer for an id that never existed. Those
/// are opposite facts and the difference matters: a wrong "dangling" verdict
/// invites someone to "fix" a citation that was correct. Measured 2026-09-12 in
/// the Enix repo: `show` called 01M1RQ7XK and 01M0QJWJ7 dangling while
/// `scripts/dangling-tracker-id-lint.sh` scanned 29,792 citations and found
/// 11,207 live, 18,585 historical and 0 dangling.
///
/// WHERE THE LINT RECOVERED IT, AND WHY THAT IS NOT ENOUGH. The lint's
/// `build_hist_set` runs `git log --all -p -- .tracker/log.jsonl` and greps
/// every id-shaped string out of the whole diff — the pre-compact log lines
/// survive in git even though the working tree no longer has them. It is
/// correct and it is the proof the information is recoverable, but it is not a
/// mechanism an interactive verb can use: measured on the Enix repo (10,574
/// commits touch that path) it is ~31 s and ~162 MB of diff output for a single
/// yes/no question.
///
/// SO THE STORE KEEPS ITS OWN RECORD. `compact` appends one line here for each
/// task it collects, BEFORE anything destructive happens, and `load` folds the
/// file into `Store.tombstones`. A lookup is then a hash probe, and the answer
/// is a real record (title, why it left, arcs it belonged to, when) rather than
/// a bare "it existed". Unlike `quarantine_name` this file IS read back by trk.
///
/// Bounded by construction: one short line per task ever collected, never per
/// event, and it carries no bodies.
pub const tombstones_name = "tombstones.jsonl";

/// Subdirectory (under `.tracker/`) holding `compact`'s pre-rewrite backups,
/// one run dir per compact (`backupDirName`), bounded by
/// `Config.backup_retain` (see `Store.compact`, `writeBackup`,
/// `evictOldBackups`).
pub const backup_subdir = "backup";

/// One `archive.routes` entry (see `Config.archive_routes`): a task carrying
/// `tag` routes its changelog bullet to `out` instead of `archive_out`.
/// Arena-owned strings.
pub const ArchiveRoute = struct { tag: []const u8, out: []const u8 };

/// Persisted per-repo config (`.tracker/config.json`). Purely optional: a repo
/// with no config file behaves exactly as before (every field null → callers
/// fall back to their prior default, which is stdout for render/archive). The
/// only job today is to persist the render/archive output path so `trk render`
/// need not be handed `--out docs/TODO.md` on every call. Fields are arena-owned.
pub const Config = struct {
    /// `render.out` — where `trk render` writes with no `--out`. null → stdout.
    render_out: ?[]const u8 = null,
    /// `archive.out` — where `trk archive` writes its draft with no `--out`,
    /// and where a task lands that matches none of `archive_routes` below.
    /// null → stdout.
    archive_out: ?[]const u8 = null,
    /// `archive.routes` — per-task changelog destinations (01M2F8GBQ). A repo
    /// can own more than one changelog with a different content policy each —
    /// e.g. Enix's `docs/CHANGELOG.md` for QEMU-gated adoption work next to
    /// `annex/prism/CHANGELOG.md` for prism-library work gated by host tests
    /// + a cross-build, not QEMU. `trk` has no opinion on what the split IS;
    /// it only guarantees that a task carrying a configured route's tag
    /// graduates to THAT file, in the SAME `archive` run as everything else,
    /// rather than silently landing in `archive_out` because that was the
    /// only destination the tool knew about. Empty when absent — the default
    /// that keeps a single-changelog repo's behavior byte-for-byte unchanged.
    /// See `Cli.resolveDestination`.
    archive_routes: []const ArchiveRoute = &.{},
    /// `add.arcless` — policy when `trk add` mints a task with neither `--in`
    /// nor `--arc`. `false` (default, `"warn"` or absent) prints a warning to
    /// stderr and proceeds; `true` (`"error"`) refuses the add outright. Warn
    /// is the default so a repo with no config behaves exactly as before.
    add_arcless_error: bool = false,
    /// `archive.decision_markers` — the substrings whose presence in a closing
    /// task's body makes `trk archive` REFUSE without
    /// `--allow-buried-decisions`. null → `default_decision_markers`. An empty
    /// JSON array is honored as "disable the check entirely", which is why this
    /// is `?[]const []const u8` and not a slice with an empty default: absent
    /// and empty must mean different things. Arena-owned.
    decision_markers: ?[]const []const u8 = null,
    /// `rule.tag` — the tag `trk rule` removes when it records a ruling (see
    /// `Cli.cmdRule`). null → `default_decision_tag` ("scott-decision"), which
    /// keeps a repo with no config behaving exactly as it does today. Overridable
    /// for the same reason `decision_markers` is: `trk` itself has no opinion on
    /// what a repo calls its "needs a human call" tag, only that `rule` needs to
    /// know the one string to look for. Arena-owned.
    rule_tag: ?[]const u8 = null,
    /// `compact.backup_retain` — how many pre-compact backup runs
    /// `.tracker/backup/` keeps before evicting the oldest (see
    /// `Store.compact`, `evictOldBackups`). Defaults to
    /// `default_backup_retain`; a malformed or missing knob never disables
    /// the safety net it configures.
    backup_retain: usize = default_backup_retain,
};

/// Default `compact.backup_retain` (see `Config.backup_retain`) for a repo
/// with no config file or no `compact` section.
pub const default_backup_retain: usize = 10;

/// Default `rule.tag` (see `Config.rule_tag`) for a repo with no config file
/// or no `rule` section. Shares its literal value with
/// `default_decision_markers[0]` by convention (both name the same tag), but
/// the two knobs are independent — a repo may reconfigure one without the
/// other.
pub const default_decision_tag: []const u8 = "scott-decision";

/// Markers `trk archive` looks for when no `archive.decision_markers` is
/// configured. Matched case-insensitively as substrings of a body line. These
/// are the shapes that carry a DECISION rather than work: archiving flips a
/// task to `archived`, which is hidden from every view, so an open fork living
/// in an otherwise-finished task's body is graduated out of sight along with it
/// (task 01M0QK25Q — measured loss, 2026-08-12).
pub const default_decision_markers: []const []const u8 = &.{
    "scott-decision",
    "OPEN QUESTION",
    "FIX NOTE",
    "your call",
    "TODO",
};

pub const Error = error{
    DependencyCycle,
    /// `T in X` named an `X` that is not a declared arc (`trk arc X` / `trk
    /// add --arc`, or the deprecated `arc:` tag) — see `isArc`'s doc comment
    /// for why this can no longer be inferred from the edge itself. Not
    /// raised for a literal self-membership (`T in T`): that shape is left to
    /// the existing self-loop/cycle rejection regardless of declaration, so a
    /// direct `Store.append` caller doing `x in x` still gets the
    /// pre-existing `DependencyCycle` diagnosis, not this one.
    UndeclaredArc,
    /// `setState claimed` on a task that is not `open` — see
    /// `State.claimRefusal` for the reasons, which the CLI turns into a hint.
    ClaimRequiresOpen,
    /// `setState claimed` without a holder. A lease nobody can be asked about
    /// or release by name is the stranding this exists to prevent.
    HolderRequired,
} || std.mem.Allocator.Error;

/// A `needs` edge in memory.
pub const Needs = model.Needs;
/// An `in` membership edge in memory.
pub const In = model.In;

/// Endpoints of the back-edge that closes a self-wait cycle (see
/// `findSelfWaitCycles`). Just a (from, to) pair — reuses `Needs`'s shape
/// since a report is two ids, regardless of whether the closing edge was a
/// genuine `needs` edge or an `in` membership edge (always reported in its
/// needs-EQUIVALENT direction: arc -> task, i.e. "arc depends on task").
pub const SelfWaitPair = Needs;

/// One log line `Store.load` could not interpret because its `op` is not in
/// this binary's `model.Op` (see `Store.skipped_unknown_ops`).
pub const SkippedOp = struct {
    /// The raw, unrecognized `op` string. gpa-owned; freed in `deinit`.
    op: []const u8,
};

/// One task whose late-merged log events were withheld as provably stale (see
/// `Store.superseded` / `Store.supersededBy`).
pub const Superseded = struct {
    id: Ulid,
    /// How many of that task's events were withheld.
    events: usize,
};

/// One record in the tombstone index (`tombstones_name`): a task that WAS real
/// and that `compact` physically GC'd out of the store. Enough to answer "this
/// id existed, here is what it was, here is why it is gone" — deliberately NOT
/// the whole task: no body, because the index must stay small enough to load on
/// every command, and the body is still recoverable from git history and from
/// `.tracker/backup/`.
pub const Tombstone = struct {
    id: Ulid,
    /// The frozen short id it displayed as, when it had one. Citations in the
    /// corpus are overwhelmingly SHORT ids, so a tombstone that could only be
    /// found by its full 26-char id would miss the case this exists for.
    short: ?[]const u8 = null,
    title: []const u8 = "",
    /// Why it left the live store: `"archived"`, `"dropped"`, `"ghost"`, or
    /// `"unknown"` for a record recovered from history that carried no
    /// `setState` (see `Cli.cmdTombstones`'s rebuild).
    reason: []const u8 = "unknown",
    /// The arcs it was a member of when it was collected. Empty for a recovered
    /// record — a history scan reconstructs tasks, not edges.
    arcs: []const Ulid = &.{},
    /// When `compact` collected it (ms epoch); `0` = unknown (recovered).
    ts: i64 = 0,
    /// `"compact"` — written at the moment of collection — or `"git-history"`,
    /// recovered after the fact by `trk tombstones --rebuild` for an id that was
    /// compacted away before this index existed.
    src: []const u8 = "compact",
};

/// What `Store.lookupTombstone` found for one citation.
pub const TombstoneMatch = union(enum) {
    /// No tombstone matches — genuinely nothing the store has ever heard of.
    none,
    one: *const Tombstone,
    /// The prefix matches this many tombstones; the caller must say so rather
    /// than pick one (same contract as `Cli.resolve`'s `AmbiguousId`).
    ambiguous: usize,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Arena owning all task strings/tags/docrefs/edges — freed wholesale on deinit.
    arena: std.heap.ArenaAllocator,
    io: Io,
    dir: Io.Dir,

    tasks: std.AutoHashMapUnmanaged(Key, Task) = .empty,
    needs: std.ArrayList(Needs) = .empty,
    ins: std.ArrayList(In) = .empty,
    /// Tombstone set for `undep` ops: every (from,to) pair for which an `undep`
    /// has been applied. A `dep` for the same pair is a no-op if this set
    /// contains it, so a tombstone beats a `dep` regardless of fold order (the
    /// union-merge determinism requirement).
    dep_tombstones: std.AutoHashMapUnmanaged([ulid.len * 2]u8, void) = .empty,
    /// Tombstone set for `unin` ops: every (task,arc) pair for which a `unin`
    /// has been applied. Exact mirror of `dep_tombstones` for the `in` edge
    /// kind — an `in` for the same pair is a no-op if this set contains it, so
    /// the tombstone beats an `in` regardless of fold order.
    in_tombstones: std.AutoHashMapUnmanaged([ulid.len * 2]u8, void) = .empty,
    /// Doc-id registry: maps stable doc_id strings to repo-relative paths.
    /// Keys and values are arena-owned. Last-write-wins: a second setDocPath for
    /// the same doc_id replaces the path in the map (old key/value stay in the
    /// arena — cheap and correct since the arena only grows until deinit).
    doc_paths: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Explicitly declared arc roots (`trk arc <id>` / `trk add --arc`), folded
    /// from `arcDeclare` events. A member of this set is an arc even with zero
    /// `in` members — the structural fix for an empty goal that was previously
    /// inexpressible. See `isArc`.
    declared_arcs: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// Standing-arc markers (`trk arc <id> --standing`), folded from
    /// `arcStanding{standing:true}` events. A member is excluded from `next`'s
    /// ready frontier UNCONDITIONALLY, drained or not — see `isStanding` and
    /// `next`.
    standing_arcs: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// Parsed `.tracker/config.json` (defaults when the file is absent). Loaded
    /// by `load` alongside the event fold; best-effort (a malformed file yields
    /// defaults and sets `config_malformed` rather than failing the command).
    config: Config = .{},
    /// True iff a `config.json` was present but could not be parsed as the
    /// expected JSON object. main.zig surfaces a one-line stderr warning; the
    /// command still runs with default config.
    config_malformed: bool = false,
    /// EVERY self-wait cycle found in the loaded log — mediated by `in` (arc
    /// membership), NOT a plain `needs` cycle (those still hard-fail `load`
    /// via `checkAcyclic`). Empty = none found. Set by `load` from
    /// `findSelfWaitCycles`; main.zig surfaces each pair as a one-line
    /// stderr warning, same shape as `config_malformed` — the log still
    /// loads, because refusing would brick a repo the bug already reached
    /// (exactly the state a real repo was found in — see
    /// `findSelfWaitCycles`'s doc). Plural, not `?SelfWaitPair`, because a
    /// log can carry more than one independent stuck pair (e.g. two
    /// unrelated bad merges) — reporting only the first would leave every
    /// OTHER cycled task exactly as silently unreachable as the bug this
    /// mechanism exists to kill. gpa-owned; freed in `deinit`.
    self_wait_cycles: std.ArrayList(SelfWaitPair) = .empty,
    /// EVERY log line `load` skipped because its `op` is not recognized by
    /// this binary (01KYT2QET, 2026-07-30). Empty = none found. `load`
    /// no longer hard-fails on an unrecognized op — a single line carrying a
    /// new op used to brick every not-yet-updated binary's READS, not just
    /// its writes (measured: `trk unin` was unusable on any checkout that
    /// hadn't picked up the new op, for hours, on a single-user machine).
    /// Skipping is the default because it is SAFE for every op that exists
    /// today (see `json_codec.zig`'s file-doc comment) — an old binary that
    /// misses an edge-ADD under-connects (a task looks more blocked than
    /// truth) and one that misses an edge-REMOVE (`undep`/`unin`)
    /// over-connects (same direction: more blocked, never less) — neither
    /// direction can make the old binary see something as falsely ready,
    /// satisfied, or done. A future op whose skip WOULD move that direction
    /// (e.g. it revokes a satisfaction, or deletes a task rather than an
    /// edge) must opt out via `"breaking":true` in its own encode() case
    /// (`json_codec.peekUnknownOp`), which routes `load` to a hard failure
    /// instead of a silent skip for THAT op specifically. Same reporting
    /// shape as `self_wait_cycles`: plural (a log can carry more than one
    /// unrecognized op), collected by `load`/`replayFile`, surfaced by
    /// main.zig as one warning per line, never fatal on its own. The
    /// ArrayList itself is gpa-owned (freed in `deinit`); each `.op` string
    /// is arena-owned (freed wholesale with the rest of the arena).
    skipped_unknown_ops: std.ArrayList(SkippedOp) = .empty,
    /// EVERY task id the fold materialized WITHOUT ever seeing an `add` for it
    /// — a ghost (01M0EJGYH, 2026-08-20). Sorted by id (the task map's
    /// iteration order is not deterministic, and a warning that reorders
    /// between runs is unreadable). Empty = none.
    ///
    /// `ensureNode` tolerates an event that arrives before its `add`, which a
    /// union-merged log legitimately produces; the tolerance is only wrong
    /// once the WHOLE fold is done and no add ever showed up. Measured in the
    /// Enix tracker: two June-era tasks surfaced with empty titles, no tags and
    /// no arcs but a full body, because `compact` GC'd their adds and a stale
    /// worktree then union-merged a lone `setBody` back in — replay rebuilt
    /// each task from that one event and reported nothing. Recovering the
    /// titles took digging the original `add` lines out of git history.
    ///
    /// Same reporting shape as `self_wait_cycles`: collected by `load`,
    /// surfaced by main.zig as one stderr warning per id, never fatal on its
    /// own — the data that IS there stays readable. `compact` is the one verb
    /// that refuses, because compacting a log in this state is what makes the
    /// loss permanent. gpa-owned; freed in `deinit`.
    ghost_tasks: std.ArrayList(Ulid) = .empty,
    /// EVERY log event `load` withheld because it predates its task's snapshot
    /// watermark — one entry per affected TASK (not per event; a resurrection
    /// re-merges whole regions, and a warning per line would be a wall of text
    /// nobody reads), carrying how many of its events were withheld. Empty =
    /// none. Never a silent drop: main.zig warns per entry, and the events are
    /// still in the log for a deliberate re-apply. See `supersededBy`.
    superseded: std.ArrayList(Superseded) = .empty,
    /// The newest `ts` folded so far, across every event. `compact` uses the
    /// per-task `Task.last_ts` rather than this, but a global figure is what
    /// makes "was anything at all timestamped" answerable.
    max_event_ts: i64 = 0,
    /// How many byte-identical duplicate lines the last `load` collapsed in the
    /// log. Purely informational (`apply` is idempotent, so a duplicate line was
    /// always a no-op) — it measures the event-bloat a union-merge resurrection
    /// leaves behind. See `replayFile`.
    deduped_log_lines: usize = 0,
    /// Ids whose round-trip fingerprint diverged across `compact`'s own
    /// rewrite (01M0YESW6 — the last open silent-data-loss class: `compact`
    /// had no post-write self-check against the pre-state). Populated only
    /// when `compact` catches a mismatch, restores the pre-compact
    /// snapshot/log files, and returns `error.CompactVerifyFailed`; empty on
    /// every successful compact. Cleared at the start of every `compact`
    /// call. See `compact`, `fingerprintLiveTasks`. gpa-owned; freed in
    /// `deinit`.
    diverged_on_verify: std.ArrayList(Ulid) = .empty,
    /// The tombstone index, folded from `tombstones_name` by `load` — every
    /// task `compact` physically GC'd (01M2M2K1J). Sorted by id after load so
    /// listings are stable. The ArrayList is gpa-owned (freed in `deinit`);
    /// every string inside it is arena-owned. See `tombstones_name`.
    tombstones: std.ArrayList(Tombstone) = .empty,
    /// id -> index into `tombstones`. Gives O(1) exact lookup, and is how the
    /// fold does last-line-wins (a union-merged index can carry the same id
    /// twice) and how `compact` avoids re-recording an id already entombed.
    tombstone_index: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    /// TEST-ONLY sabotage seam for `compact`'s round-trip self-verify (see
    /// store_test.zig): when set, `serializeState` writes THIS replacement
    /// body into the named id's persisted `add` event while leaving the
    /// in-memory task (and therefore the PRE-compact fingerprint) untouched —
    /// simulating "the write path silently corrupts a live task's content" so
    /// a test can prove the verify catches it. Gated on `builtin.is_test`
    /// (comptime-false in a real build), so the branch that reads it is never
    /// even compiled into a production binary — this field existing costs a
    /// few inert bytes there, nothing else.
    test_sabotage_body: if (builtin.is_test) ?struct { id: Ulid, replacement: []const u8 } else void =
        if (builtin.is_test) null else {},

    /// Open a store rooted at `dir`. Does NOT load — call `load` for that, or
    /// `openAndLoad`. `dir` is borrowed; the caller keeps ownership/closes it.
    pub fn open(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) Store {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .io = io,
            .dir = dir,
        };
    }

    pub fn deinit(self: *Store) void {
        self.tasks.deinit(self.gpa);
        self.needs.deinit(self.gpa);
        self.ins.deinit(self.gpa);
        self.dep_tombstones.deinit(self.gpa);
        self.in_tombstones.deinit(self.gpa);
        self.doc_paths.deinit(self.gpa);
        self.declared_arcs.deinit(self.gpa);
        self.standing_arcs.deinit(self.gpa);
        self.self_wait_cycles.deinit(self.gpa);
        self.ghost_tasks.deinit(self.gpa);
        self.superseded.deinit(self.gpa);
        self.skipped_unknown_ops.deinit(self.gpa);
        self.diverged_on_verify.deinit(self.gpa);
        self.tombstones.deinit(self.gpa);
        self.tombstone_index.deinit(self.gpa);
        self.arena.deinit();
    }

    fn a(self: *Store) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ----------------------------------------------------------------- fold

    /// Get-or-create a task node by id. Out-of-order tolerance: an event that
    /// references an id we haven't `add`ed yet (a `dep`/`in`/`setState` whose
    /// endpoints precede their `add`) creates a **placeholder** node (empty
    /// title, default state). A later `add` fills it in. We tolerate rather than
    /// require add-first because a textual log union-merge can legitimately
    /// interleave lines from two worktrees out of add-order, and rejecting that
    /// would make a merge-safe log unloadable.
    fn ensureNode(self: *Store, id: Ulid) !*Task {
        const gop = try self.tasks.getOrPut(self.gpa, key(id));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = id };
        }
        return gop.value_ptr;
    }

    /// The task id a last-write-wins SCALAR event targets, or null for every
    /// other op. Only these can REVERT a task by arriving late: an edge, tag or
    /// docref event is additive (or a tombstone that wins regardless of order),
    /// so a stale one converges to the same state and must never be withheld —
    /// withholding it would silently drop a lane's real work. See
    /// `supersededBy`.
    fn scalarTarget(ev: Event) ?Ulid {
        return switch (ev) {
            .add => |x| x.id,
            .setState => |x| x.id,
            .setTitle => |x| x.id,
            .setBody => |x| x.id,
            .setPriority => |x| x.id,
            .setShort => |x| x.id,
            .release => |x| x.id,
            else => null,
        };
    }

    /// Non-null iff this event is provably older than the snapshot's own value
    /// for the task it targets — i.e. a resurrection, not new work. Returns the
    /// task id (for reporting).
    ///
    /// The judgment rests on the disjoint-writer rule (design.md "merge
    /// model"): two writers never mutate the SAME task, so for a task the
    /// snapshot already knows, any log event with a `ts` older than that task's
    /// watermark cannot be a concurrent edit — it can only be an event a
    /// `compact` already folded, union-merged back in by a lane whose base
    /// predates it. `ts == 0` (legacy, no timestamp) is never judged, and a task
    /// with no watermark (legacy snapshot, or one written before this existed) is
    /// never judged either — both fall through to the old behavior.
    ///
    /// An id the snapshot does NOT know is deliberately not judged: a GC'd task
    /// and a task that never existed are indistinguishable once compaction has
    /// erased the former, so an event for an unknown id is applied and — if no
    /// `add` ever accompanies it — surfaces through `ghost_tasks` instead.
    fn supersededBy(self: *Store, ev: Event) ?Ulid {
        const ts = model.eventTs(ev);
        if (ts == 0) return null;
        const id = scalarTarget(ev) orelse return null;
        const t = self.tasks.get(key(id)) orelse return null;
        if (t.watermark == 0 or ts >= t.watermark) return null;
        return id;
    }

    /// Track the newest `ts` seen, globally and per task, so `compact` can stamp
    /// each task's watermark. Runs for every applied event, replay and append
    /// alike.
    fn noteTs(self: *Store, ev: Event) !void {
        const ts = model.eventTs(ev);
        if (ts == 0) return;
        if (ts > self.max_event_ts) self.max_event_ts = ts;
        const id = switch (ev) {
            .add => |x| x.id,
            .setState => |x| x.id,
            .setTitle => |x| x.id,
            .setBody => |x| x.id,
            .setPriority => |x| x.id,
            .setShort => |x| x.id,
            .release => |x| x.id,
            .tag => |x| x.id,
            .untag => |x| x.id,
            .docref => |x| x.id,
            .undocref => |x| x.id,
            .arcDeclare => |x| x.id,
            .arcStanding => |x| x.id,
            // An edge event touches two tasks, but the watermark only ever gates
            // SCALAR ops (see `scalarTarget`), so stamping either endpoint would
            // raise a bar nothing checks. Left alone deliberately.
            .dep, .undep, .in, .unin, .setDocPath => return,
        };
        const t = try self.ensureNode(id);
        if (ts > t.last_ts) t.last_ts = ts;
    }

    /// Apply one event to in-memory state. Idempotent where the doc requires:
    /// re-applying `add`/`setState`/`setPriority` for the same id converges to
    /// the same value; a duplicate `dep`/`in`/`tag`/`docref` is de-duplicated so
    /// replaying a log twice is a no-op.
    pub fn apply(self: *Store, ev: Event) !void {
        try self.noteTs(ev);
        switch (ev) {
            .add => |x| {
                const t = try self.ensureNode(x.id);
                t.has_add = true; // no longer a placeholder — see `ghost_tasks`
                // A snapshot `add` carries the task's watermark; a log `add`
                // never does (`wm` defaults to 0), so this only ever tightens.
                if (x.wm > t.watermark) t.watermark = x.wm;
                // Last add wins for scalar fields (idempotent for a replay; a
                // genuine re-add with new text is a deliberate overwrite).
                t.title = try self.a().dupe(u8, x.title);
                t.body = try self.a().dupe(u8, x.body);
                // Reset tags to exactly the add's set (idempotent on replay).
                t.tags = .empty;
                for (x.tags) |tg| try t.tags.append(self.a(), try self.a().dupe(u8, tg));
                // Freeze the short id carried on this add (mint time, or a
                // compact's re-canonicalized add carrying the already-frozen
                // value forward). null means "never frozen" — display falls
                // back to the dynamic computation. See `Task.short`.
                t.short = if (x.short) |s| try self.a().dupe(u8, s) else null;
            },
            .setState => |x| {
                const t = try self.ensureNode(x.id);
                if (x.state == .claimed) {
                    // A lease only ever takes OPEN work. Reaching anything else
                    // means a merge delivered it after the task moved on (a
                    // lane's submission, a close) — the lease is stale.
                    if (t.state != .open) return;
                    t.holder = if (x.holder) |h| try self.a().dupe(u8, h) else null;
                    t.lease_ts = x.ts;
                } else {
                    t.holder = null;
                    t.lease_ts = 0;
                }
                t.state = x.state;
            },
            .release => |x| {
                const t = try self.ensureNode(x.id);
                if (t.state != .claimed) return;
                const h = t.holder orelse return;
                if (!std.mem.eql(u8, h, x.holder)) return;
                t.state = .open;
                t.holder = null;
                t.lease_ts = 0;
            },
            .setPriority => |x| {
                const t = try self.ensureNode(x.id);
                t.priority = x.priority;
            },
            .tag => |x| {
                const t = try self.ensureNode(x.id);
                for (t.tags.items) |existing| {
                    if (std.mem.eql(u8, existing, x.tag)) return; // dedup
                }
                try t.tags.append(self.a(), try self.a().dupe(u8, x.tag));
            },
            .docref => |x| {
                const t = try self.ensureNode(x.id);
                for (t.docrefs.items) |dr| {
                    const same_doc = std.mem.eql(u8, dr.doc_id, x.doc_id);
                    const same_sec = (dr.section_id == null and x.section_id == null) or
                        (dr.section_id != null and x.section_id != null and
                            std.mem.eql(u8, dr.section_id.?, x.section_id.?));
                    if (same_doc and same_sec) return; // dedup
                }
                try t.docrefs.append(self.a(), .{
                    .doc_id = try self.a().dupe(u8, x.doc_id),
                    .section_id = if (x.section_id) |s| try self.a().dupe(u8, s) else null,
                });
            },
            .dep => |x| {
                _ = try self.ensureNode(x.from);
                _ = try self.ensureNode(x.to);
                // Tombstone check: if an `undep` for this edge exists (in any
                // fold-order position), the edge stays absent — tombstone beats add.
                if (self.dep_tombstones.contains(edgeKey(x.from, x.to))) return;
                for (self.needs.items) |e| {
                    if (e.from.eql(x.from) and e.to.eql(x.to)) return; // dedup
                }
                try self.needs.append(self.gpa, .{ .from = x.from, .to = x.to });
            },
            .in => |x| {
                _ = try self.ensureNode(x.task);
                _ = try self.ensureNode(x.arc);
                // Tombstone check: if a `unin` for this edge exists (in any
                // fold-order position), the edge stays absent — tombstone beats
                // add (exact mirror of `dep`'s tombstone check above).
                if (self.in_tombstones.contains(edgeKey(x.task, x.arc))) return;
                // An `in` (task,arc) pair is a set member; a repeat updates seq
                // (last-write-wins on the priority attribute, idempotent on replay).
                for (self.ins.items) |*e| {
                    if (e.task.eql(x.task) and e.arc.eql(x.arc)) {
                        e.seq = x.seq;
                        return;
                    }
                }
                try self.ins.append(self.gpa, .{ .task = x.task, .arc = x.arc, .seq = x.seq });
            },
            .setDocPath => |x| {
                // Empty path = tombstone (`trk doc unset`): remove the mapping so
                // docPath/list see it as never-registered. Same last-write-wins
                // fold as a set; serializeState simply never emits a removed
                // entry, so compaction GCs the tombstone for free.
                if (x.path.len == 0) {
                    _ = self.doc_paths.remove(x.doc_id);
                    return;
                }
                // Last-write-wins: dup both key and value into the arena each time.
                // The old arena strings are never freed (arena-only), which is fine.
                const k = try self.a().dupe(u8, x.doc_id);
                const v = try self.a().dupe(u8, x.path);
                try self.doc_paths.put(self.gpa, k, v);
            },
            .setTitle => |x| {
                const t = try self.ensureNode(x.id);
                t.title = try self.a().dupe(u8, x.title);
            },
            .setBody => |x| {
                const t = try self.ensureNode(x.id);
                t.body = try self.a().dupe(u8, x.body);
            },
            .untag => |x| {
                const t = try self.ensureNode(x.id);
                // Find and remove the tag if present. Shift-remove to preserve order.
                var idx: ?usize = null;
                for (t.tags.items, 0..) |tg, i| {
                    if (std.mem.eql(u8, tg, x.tag)) {
                        idx = i;
                        break;
                    }
                }
                if (idx) |i| _ = t.tags.orderedRemove(i);
            },
            .undocref => |x| {
                const t = try self.ensureNode(x.id);
                // Remove EVERY ref to this doc_id, section or not. The removal
                // verb takes a doc id (the caller cannot always know which
                // sections got attached), and a task's refs to one doc differ
                // only by section — so "drop the ref to this doc" is the whole
                // operation. Shift-remove back-to-front to keep order stable.
                var i = t.docrefs.items.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, t.docrefs.items[i].doc_id, x.doc_id))
                        _ = t.docrefs.orderedRemove(i);
                }
            },
            .undep => |x| {
                // Record the tombstone so a later `dep` for the same edge (in
                // union-merge order) is blocked. This makes the tombstone win
                // regardless of which event appears first in the merged log.
                try self.dep_tombstones.put(self.gpa, edgeKey(x.from, x.to), {});
                // Also remove the edge if it is already present in the needs list
                // (handles the case where the `dep` precedes the `undep` in fold order).
                var idx: ?usize = null;
                for (self.needs.items, 0..) |e, i| {
                    if (e.from.eql(x.from) and e.to.eql(x.to)) {
                        idx = i;
                        break;
                    }
                }
                if (idx) |i| _ = self.needs.orderedRemove(i);
            },
            .unin => |x| {
                // Exact mirror of `undep`, for the `in` edge kind: record the
                // tombstone (so a later `in` for the same pair, in union-merge
                // order, is blocked regardless of append order), then also
                // remove the edge if already present (handles the case where
                // the `in` precedes the `unin` in fold order).
                try self.in_tombstones.put(self.gpa, edgeKey(x.task, x.arc), {});
                var idx: ?usize = null;
                for (self.ins.items, 0..) |e, i| {
                    if (e.task.eql(x.task) and e.arc.eql(x.arc)) {
                        idx = i;
                        break;
                    }
                }
                if (idx) |i| _ = self.ins.orderedRemove(i);
            },
            .arcDeclare => |x| {
                // Out-of-order tolerance like dep/in: a declare for an id we
                // haven't `add`ed yet creates the placeholder.
                _ = try self.ensureNode(x.id);
                if (x.declared) {
                    try self.declared_arcs.put(self.gpa, key(x.id), {});
                } else {
                    _ = self.declared_arcs.remove(key(x.id));
                }
            },
            .arcStanding => |x| {
                // Out-of-order tolerance like arcDeclare/dep/in.
                _ = try self.ensureNode(x.id);
                if (x.standing) {
                    try self.standing_arcs.put(self.gpa, key(x.id), {});
                } else {
                    _ = self.standing_arcs.remove(key(x.id));
                }
            },
            .setShort => |x| {
                const t = try self.ensureNode(x.id);
                t.short = try self.a().dupe(u8, x.short);
            },
        }
    }

    /// Replay snapshot (if present) then the log, then verify the DAG invariant.
    /// A cycle anywhere in the folded `needs` set is a loud `error.DependencyCycle`
    /// — re-checked here (not only on append) because a merge could introduce a
    /// cycle neither side had.
    ///
    /// A self-wait cycle mediated by `in` (arc membership) — e.g. a task that
    /// `needs` its own arc — is a DIFFERENT case: `append` refuses to ever
    /// CREATE one going forward (`combinedReaches`, below), but a log that
    /// predates this check, or was hand-edited/badly merged, may already
    /// carry one. Refusing to load it would brick an already-affected repo,
    /// which is strictly worse than the bug (a real repo was found in
    /// exactly this state — see `docs/design.md` "Arc-as-prereq"). So this
    /// is a WARNING, not a load failure: EVERY such pair found is collected
    /// into `self_wait_cycles` and surfaced by main.zig; `load` still
    /// succeeds. Union-merge is exactly why this must run at load time and
    /// not only at append time: two parallel worktrees can each append an
    /// edge that is individually acyclic from that writer's own local view
    /// (one adds `t needs arc`, the other adds `t in arc`, neither sees the
    /// other's edge) — `append`'s incremental gate cannot catch a cycle
    /// that only exists in the UNION of two logs neither writer held
    /// locally; the full rescan here is the check that cannot be evaded by
    /// that race (see store_test.zig's union-merge self-wait test).
    ///
    /// A line whose `op` is not in THIS binary's `model.Op` is likewise
    /// non-fatal by default (01KYT2QET) — skipped and collected into
    /// `skipped_unknown_ops` for main.zig to warn about, rather than failing
    /// the whole load. See that field's doc comment for the safety argument
    /// and the `"breaking"` escape hatch a future op can opt into.
    pub fn load(self: *Store) !void {
        // Reset before replay: `load` is safe to call more than once on a
        // live Store (tests do), and this must not accumulate stale entries
        // from a prior fold. `replayFile` populates it as it goes, unlike
        // `self_wait_cycles` (computed in one pass AFTER replay), so it's
        // cleared here rather than alongside that reset below.
        self.skipped_unknown_ops.clearRetainingCapacity();
        self.superseded.clearRetainingCapacity();
        self.deduped_log_lines = 0;
        try self.replayFile(snapshot_name, false);
        try self.replayFile(log_name, true);
        try self.checkAcyclic();
        try self.collectGhostTasks();
        // Reset before recomputing: `load` is safe to call more than once on
        // a live Store (tests do), and the list must not accumulate stale
        // pairs from a prior fold.
        self.self_wait_cycles.clearRetainingCapacity();
        try self.findSelfWaitCycles(&self.self_wait_cycles);
        self.loadConfig();
        try self.loadTombstones();
    }

    /// Fold `.tracker/tombstones.jsonl` into `self.tombstones` (01M2M2K1J).
    ///
    /// Best-effort in the same sense as `loadConfig`: an absent file is the
    /// normal state of a store that has never compacted, and a line this binary
    /// cannot parse is SKIPPED rather than failing the load — the index is a
    /// recovery aid, and a verb must never become unrunnable because one
    /// tombstone line is malformed. Losing a line costs a resolvable citation;
    /// failing the load costs the whole tracker.
    ///
    /// Last line wins per id: the file is union-merged, so the same id can
    /// legitimately appear twice (two branches each compacted it), and a
    /// `--rebuild` record can be superseded by a real one.
    pub fn loadTombstones(self: *Store) !void {
        self.tombstones.clearRetainingCapacity();
        self.tombstone_index.clearRetainingCapacity();

        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch return;
        defer sub.close(self.io);
        const bytes = sub.readFileAlloc(self.io, tombstones_name, self.gpa, .unlimited) catch return;
        defer self.gpa.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const t = self.parseTombstone(line) catch continue orelse continue;
            const gop = try self.tombstone_index.getOrPut(self.gpa, key(t.id));
            if (gop.found_existing) {
                self.tombstones.items[gop.value_ptr.*] = t;
            } else {
                gop.value_ptr.* = self.tombstones.items.len;
                try self.tombstones.append(self.gpa, t);
            }
        }

        std.sort.pdq(Tombstone, self.tombstones.items, {}, tombstoneLessThan);
        // The sort moved rows, so every index in the map is now wrong. Rebuild
        // it from the sorted order rather than sorting a parallel structure —
        // a stale index here would silently resolve one id to another's record,
        // which is a worse failure than the one this whole file exists to fix.
        self.tombstone_index.clearRetainingCapacity();
        for (self.tombstones.items, 0..) |t, i|
            try self.tombstone_index.put(self.gpa, key(t.id), i);
    }

    fn tombstoneLessThan(_: void, lhs: Tombstone, rhs: Tombstone) bool {
        return std.mem.lessThan(u8, &lhs.id.text, &rhs.id.text);
    }

    /// Decode one tombstone line. Returns null (not an error) for a line that
    /// parses as JSON but is not a tombstone — the file's own forward-compat
    /// slack, mirroring `json_codec`'s unknown-op contract. Strings are
    /// arena-dup'd so they outlive the parse tree.
    fn parseTombstone(self: *Store, line: []const u8) !?Tombstone {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, line, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const op = switch (root.get("op") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (!std.mem.eql(u8, op, "tombstone")) return null;
        const id_s = switch (root.get("id") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        const id = ulid.parse(id_s) catch return null;

        var t: Tombstone = .{ .id = id };
        if (root.get("short")) |v| switch (v) {
            .string => |s| t.short = try self.a().dupe(u8, s),
            else => {},
        };
        if (root.get("title")) |v| switch (v) {
            .string => |s| t.title = try self.a().dupe(u8, s),
            else => {},
        };
        if (root.get("reason")) |v| switch (v) {
            .string => |s| t.reason = try self.a().dupe(u8, s),
            else => {},
        };
        if (root.get("src")) |v| switch (v) {
            .string => |s| t.src = try self.a().dupe(u8, s),
            else => {},
        };
        if (root.get("ts")) |v| switch (v) {
            .integer => |n| t.ts = n,
            else => {},
        };
        if (root.get("arcs")) |v| switch (v) {
            .array => |arr| {
                var arcs: std.ArrayList(Ulid) = .empty;
                for (arr.items) |el| switch (el) {
                    .string => |s| try arcs.append(self.a(), ulid.parse(s) catch continue),
                    else => {},
                };
                t.arcs = arcs.items;
            },
            else => {},
        };
        return t;
    }

    /// Resolve a citation against the tombstone index — the dead half of
    /// `Cli.resolve`. Accepts a full id, a frozen short id, or any prefix of
    /// either, case-insensitively, so it answers for exactly the citation
    /// shapes the live resolver accepts.
    ///
    /// Never consulted BEFORE the live store: a live task and a tombstone for
    /// the same id cannot coexist (compact only entombs what it removes), but
    /// the ordering keeps that a property of the caller rather than a thing to
    /// trust, and keeps the common path free of this lookup entirely.
    pub fn lookupTombstone(self: *const Store, s: []const u8) TombstoneMatch {
        if (s.len == 0) return .none;
        var found: ?*const Tombstone = null;
        var n: usize = 0;
        for (self.tombstones.items) |*t| {
            const hit = citationMatches(s, &t.id.text) or
                (t.short != null and citationMatches(s, t.short.?));
            if (!hit) continue;
            n += 1;
            if (found == null) found = t;
        }
        if (n == 0) return .none;
        if (n > 1) return .{ .ambiguous = n };
        return .{ .one = found.? };
    }

    /// Every tombstone naming `arc` among its memberships: the GRADUATED
    /// members of an arc (01M29P5T7).
    ///
    /// This is the only arc-membership fact that survives compaction, and it
    /// exists solely because `compact` writes the index BEFORE its destructive
    /// rewrite. `serializeState` drops every `in` edge with a collectable
    /// endpoint (its `gc_set`), so once an arc's members are collected the live
    /// store holds no edge connecting them to it at all — and every view that
    /// enumerates `ins` renders a fully-built arc exactly like one that was
    /// never sliced. That is the asymmetry this closes: `show` on a collected
    /// id at least answered COMPACTED, while `tree` on its arc answered with a
    /// well-formed, entirely unremarkable empty tree.
    ///
    /// Returns pointers INTO `self.tombstones`, valid until the next
    /// `loadTombstones`; the slice itself is caller-owned. Order is the index's
    /// own (ascending id = mint order), inherited from the sort in
    /// `loadTombstones` — a filtered scan of a sorted list is still sorted.
    pub fn compactedMembers(self: *const Store, gpa: std.mem.Allocator, arc: Ulid) ![]const *const Tombstone {
        var out: std.ArrayList(*const Tombstone) = .empty;
        errdefer out.deinit(gpa);
        for (self.tombstones.items) |*t| {
            for (t.arcs) |member_of| {
                if (!member_of.eql(arc)) continue;
                try out.append(gpa, t);
                break;
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Case-insensitive "is `pfx` a prefix of `text`" (ids are upper-case
    /// canonical Crockford). Same rule as `Cli.prefixMatches`; duplicated here
    /// rather than shared because the store must not depend on the CLI.
    pub fn citationMatches(pfx: []const u8, text: []const u8) bool {
        if (pfx.len > text.len) return false;
        for (pfx, text[0..pfx.len]) |p, c| {
            if (std.ascii.toUpper(p) != std.ascii.toUpper(c)) return false;
        }
        return true;
    }

    /// Append one tombstone line for `t` to `buf` (hand-rolled JSON,
    /// deterministic key order — same rule as the event codec).
    pub fn emitTombstone(self: *Store, buf: *std.ArrayList(u8), t: Tombstone) !void {
        try buf.appendSlice(self.gpa, "{\"op\":\"tombstone\",\"id\":\"");
        try buf.appendSlice(self.gpa, &t.id.text);
        try buf.appendSlice(self.gpa, "\",\"short\":");
        if (t.short) |s| try codec.writeJsonString(buf, self.gpa, s) else try buf.appendSlice(self.gpa, "null");
        try buf.appendSlice(self.gpa, ",\"title\":");
        try codec.writeJsonString(buf, self.gpa, t.title);
        try buf.appendSlice(self.gpa, ",\"reason\":");
        try codec.writeJsonString(buf, self.gpa, t.reason);
        try buf.appendSlice(self.gpa, ",\"arcs\":[");
        for (t.arcs, 0..) |arc, i| {
            if (i != 0) try buf.append(self.gpa, ',');
            try buf.append(self.gpa, '"');
            try buf.appendSlice(self.gpa, &arc.text);
            try buf.append(self.gpa, '"');
        }
        try buf.appendSlice(self.gpa, "],\"src\":");
        try codec.writeJsonString(buf, self.gpa, t.src);
        try buf.print(self.gpa, ",\"ts\":{d}}}\n", .{t.ts});
    }

    /// Append `rows` to `.tracker/tombstones.jsonl`. Returns how many lines were
    /// written. The append is a read-modify-atomicWrite (same shape as
    /// `quarantineGhosts`) so a crash cannot leave a half-line behind.
    ///
    /// An id already in the index is skipped — UNLESS the new row strictly
    /// improves the record (`supersedes`). That exception is what lets a fix to
    /// the reconstruction reach a store that already ran the old one
    /// (01M2V2TYC): `--rebuild` is idempotent by id, so without it the 2521
    /// membership-less records this file's fix exists to repair would stay
    /// membership-less forever, and the fix would only ever help stores that
    /// had never been rebuilt. `loadTombstones` is last-line-wins per id, so an
    /// appended better record simply supersedes the earlier one on the next
    /// fold; nothing is rewritten in place.
    pub const TombstoneWrite = struct {
        /// Ids the index had never heard of.
        new: usize = 0,
        /// Ids already on record whose row this call improved (`supersedes`).
        upgraded: usize = 0,

        pub fn total(w: TombstoneWrite) usize {
            return w.new + w.upgraded;
        }
    };

    pub fn appendTombstones(self: *Store, sub: Io.Dir, rows: []const Tombstone) !TombstoneWrite {
        if (rows.len == 0) return .{};

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const existing = sub.readFileAlloc(self.io, tombstones_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => try self.gpa.dupe(u8, ""),
            else => return e,
        };
        defer self.gpa.free(existing);
        try out.appendSlice(self.gpa, existing);
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n')
            try out.append(self.gpa, '\n');

        var w: TombstoneWrite = .{};
        for (rows) |t| {
            if (self.tombstone_index.get(key(t.id))) |idx| {
                if (!supersedes(t, self.tombstones.items[idx])) continue;
                w.upgraded += 1;
            } else {
                w.new += 1;
            }
            try self.emitTombstone(&out, t);
        }
        if (w.total() == 0) return w;
        try self.atomicWrite(sub, tombstones_name, out.items);
        return w;
    }

    /// Is `new` a strictly better record for this id than `old`? Only two ways,
    /// both of them "a reconstruction is being replaced by something that knows
    /// more":
    ///   * `old` came from `git-history` and `new` from `compact` — the latter
    ///     was written at the moment of collection, from the live store, and is
    ///     authoritative about state, arcs and time;
    ///   * both are reconstructions, and `new` recovered arc memberships that
    ///     `old` has none of (01M2V2TYC — the old scan recovered title and
    ///     end-state but never read the `in` edges).
    /// A `compact`-sourced record is NEVER overwritten by a reconstruction, and
    /// nothing is overwritten merely for being newer: an equal-or-worse row is
    /// dropped, so re-running `--rebuild` stays a no-op once it has nothing to
    /// add.
    fn supersedes(new: Tombstone, old: Tombstone) bool {
        const old_recovered = std.mem.eql(u8, old.src, "git-history");
        if (!old_recovered) return false;
        if (std.mem.eql(u8, new.src, "compact")) return true;
        return old.arcs.len == 0 and new.arcs.len > 0;
    }

    /// After the WHOLE fold: every node that never received an `add` is a ghost
    /// (see `ghost_tasks`). Sorted by id so the warning order is stable across
    /// runs — the task map's iteration order is not.
    pub fn collectGhostTasks(self: *Store) !void {
        self.ghost_tasks.clearRetainingCapacity();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.has_add) try self.ghost_tasks.append(self.gpa, entry.value_ptr.id);
        }
        std.sort.pdq(Ulid, self.ghost_tasks.items, {}, Ulid.lessThan);
    }

    /// Read `.tracker/config.json` into `self.config`. Best-effort and never
    /// fatal: an absent file (or no `.tracker/` yet) leaves the defaults; a file
    /// present but unparseable sets `config_malformed` and still leaves defaults,
    /// so a broken config can never block a mutating command. Strings are dup'd
    /// into the store arena so they outlive the parse tree.
    pub fn loadConfig(self: *Store) void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch return;
        defer sub.close(self.io);
        const bytes = sub.readFileAlloc(self.io, config_name, self.gpa, .unlimited) catch return;
        defer self.gpa.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch {
            self.config_malformed = true;
            return;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => {
                self.config_malformed = true;
                return;
            },
        };
        self.config.render_out = self.readNestedOut(root, "render");
        self.config.archive_out = self.readNestedOut(root, "archive");
        self.config.archive_routes = self.readArchiveRoutes(root);
        self.config.add_arcless_error = self.readAddArclessError(root);
        self.config.decision_markers = self.readDecisionMarkers(root);
        self.config.rule_tag = self.readRuleTag(root);
        self.config.backup_retain = self.readBackupRetain(root);
    }

    /// Pull `compact.backup_retain` (a non-negative integer) from the config
    /// root. Returns `default_backup_retain` for a missing section/key, a
    /// non-integer value, or a negative one — a malformed knob must never
    /// silently disable the pre-compact backup it configures.
    fn readBackupRetain(_: *Store, root: std.json.ObjectMap) usize {
        const sv = root.get("compact") orelse return default_backup_retain;
        const so = switch (sv) {
            .object => |o| o,
            else => return default_backup_retain,
        };
        const rv = so.get("backup_retain") orelse return default_backup_retain;
        const n = switch (rv) {
            .integer => |i| i,
            else => return default_backup_retain,
        };
        if (n < 0) return default_backup_retain;
        return @intCast(n);
    }

    /// Pull `archive.decision_markers` (an array of strings) from the config
    /// root, arena-dup'd. Returns null — meaning "use the built-in default set"
    /// — when the section, the key, or its array type is absent. An explicitly
    /// EMPTY array returns an empty slice, which disables the check; that is a
    /// deliberate, spellable opt-out and must not collapse into the default.
    /// Non-string elements are skipped rather than failing the load, matching
    /// every other reader here (a broken config never blocks a command).
    fn readDecisionMarkers(self: *Store, root: std.json.ObjectMap) ?[]const []const u8 {
        const sv = root.get("archive") orelse return null;
        const so = switch (sv) {
            .object => |o| o,
            else => return null,
        };
        const av = so.get("decision_markers") orelse return null;
        const arr = switch (av) {
            .array => |arr_val| arr_val,
            else => return null,
        };
        var out: std.ArrayList([]const u8) = .empty;
        for (arr.items) |item| {
            const str = switch (item) {
                .string => |x| x,
                else => continue,
            };
            const dup = self.a().dupe(u8, str) catch return null;
            out.append(self.a(), dup) catch return null;
        }
        return out.toOwnedSlice(self.a()) catch null;
    }

    /// Pull `archive.routes` (a JSON object `{ "<tag>": "<path>", ... }`) from
    /// the config root, arena-dup'd. Absent section/key, or a non-object
    /// value, yields an empty slice — the "no extra destinations configured"
    /// default that keeps a single-changelog repo's behavior unchanged. A
    /// non-string value for a given tag is skipped rather than failing the
    /// whole load, matching every other reader here (a broken config entry
    /// never blocks a command; it just doesn't route that one tag).
    fn readArchiveRoutes(self: *Store, root: std.json.ObjectMap) []const ArchiveRoute {
        const sv = root.get("archive") orelse return &.{};
        const so = switch (sv) {
            .object => |o| o,
            else => return &.{},
        };
        const rv = so.get("routes") orelse return &.{};
        const ro = switch (rv) {
            .object => |o| o,
            else => return &.{},
        };
        var out: std.ArrayList(ArchiveRoute) = .empty;
        var it = ro.iterator();
        while (it.next()) |entry| {
            const path = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            const tag_dup = self.a().dupe(u8, entry.key_ptr.*) catch return &.{};
            const path_dup = self.a().dupe(u8, path) catch return &.{};
            out.append(self.a(), .{ .tag = tag_dup, .out = path_dup }) catch return &.{};
        }
        return out.toOwnedSlice(self.a()) catch &.{};
    }

    /// Pull `add.arcless` (a string, `"warn"` or `"error"`) from the config
    /// root. Returns `false` (warn) for a missing section/key, a non-string
    /// value, or any string other than exactly `"error"` — so a typo degrades
    /// to the safe default rather than silently hard-erroring every add.
    fn readAddArclessError(_: *Store, root: std.json.ObjectMap) bool {
        const sv = root.get("add") orelse return false;
        const so = switch (sv) {
            .object => |o| o,
            else => return false,
        };
        const ov = so.get("arcless") orelse return false;
        const s = switch (ov) {
            .string => |str| str,
            else => return false,
        };
        return std.mem.eql(u8, s, "error");
    }

    /// Pull `rule.tag` (a string) from the config root, arena-dup'd. Returns
    /// null — meaning "use `default_decision_tag`" — when the `rule` section,
    /// the `tag` key, or its string type is absent. Mirrors `readDecisionMarkers`
    /// (absent -> default) rather than `readNestedOut` (absent -> stdout): there
    /// is no "unset" behavior for `rule` to fall back to other than the default
    /// tag, so null and "not configured" mean the same thing here.
    fn readRuleTag(self: *Store, root: std.json.ObjectMap) ?[]const u8 {
        const sv = root.get("rule") orelse return null;
        const so = switch (sv) {
            .object => |o| o,
            else => return null,
        };
        const tv = so.get("tag") orelse return null;
        const s = switch (tv) {
            .string => |str| str,
            else => return null,
        };
        return self.a().dupe(u8, s) catch null;
    }

    /// Pull `<section>.out` (a string) from the config root, arena-dup'd. Returns
    /// null when the section, the `out` key, or its string type is absent — a
    /// `null` JSON value or a missing key both mean "unset" (fall back to stdout).
    fn readNestedOut(self: *Store, root: std.json.ObjectMap, section: []const u8) ?[]const u8 {
        const sv = root.get(section) orelse return null;
        const so = switch (sv) {
            .object => |o| o,
            else => return null,
        };
        const ov = so.get("out") orelse return null;
        const s = switch (ov) {
            .string => |str| str,
            else => return null,
        };
        return self.a().dupe(u8, s) catch null;
    }

    /// One decoded line, held so the whole file can be ORDERED before any of it
    /// is applied. `idx` is the original file position, which makes the sort a
    /// total order — a ts tie replays in file order, and no stable sort is
    /// needed to get a deterministic fold.
    const Pending = struct {
        ev: Event,
        ts: i64,
        idx: usize,

        fn less(_: void, x: Pending, y: Pending) bool {
            if (x.ts != y.ts) return x.ts < y.ts;
            return x.idx < y.idx;
        }
    };

    /// Replay one file. `reorder` = fold it by `ts` (ties in file order) and
    /// drop byte-identical duplicate lines first, instead of straight file order.
    ///
    /// The log gets `reorder`; the snapshot does NOT. `log.jsonl` is union-merged
    /// by git (`merge=union`), which concatenates two writers' regions in
    /// whatever order the driver picks — so file order there is not chronological
    /// order, while every event already carries the `ts` that is. Folding in file
    /// order let a merge decide which of two `setTitle`s won, and let a lane's
    /// resurrected pre-compact events land after the state that superseded them
    /// (01M0EJGYH). `snapshot.jsonl` is a whole-file baseline written only by a
    /// serialized `compact` and never union-merged, so its file order IS its
    /// authored order — reordering it would only risk disturbing the canonical
    /// add-before-edges sequence `serializeState` emits.
    ///
    /// This does not make every merge artifact self-healing: an event that a
    /// compact already folded into the snapshot, then resurrected by a stale
    /// lane, still applies after the snapshot no matter how old its `ts` is,
    /// because the snapshot carries no watermark to compare it against. What
    /// this buys is that the fold no longer depends on the merge driver's line
    /// order — the same set of events lands in the same state every time.
    fn replayFile(self: *Store, name: []const u8, reorder: bool) !void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return, // no store yet -> empty fold
            else => return e,
        };
        defer sub.close(self.io);

        const bytes = sub.readFileAlloc(self.io, name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.gpa.free(bytes);

        // Held only when reordering; each entry owns codec-dup'd strings until
        // it is applied and freed below.
        var pending: std.ArrayList(Pending) = .empty;
        defer {
            for (pending.items) |p| freeEvent(self.gpa, p.ev);
            pending.deinit(self.gpa);
        }
        // Byte-identical lines seen so far. Keys borrow `bytes`, which outlives
        // this set (freed by the defer above it).
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        var idx: usize = 0;
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (reorder) {
                const gop = try seen.getOrPut(self.gpa, trimmed);
                if (gop.found_existing) {
                    // A union-merge resurrection re-concatenates whole regions
                    // of an already-folded log; the copies are byte-identical
                    // (same ts included), so collapsing them is a no-op that
                    // costs nothing and keeps the fold's cost linear in the
                    // DISTINCT event count.
                    self.deduped_log_lines += 1;
                    continue;
                }
            }
            const maybe_ev = codec.decode(self.gpa, trimmed);
            if (maybe_ev) |ev| {
                if (reorder) {
                    pending.append(self.gpa, .{
                        .ev = ev,
                        .ts = model.eventTs(ev),
                        .idx = idx,
                    }) catch |e| {
                        freeEvent(self.gpa, ev);
                        return e;
                    };
                    idx += 1;
                } else {
                    // Free the codec's gpa-dup'd transient strings after apply
                    // re-dups into the arena.
                    defer freeEvent(self.gpa, ev);
                    try self.apply(ev);
                }
            } else |e| {
                // An unrecognized op is skip-and-warn by default, not fatal —
                // see `skipped_unknown_ops`'s doc comment for why. Any OTHER
                // decode failure on this line (bad JSON, a known op missing a
                // required field, ...) is a genuinely corrupt line, not a
                // forward-compat gap, and stays fatal exactly as before.
                if (e != error.UnknownOp) return e;
                if (try self.recordSkippedUnknownOp(trimmed)) continue;
                return e;
            }
        }

        if (reorder) {
            std.sort.pdq(Pending, pending.items, {}, Pending.less);
            for (pending.items) |p| {
                if (self.supersededBy(p.ev)) |id| {
                    try self.noteSuperseded(id);
                    continue;
                }
                try self.apply(p.ev);
            }
        }
    }

    /// Record (or bump the count of) a task whose stale event was withheld.
    fn noteSuperseded(self: *Store, id: Ulid) !void {
        for (self.superseded.items) |*sd| {
            if (sd.id.eql(id)) {
                sd.events += 1;
                return;
            }
        }
        try self.superseded.append(self.gpa, .{ .id = id, .events = 1 });
    }

    /// Handles one line whose `op` is unrecognized (`codec.decode` returned
    /// `error.UnknownOp` on it). Peeks the raw line for the op name + the
    /// `"breaking"` escape hatch (`codec.peekUnknownOp`): if the writer
    /// marked it breaking, returns `false` so the caller propagates the
    /// fatal error unchanged; otherwise records it into
    /// `skipped_unknown_ops` (for main.zig to warn about) and returns `true`
    /// so the caller skips the line and keeps loading. If the line somehow
    /// doesn't even peek cleanly (shouldn't happen for a line `decode` got as
    /// far as `UnknownOp` on), errs toward safety and treats it as breaking.
    fn recordSkippedUnknownOp(self: *Store, line: []const u8) !bool {
        const info = (try codec.peekUnknownOp(self.gpa, line)) orelse return false;
        defer self.gpa.free(info.op);
        if (info.breaking) return false;
        try self.skipped_unknown_ops.append(self.gpa, .{ .op = try self.a().dupe(u8, info.op) });
        return true;
    }

    pub fn freeEvent(gpa: std.mem.Allocator, ev: Event) void {
        switch (ev) {
            .add => |x| {
                gpa.free(x.title);
                gpa.free(x.body);
                for (x.tags) |t| gpa.free(t);
                gpa.free(x.tags);
                if (x.short) |s| gpa.free(s);
            },
            .tag => |x| gpa.free(x.tag),
            .docref => |x| {
                gpa.free(x.doc_id);
                if (x.section_id) |s| gpa.free(s);
            },
            .setDocPath => |x| {
                gpa.free(x.doc_id);
                gpa.free(x.path);
            },
            .setTitle => |x| gpa.free(x.title),
            .setBody => |x| gpa.free(x.body),
            .untag => |x| gpa.free(x.tag),
            .undocref => |x| gpa.free(x.doc_id),
            .setShort => |x| gpa.free(x.short),
            .setState => |x| if (x.holder) |h| gpa.free(h),
            .release => |x| gpa.free(x.holder),
            else => {},
        }
    }

    // ----------------------------------------------------------------- acyclic

    const Color = enum { white, gray, black };

    /// DFS three-color cycle detection over the `needs` edges. `from needs to`
    /// is a directed edge from -> to; a back-edge (to a gray node) is a cycle.
    pub fn checkAcyclic(self: *Store) Error!void {
        var color = std.AutoHashMapUnmanaged(Key, Color){};
        defer color.deinit(self.gpa);

        // Build adjacency: from -> [to...].
        var adj = std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)){};
        defer {
            var vit = adj.valueIterator();
            while (vit.next()) |list| list.deinit(self.gpa);
            adj.deinit(self.gpa);
        }
        for (self.needs.items) |e| {
            const gop = try adj.getOrPut(self.gpa, key(e.from));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, e.to);
        }

        // Iterative DFS (explicit stack) over every task to catch disjoint cycles.
        var task_it = self.tasks.keyIterator();
        while (task_it.next()) |k| {
            if ((color.get(k.*) orelse .white) != .white) continue;
            try self.dfsVisit(k.*, &adj, &color);
        }
    }

    /// True iff `target` is reachable from `start` via the COMBINED self-wait
    /// graph: `needs` edges (from -> to) union `in` membership edges
    /// reversed (arc -> task, since an arc structurally depends on
    /// completing every direct member before IT can be considered done —
    /// see `append`'s doc comment and design.md "Arc-as-prereq"). Pure
    /// query over whatever is currently applied; no allocation escapes.
    ///
    /// This is the incremental, single-edge gate `append` uses: adding a new
    /// directed edge X -> Y closes a cycle iff Y can already reach X, so the
    /// call site checks `combinedReaches(Y, X)` AFTER tentatively applying
    /// the edge — the edge itself points the wrong way to matter to this
    /// search (it goes OUT of X, this search is looking for a path INTO X),
    /// so including it in the graph already is harmless.
    fn combinedReaches(self: *Store, alloc: std.mem.Allocator, start: Ulid, target: Ulid) Error!bool {
        var seen = std.AutoHashMapUnmanaged(Key, void){};
        defer seen.deinit(alloc);
        var stack: std.ArrayList(Ulid) = .empty;
        defer stack.deinit(alloc);
        try stack.append(alloc, start);
        try seen.put(alloc, key(start), {});

        while (stack.pop()) |cur| {
            if (cur.eql(target)) return true;
            for (self.needs.items) |e| {
                if (!e.from.eql(cur)) continue;
                const gop = try seen.getOrPut(alloc, key(e.to));
                if (!gop.found_existing) try stack.append(alloc, e.to);
            }
            for (self.ins.items) |e| {
                if (!e.arc.eql(cur)) continue; // arc -> task, reversed
                const gop = try seen.getOrPut(alloc, key(e.task));
                if (!gop.found_existing) try stack.append(alloc, e.task);
            }
        }
        return false;
    }

    /// Full scan of the COMBINED self-wait graph (see `combinedReaches` for
    /// the edge-set definition) for EVERY cycle anywhere in it — appends the
    /// (from, to) endpoints of the back-edge that closes each one found to
    /// `out` (scan order, not necessarily insertion order; `out` is left
    /// empty, not cleared, on an acyclic graph). Pure query: never mutates
    /// self, never raises on a found cycle — the caller decides what a
    /// cycle means (`append` rejects via `combinedReaches`, `load` warns via
    /// this, once per pair).
    ///
    /// Reports ALL cycles, not just the first: a log can carry more than one
    /// independent self-wait pair (two unrelated bad merges, or debris from
    /// before this check existed), and stopping at the first would leave
    /// every OTHER cycled task exactly as silently unreachable from every
    /// view as the bug this whole mechanism exists to make visible.
    ///
    /// Unlike `combinedReaches` (a single-edge, incremental check), this is
    /// an unconditional full rescan — too expensive to run on every write,
    /// but exactly right for the ONE-TIME check right after `load`, where
    /// the log may hold structure no incremental gate ever validated (a
    /// hand-edited log, a log predating this check, or a union-merge of two
    /// worktree logs — see `load`'s doc comment for why append-time
    /// checking alone cannot catch the merge case).
    pub fn findSelfWaitCycles(self: *Store, out: *std.ArrayList(SelfWaitPair)) Error!void {
        var adj = std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)){};
        defer {
            var vit = adj.valueIterator();
            while (vit.next()) |list| list.deinit(self.gpa);
            adj.deinit(self.gpa);
        }
        for (self.needs.items) |e| {
            const gop = try adj.getOrPut(self.gpa, key(e.from));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, e.to);
        }
        for (self.ins.items) |e| {
            // Reversed: the arc depends on the member, exactly like a needs edge.
            const gop = try adj.getOrPut(self.gpa, key(e.arc));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, e.task);
        }

        var color = std.AutoHashMapUnmanaged(Key, Color){};
        defer color.deinit(self.gpa);
        var task_it = self.tasks.keyIterator();
        while (task_it.next()) |k| {
            if ((color.get(k.*) orelse .white) != .white) continue;
            try self.selfWaitDfs(k.*, &adj, &color, out);
        }
    }

    fn selfWaitDfs(
        self: *Store,
        start: Key,
        adj: *std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)),
        color: *std.AutoHashMapUnmanaged(Key, Color),
        out: *std.ArrayList(SelfWaitPair),
    ) Error!void {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, .{ .node = start, .idx = 0 });
        try color.put(self.gpa, start, .gray);

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const neighbors: []const Ulid = if (adj.get(top.node)) |list| list.items else &.{};
            if (top.idx < neighbors.len) {
                const next_id = neighbors[top.idx];
                top.idx += 1;
                const nk = key(next_id);
                switch (color.get(nk) orelse .white) {
                    .white => {
                        try color.put(self.gpa, nk, .gray);
                        try stack.append(self.gpa, .{ .node = nk, .idx = 0 });
                    },
                    // A back-edge closes a cycle: RECORD it and keep scanning
                    // (do not push/descend into an already-gray node — that
                    // would loop forever) so a second, independent cycle
                    // elsewhere in the graph is not left unreported.
                    .gray => try out.append(self.gpa, .{ .from = .{ .text = top.node }, .to = next_id }),
                    .black => {},
                }
            } else {
                try color.put(self.gpa, top.node, .black);
                _ = stack.pop();
            }
        }
    }

    const Frame = struct { node: Key, idx: usize };

    fn dfsVisit(
        self: *Store,
        start: Key,
        adj: *std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)),
        color: *std.AutoHashMapUnmanaged(Key, Color),
    ) Error!void {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, .{ .node = start, .idx = 0 });
        try color.put(self.gpa, start, .gray);

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const neighbors: []const Ulid = if (adj.get(top.node)) |list| list.items else &.{};
            if (top.idx < neighbors.len) {
                const next_id = neighbors[top.idx];
                top.idx += 1;
                const nk = key(next_id);
                switch (color.get(nk) orelse .white) {
                    .white => {
                        try color.put(self.gpa, nk, .gray);
                        try stack.append(self.gpa, .{ .node = nk, .idx = 0 });
                    },
                    .gray => return error.DependencyCycle, // back-edge
                    .black => {},
                }
            } else {
                try color.put(self.gpa, top.node, .black);
                _ = stack.pop();
            }
        }
    }

    // ----------------------------------------------------------------- writes

    /// Append a single event to the log (creating .tracker/log.jsonl as needed),
    /// applying it to in-memory state. For a `dep`/`in` event we re-verify the
    /// self-wait invariant and reject `error.DependencyCycle` *before*
    /// persisting, so the log never holds a write that closes a cycle.
    ///
    /// Stamps a real wall-clock ts (ms since Unix epoch) on every event at append
    /// time using comptime field injection. ts=0 on a loaded event means unknown /
    /// legacy (tolerated by the codec's getIntDefault fallback).
    pub fn append(self: *Store, ev_in: Event) !void {
        // `T in X`'s `X` must already be a declared arc (01KYTFRD7) — checked
        // BEFORE anything else so a rejected write never touches in-memory
        // state or the log. Exempts literal self-membership (`T in T`): that
        // shape is nonsensical regardless of `T`'s declared-ness, and is
        // already given its own, more specific rejection further down
        // (`combinedReaches` catches it as a trivial self-reach) — gating it
        // behind "must be declared first" would just replace one clear
        // diagnosis with a less specific one for no benefit. See `isArc`'s
        // doc comment for why this can no longer be inferred from the edge.
        switch (ev_in) {
            .in => |x| if (!x.task.eql(x.arc) and !self.isArc(x.arc)) return error.UndeclaredArc,
            // A lease is taken only on open work. Checked at WRITE time only:
            // the fold applies any sequence a merge delivers.
            .setState => |x| if (x.state == .claimed) {
                if (x.holder == null or x.holder.?.len == 0) return error.HolderRequired;
                if (self.tasks.get(key(x.id))) |t| {
                    if (State.claimRefusal(t.state) != null) return error.ClaimRequiresOpen;
                }
            },
            else => {},
        }

        // Stamp ts on whichever variant has the field (all do now, via comptime check).
        var ev = ev_in;
        const ts_now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        switch (ev) {
            inline else => |*x| if (@hasField(@TypeOf(x.*), "ts")) {
                x.ts = ts_now;
            },
        }

        // Capture lengths so we can tell a genuinely NEW edge from a dedup
        // no-op (`dep`) or a seq-only update (`in`) — both append-only lists
        // grow iff `apply` actually added an entry (see `apply`'s dedup
        // guards). This matters: re-checking on a no-op/update is not just
        // wasted work, it risks popping the WRONG (unrelated) tail entry.
        const needs_before = self.needs.items.len;
        const ins_before = self.ins.items.len;
        try self.apply(ev);

        // A freshly-added `dep` or `in` edge can close a cycle in the
        // COMBINED self-wait graph: `needs` edges (from -> to) union `in`
        // membership edges reversed (arc -> task — an arc structurally
        // depends on completing every direct member before IT can be
        // considered done, exactly like a needs edge, just spelled the other
        // way round from the `in(task, arc)` event; see design.md
        // "Arc-as-prereq"). The single most common shape: a task that
        // `needs` its own arc (directly or transitively) can never become
        // ready, because the arc can never drain while that same task is
        // still open — each waits on the other forever.
        //
        // Checked INCREMENTALLY against just the new edge: every prior
        // structural change went through this same gate, so the combined
        // graph was self-wait-free immediately before this one edge lands,
        // which means any cycle in the new graph must run through it —
        // scanning from its far endpoint back to its near endpoint
        // (`combinedReaches`) is therefore equivalent to, and far cheaper
        // than, a full rescan. It also stays scoped to THIS edit even in a
        // repo that already carries a pre-existing (legacy, load-time-warned
        // — see `load`) cycle elsewhere: an unrelated future `dep`/`in` is
        // never blocked by debt it doesn't touch, because the search starts
        // at this edge's own endpoints, not at the whole graph.
        switch (ev) {
            .dep => |x| {
                if (self.needs.items.len > needs_before and try self.combinedReaches(self.gpa, x.to, x.from)) {
                    _ = self.needs.pop();
                    return error.DependencyCycle;
                }
            },
            .in => |x| {
                if (self.ins.items.len > ins_before and try self.combinedReaches(self.gpa, x.task, x.arc)) {
                    _ = self.ins.pop();
                    return error.DependencyCycle;
                }
            },
            else => {},
        }
        try self.persistAppend(ev);
    }

    fn persistAppend(self: *Store, ev: Event) !void {
        var sub = try self.dir.createDirPathOpen(self.io, tracker_subdir, .{});
        defer sub.close(self.io);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        try codec.encode(&line, self.gpa, ev);
        try line.append(self.gpa, '\n');

        // Open (or create) the log and write at end-of-file, UNDER AN
        // EXCLUSIVE ADVISORY LOCK on the log itself (01M2V2NPA).
        //
        // length-then-pwrite is a read-modify-write: two writers that both
        // read `end = N` both pwrite at N, and the second overwrites the
        // first — losing an event outright, and, when the two lines differ in
        // length, leaving the survivor with a tail of the loser glued to it
        // (one line holding two JSON objects, which fails the whole load with
        // NotAnObject). Measured: 24 concurrent `trk add` -> 5 lines, 6 of 24
        // titles, store unloadable. The lock closes that window: it is taken
        // at open, before `length`, and released by `close` below, so the
        // whole read-modify-write is serialized against every other trk
        // writer — including ones in sibling worktrees, since the fan-out
        // pattern aims every lane's incidental filings at the MAIN checkout's
        // one log. (merge=union does not help here: it reconciles two
        // committed COPIES of the file, not two processes writing one file in
        // one working tree.)
        //
        // The lock is on the log's own inode, not a sibling lockfile: it is
        // the file being mutated, it needs no new on-disk artifact and no
        // .gitignore entry, and it works unchanged in a store created before
        // this fix. What it deliberately does NOT cover is a whole-file
        // REWRITE of log.jsonl by something that does not take the lock —
        // `compact`'s rename, or a git merge/checkout. Both already carry
        // that hazard explicitly (see `compact`'s doc comment: orchestrator-
        // only, serialized, never while worktrees are in flight); a sibling
        // lockfile would not fix them either, because git does not ask.
        //
        // Blocking, not `lock_nonblocking`: a writer that waits its turn is
        // exactly right here — appends are microseconds — and returning
        // WouldBlock would just move the loss to the caller.
        var f = try sub.createFile(self.io, log_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        defer f.close(self.io);
        const end = try f.length(self.io);
        try f.writePositionalAll(self.io, line.items, end);
        try f.sync(self.io);
    }

    /// Atomic full-file write helper: write `data` to a temp file in the same
    /// dir, then rename over `name` (atomic on the same filesystem). Used by
    /// compaction (and any future snapshot rewrite).
    pub fn atomicWrite(self: *Store, sub: Io.Dir, name: []const u8, data: []const u8) !void {
        // Temp name in the SAME dir so the rename is a same-filesystem atomic op.
        var tmp_buf: [80]u8 = undefined;
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        const hex = std.fmt.bytesToHex(rnd, .lower);
        const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.tmp.{s}", .{ name, &hex }) catch unreachable;

        {
            var f = try sub.createFile(self.io, tmp_name, .{ .truncate = true });
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, data);
            try f.sync(self.io);
        }
        try sub.rename(tmp_name, sub, name, self.io);
    }

    /// Every task this store would collect right now, as the tombstone rows it
    /// would be entombed as: `isCollectable` (garbage state, or a ghost), its
    /// direct `in` memberships, and the reason it is going. `now` stamps the
    /// rows' collection time — `compact` passes the real clock; a preview
    /// passes `0`, the same "unknown" `Tombstone.ts` a recovered record carries.
    ///
    /// Factored out of `compact` so `compact --dry-run` reports EXACTLY the set
    /// the real run would collect (01M1FMNSZ). A preview computed by a second
    /// implementation would be worth less than none: its whole job is to be
    /// trusted before an irreversible-looking step, and a preview that can
    /// disagree with the run is a preview nobody can act on.
    ///
    /// The returned slice is `alloc`-owned; every string and arc slice inside it
    /// borrows from the store (arena-owned) and dies with it.
    pub fn collectableRows(self: *Store, alloc: std.mem.Allocator, now: i64) ![]Tombstone {
        var rows: std.ArrayList(Tombstone) = .empty;
        errdefer rows.deinit(alloc);
        const all_ids = try self.sortedTaskIds(self.gpa);
        defer self.gpa.free(all_ids);
        for (all_ids) |id| {
            const t = self.tasks.get(key(id)).?;
            if (!isCollectable(t)) continue;
            var arcs: std.ArrayList(Ulid) = .empty;
            for (self.ins.items) |e| {
                if (e.task.eql(id)) try arcs.append(self.a(), e.arc);
            }
            try rows.append(alloc, .{
                .id = id,
                .short = t.short,
                .title = t.title,
                // A ghost's `open` is `ensureNode`'s default, not a
                // judgment — classify it as what it is, never as its state.
                .reason = if (!t.has_add) "ghost" else t.state.toString(),
                .arcs = arcs.items,
                .ts = now,
                .src = "compact",
            });
        }
        return rows.toOwnedSlice(alloc);
    }

    /// Compaction result: summary counts for the CLI one-liner.
    pub const CompactResult = struct {
        /// Number of live (non-dropped) tasks written to the new snapshot.
        live_tasks: usize,
        /// Number of events that were in the log before it was truncated.
        log_events_before: usize,
        /// Number of ghost ids GC'd out of this compaction (see `ghost_tasks`).
        ghosts: usize,
        /// Number of raw log lines moved to `quarantine.jsonl` because they
        /// referenced a ghost id.
        quarantined_lines: usize,
        /// Number of tombstone lines appended to `tombstones.jsonl` — one per
        /// task this run physically GC'd that was not already entombed. See
        /// `tombstones_name`.
        tombstoned: usize,
    };

    /// Compact: write a fresh full-state snapshot then truncate the log.
    ///
    /// **Single-writer / orchestrator-only** (issue-tracker.md §Compaction).
    ///
    /// **Crash-safety ordering:**
    ///   1. Serialize state → temp file → rename over snapshot.jsonl  (atomic)
    ///   2. Empty string   → temp file → rename over log.jsonl        (atomic)
    ///
    /// If we crash between step 1 and step 2, the old log is still intact.
    /// Re-folding: new snapshot (current state minus dropped tasks) + old log
    /// (all events including the ones for dropped tasks) → every `apply` is
    /// idempotent (last-write-wins for scalars, dedup-guards for edges), so the
    /// fold converges to the pre-compaction state. Dropped tasks may transiently
    /// reappear; a second compact run cleans them. No data is ever lost.
    ///
    /// **History retention ruling** (resolves docs/design.md open
    /// fork "Compaction & history retention"):
    ///   - `dropped` tasks are EXCLUDED from the snapshot. They are abandoned work
    ///     with no future structural role. Git history preserves the raw log as
    ///     an audit trail if a recovery is ever needed. Dropping them here is the
    ///     GC step analogous to `externalization.md`'s adopt/condemn: condemn =
    ///     mark dropped, compact = collect.
    ///   - `done` tasks are KEPT in the snapshot. A completed task is still a live
    ///     structural node: other tasks may hold `needs` edges pointing at it, and
    ///     dropping it from the snapshot would silently un-block their dependents
    ///     on the next load. A done prereq is what makes a dependent eligible —
    ///     losing it corrupts the graph.
    ///   - Edges (`dep`, `in`) involving a dropped endpoint are also excluded.
    ///   - EVERYTHING GC'd IS ENTOMBED FIRST (01M2M2K1J). Excluding a task from
    ///     the snapshot is what makes its id unresolvable, and "never existed"
    ///     and "existed, finished, graduated" then read identically to every
    ///     reader — a wrong "dangling" verdict that invites someone to correct
    ///     a correct citation. So each collected task gets one line in
    ///     `tombstones.jsonl` (id, short, title, why, arcs, when) before any
    ///     rewrite. That does not un-GC anything: the task is still out of the
    ///     graph, out of `next`, out of every view. It is the difference
    ///     between forgetting a task and forgetting that it ever was.
    ///   - GHOST ids are EXCLUDED too, and their log lines are spooled to
    ///     `quarantine.jsonl` first (see `quarantineGhosts`). A ghost is an id
    ///     the fold only ever saw REFERENCED, never `add`ed (`ghost_tasks`) —
    ///     it is not a task, it is the residue of events about one that no
    ///     longer exists. Serializing it would `add` a nameless, arc-less,
    ///     `open` task into the baseline, where it becomes indistinguishable
    ///     from a real one (it now HAS an add, so the load-time ghost warning
    ///     goes quiet forever) and surfaces in `next`/`render` as work. That
    ///     promotion — not the truncation — is the irreversible step, so this
    ///     is a GC class exactly like `dropped`/`archived`, not a refusal.
    ///     (It was a refusal, briefly. The only exit was `--force`, which did
    ///     the promoting; every other suggested remedy was unreachable from
    ///     the CLI — `add` mints a fresh id, so re-filing cannot re-home the
    ///     orphaned events, and nothing but `compact` clears the log lines
    ///     that re-materialize the ghost on every load. A precondition whose
    ///     sole exit is the destructive override is a speed bump, not a
    ///     guard.)
    pub fn compact(self: *Store) !CompactResult {
        // Re-scanned rather than trusted from `load` because in-memory state can
        // have moved since (this process's own appends). It deliberately does
        // NOT see another writer's post-load appends — those lines were never
        // folded, and this compact truncates them either way; that hazard is
        // what "orchestrator-only, serialized, never while worktrees are in
        // flight" buys off, not something a rescan here could catch.
        try self.collectGhostTasks();

        // Count log events before truncation.
        const log_events_before = try self.countLogEvents();

        var sub = try self.dir.createDirPathOpen(self.io, tracker_subdir, .{});
        defer sub.close(self.io);

        // Round-trip self-verify setup (01M0YESW6 — the last open silent-
        // data-loss class): fingerprint the CURRENT fold — the exact state
        // `serializeState` below is about to persist — BEFORE any write, so
        // it can be compared against a FRESH reload of what actually landed
        // on disk. See the verify block after the writes for the other half.
        self.diverged_on_verify.clearRetainingCapacity();
        var pre_fp = try self.fingerprintLiveTasks(self.gpa);
        defer pre_fp.deinit(self.gpa);

        // Snapshot the ORIGINAL bytes (if any) before anything destructive
        // happens: `atomicWrite`'s rename discards the old inode's content,
        // so this in-memory copy is the only way to restore on a failed
        // verify, and it doubles as the source for the pre-compact backup.
        const orig_snapshot = sub.readFileAlloc(self.io, snapshot_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        defer if (orig_snapshot) |b| self.gpa.free(b);
        const orig_log = sub.readFileAlloc(self.io, log_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        defer if (orig_log) |b| self.gpa.free(b);
        // The tombstone index is APPENDED to below, before the point of no
        // return — so a failed verify must restore it too, or a refused compact
        // would leave behind tombstones for tasks that are still live. That is
        // the one direction this index must never get wrong: a tombstone for a
        // live id would make `show` report a live task as compacted.
        const orig_tombstones = sub.readFileAlloc(self.io, tombstones_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        defer if (orig_tombstones) |b| self.gpa.free(b);

        // Bounded pre-compact backup, taken from the same original bytes,
        // BEFORE the rewrite. Recovery today is git archaeology across
        // worktree merges — exactly how the 01KZTV44M loss stayed invisible
        // for weeks; this gives a same-machine fallback that needs no git
        // history and no reconstructed worktree at all.
        try self.writeBackup(sub, orig_snapshot, orig_log, orig_tombstones);

        // Step 0: spool the ghosts' log lines, durable BEFORE anything is
        // rewritten. Nothing this compaction discards is destroyed — a
        // clobbered/mis-resolved snapshot (the one ghost cause where the add
        // really was worth recovering) is repaired by restoring the snapshot
        // from git and appending the spool back onto the log, ids intact.
        const quarantined = try self.quarantineGhosts(sub);

        // Step 0b: entomb every task this run is about to erase, likewise
        // durable BEFORE the rewrite (01M2M2K1J). This is the ONLY moment the
        // information exists in memory: after the snapshot is rewritten the
        // task, its title and its edges are gone from every file in
        // `.tracker/`, and the only remaining record is git history — which the
        // dangling-id lint proves is recoverable but costs ~31 s per query.
        const tombstoned = blk: {
            const now: i64 = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            const rows = try self.collectableRows(self.gpa, now);
            defer self.gpa.free(rows);
            break :blk (try self.appendTombstones(sub, rows)).total();
        };

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        const live = try self.serializeState(&buf);

        // Step 1: new snapshot, durable before we touch the log.
        try self.atomicWrite(sub, snapshot_name, buf.items);

        // Step 2: truncate the log. A crash between here and step 1 leaves the
        // old log intact; crash-safe re-fold described in the doc above.
        try self.atomicWrite(sub, log_name, "");

        // Round-trip self-verify: reload FRESH from exactly what was just
        // written (never trust `self` for the "after" side — the whole point
        // is to catch the rewrite itself, or the reload path, corrupting
        // something) and confirm every task fingerprinted above survives with
        // an identical fingerprint. A task that was legitimately GC'd
        // (dropped/archived/ghost) was never in `pre_fp` to begin with — see
        // `fingerprintLiveTasks` — so this can only fire on a task compact was
        // contracted to KEEP.
        const verify_failed = blk: {
            var check = Store.open(self.gpa, self.io, self.dir);
            defer check.deinit();
            check.load() catch {
                // An unreadable post-write state is itself the worst-case
                // divergence — treat it as a full failure rather than
                // silently skipping the check.
                break :blk true;
            };
            var post_fp = check.fingerprintLiveTasks(self.gpa) catch break :blk true;
            defer post_fp.deinit(self.gpa);

            var it = pre_fp.iterator();
            while (it.next()) |entry| {
                const post_val = post_fp.get(entry.key_ptr.*);
                if (post_val == null or post_val.? != entry.value_ptr.*) {
                    self.diverged_on_verify.append(self.gpa, .{ .text = entry.key_ptr.* }) catch {};
                }
            }
            break :blk self.diverged_on_verify.items.len != 0;
        };

        if (verify_failed) {
            std.sort.pdq(Ulid, self.diverged_on_verify.items, {}, Ulid.lessThan);
            // Restore the pre-compact files exactly, so a failed compact
            // leaves no trace of the rewrite — a first-ever compact (no
            // prior snapshot/log) restores to "absent" rather than leaving a
            // corrupt file where none existed.
            if (orig_snapshot) |b| try self.atomicWrite(sub, snapshot_name, b) else sub.deleteFile(self.io, snapshot_name) catch {};
            if (orig_log) |b| try self.atomicWrite(sub, log_name, b) else sub.deleteFile(self.io, log_name) catch {};
            if (orig_tombstones) |b| try self.atomicWrite(sub, tombstones_name, b) else sub.deleteFile(self.io, tombstones_name) catch {};
            return error.CompactVerifyFailed;
        }

        return .{
            .live_tasks = live,
            .log_events_before = log_events_before,
            .ghosts = self.ghost_tasks.items.len,
            .quarantined_lines = quarantined,
            .tombstoned = tombstoned,
        };
    }

    /// Directory name for one pre-compact backup run, under
    /// `.tracker/backup/`: the millisecond epoch, zero-padded to a fixed
    /// width so lexicographic order agrees with chronological order (see
    /// `evictOldBackups`, which relies on that for eviction-oldest-first).
    fn backupDirName(self: *Store, buf: []u8) []const u8 {
        const ts: i64 = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        // Unsigned before formatting: `{d:0>20}` on a SIGNED integer reserves
        // a sign column and zero-pads around it, printing a literal `+` for
        // every positive timestamp (the exact footgun `22b02f7` already
        // fixed once for a different formatted timestamp in this repo). A
        // wall-clock ms epoch is never negative, so the cast is lossless.
        const ts_u: u64 = @intCast(ts);
        return std.fmt.bufPrint(buf, "{d:0>20}", .{ts_u}) catch unreachable;
    }

    /// Copy the pre-compact `snapshot.jsonl`/`log.jsonl`/`tombstones.jsonl`
    /// bytes (whichever existed) into a fresh `.tracker/backup/<ts>/` run dir
    /// BEFORE compact does anything destructive, then evict down to
    /// `config.backup_retain`. A no-op on the very first compact (nothing to
    /// protect yet — no prior snapshot AND no prior log).
    fn writeBackup(self: *Store, sub: Io.Dir, orig_snapshot: ?[]const u8, orig_log: ?[]const u8, orig_tombstones: ?[]const u8) !void {
        if (orig_snapshot == null and orig_log == null and orig_tombstones == null) return;

        // `.iterate = true`: `evictOldBackups` below scans this dir's entries,
        // which requires the handle to have been opened with iteration
        // capability (a handle opened without it fails the scan with BADF,
        // not an empty listing).
        var backup_root = try sub.createDirPathOpen(self.io, backup_subdir, .{ .open_options = .{ .iterate = true } });
        defer backup_root.close(self.io);

        var name_buf: [20]u8 = undefined;
        const name = self.backupDirName(&name_buf);

        // Collision-avoid: two compacts landing in the same millisecond (a
        // fast host-unit test loop can do this; real usage is orchestrator-
        // paced and rare) get a numeric suffix rather than one clobbering the
        // other's backup.
        var final_name_buf: [40]u8 = undefined;
        var final_name: []const u8 = name;
        var suffix: usize = 0;
        while (true) {
            const exists = existsBlk: {
                var d = backup_root.openDir(self.io, final_name, .{}) catch |e| switch (e) {
                    error.FileNotFound => break :existsBlk false,
                    else => return e,
                };
                d.close(self.io);
                break :existsBlk true;
            };
            if (!exists) break;
            suffix += 1;
            final_name = std.fmt.bufPrint(&final_name_buf, "{s}-{d}", .{ name, suffix }) catch unreachable;
        }

        var run_dir = try backup_root.createDirPathOpen(self.io, final_name, .{});
        defer run_dir.close(self.io);

        if (orig_snapshot) |b| try self.atomicWrite(run_dir, snapshot_name, b);
        if (orig_log) |b| try self.atomicWrite(run_dir, log_name, b);
        if (orig_tombstones) |b| try self.atomicWrite(run_dir, tombstones_name, b);

        try self.evictOldBackups(backup_root);
    }

    /// Evict `.tracker/backup/` run dirs beyond `config.backup_retain`,
    /// oldest first. Run-dir names are zero-padded millisecond timestamps
    /// (`backupDirName`), so a plain lexicographic sort is chronological.
    fn evictOldBackups(self: *Store, backup_root: Io.Dir) !void {
        const retain = self.config.backup_retain;

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }

        var it = backup_root.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            try names.append(self.gpa, try self.gpa.dupe(u8, entry.name));
        }
        std.sort.pdq([]const u8, names.items, {}, lessThanStr);

        if (names.items.len <= retain) return;
        const n_to_evict = names.items.len - retain;
        for (names.items[0..n_to_evict]) |old| {
            try backup_root.deleteTree(self.io, old);
        }
    }

    /// A whole-task content fingerprint used by `compact`'s round-trip
    /// self-verify. Built from the SAME canonicalization `serializeState`
    /// uses to persist a task — title/body/tags/short/state/priority/
    /// docrefs/arc-declared/arc-standing, plus this id's OWN `needs`/`in`
    /// edges with a collectable endpoint excluded exactly as
    /// `serializeState` excludes it — so two fingerprints matching means
    /// "compact would write identical bytes for this id", and a mismatch
    /// names precisely the id whose persisted content changed underneath the
    /// rewrite. A single hash rather than a struct of hashes: the equality
    /// check this feeds is plain `u64 == u64`.
    fn taskFingerprint(
        self: *Store,
        buf: *std.ArrayList(u8),
        gc_set: *const std.AutoHashMapUnmanaged(Key, void),
        id: Ulid,
        t: Task,
    ) !u64 {
        buf.clearRetainingCapacity();
        try buf.print(self.gpa, "title\x00{s}\x00body\x00{s}\x00state\x00{s}\x00holder\x00{s}\x00lease_ts\x00{d}\x00priority\x00{d}\x00short\x00{s}\x00declared\x00{}\x00standing\x00{}\x00", .{
            t.title,
            t.body,
            @tagName(t.state),
            t.holder orelse "\x01",
            t.lease_ts,
            t.priority,
            t.short orelse "\x01",
            self.declared_arcs.contains(key(id)),
            self.standing_arcs.contains(key(id)),
        });

        // Tags: sorted, order-independent (a re-fold may reorder them).
        {
            const tags = try self.gpa.dupe([]const u8, t.tags.items);
            defer self.gpa.free(tags);
            std.sort.pdq([]const u8, tags, {}, lessThanStr);
            try buf.appendSlice(self.gpa, "tags\x00");
            for (tags) |tg| try buf.print(self.gpa, "{s}\x00", .{tg});
        }

        // Docrefs: sorted by (doc_id, section_id), order-independent.
        {
            const drs = try self.gpa.dupe(model.DocRef, t.docrefs.items);
            defer self.gpa.free(drs);
            std.sort.pdq(model.DocRef, drs, {}, docrefLessThan);
            try buf.appendSlice(self.gpa, "docrefs\x00");
            for (drs) |dr| try buf.print(self.gpa, "{s}\x00{s}\x00", .{ dr.doc_id, dr.section_id orelse "\x01" });
        }

        // `needs` edges OWNED by this id (from == id), skipping a collectable
        // endpoint exactly as `serializeState` does — an edge compact is
        // contracted to drop must never register as a divergence.
        {
            var tos: std.ArrayList(Ulid) = .empty;
            defer tos.deinit(self.gpa);
            for (self.needs.items) |e| {
                if (!e.from.eql(id)) continue;
                if (gc_set.contains(key(e.from)) or gc_set.contains(key(e.to))) continue;
                try tos.append(self.gpa, e.to);
            }
            std.sort.pdq(Ulid, tos.items, {}, Ulid.lessThan);
            try buf.appendSlice(self.gpa, "needs\x00");
            for (tos.items) |to| try buf.print(self.gpa, "{s}\x00", .{&to.text});
        }

        // `in` edges OWNED by this id (task == id), same collectable-endpoint
        // exclusion, carrying `seq` (an edge attribute, not just membership).
        {
            var ins_here: std.ArrayList(In) = .empty;
            defer ins_here.deinit(self.gpa);
            for (self.ins.items) |e| {
                if (!e.task.eql(id)) continue;
                if (gc_set.contains(key(e.task)) or gc_set.contains(key(e.arc))) continue;
                try ins_here.append(self.gpa, e);
            }
            std.sort.pdq(In, ins_here.items, {}, inLessThan);
            try buf.appendSlice(self.gpa, "in\x00");
            for (ins_here.items) |e| try buf.print(self.gpa, "{s}\x00{d}\x00", .{ &e.arc.text, e.seq });
        }

        return std.hash.Wyhash.hash(0, buf.items);
    }

    fn docrefLessThan(_: void, lhs: model.DocRef, rhs: model.DocRef) bool {
        const c = std.mem.order(u8, lhs.doc_id, rhs.doc_id);
        if (c != .eq) return c == .lt;
        const ls = lhs.section_id orelse "";
        const rs = rhs.section_id orelse "";
        return std.mem.lessThan(u8, ls, rs);
    }

    /// Build the id->collectable set (dropped/archived/ghost) for the
    /// CURRENT in-memory fold — the same GC classification `serializeState`
    /// computes inline, factored out so the fingerprint's edge exclusion can
    /// apply the identical rule without re-deriving it.
    fn buildGcSet(self: *Store, alloc: std.mem.Allocator) !std.AutoHashMapUnmanaged(Key, void) {
        var gc_set: std.AutoHashMapUnmanaged(Key, void) = .empty;
        errdefer gc_set.deinit(alloc);
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (isCollectable(entry.value_ptr.*)) try gc_set.put(alloc, entry.key_ptr.*, {});
        }
        return gc_set;
    }

    /// Fingerprint every LIVE (non-collectable) task in the CURRENT in-memory
    /// fold, keyed by id. Used both before `compact` rewrites anything
    /// (against `self`, already loaded) and after (against a freshly
    /// reloaded `Store` reading exactly what was just written) — see
    /// `compact`. A dropped/archived/ghost task is never a key in the
    /// returned map, which is what makes "diff the two maps" automatically
    /// exclude legitimate GC from the comparison.
    fn fingerprintLiveTasks(self: *Store, alloc: std.mem.Allocator) !std.AutoHashMapUnmanaged(Key, u64) {
        var gc_set = try self.buildGcSet(alloc);
        defer gc_set.deinit(alloc);

        var out: std.AutoHashMapUnmanaged(Key, u64) = .empty;
        errdefer out.deinit(alloc);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (isCollectable(entry.value_ptr.*)) continue;
            const fp = try self.taskFingerprint(&buf, &gc_set, entry.value_ptr.id, entry.value_ptr.*);
            try out.put(alloc, entry.key_ptr.*, fp);
        }
        return out;
    }

    /// Move every log line that references a ghost id into `quarantine.jsonl`
    /// (appended under a header line naming the run and the ids), returning how
    /// many lines were spooled. A no-op returning 0 when there are no ghosts —
    /// the file is never created for a clean store.
    ///
    /// The header is itself a JSON line with an `"op"` trk does not know, so if
    /// a human ever cats the spool back onto the log to recover it, the header
    /// is skip-and-warned by `replayFile` rather than breaking the fold (see
    /// `skipped_unknown_ops`) — and the real events around it apply.
    ///
    /// A line that fails to decode is left alone: its op is unknown, so which
    /// id it belongs to is unknowable, and guessing would spool a newer
    /// binary's event on no evidence.
    fn quarantineGhosts(self: *Store, sub: Io.Dir) !usize {
        if (self.ghost_tasks.items.len == 0) return 0;

        var ghosts: std.AutoHashMapUnmanaged(Key, void) = .empty;
        defer ghosts.deinit(self.gpa);
        for (self.ghost_tasks.items) |id| try ghosts.put(self.gpa, key(id), {});

        const bytes = sub.readFileAlloc(self.io, log_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer self.gpa.free(bytes);

        var spool: std.ArrayList(u8) = .empty;
        defer spool.deinit(self.gpa);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const ev = codec.decode(self.gpa, trimmed) catch continue;
            defer freeEvent(self.gpa, ev);
            var hit = false;
            for (model.eventTaskIds(ev)) |maybe| {
                if (maybe) |id| {
                    if (ghosts.contains(key(id))) hit = true;
                }
            }
            if (!hit) continue;
            try spool.appendSlice(self.gpa, trimmed);
            try spool.append(self.gpa, '\n');
            n += 1;
        }
        if (n == 0) return 0;

        // Hand-rolled JSON, deterministic key order — same rule as the codec.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const existing = sub.readFileAlloc(self.io, quarantine_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => try self.gpa.dupe(u8, ""),
            else => return e,
        };
        defer self.gpa.free(existing);
        try out.appendSlice(self.gpa, existing);
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n')
            try out.append(self.gpa, '\n');
        try out.print(self.gpa, "{{\"op\":\"quarantine\",\"ts\":{d},\"reason\":\"ghost\",\"ids\":[", .{
            std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        });
        for (self.ghost_tasks.items, 0..) |id, i| {
            if (i != 0) try out.appendSlice(self.gpa, ",");
            try out.print(self.gpa, "\"{s}\"", .{&id.text});
        }
        try out.appendSlice(self.gpa, "]}\n");
        try out.appendSlice(self.gpa, spool.items);
        try self.atomicWrite(sub, quarantine_name, out.items);
        return n;
    }

    /// Count non-empty lines in the log file (≈ events before compaction).
    /// Returns 0 if the log does not exist.
    fn countLogEvents(self: *Store) !usize {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer sub.close(self.io);
        const bytes = sub.readFileAlloc(self.io, log_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer self.gpa.free(bytes);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
        }
        return n;
    }

    /// Emit current in-memory state as a minimal canonical event stream:
    ///   - one `add` per live task (not dropped, not archived), in ULID order
    ///   - `setState` for any non-open state (omitted for dropped/archived — they
    ///     are excluded entirely)
    ///   - `setPriority` if non-zero
    ///   - `docref` events per task
    ///   - `arcDeclare{declared:true}` if the task is in `declared_arcs`
    ///   - `dep` edges sorted by (from, to) — skipped if either endpoint is gone
    ///   - `in`  edges sorted by (task, arc) — skipped if either endpoint is gone
    ///
    /// `dropped` (won't-do, retention ruling), `archived` (completed + recorded
    /// in the changelog) and GHOST nodes (no `add` ever folded — see
    /// `ghost_tasks`) are all GC'd here: compaction is where a task with no
    /// structural future physically leaves the store. Emitting a ghost would be
    /// worse than dropping it — the `add` this writes is what turns a husk into
    /// a task nothing can tell apart from a real one.
    ///
    /// Tags within each `add` are **sorted** so the output is byte-identical for
    /// the same logical state (two compactions produce the same bytes — testable).
    ///
    /// Returns the count of live tasks written.
    fn serializeState(self: *Store, buf: *std.ArrayList(u8)) !usize {
        const all_ids = try self.sortedTaskIds(self.gpa);
        defer self.gpa.free(all_ids);

        // Build a set of GC'd (dropped, archived, or ghost) task keys so edge
        // filtering is O(1) and a graduated/abandoned/never-added task drops out
        // of the snapshot along with every edge that touched it.
        var gc_set = std.AutoHashMapUnmanaged(Key, void){};
        defer gc_set.deinit(self.gpa);
        for (all_ids) |id| {
            if (isCollectable(self.tasks.get(key(id)).?))
                try gc_set.put(self.gpa, key(id), {});
        }

        var live: usize = 0;
        for (all_ids) |id| {
            const t = self.tasks.get(key(id)).?;
            if (isCollectable(t)) continue; // dropped/archived/ghost: excluded

            // Sort tags for determinism before folding them into the `add`.
            const tag_slice = try self.gpa.alloc([]const u8, t.tags.items.len);
            defer self.gpa.free(tag_slice);
            for (t.tags.items, 0..) |tg, i| tag_slice[i] = tg;
            std.sort.pdq([]const u8, tag_slice, {}, lessThanStr);

            // .short is carried through VERBATIM — this is the fix for the
            // instability bug: a compact must never let a task's frozen short
            // silently regress to a shorter/different dynamically-computed
            // value just because the live id set shrank.
            // TEST-ONLY sabotage seam (see `test_sabotage_body`'s doc): comptime-
            // eliminated in a non-test build, so `persisted_body` is always
            // `t.body` there.
            const persisted_body = if (builtin.is_test) blk: {
                if (self.test_sabotage_body) |s| {
                    if (s.id.eql(id)) break :blk s.replacement;
                }
                break :blk t.body;
            } else t.body;
            try self.emit(buf, .{ .add = .{
                .id = id,
                .title = t.title,
                .body = persisted_body,
                .tags = tag_slice,
                .short = t.short,
                // The task's watermark: the newest event ts this state
                // incorporates. Replay uses it to withhold a stale event that a
                // later union-merge drags back in (01M0EM3G6). Carried forward
                // rather than recomputed, so a task nothing has touched since an
                // earlier compact keeps the bar it already had.
                .wm = @max(t.last_ts, t.watermark),
            } });
            if (t.state != .open)
                // A lease keeps its holder and its age across the rewrite.
                try self.emit(buf, .{ .setState = .{
                    .id = id,
                    .state = t.state,
                    .holder = t.holder,
                    .ts = t.lease_ts,
                } });
            if (t.priority != 0)
                try self.emit(buf, .{ .setPriority = .{ .id = id, .priority = t.priority } });
            for (t.docrefs.items) |dr|
                try self.emit(buf, .{ .docref = .{
                    .id = id,
                    .doc_id = dr.doc_id,
                    .section_id = dr.section_id,
                } });
            if (self.declared_arcs.contains(key(id)))
                try self.emit(buf, .{ .arcDeclare = .{ .id = id, .declared = true } });
            if (self.standing_arcs.contains(key(id)))
                try self.emit(buf, .{ .arcStanding = .{ .id = id, .standing = true } });
            live += 1;
        }

        // `dep` edges: stable (from, to) order; skip dropped endpoints.
        const sorted_needs = try self.gpa.dupe(Needs, self.needs.items);
        defer self.gpa.free(sorted_needs);
        std.sort.pdq(Needs, sorted_needs, {}, needsLessThan);
        for (sorted_needs) |e| {
            if (gc_set.contains(key(e.from))) continue;
            if (gc_set.contains(key(e.to))) continue;
            try self.emit(buf, .{ .dep = .{ .from = e.from, .to = e.to } });
        }

        // `in` edges: stable (task, arc) order; skip dropped endpoints.
        const sorted_ins = try self.gpa.dupe(In, self.ins.items);
        defer self.gpa.free(sorted_ins);
        std.sort.pdq(In, sorted_ins, {}, inLessThan);
        for (sorted_ins) |e| {
            if (gc_set.contains(key(e.task))) continue;
            if (gc_set.contains(key(e.arc))) continue;
            try self.emit(buf, .{ .in = .{ .task = e.task, .arc = e.arc, .seq = e.seq } });
        }

        // `setDocPath` entries: sorted by doc_id for determinism.
        // Collect all keys into a slice, sort, then emit in order.
        const n_docs = self.doc_paths.count();
        if (n_docs > 0) {
            const doc_ids = try self.gpa.alloc([]const u8, n_docs);
            defer self.gpa.free(doc_ids);
            var it = self.doc_paths.keyIterator();
            var i: usize = 0;
            while (it.next()) |dk| : (i += 1) doc_ids[i] = dk.*;
            std.sort.pdq([]const u8, doc_ids, {}, lessThanStr);
            for (doc_ids) |doc_id| {
                const path = self.doc_paths.get(doc_id).?;
                try self.emit(buf, .{ .setDocPath = .{ .doc_id = doc_id, .path = path } });
            }
        }

        return live;
    }

    /// A state that compaction physically GCs from the snapshot: `dropped`
    /// (won't-do) or `archived` (completed + recorded in the changelog).
    fn isGarbage(s: State) bool {
        return s == .dropped or s == .archived;
    }

    /// Everything compaction GCs: a garbage STATE, or a GHOST — a node the fold
    /// only ever saw referenced, never `add`ed. The ghost's `open` state is an
    /// artifact of `ensureNode`'s default, not a judgment anyone made about it,
    /// so state alone can't classify it. See `ghost_tasks` and `compact`.
    fn isCollectable(t: Task) bool {
        return isGarbage(t.state) or !t.has_add;
    }

    fn lessThanStr(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }

    fn needsLessThan(_: void, lhs: Needs, rhs: Needs) bool {
        const cf = std.mem.order(u8, &lhs.from.text, &rhs.from.text);
        if (cf != .eq) return cf == .lt;
        return std.mem.lessThan(u8, &lhs.to.text, &rhs.to.text);
    }

    fn inLessThan(_: void, lhs: In, rhs: In) bool {
        const ct = std.mem.order(u8, &lhs.task.text, &rhs.task.text);
        if (ct != .eq) return ct == .lt;
        return std.mem.lessThan(u8, &lhs.arc.text, &rhs.arc.text);
    }

    fn emit(self: *Store, buf: *std.ArrayList(u8), ev: Event) !void {
        try codec.encode(buf, self.gpa, ev);
        try buf.append(self.gpa, '\n');
    }

    // ----------------------------------------------------------------- queries

    /// Look up a doc_id in the registry. Returns the repo-relative path if
    /// registered, or null if the doc_id has never been set. The returned slice
    /// is arena-owned and valid for the lifetime of the Store.
    pub fn docPath(self: *Store, doc_id: []const u8) ?[]const u8 {
        return self.doc_paths.get(doc_id);
    }

    /// All tasks that directly need `id` (the reverse of `dep` edges — tasks
    /// whose `from` points at `id`). Caller owns the returned slice.
    /// Sorted ascending by Ulid for deterministic output.
    pub fn reverseDeps(self: *Store, alloc: std.mem.Allocator, id: Ulid) ![]Ulid {
        var out: std.ArrayList(Ulid) = .empty;
        for (self.needs.items) |e| {
            if (e.to.eql(id)) try out.append(alloc, e.from);
        }
        const s = try out.toOwnedSlice(alloc);
        std.sort.pdq(Ulid, s, {}, Ulid.lessThan);
        return s;
    }

    /// A raw log entry for `trk log` (event history view).
    pub const LogEntry = struct {
        ts: i64,
        op: model.Op,
        /// The primary task id for this event (null for setDocPath which has no task id).
        task_id: ?Ulid,
        /// Human-readable summary of the event. gpa-owned; caller frees.
        summary: []const u8,
    };

    /// Read the raw event log (snapshot + log) in file order, returning a slice of
    /// LogEntry. Caller owns the slice and must free each `summary` plus the slice
    /// itself. Events are returned in file order (snapshot first, then log).
    pub fn readLogEntries(self: *Store, alloc: std.mem.Allocator) ![]LogEntry {
        var out: std.ArrayList(LogEntry) = .empty;
        try self.collectLogEntries(&out, alloc, snapshot_name);
        try self.collectLogEntries(&out, alloc, log_name);
        return out.toOwnedSlice(alloc);
    }

    fn collectLogEntries(self: *Store, out: *std.ArrayList(LogEntry), alloc: std.mem.Allocator, name: []const u8) !void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer sub.close(self.io);

        const bytes = sub.readFileAlloc(self.io, name, alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer alloc.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const ev = codec.decode(alloc, trimmed) catch continue;
            defer freeEvent(alloc, ev);

            var ts: i64 = 0;
            var task_id: ?Ulid = null;
            const summary = switch (ev) {
                .add => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "add: {s}", .{x.title});
                },
                .setState => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk if (x.holder) |h|
                        try std.fmt.allocPrint(alloc, "state -> {s} (held by {s})", .{ x.state.toString(), h })
                    else
                        try std.fmt.allocPrint(alloc, "state -> {s}", .{x.state.toString()});
                },
                .dep => |x| blk: {
                    ts = x.ts;
                    task_id = x.from;
                    break :blk try std.fmt.allocPrint(alloc, "dep: {s} needs {s}", .{ x.from.slice(), x.to.slice() });
                },
                .undep => |x| blk: {
                    ts = x.ts;
                    task_id = x.from;
                    break :blk try std.fmt.allocPrint(alloc, "undep: {s} no longer needs {s}", .{ x.from.slice(), x.to.slice() });
                },
                .in => |x| blk: {
                    ts = x.ts;
                    task_id = x.task;
                    break :blk try alloc.dupe(u8, "in arc");
                },
                .unin => |x| blk: {
                    ts = x.ts;
                    task_id = x.task;
                    break :blk try std.fmt.allocPrint(alloc, "unin: {s} no longer in {s}", .{ x.task.slice(), x.arc.slice() });
                },
                .setPriority => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "priority -> {d}", .{x.priority});
                },
                .tag => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "tag: +{s}", .{x.tag});
                },
                .untag => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "tag: -{s}", .{x.tag});
                },
                .setTitle => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "title -> {s}", .{x.title});
                },
                .setBody => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try alloc.dupe(u8, "body updated");
                },
                .docref => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "docref: {s}", .{x.doc_id});
                },
                .undocref => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "docref: -{s}", .{x.doc_id});
                },
                .setDocPath => |x| blk: {
                    ts = x.ts;
                    task_id = null;
                    break :blk try std.fmt.allocPrint(alloc, "docpath: {s} -> {s}", .{ x.doc_id, x.path });
                },
                .arcDeclare => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "arc: {s}", .{if (x.declared) "declared" else "undeclared"});
                },
                .arcStanding => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "arc: {s}", .{if (x.standing) "marked standing" else "unmarked standing"});
                },
                .setShort => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "short frozen: {s}", .{x.short});
                },
                .release => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "release: lease held by {s}", .{x.holder});
                },
            };
            try out.append(alloc, .{
                .ts = ts,
                .op = std.meta.activeTag(ev),
                .task_id = task_id,
                .summary = summary,
            });
        }
    }

    pub fn get(self: *Store, id: Ulid) ?Task {
        return self.tasks.get(key(id));
    }

    pub fn count(self: *Store) usize {
        return self.tasks.count();
    }

    /// Every task id, sorted ascending (ULID == chronological). Caller owns the
    /// slice. Used by the CLI for prefix resolution and `shortId` (it needs the
    /// full id set to find the shortest unambiguous prefix). A thin public
    /// wrapper over the internal `sortedTaskIds` — keeps the iteration order
    /// deterministic for the human projections.
    pub fn allIds(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        return self.sortedTaskIds(alloc);
    }

    fn sortedTaskIds(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var ids = try alloc.alloc(Ulid, self.tasks.count());
        var it = self.tasks.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) ids[i] = .{ .text = k.* };
        std.sort.pdq(Ulid, ids, {}, Ulid.lessThan);
        return ids;
    }

    /// All tasks in arc `arc`: direct `in arc` members, plus everything
    /// reachable from a member by following `needs` edges (a prereq of a member
    /// is in the arc). The arc root itself is included. Caller owns the slice.
    pub fn membersOf(self: *Store, alloc: std.mem.Allocator, arc: Ulid) ![]Ulid {
        var seen = std.AutoHashMapUnmanaged(Key, void){};
        defer seen.deinit(self.gpa);
        var frontier: std.ArrayList(Ulid) = .empty;
        defer frontier.deinit(self.gpa);

        // Seeds: the arc root + every direct `in arc` member.
        try self.pushUnseen(&seen, &frontier, arc);
        for (self.ins.items) |e| {
            if (e.arc.eql(arc)) try self.pushUnseen(&seen, &frontier, e.task);
        }

        // Closure over `needs`: from a member `m`, every `to` of `m needs to`
        // is also a member (the prereq belongs to the arc).
        var i: usize = 0;
        while (i < frontier.items.len) : (i += 1) {
            const m = frontier.items[i];
            for (self.needs.items) |e| {
                if (e.from.eql(m)) try self.pushUnseen(&seen, &frontier, e.to);
            }
        }

        const out = try alloc.alloc(Ulid, frontier.items.len);
        @memcpy(out, frontier.items);
        std.sort.pdq(Ulid, out, {}, Ulid.lessThan);
        return out;
    }

    fn pushUnseen(self: *Store, seen: *std.AutoHashMapUnmanaged(Key, void), frontier: *std.ArrayList(Ulid), id: Ulid) !void {
        const gop = try seen.getOrPut(self.gpa, key(id));
        if (!gop.found_existing) try frontier.append(self.gpa, id);
    }

    /// Every arc that `task` belongs to (direct `in` membership OR reachability:
    /// `task` is reachable-via-`needs` from a member of the arc). Caller owns slice.
    pub fn arcsOf(self: *Store, alloc: std.mem.Allocator, task: Ulid) ![]Ulid {
        // An arc is any id that appears as an `in.arc`. For each, test membership.
        var arc_seen = std.AutoHashMapUnmanaged(Key, void){};
        defer arc_seen.deinit(self.gpa);
        var arcs: std.ArrayList(Ulid) = .empty;
        defer arcs.deinit(self.gpa);
        for (self.ins.items) |e| {
            const gop = try arc_seen.getOrPut(self.gpa, key(e.arc));
            if (!gop.found_existing) try arcs.append(self.gpa, e.arc);
        }

        var out: std.ArrayList(Ulid) = .empty;
        for (arcs.items) |arc| {
            const members = try self.membersOf(self.gpa, arc);
            defer self.gpa.free(members);
            for (members) |m| {
                if (m.eql(task)) {
                    try out.append(self.gpa, arc);
                    break;
                }
            }
        }
        const slice = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(slice);
        const final = try alloc.alloc(Ulid, slice.len);
        @memcpy(final, slice);
        std.sort.pdq(Ulid, final, {}, Ulid.lessThan);
        return final;
    }

    // -------------------------------------------------------------- arc-as-prereq

    /// True if `id` is an arc: EXPLICITLY DECLARED — an `arcDeclare{declared:
    /// true}` event (`trk arc <id>` / `trk add --arc`, folded into
    /// `declared_arcs`), OR (back-compat, read-only) the deprecated cosmetic
    /// `arc:` slug tag. A `needs` edge whose target is an arc means "needs
    /// the whole arc."
    ///
    /// Arc-ness is NEVER inferred from a bare `in` edge (01KYTFRD7, fixed
    /// 2026-07-30). It used to be: `isArc` returned true for ANY id that
    /// appeared as the `arc` of some `in` edge, with no declaration and no
    /// check — so `trk in <anything> <X>` silently MINTED X as an arc root,
    /// which is exactly how a reversed-argument call (`trk in <arc> <task>`
    /// instead of `<task> <arc>`) turned `<task>` into a spurious arc root
    /// instead of failing loud. `Store.append` now requires `T in X`'s `X` to
    /// already satisfy `isArc` (see there) — declared first, `in` second —
    /// which is also what makes legitimate NESTED-arc authoring (`trk arc P`,
    /// then `trk in A P`) unambiguous: the target was already a real arc
    /// before the edge, not retroactively promoted by it. `trk migrate-arcs`
    /// backfilled a real `arcDeclare` for every arc that existed ONLY via
    /// in-edge inference at the time of the fix, so this narrowing changes
    /// nothing for any arc that existed before it landed — only a brand-new,
    /// never-declared `in` target is affected going forward. The `arc:` tag
    /// path is untouched by this narrowing (a separate, already-migratable
    /// back-compat path with its own `trk migrate-arcs` handling — DEPRECATED,
    /// do not write new `arc:` tags).
    pub fn isArc(self: *Store, id: Ulid) bool {
        if (self.declared_arcs.contains(key(id))) return true;
        if (self.tasks.get(key(id))) |t| {
            for (t.tags.items) |tg| {
                if (std.mem.startsWith(u8, tg, "arc:")) return true;
            }
        }
        return false;
    }

    /// True iff `id` is marked a STANDING arc (`trk arc <id> --standing`): a
    /// goal container that names a perpetual category rather than a
    /// completable goal. Consulted only where it matters — `next` excludes a
    /// standing arc from the ready frontier unconditionally, drained or not,
    /// so it never surfaces as a false "this looks finished, close it?"
    /// prompt. Meaningless (but harmless) on a task for which `isArc` is
    /// false; `trk arc <id> --standing` always declares the arc in the same
    /// act, so that combination should not arise via the CLI.
    pub fn isStanding(self: *Store, id: Ulid) bool {
        return self.standing_arcs.contains(key(id));
    }

    /// Every declared arc root id: in `declared_arcs`, or (back-compat)
    /// carries an `arc:` tag — i.e. every id for which `isArc` is true.
    /// Caller owns the slice. Shared by `arcless` and the CLI's arc-section
    /// collector so both use the identical set.
    pub fn arcRoots(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var out: std.ArrayList(Ulid) = .empty;
        var it = self.tasks.keyIterator();
        while (it.next()) |k| {
            const id: Ulid = .{ .text = k.* };
            if (self.isArc(id)) try out.append(alloc, id);
        }
        const s = try out.toOwnedSlice(alloc);
        std.sort.pdq(Ulid, s, {}, Ulid.lessThan);
        return s;
    }

    /// Every task belonging to NO arc: not itself an arc root, not a direct
    /// `in` member of one, and not `needs`-reachable from a member of one —
    /// the complement of the union of `membersOf(arc)` over every arc root.
    /// The completeness counterpart to `membersOf`: the terminating condition
    /// for "sort everything into arcs" (`trk list --no-arc`), and what
    /// `render`'s generated header counts as drift. Caller owns the slice.
    pub fn arcless(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        const roots = try self.arcRoots(self.gpa);
        defer self.gpa.free(roots);

        var in_some = std.AutoHashMapUnmanaged(Key, void){};
        defer in_some.deinit(self.gpa);
        for (roots) |arc| {
            const members = try self.membersOf(self.gpa, arc);
            defer self.gpa.free(members);
            for (members) |m| try in_some.put(self.gpa, key(m), {});
        }

        var out: std.ArrayList(Ulid) = .empty;
        var it = self.tasks.keyIterator();
        while (it.next()) |k| {
            if (!in_some.contains(k.*)) try out.append(self.gpa, .{ .text = k.* });
        }
        const s = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(s);
        const final = try alloc.alloc(Ulid, s.len);
        @memcpy(final, s);
        std.sort.pdq(Ulid, final, {}, Ulid.lessThan);
        return final;
    }

    /// Drained: no DIRECT member (a task with `in id`), excluding members tagged
    /// `parked` (optional/future stubs), is unsatisfied. Vacuously TRUE for an
    /// arc with no non-parked members — nothing actionable is pending, so the
    /// root should surface for its close-out rather than black-hole.
    ///
    /// Drained is the OBSERVED fact and is never stored (it flaps by design: a
    /// newly filed member un-drains the arc). The root's own `done` is the
    /// completion JUDGMENT: `needs` gates wait on the root's state like any
    /// other prereq; `next` uses drained only to decide when to OFFER the root
    /// (the close-out prompt). See design.md's drained-vs-complete ruling.
    /// Direct members only: a member can't be done while its own `needs` are
    /// open, so "all direct members satisfied" implies their prereqs.
    pub fn arcDrained(self: *Store, id: Ulid) bool {
        for (self.ins.items) |e| {
            if (!e.arc.eql(id)) continue;
            const m = self.tasks.get(key(e.task)) orelse return false; // unknown member → not drained
            if (self.taskHasTag(m, "parked")) continue; // parked stubs don't gate
            if (!m.state.satisfiesPrereq()) return false;
        }
        return true;
    }

    /// (done, total) over an arc's DIRECT, non-parked members — for display.
    pub fn arcProgress(self: *Store, id: Ulid) struct { done: usize, total: usize } {
        var d: usize = 0;
        var n: usize = 0;
        for (self.ins.items) |e| {
            if (!e.arc.eql(id)) continue;
            const m = self.tasks.get(key(e.task)) orelse continue;
            if (self.taskHasTag(m, "parked")) continue;
            n += 1;
            if (m.state.satisfiesPrereq()) d += 1;
        }
        return .{ .done = d, .total = n };
    }

    fn taskHasTag(_: *Store, t: Task, tag: []const u8) bool {
        for (t.tags.items) |tg| {
            if (std.mem.eql(u8, tg, tag)) return true;
        }
        return false;
    }

    // ----------------------------------------------------------------- next

    /// The per-task sort key for `next` / a future list view.
    /// Ordering:
    ///   1. personal priority, EFFECTIVE (`model.effectivePriority`: stored `0`
    ///      = unset ranks at `default_priority`); lower first.
    ///   2. best (smallest) arc-priority `seq` across all arcs the task is in
    ///      (a task in NO arc gets the sentinel max → orders after arc'd tasks
    ///      OF THE SAME PRIORITY).
    ///   3. id (ULID; stable, time-ascending tiebreak).
    ///
    /// Priority leads and arc-seq breaks its ties (2026-08-19, task 01KZD94QY);
    /// it used to be the reverse, which made priority vestigial — arc-seq is a
    /// task's position WITHIN its arc, not the arc's rank, so priority only ever
    /// separated tasks sharing a seq, and the arcless sentinel buried every
    /// standalone task no matter how extreme its priority (measured: the single
    /// highest-priority task in the Enix backlog sat at row 131 of 211, unseen
    /// under any `--limit`). Because unset now ranks at `default_priority`
    /// rather than at the strongest value, the untouched majority still ties on
    /// key 1 and falls through to arc-seq — so this reorders exactly the tasks
    /// someone deliberately prioritised, and nothing else.
    pub const Ranked = struct {
        id: Ulid,
        best_arc_seq: i64,
        /// Already passed through `model.effectivePriority`.
        priority: i32,

        fn less(_: void, x: Ranked, y: Ranked) bool {
            if (x.priority != y.priority) return x.priority < y.priority;
            if (x.best_arc_seq != y.best_arc_seq) return x.best_arc_seq < y.best_arc_seq;
            return x.id.order(y.id) == .lt;
        }
    };

    /// The ready frontier: every `open` task whose every `needs`-target is
    /// satisfied (state `done` or `dropped`), ordered per `Ranked.less`. A task
    /// with no `needs` is trivially ready; a task in no arc still appears
    /// (sorted after arc'd tasks of the SAME priority, by the sentinel). An arc
    /// ROOT is a container —
    /// its work is its members' — so it is additionally held back until the arc
    /// is drained, then surfaces exactly once as the close-out prompt. A `needs`
    /// edge targeting a root gates on the root's own state (the completion
    /// judgment), NOT on drainage — the root is an ordinary prereq here.
    /// Caller owns the slice.
    pub fn next(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(self.gpa);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr.*;
            if (!t.state.isEligible()) continue; // only `open` is eligible

            if (self.isArc(t.id)) {
                // A standing arc (a perpetual category, not a completable goal)
                // NEVER surfaces here, drained or not — offering it as the
                // close-out prompt would assert a completion that never
                // happens (see `isStanding`).
                if (self.isStanding(t.id)) continue;
                // An undrained arc root is never handed out (do the members first).
                if (!self.arcDrained(t.id)) continue;
            }

            // Every prereq must be satisfied.
            var ready = true;
            for (self.needs.items) |e| {
                if (!e.from.eql(t.id)) continue;
                const pre = self.tasks.get(key(e.to)) orelse {
                    // A placeholder prereq we never learned the state of: treat
                    // as not-satisfied (default state `open` blocks) — it's
                    // conservatively NOT ready. (Placeholders default to .open.)
                    ready = false;
                    break;
                };
                if (!pre.state.satisfiesPrereq()) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;

            // Best arc-priority across this task's arcs.
            const arcs = try self.arcsOf(self.gpa, t.id);
            defer self.gpa.free(arcs);
            var best: i64 = std.math.maxInt(i64); // sentinel: arc-less sorts last
            for (arcs) |arc| {
                for (self.ins.items) |e| {
                    if (e.task.eql(t.id) and e.arc.eql(arc)) {
                        if (e.seq < best) best = e.seq;
                    }
                }
            }
            try ranked.append(self.gpa, .{
                .id = t.id,
                .best_arc_seq = best,
                .priority = model.effectivePriority(t.priority),
            });
        }

        std.sort.pdq(Ranked, ranked.items, {}, Ranked.less);
        const out = try alloc.alloc(Ulid, ranked.items.len);
        for (ranked.items, 0..) |r, i| out[i] = r.id;
        return out;
    }
};
