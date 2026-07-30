// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! `trk` CLI core — argument parsing, prefix resolution, the `next`/`list`
//! output formatting, and the two human projections (`render` markdown +
//! `tree` ASCII hierarchy). Wires the verbs onto the Wave-1 `Store` API; no
//! store *semantics* live here (writes go through `Store.append`).
//!
//! Design notes:
//!   - Output is written into a caller-owned `*std.ArrayList(u8)` (the `out`
//!     field), never directly to a TTY. main.zig flushes it to stdout; tests
//!     assert against it. This keeps the CLI writer-parameterized and
//!     cross-compile-clean (no POSIX TTY assumptions).
//!   - User errors surface as `CliError` + a clean message appended to `out`
//!     (main maps that to a non-zero exit). No Zig stack traces on bad input.
//!   - ID ergonomics: every id argument accepts a unique ULID *prefix*
//!     (git-short-hash style). All human output uses short ids, but a short
//!     id is NOT always dynamically computed: a task minted after short-id
//!     freezing landed (or migrated via `trk migrate-shorts`) carries a
//!     PERSISTED `short` that `shortId` returns verbatim, stable forever —
//!     it never changes on add, archive, or compact. A task with no
//!     persisted short falls back to the legacy behavior: the shortest
//!     CURRENTLY-unambiguous prefix (min `min_short`), which moves as the
//!     live id set moves. See design.md "short-id stability".

const std = @import("std");
const tracker = @import("tracker");
const ulid = tracker.ulid;

const Store = tracker.Store;
const Ulid = tracker.Ulid;
const State = tracker.State;
const Task = tracker.Task;
const Io = std.Io;

/// Minimum length of a DYNAMICALLY-computed short id — the legacy/back-compat
/// path for a task with no persisted `short` (git uses 7; ULIDs are denser,
/// but a short floor keeps them recognizable). This value governs ONLY the
/// fallback computation; it is intentionally left at its historical value —
/// existing un-migrated ids are never retroactively re-lengthened.
pub const min_short = 6;

/// Floor for a NEWLY MINTED task's short id (`Cli.mintShortId`), frozen
/// forever into `Task.short` at mint time. Higher than the legacy
/// `min_short` floor: 9 matches the dominant historical id length in
/// practice, so a fresh mint less often needs extending past the floor —
/// and because a frozen short is never recomputed, a longer floor pays off
/// once instead of on every future collision check.
pub const min_short_mint = 9;

/// User-facing errors. Each is reported as a clean one-line message; the caller
/// (main) maps any `CliError` to a non-zero exit code. `error.DependencyCycle`
/// from the store is folded in here too.
pub const CliError = error{
    UsageError,
    UnknownCommand,
    MissingArgument,
    UnknownFlag,
    BadId,
    AmbiguousId,
    NoSuchId,
    BadState,
    BadNumber,
    DependencyCycle,
    /// A mutating verb was rejected because `read_only` is set (mirrors the
    /// `TRK_READONLY` env var main.zig checks).
    ReadOnly,
    /// `trk add` landed a task in no arc (neither `--in` nor `--arc`) while
    /// `.tracker/config.json`'s `add.arcless` is `"error"`.
    NoArc,
    /// `trk in <task> <arc>` (or `trk add --in <arc>`) named an `<arc>` that
    /// is not a declared arc — see `Store.isArc`/`Store.append`'s doc
    /// comments for why this is no longer inferred from the edge itself.
    UndeclaredArc,
    /// `trk stale` could not run or was refused by `git log` (not a git repo,
    /// `git` missing from PATH, non-zero exit). A clean message is already
    /// appended to `out` before this is returned.
    GitLogFailed,
};

/// The store's write path surfaces a broad fs error set (append/atomicWrite).
/// We union it in rather than re-listing it so it stays correct if the store's
/// I/O surface changes.
const StoreWriteError = @typeInfo(@typeInfo(@TypeOf(Store.append)).@"fn".return_type.?).error_union.error_set;
const StoreCompactError = @typeInfo(@typeInfo(@TypeOf(Store.compact)).@"fn".return_type.?).error_union.error_set;

pub const Error = CliError || std.mem.Allocator.Error || error{WriteFailed} ||
    StoreWriteError || StoreCompactError || std.Io.Dir.WriteFileError;

pub const Cli = struct {
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    /// Where `dir`-relative `--out` paths are written. Borrowed.
    dir: Io.Dir,
    /// Accumulated stdout-bound output. Caller owns it.
    out: *std.ArrayList(u8),
    /// Accumulated stderr-bound output (currently: the `trk add` arc-less
    /// warning). Kept separate from `out` because `out` is scriptable
    /// (`ID=$(trk add "x")`) and must never carry a warning line. main.zig
    /// flushes this to real stderr; tests assert against it directly. Caller
    /// owns it.
    warn: *std.ArrayList(u8),
    /// When true, every mutating verb (see `mutating_verbs` below) refuses
    /// with `error.ReadOnly` before dispatch; read verbs are unaffected.
    /// main.zig sets this from the `TRK_READONLY` env var; tests can set it
    /// directly on a `Cli` built over a `Fixture`.
    read_only: bool = false,
    /// Scratch for `directPrereqs` — must be drained/copied before the next
    /// call. tree recursion copies into a local dupe before recursing, so reuse
    /// is safe. Owned by the Cli; the caller (main/tests) deinits it.
    prereq_scratch: std.ArrayList(Ulid) = .empty,

    fn print(self: *Cli, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, fmt, args);
    }

    fn write(self: *Cli, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    /// Append `s` as a JSON string literal (quotes + minimal escaping). Used by
    /// the `--json` output of `list`/`next` so titles/tags with quotes, newlines,
    /// or control chars stay valid JSON.
    fn writeJsonString(self: *Cli, s: []const u8) !void {
        try self.write("\"");
        for (s) |ch| switch (ch) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => if (ch < 0x20)
                try self.print("\\u{x:0>4}", .{ch})
            else
                try self.out.append(self.gpa, ch),
        };
        try self.write("\"");
    }

    /// One task as a JSON object: id (full), short, title, state, priority,
    /// [seq when an arc context is given], tags. Relations stay in `trk show`.
    fn appendTaskJson(self: *Cli, id: Ulid, arc_id: ?Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        try self.print("{{\"id\":\"{s}\",\"short\":\"{s}\",\"title\":", .{ &id.text, sid });
        try self.writeJsonString(t.title);
        try self.print(",\"state\":\"{s}\",\"priority\":{d}", .{ t.state.toString(), t.priority });
        if (self.seqFor(id, arc_id)) |s| try self.print(",\"seq\":{d}", .{s});
        try self.write(",\"tags\":[");
        for (t.tags.items, 0..) |tg, i| {
            if (i != 0) try self.write(",");
            try self.writeJsonString(tg);
        }
        try self.write("]}");
    }

    // ----------------------------------------------------------- dispatch

    /// Run one CLI invocation. `args` is argv WITHOUT the program name (so
    /// `args[0]` is the subcommand). The store must already be loaded.
    pub fn run(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) return self.usage();
        const cmd = args[0];
        const rest = args[1..];

        // Help routing, BEFORE dispatch. `trk help [<verb>]`, `trk -h`/`--help`,
        // and `trk <verb> --help`/`-h` all explain rather than execute. This also
        // guards the classic agent trap: without it `trk add --help` parses
        // `--help` as the <title> and mints a task literally called "--help".
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            if (rest.len > 0) return self.helpFor(rest[0]);
            return self.usage();
        }
        if (argsWantHelp(rest)) return self.helpFor(cmd);

        if (self.read_only and isMutating(cmd, rest)) {
            try self.print("trk: refusing to run '{s}' — TRK_READONLY is set (mutations are disabled)\n", .{cmd});
            return error.ReadOnly;
        }

        if (std.mem.eql(u8, cmd, "init")) return self.cmdInit(rest);
        if (std.mem.eql(u8, cmd, "add")) return self.cmdAdd(rest);
        if (std.mem.eql(u8, cmd, "dep")) return self.cmdDep(rest);
        if (std.mem.eql(u8, cmd, "undep")) return self.cmdUndep(rest);
        if (std.mem.eql(u8, cmd, "in")) return self.cmdIn(rest);
        if (std.mem.eql(u8, cmd, "unin")) return self.cmdUnin(rest);
        if (std.mem.eql(u8, cmd, "arc")) return self.cmdArc(rest);
        if (std.mem.eql(u8, cmd, "migrate-arcs")) return self.cmdMigrateArcs(rest);
        if (std.mem.eql(u8, cmd, "migrate-shorts")) return self.cmdMigrateShorts(rest);
        if (std.mem.eql(u8, cmd, "state")) return self.cmdState(rest);
        if (std.mem.eql(u8, cmd, "next")) return self.cmdNext(rest);
        if (std.mem.eql(u8, cmd, "list")) return self.cmdList(rest);
        if (std.mem.eql(u8, cmd, "render")) return self.cmdRender(rest);
        if (std.mem.eql(u8, cmd, "tree")) return self.cmdTree(rest);
        if (std.mem.eql(u8, cmd, "compact")) return self.cmdCompact(rest);
        if (std.mem.eql(u8, cmd, "archive")) return self.cmdArchive(rest);
        if (std.mem.eql(u8, cmd, "doc")) return self.cmdDoc(rest);
        if (std.mem.eql(u8, cmd, "show")) return self.cmdShow(rest);
        if (std.mem.eql(u8, cmd, "edit")) return self.cmdEdit(rest);
        if (std.mem.eql(u8, cmd, "log")) return self.cmdLog(rest);
        if (std.mem.eql(u8, cmd, "stale")) return self.cmdStale(rest);
        try self.print("trk: unknown command '{s}'\n", .{cmd});
        return error.UnknownCommand;
    }

    /// True iff `--help` or `-h` appears as a standalone token in `rest`. A flag
    /// *value* of literally "--help" (e.g. `--body --help`) would also trip this,
    /// but "--help" is never a real title/body/tag in practice, so treating it as
    /// a help request everywhere is the right trade for agent ergonomics.
    fn argsWantHelp(rest: []const []const u8) bool {
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
        }
        return false;
    }

    /// Every verb whose dispatch writes persisted state: an appended log
    /// event (`add`/`dep`/`undep`/`in`/`unin`/`state`/`edit`/`doc set`/`doc
    /// unset`), a scaffolded `.tracker/` (`init`), a rewritten snapshot
    /// (`compact`), or an out-file (`render`, `archive`). Everything else
    /// (`next`/`list`/`show`/`tree`/`log`/`doc list`/`doc resolve`/`help`) is
    /// read-only. `read_only` (`TRK_READONLY`) gates exactly this set.
    const mutating_verbs = [_][]const u8{
        "init", "add", "dep", "undep", "in", "unin", "arc", "migrate-arcs", "migrate-shorts", "state", "render", "compact", "archive", "edit",
    };

    fn isMutating(cmd: []const u8, rest: []const []const u8) bool {
        for (mutating_verbs) |v| {
            if (std.mem.eql(u8, cmd, v)) return true;
        }
        if (std.mem.eql(u8, cmd, "doc")) {
            if (rest.len > 0 and (std.mem.eql(u8, rest[0], "set") or std.mem.eql(u8, rest[0], "unset"))) return true;
        }
        return false;
    }

    /// Per-verb help. `text` is a full synopsis + purpose + key flags + an
    /// example for one verb. Keep an entry here for EVERY dispatched verb — the
    /// "every verb supports --help" test enumerates the verbs and asserts each
    /// has an entry (and that the table count matches), so the `trk <verb> --help`
    /// contract can't silently rot as verbs are added.
    const VerbHelp = struct { name: []const u8, text: []const u8 };
    pub const verb_help = [_]VerbHelp{
        .{ .name = "init", .text =
        \\trk init [--out <path>] [--force]
        \\  Scaffold a fresh tracker: .tracker/ + an empty log, a config.json
        \\  (render.out defaults to docs/TODO.md; set it with --out), and a starter
        \\  TODO.md. Idempotent + non-destructive: never overwrites an existing
        \\  TODO.md; --force rewrites config.json only.
        \\  e.g.  trk init            trk init --out TODO.md
        },
        .{ .name = "add", .text =
        \\trk add "<title>" [--body <s>] [--tag <t> ...] [--doc <doc_id[#section]> ...]
        \\       [--in <arc> [--seq <n>]] [--arc] [--needs <id> ...] [--priority <n>] [-v]
        \\  Create a task. Prints ONLY the new full ULID (scriptable: ID=$(trk add "x"));
        \\  -v/--verbose prints the friendly "added <short> (<full>)" instead. --needs
        \\  wires prerequisite edges, --in adds it to an EXISTING, ALREADY-DECLARED arc as
        \\  a member (refused with UndeclaredArc otherwise — declare it first with `trk
        \\  arc`), --arc declares THIS new task itself an arc root (even with zero members
        \\  yet, and needs no prior declaration), --doc
        \\  attaches a design pointer (register the id first with `trk doc set`). Priority:
        \\  int, lower first. Neither --in nor --arc given -> a stderr warning (never
        \\  stdout); escalate to a hard error via .tracker/config.json's add.arcless.
        \\  A `--tag arc:<slug>` is a DEPRECATED way to mark an arc (still honored, but
        \\  warns) — use --arc instead.
        \\  e.g.  trk add "Add dark mode" --tag ui --in 01KVX4K0 --needs 01KWZJFRR
        \\        trk add "Ship v2" --arc
        },
        .{ .name = "dep", .text =
        \\trk dep <needer> <prereq>
        \\  Make <needer> require prerequisite <prereq> (a `needs` edge). Arg order
        \\  is needer-THEN-prereq; reversing wires the DAG backwards. Rejected if it
        \\  would close a cycle. Fix a backwards edge with `trk undep`.
        \\  `dep`/`in` are NOT interchangeable: `dep` only adds DAG ordering (and, as a
        \\  side effect, reachability-membership if the prereq belongs to an arc) — it
        \\  never by itself makes anything an arc. See `trk in --help`.
        \\  ALSO rejected if <needer> is a (direct or transitive) member of <prereq>'s
        \\  arc: an arc can't finish while an open member waits on it, so a member
        \\  needing its own arc is a permanent self-wait, not an ordinary cycle. A
        \\  prereq in a DIFFERENT arc — or the whole of a different arc — is unaffected.
        \\  e.g.  trk dep 01KX6H4V 01KX6H48   (init needs config)
        },
        .{ .name = "undep", .text =
        \\trk undep <needer> <prereq>
        \\  Remove the <needer> needs <prereq> edge (tombstoned; a no-op if absent).
        \\  Use to undo a `dep` wired the wrong way.
        },
        .{ .name = "in", .text =
        \\trk in <task> <arc> [--seq <n>]
        \\  Add <task> to arc <arc> as a DIRECT member, optionally ordered by --seq.
        \\  <arc> MUST already be a declared arc (`trk arc <arc>` / `trk add --arc`) —
        \\  `in` no longer mints one on the fly. Rejected with `UndeclaredArc` if it
        \\  isn't; declare it first, then retry.
        \\  ARGUMENT ORDER: <task> FIRST, <arc> SECOND — the opposite of how you'd say
        \\  "arc needs task" via `trk dep <arc> <task>`. Reversing it (`trk in <arc>
        \\  <task>`) either fails outright (if <task> was never declared an arc — the
        \\  common case, and the whole point of the declared-arc requirement above) or,
        \\  if BOTH ids happen to already be declared arcs, silently makes <arc> a
        \\  member of <task> instead, exactly backwards. If unsure, verify after with
        \\  `trk tree <arc>` (the new task should appear nested under it) or
        \\  `trk show <task>` (its `arcs:` list should include <arc>).
        \\  A backwards call between two already-declared arcs is fixed with
        \\  `trk unin <task> <arc>` — same argument order as this command, NOT swapped
        \\  (see `trk unin --help`).
        \\  `in` and `dep` are NOT interchangeable: `in` is the membership-authoring
        \\  primitive (requires <arc> already declared, per above); `dep` only adds a
        \\  `needs` prerequisite edge, and merely auto-JOINS an existing arc via
        \\  reachability when the prereq's dependent is already a member.
        \\  Rejected if <task> already (directly or transitively) NEEDS <arc>: the
        \\  membership would close the same self-wait loop `dep` guards against, just
        \\  from the other direction — see `trk dep --help`. Also rejected if <task>
        \\  and <arc> are the same id (a task cannot be a member of itself).
        \\  e.g.  trk arc 01KVX4K0               (declare 01KVX4K0 an arc, once)
        \\        trk in 01KX6H4V 01KVX4K0       (add 01KX6H4V to arc 01KVX4K0)
        },
        .{ .name = "unin", .text =
        \\trk unin <task> <arc>
        \\  Remove the <task> in <arc> membership edge (tombstoned; a no-op if
        \\  absent). Exact mirror of `undep`, for the `in` edge kind. Same argument
        \\  order as `trk in` (task first, arc second) — do NOT swap.
        \\  To undo a swapped-argument `trk in` mistake, replay the SAME two ids in
        \\  the SAME (wrong) order you originally typed, just with `unin` swapped
        \\  in for `in` — e.g. if `trk in A B` was meant to be `trk in B A`, the fix
        \\  is `trk unin A B` (not `trk unin B A`), because the edge that actually
        \\  got written has A in the task slot and B in the arc slot.
        \\  e.g.  trk unin 01KX6H4V 01KVX4K0
        },
        .{ .name = "arc", .text =
        \\trk arc <id> [--undo] [--standing [--undo]]
        \\  Declare <id> an arc root (an `arcDeclare` event), independent of whether any
        \\  task is `in` it — the fix for an arc with genuinely zero members yet (a real
        \\  goal with no work filed), which a direct-`in`/reachability check alone cannot
        \\  express. `--undo` retracts the declaration (a no-op if <id> is still an arc
        \\  via an `in` member) and also clears any standing mark. `trk add --arc`
        \\  declares a brand-new task in one step.
        \\  --standing marks <id> a STANDING arc: a perpetual category (housekeeping,
        \\  the debug/observability substrate) rather than a completable goal — it
        \\  never surfaces in `trk next`, drained or not, but still accepts new `in`
        \\  members. Declares the arc in the same act. `--standing --undo` clears
        \\  JUST the standing mark, leaving the arc declaration intact.
        \\  e.g.  trk arc 01KX6H4V           trk arc 01KX6H4V --undo
        \\        trk arc 01KVKHBZQ --standing           trk arc 01KVKHBZQ --standing --undo
        },
        .{ .name = "migrate-arcs", .text =
        \\trk migrate-arcs
        \\  One-time (but idempotent/re-runnable) migration, two passes: (1) for every
        \\  task carrying a legacy `arc:<slug>` tag, emit an `arcDeclare{declared:true}`
        \\  and strip the tag; (2) for every id that is an arc ONLY because some task
        \\  carries a direct `in` edge naming it (never explicitly declared), emit an
        \\  `arcDeclare{declared:true}` for it too. Prints what it changed, one line per
        \\  migrated task, plus a summary count. A second run finds nothing — safe to
        \\  re-run blind.
        },
        .{ .name = "migrate-shorts", .text =
        \\trk migrate-shorts [--min <n>]
        \\  One-time (but idempotent/re-runnable) migration: for every task with no
        \\  FROZEN short id yet, freeze it at its CURRENT dynamically-computed short
        \\  (a `setShort` event) so it never again changes on add/archive/compact.
        \\  A second run finds nothing (every task now has a frozen short) — safe to
        \\  re-run blind. LIMITATION: if a prior `compact` already shortened/changed an
        \\  id's displayed prefix, that PRE-compact value is not recorded anywhere and
        \\  cannot be recovered — this freezes whatever prefix is CURRENT right now,
        \\  which is the only recoverable baseline. Going forward, frozen ids are stable.
        \\
        \\  --min <n>  REPAIR mode: freeze/re-freeze every task at max(its current
        \\  short length, n), collision-checked. Without --min, an already-frozen
        \\  short is NEVER touched; --min is the one exception that DELIBERATELY
        \\  LENGTHENS an already-frozen short shorter than n — this CHANGES an id a
        \\  prior run already froze (e.g. every id you'd already written down at 8
        \\  or 6 chars becomes longer). Run it once, on purpose, not routinely.
        \\  e.g.  trk migrate-shorts --min 9
        },
        .{ .name = "state", .text =
        \\trk state <id> <open|done|blocked|dropped|claimed>
        \\  Set a task's state. `done` drops it from TODO.md and queues it for
        \\  `trk archive` — it asserts the work PASSED ITS GATE; `dropped` = won't-do
        \\  (also leaves TODO.md); `blocked` is a manual hold. `claimed` is weaker
        \\  than `done`: a CLAIM ("this commit completes the task, pending
        \\  verification"), safe for a compile-only builder to write in the same
        \\  commit as the implementing change — it stays in TODO.md (marker `[c]`,
        \\  distinct from open `[ ]`), does NOT satisfy a dependent's prereq, and
        \\  does NOT appear in `trk next`'s ready frontier. The orchestrator's
        \\  post-gate reconcile promotes it to `done` or demotes it to `open`.
        \\  `trk list --state claimed` is the awaiting-verification queue. Ids
        \\  accept any unique prefix.
        \\  e.g.  trk state 01KX6H48 done           trk state 01KX6H48 claimed
        },
        .{ .name = "next", .text =
        \\trk next [--arc <id>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> ...]
        \\  The ready frontier: open tasks whose prereqs are ALL met. An arc root is
        \\  a container: it is held back until its non-parked members are finished,
        \\  then surfaces once as the close-out prompt (`trk state <root> done` marks
        \\  the goal complete and unblocks anything that needs the arc) — UNLESS the
        \\  arc is marked --standing (`trk arc`), in which case it never surfaces.
        \\  Bare <term>s (repeatable, ANDed) are a case-insensitive substring search
        \\  over title+body+tags. --not-tag <t> (repeatable, ANDed exclusion) drops
        \\  any task carrying that tag — the autonomous-eligible bucket (no blocker
        \\  tag) is one bare command:
        \\    trk next --not-tag metal --not-tag scott-testing --not-tag scott-decision
        \\  --json emits a machine-readable array.
        \\  e.g.  trk next           trk next prism windowed
        },
        .{ .name = "list", .text =
        \\trk list [--arc <id> | --no-arc] [--state <s>] [--tag <t>] [--not-tag <t> ...]
        \\         [--limit <n>] [--json] [<term> ...]
        \\  Every task (not just the ready frontier), filterable by arc/state/tag and
        \\  the same bare-term search as `next`. --not-tag (repeatable, ANDed
        \\  exclusion) drops any task carrying that tag. --no-arc lists every task in
        \\  NO arc (by the unified isArc/membership model, including needs-
        \\  reachability) — the completeness query for "sort everything into arcs";
        \\  mutually exclusive with --arc. --json for machine-readable output.
        \\  e.g.  trk list --state open net           trk list --no-arc
        \\        trk list --state claimed             (the awaiting-verification queue)
        },
        .{ .name = "render", .text =
        \\trk render [--out <path>]
        \\  Write the TODO.md markdown projection. Destination precedence:
        \\  explicit --out > config render.out > stdout. Overwrites the target (it is
        \\  a generated projection with a do-not-edit header) — never hand-edit it.
        \\  A task shared by several arcs is listed in full (tags, docs, body) only
        \\  the first time; later listings link back to that anchor. The header
        \\  reports an arc-less drift count every regeneration (`trk list --no-arc`
        \\  for the list).
        },
        .{ .name = "tree", .text =
        \\trk tree <arc-or-task>
        \\  Print the ASCII prereq hierarchy rooted at an arc or task (prereqs nested
        \\  under their dependents; a shared prereq prints once, then "(seen)").
        },
        .{ .name = "compact", .text =
        \\trk compact
        \\  Rewrite the snapshot + truncate the log, physically GC'ing archived/dropped
        \\  tasks. Orchestrator-only (rewrites the whole snapshot — the merge flashpoint).
        },
        .{ .name = "archive", .text =
        \\trk archive [<term> ...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]
        \\  Graduate DONE tasks to changelog bullets (--out > config archive.out >
        \\  stdout), then flip each to `archived` so it leaves every view (structural
        \\  dedup — re-running finds nothing). A file target is APPENDED to under a
        \\  `## YYYY-MM-DD` run heading, never truncated. --dry-run previews on
        \\  stdout without flipping (and never touches the file).
        },
        .{ .name = "doc", .text =
        \\trk doc set <doc_id> <path>   register/update a doc_id -> repo-relative path
        \\trk doc unset <doc_id>        unregister a doc_id (idempotent; refs fall back
        \\                              to the raw doc_id until it is re-set)
        \\trk doc list                  print all registered doc_id -> path mappings
        \\trk doc resolve <doc_id>      print the path for a doc_id
        \\  The registry backs the --doc/--add-doc design pointers on add/edit.
        },
        .{ .name = "show", .text =
        \\trk show <id> [--body]
        \\  Full detail for one task: body, state, priority, tags, prereqs,
        \\  dependents, arc memberships, and doc pointers. Ids accept any unique prefix.
        \\  --body prints ONLY the raw body bytes (no header, no indent) — the safe
        \\  read half of an edit round-trip:
        \\  trk edit <id> --body "$(trk show <id> --body)"
        },
        .{ .name = "edit", .text =
        \\trk edit <id> [--title <s>] [--body <s>] [--add-tag <t> ...] [--rm-tag <t> ...]
        \\        [--add-doc <doc_id[#section]> ...] [--priority <n>]
        \\  Modify an existing task in place. --body replaces the whole body.
        \\  `--add-tag arc:<slug>` is a DEPRECATED way to mark an arc (still honored,
        \\  but warns) — use `trk arc <id>` instead.
        \\  e.g.  trk edit 01KX6H --body "revised plan" --add-tag tooling
        },
        .{ .name = "log", .text =
        \\trk log [<id>] [--limit <n>]
        \\  Event history, most-recent-last: the whole log, or one task's events.
        },
        .{ .name = "stale", .text =
        \\trk stale
        \\  Cross-reference: which OPEN tasks have their id cited in a LANDED commit
        \\  message (this branch's `git log --oneline` ancestry — deliberately NOT
        \\  `--all`, which would count unmerged worktree-branch commits as landed)
        \\  but were never closed? Matches by exact token (full id or displayed short
        \\  id), not raw substring. `claimed` tasks are excluded (already a healthy,
        \\  awaiting-verification claim, not the "invisible in the haystack" rot this
        \\  targets — see `trk state --help`). Runs `git` against the store root (the
        \\  repo housing `.tracker/`, which may differ from where `trk` itself lives).
        \\  e.g.  trk stale
        },
    };

    /// Print one verb's help (from `verb_help`), or fall back to the full usage
    /// overview for an unknown/absent verb (so `trk help nonsense` still helps).
    fn helpFor(self: *Cli, cmd: []const u8) !void {
        for (verb_help) |v| {
            if (std.mem.eql(u8, v.name, cmd)) {
                try self.write(v.text);
                try self.write("\n");
                return;
            }
        }
        return self.usage();
    }

    fn usage(self: *Cli) !void {
        try self.write(
            \\trk — an in-repo issue tracker
            \\
            \\Usage:
            \\  trk init [--out <path>] [--force]   scaffold .tracker/ + config.json + a starter TODO.md
            \\      Idempotent and non-destructive: never overwrites an existing TODO.md (or
            \\      config.json without --force). --out sets config's render.out (default docs/TODO.md).
            \\  trk add "<title>" [--body <s>] [--tag <t> ...] [--doc <doc_id[#section]> ...] [--in <arc> [--seq <n>]] [--arc]
            \\                    [--needs <id> ...] [--priority <n>] [-v]   (prints the new ULID; -v = friendly)
            \\      Neither --in nor --arc -> warns to stderr (escalate via config's add.arcless).
            \\  trk dep <from> <to>          mark <from> as needing prerequisite <to>
            \\  trk undep <from> <to>        remove the <from> needs <to> edge (tombstone; no-op if absent)
            \\  trk in <task> <arc> [--seq <n>]   add task to an arc, task FIRST (NOT the same order as
            \\      `dep`'s arc-needs-task phrasing — see `trk in --help`)
            \\  trk unin <task> <arc>         remove the <task> in <arc> edge (tombstone; no-op if absent;
            \\      same arg order as `trk in` — fixes a swapped-argument `in` mistake)
            \\  trk arc <id> [--undo] [--standing [--undo]]   declare/retract <id> as an arc root
            \\      --standing marks a perpetual-category arc (never surfaces in `next`,
            \\      drained or not, but still accepts new members); `--standing --undo`
            \\      clears just the mark.
            \\  trk migrate-arcs             backfill real declarations for legacy `arc:` tags AND in-edge-only arcs; idempotent
            \\  trk migrate-shorts [--min <n>]   freeze every task's CURRENT short id so it never changes again
            \\      --min <n> is a one-time REPAIR: also lengthens an already-frozen short below n
            \\  trk state <id> <open|done|blocked|dropped|claimed>
            \\      `claimed` = a builder's self-report ("this commit completes it, pending
            \\      verification") — safe for a compile-only agent, unlike `done`.
            \\  trk next [--arc <id>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> ...]   the ready frontier
            \\  trk list [--arc <id> | --no-arc] [--state <s>] [--tag <t>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> ...]
            \\      <term> (bare or --word <term>, repeatable) ANDs a case-insensitive
            \\      substring search over title+body+tags. --not-tag (repeatable, ANDed
            \\      exclusion) drops any task carrying that tag. --no-arc lists every task in
            \\      no arc. --json emits a machine-readable array
            \\      (id/short/title/state/priority/seq?/tags).
            \\  trk render [--out <path>]    the TODO.md markdown projection (--out > config render.out > stdout)
            \\      Header reports an arc-less drift count every regeneration.
            \\  trk tree <arc-or-task>       the ASCII prereq hierarchy
            \\  trk archive [<term> ...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]
            \\      Graduate DONE tasks to the changelog: emit them as markdown bullets
            \\      (appended to --out/config target under a dated heading, else stdout),
            \\      then flip each to `archived` so it leaves every view (structural
            \\      dedup). --dry-run previews on stdout without archiving.
            \\  trk compact                  rewrite snapshot + truncate log (drops archived/dropped)
            \\  trk doc set <doc_id> <path>  register/update a doc_id -> repo-relative path
            \\  trk doc list                 print all registered doc_id -> path mappings
            \\  trk doc resolve <doc_id>     print the path for a doc_id
            \\  trk show <id>                full task detail
            \\  trk edit <id> [--title <s>] [--body <s>] [--add-tag <t> ...] [--rm-tag <t> ...] [--add-doc <doc_id[#section]> ...] [--priority <n>]
            \\  trk log [<id>] [--limit <n>] event history (most-recent-last)
            \\  trk stale                    open tasks cited in a landed commit but never closed
            \\
            \\Ids accept any unique prefix (git-short-hash style). A task minted after
            \\short-id freezing (or migrated via `trk migrate-shorts`) always displays
            \\the SAME short id — it never changes on add/archive/compact. A task with
            \\no frozen short falls back to a dynamically-computed prefix that can
            \\change as the id set changes; `trk migrate-shorts` freezes it in place.
            \\Per-verb help: `trk <verb> --help`  (or  `trk help <verb>`).
            \\
            \\.tracker/ is found by walking up from cwd (git-style), bounded at a linked
            \\worktree's root (never escapes into an enclosing repo's tracker).
            \\TRK_READONLY=1 in the environment refuses every mutating verb.
            \\
        );
    }

    // ----------------------------------------------------------- id resolution

    /// Resolve a (possibly short) id string to a full task id. Accepts:
    ///   - a full 26-char ULID (parsed/canonicalized), OR
    ///   - a unique case-insensitive prefix of an existing task's id.
    /// Errors cleanly (with candidate list) on ambiguity / no-match / bad chars.
    pub fn resolve(self: *Cli, s: []const u8) Error!Ulid {
        // Full ULID: parse + verify it exists (a full id that isn't a task is a
        // NoSuchId, not a parse success that later faults).
        if (s.len == ulid.len) {
            const u = ulid.parse(s) catch {
                try self.print("trk: '{s}' is not a valid id\n", .{s});
                return error.BadId;
            };
            if (self.store.get(u) == null) {
                try self.print("trk: no task with id {s}\n", .{s});
                return error.NoSuchId;
            }
            return u;
        }
        if (s.len == 0) {
            try self.write("trk: empty id\n");
            return error.BadId;
        }

        // Prefix match (case-insensitive, against the canonical upper-case text).
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var match: ?Ulid = null;
        var n_matches: usize = 0;
        for (ids) |id| {
            if (prefixMatches(s, &id.text)) {
                n_matches += 1;
                if (match == null) match = id;
            }
        }
        if (n_matches == 0) {
            try self.print("trk: no task matches prefix '{s}'\n", .{s});
            return error.NoSuchId;
        }
        if (n_matches > 1) {
            try self.print("trk: prefix '{s}' is ambiguous ({d} matches):\n", .{ s, n_matches });
            for (ids) |id| {
                if (prefixMatches(s, &id.text)) {
                    const t = self.store.get(id).?;
                    var sb: [ulid.len]u8 = undefined;
                    try self.print("  {s}  {s}\n", .{ try self.shortId(id, &sb), t.title });
                }
            }
            return error.AmbiguousId;
        }
        return match.?;
    }

    /// Case-insensitive "does `pfx` prefix the canonical id text". Crockford ids
    /// are upper-case canonical; we upper the user input per char to compare.
    fn prefixMatches(pfx: []const u8, id_text: []const u8) bool {
        if (pfx.len > id_text.len) return false;
        for (pfx, id_text[0..pfx.len]) |p, c| {
            if (std.ascii.toUpper(p) != c) return false;
        }
        return true;
    }

    /// Shared prefix-search: the shortest prefix of `id.text` (>= `floor`,
    /// capped at the full ULID) that collides with at most `max_collisions`
    /// other entries in `ids`. Two call shapes:
    ///   - DISPLAY (`id` is already a member of `ids`): `max_collisions = 1`
    ///     tolerates the id matching itself.
    ///   - MINT (`id` is NOT yet in `ids` — not yet inserted into the store):
    ///     `max_collisions = 0`, so any match is a real collision to extend past.
    /// Written into the caller-provided `buf`; returns a slice of `buf`. No heap
    /// allocation. Lookup is O(N·len) over the id set — fine for an in-repo backlog.
    fn shortestPrefix(id: Ulid, ids: []const Ulid, floor: usize, max_collisions: usize, buf: *[ulid.len]u8) []const u8 {
        var n: usize = floor;
        while (n < ulid.len) : (n += 1) {
            var collisions: usize = 0;
            for (ids) |other| {
                if (std.mem.eql(u8, id.text[0..n], other.text[0..n])) collisions += 1;
            }
            if (collisions <= max_collisions) break;
        }
        @memcpy(buf[0..n], id.text[0..n]);
        return buf[0..n];
    }

    /// The short id to DISPLAY for `id`. If a short was frozen for this task
    /// (at mint time via `mintShortId`, or later via `trk migrate-shorts`),
    /// returns it verbatim — stable forever, independent of the live id set.
    /// Otherwise falls back to the legacy dynamically-computed prefix (>=
    /// `min_short`), which is UNSTABLE: it moves as the id set moves (an add,
    /// an archive, a compact can all change it). Written into the
    /// caller-provided `buf`; returns a slice of `buf`. No heap allocation
    /// needed by the caller (two short ids in one line want two buffers).
    pub fn shortId(self: *Cli, id: Ulid, buf: *[ulid.len]u8) ![]const u8 {
        if (self.store.get(id)) |t| {
            if (t.short) |s| {
                @memcpy(buf[0..s.len], s);
                return buf[0..s.len];
            }
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        return shortestPrefix(id, ids, min_short, 1, buf);
    }

    /// The short id to FREEZE for a newly-minted `id` that is NOT YET in the
    /// store (called before `store.append(.add)`). The shortest prefix (>=
    /// `min_short_mint`) that does not collide with any EXISTING task's id —
    /// collision handling is one-sided: only the new id's candidate is ever
    /// extended; an already-frozen short is never touched. The caller embeds
    /// the result in the `add` event's `short` field so it persists forever.
    pub fn mintShortId(self: *Cli, id: Ulid, buf: *[ulid.len]u8) ![]const u8 {
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        return shortestPrefix(id, ids, min_short_mint, 0, buf);
    }

    // ----------------------------------------------------------- small parse helpers

    fn parseI32(self: *Cli, s: []const u8) Error!i32 {
        return std.fmt.parseInt(i32, s, 10) catch {
            try self.print("trk: '{s}' is not a number\n", .{s});
            return error.BadNumber;
        };
    }

    fn parseUsize(self: *Cli, s: []const u8) Error!usize {
        return std.fmt.parseInt(usize, s, 10) catch {
            try self.print("trk: '{s}' is not a non-negative number\n", .{s});
            return error.BadNumber;
        };
    }

    /// Read the next arg as a flag value or report a clean missing-arg error.
    fn flagVal(self: *Cli, args: []const []const u8, i: *usize, flag: []const u8) Error![]const u8 {
        if (i.* + 1 >= args.len) {
            try self.print("trk: {s} needs a value\n", .{flag});
            return error.MissingArgument;
        }
        i.* += 1;
        return args[i.*];
    }

    /// True iff `path` (relative to `self.dir`) exists.
    fn fileExists(self: *Cli, path: []const u8) bool {
        self.dir.access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Write `data` to `path` under `self.dir`, best-effort creating the parent
    /// directory chain first (`writeFile` alone does no `mkdir -p`, so a config
    /// render.out like `docs/TODO.md` in a fresh checkout would else fail). The
    /// mkdir is best-effort — if it fails, the `writeFile` surfaces the real error.
    fn writeOutFile(self: *Cli, path: []const u8, data: []const u8) Error!void {
        if (std.fs.path.dirname(path)) |d| {
            if (d.len > 0) {
                if (self.dir.createDirPathOpen(self.io, d, .{})) |pd| {
                    var pdv = pd;
                    pdv.close(self.io);
                } else |_| {}
            }
        }
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = data, .flags = .{} });
    }

    /// Append `data` at the end of `path` under `self.dir` (created if absent,
    /// parent chain best-effort like `writeOutFile`), preceded by a blank-line
    /// separator when the file already has content. For accumulating targets
    /// (the changelog): `render` regenerates its whole projection so it
    /// truncates; `archive` emits increments, so truncating would destroy the
    /// prior records.
    fn appendOutFile(self: *Cli, path: []const u8, data: []const u8) Error!void {
        if (std.fs.path.dirname(path)) |d| {
            if (d.len > 0) {
                if (self.dir.createDirPathOpen(self.io, d, .{})) |pd| {
                    var pdv = pd;
                    pdv.close(self.io);
                } else |_| {}
            }
        }
        var f = try self.dir.createFile(self.io, path, .{ .read = true, .truncate = false });
        defer f.close(self.io);
        var end = try f.length(self.io);
        if (end > 0) {
            try f.writePositionalAll(self.io, "\n", end);
            end += 1;
        }
        try f.writePositionalAll(self.io, data, end);
    }

    // ----------------------------------------------------------- init

    /// `trk init [--out <path>] [--force]` — scaffold a fresh project's tracker.
    /// Three artifacts, each created only if absent (idempotent, non-destructive):
    ///   1. `.tracker/` + an empty `log.jsonl` (today made lazily on first write;
    ///      init makes it explicit so `trk next` works immediately),
    ///   2. `.tracker/config.json` with a default `render.out` (rewritten only
    ///      under `--force`),
    ///   3. a starter `TODO.md` at the render path — a valid empty projection.
    /// The TODO.md is NEVER overwritten (unlike `trk render`, which regenerates
    /// its projection by design): if one exists init leaves it and reports it, so
    /// init can't clobber a live projection or a user's file.
    fn cmdInit(self: *Cli, args: []const []const u8) Error!void {
        var out_arg: ?[]const u8 = null;
        var force = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_arg = try self.flagVal(args, &i, "--out");
            } else if (std.mem.eql(u8, args[i], "--force")) {
                force = true;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        const sd = tracker.store.tracker_subdir;
        const default_out = "docs/TODO.md";

        // 1. .tracker/ + an empty log.jsonl (createDirPathOpen is mkdir -p; idempotent).
        var sub = self.dir.createDirPathOpen(self.io, sd, .{}) catch {
            try self.print("trk: init: cannot create {s}/\n", .{sd});
            return error.WriteFailed;
        };
        defer sub.close(self.io);
        const log_existed = blk: {
            sub.access(self.io, tracker.store.log_name, .{}) catch break :blk false;
            break :blk true;
        };
        if (!log_existed) {
            var lf = sub.createFile(self.io, tracker.store.log_name, .{ .truncate = false }) catch {
                try self.print("trk: init: cannot create {s}/{s}\n", .{ sd, tracker.store.log_name });
                return error.WriteFailed;
            };
            lf.close(self.io);
            try self.print("created {s}/{s}\n", .{ sd, tracker.store.log_name });
        } else {
            try self.print("{s}/{s} already exists\n", .{ sd, tracker.store.log_name });
        }

        // 2. config.json — write if absent (or --force). An existing config's
        //    render.out wins over --out for the seed step below (don't fight a
        //    path the project already chose).
        const cfg = tracker.store.config_name;
        const cfg_existed = self.dirHas(sub, cfg);
        var render_out: []const u8 = out_arg orelse default_out;
        if (cfg_existed and !force) {
            if (self.store.config.render_out) |ro| render_out = ro;
            try self.print("{s}/{s} already exists (use --force to rewrite)\n", .{ sd, cfg });
        } else {
            var cbuf: std.ArrayList(u8) = .empty;
            defer cbuf.deinit(self.gpa);
            try cbuf.print(self.gpa,
                \\{{
                \\  "render": {{ "out": "{s}" }},
                \\  "archive": {{ "out": null }}
                \\}}
                \\
            , .{render_out});
            sub.writeFile(self.io, .{ .sub_path = cfg, .data = cbuf.items, .flags = .{} }) catch {
                try self.print("trk: init: cannot write {s}/{s}\n", .{ sd, cfg });
                return error.WriteFailed;
            };
            try self.print("{s} {s}/{s} (render.out = {s})\n", .{
                if (cfg_existed) "rewrote" else "created",
                sd,
                cfg,
                render_out,
            });
        }

        // 3. Seed a starter TODO.md at render_out — ONLY if none exists.
        if (self.fileExists(render_out)) {
            try self.print("{s} already exists — left untouched (init never overwrites it)\n", .{render_out});
        } else {
            var md: std.ArrayList(u8) = .empty;
            defer md.deinit(self.gpa);
            try self.renderMarkdown(&md);
            try self.writeOutFile(render_out, md.items);
            try self.print("seeded {s} (starter projection)\n", .{render_out});
        }
    }

    /// True iff `name` exists directly inside the already-open dir `d`.
    fn dirHas(self: *Cli, d: Io.Dir, name: []const u8) bool {
        d.access(self.io, name, .{}) catch return false;
        return true;
    }

    // ----------------------------------------------------------- add

    fn cmdAdd(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: add needs a \"<title>\"\n");
            return error.MissingArgument;
        }
        const title = args[0];
        var body: []const u8 = "";
        var priority: ?i32 = null;
        var in_arc: ?[]const u8 = null;
        var declare_arc = false;
        var seq: i32 = 0;
        var verbose = false;
        var tags: std.ArrayList([]const u8) = .empty;
        defer tags.deinit(self.gpa);
        var needs: std.ArrayList([]const u8) = .empty;
        defer needs.deinit(self.gpa);
        var docs: std.ArrayList([]const u8) = .empty;
        defer docs.deinit(self.gpa);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--body")) {
                body = try self.flagVal(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--tag")) {
                try tags.append(self.gpa, try self.flagVal(args, &i, "--tag"));
            } else if (std.mem.eql(u8, arg, "--needs")) {
                try needs.append(self.gpa, try self.flagVal(args, &i, "--needs"));
            } else if (std.mem.eql(u8, arg, "--doc")) {
                try docs.append(self.gpa, try self.flagVal(args, &i, "--doc"));
            } else if (std.mem.eql(u8, arg, "--in")) {
                in_arc = try self.flagVal(args, &i, "--in");
            } else if (std.mem.eql(u8, arg, "--arc")) {
                declare_arc = true;
            } else if (std.mem.eql(u8, arg, "--seq")) {
                seq = try self.parseI32(try self.flagVal(args, &i, "--seq"));
            } else if (std.mem.eql(u8, arg, "--priority")) {
                priority = try self.parseI32(try self.flagVal(args, &i, "--priority"));
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            }
        }

        // Resolve referenced ids BEFORE minting, so a bad --in/--needs fails
        // without leaving a half-built task in the log.
        const arc_id: ?Ulid = if (in_arc) |a| try self.resolve(a) else null;
        // `--in` must name an already-declared arc, checked here (not left to
        // the `.in` append below) so the failure happens BEFORE minting —
        // same "no half-built task in the log" reasoning as --needs.
        if (arc_id) |a| {
            if (!self.store.isArc(a)) {
                var ab: [ulid.len]u8 = undefined;
                const as = try self.shortId(a, &ab);
                try self.print(
                    "trk: refusing: {s} is not a declared arc — declare it first with `trk arc {s}` (or `trk add --arc`), then retry\n",
                    .{ as, as },
                );
                return error.UndeclaredArc;
            }
        }
        var need_ids = try self.gpa.alloc(Ulid, needs.items.len);
        defer self.gpa.free(need_ids);
        for (needs.items, 0..) |n, idx| need_ids[idx] = try self.resolve(n);

        // Neither --in nor --arc: the task lands in no arc. Decided BEFORE
        // minting so the hard-error path (config add.arcless = "error") never
        // leaves a half-built task in the log.
        const has_arc = arc_id != null or declare_arc;
        if (!has_arc and self.store.config.add_arcless_error) {
            try self.write(
                "trk: refusing: this task would land in no arc (neither --in nor --arc given) — " ++
                    "pass one, or set add.arcless to \"warn\" in .tracker/config.json to downgrade this to a warning\n",
            );
            return error.NoArc;
        }

        const id = ulid.mint(self.io);
        // Freeze the short id NOW, before `id` exists in the store, so the
        // collision check is against the pre-add id set (mintShortId's
        // contract) — then carry it in the add event so it's persisted
        // forever (Task.short), never recomputed.
        var short_buf: [ulid.len]u8 = undefined;
        const short = try self.mintShortId(id, &short_buf);
        const tag_slice = tags.items;
        try self.store.append(.{ .add = .{ .id = id, .title = title, .body = body, .tags = tag_slice, .short = short } });
        if (priority) |p| try self.store.append(.{ .setPriority = .{ .id = id, .priority = p } });
        if (arc_id) |a| try self.store.append(.{ .in = .{ .task = id, .arc = a, .seq = seq } });
        if (declare_arc) try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
        for (need_ids) |to| try self.store.append(.{ .dep = .{ .from = id, .to = to } });
        for (docs.items) |d| {
            const ref = splitDocRef(d);
            try self.store.append(.{ .docref = .{ .id = id, .doc_id = ref.doc_id, .section_id = ref.section_id } });
        }

        // Arc-less warning goes to the SEPARATE `warn` buffer (stderr), never
        // `out` (stdout) — `out` is exactly the scriptable ULID and nothing else.
        if (!has_arc) {
            var sb: [ulid.len]u8 = undefined;
            try self.warn.print(self.gpa, "trk: warning: {s} \"{s}\" is in no arc (pass --in <arc> or --arc)\n", .{ try self.shortId(id, &sb), title });
        }
        for (tag_slice) |tg| try self.warnDeprecatedArcTag(id, tg);

        // Quiet by default: print ONLY the full ULID so `ID=$(trk add ...)` is
        // scriptable with no parsing. `-v`/`--verbose` gives the friendly form.
        if (verbose) {
            var sb: [ulid.len]u8 = undefined;
            try self.print("added {s}  ({s})\n", .{ try self.shortId(id, &sb), &id.text });
        } else {
            try self.print("{s}\n", .{&id.text});
        }
    }

    // ----------------------------------------------------------- dep

    fn cmdDep(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk dep <from> <to>\n");
            return error.UsageError;
        }
        const from = try self.resolve(args[0]);
        const to = try self.resolve(args[1]);
        var fb: [ulid.len]u8 = undefined;
        var tb: [ulid.len]u8 = undefined;
        self.store.append(.{ .dep = .{ .from = from, .to = to } }) catch |e| {
            if (e == error.DependencyCycle) {
                const fs = try self.shortId(from, &fb);
                const ts = try self.shortId(to, &tb);
                // Covers both shapes the store now rejects: a plain needs
                // cycle (A->B->...->A) and a self-wait mediated by arc
                // membership (e.g. `to` is an arc `from` is itself a
                // member of) — "ts already depends on fs" is literally true
                // either way, so one message serves both without needing to
                // know which relation closed the loop.
                try self.print(
                    "trk: refusing: {s} needs {s} would close a cycle — {s} already (directly or transitively) depends on {s}, so {s} would wait on itself forever\n",
                    .{ fs, ts, ts, fs, fs },
                );
                return error.DependencyCycle;
            }
            return e;
        };
        try self.print("{s} now needs {s}\n", .{ try self.shortId(from, &fb), try self.shortId(to, &tb) });
    }

    // ----------------------------------------------------------- undep

    fn cmdUndep(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk undep <from> <to>\n");
            return error.UsageError;
        }
        const from = try self.resolve(args[0]);
        const to = try self.resolve(args[1]);
        try self.store.append(.{ .undep = .{ .from = from, .to = to } });
        var fb: [ulid.len]u8 = undefined;
        var tb: [ulid.len]u8 = undefined;
        try self.print("{s} no longer needs {s}\n", .{ try self.shortId(from, &fb), try self.shortId(to, &tb) });
    }

    // ----------------------------------------------------------- in

    fn cmdIn(self: *Cli, args: []const []const u8) Error!void {
        if (args.len < 2) {
            try self.write("trk: usage: trk in <task> <arc> [--seq <n>]\n");
            return error.UsageError;
        }
        const task = try self.resolve(args[0]);
        const arc = try self.resolve(args[1]);
        var seq: i32 = 0;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--seq")) {
                seq = try self.parseI32(try self.flagVal(args, &i, "--seq"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }
        // A task cannot be a member of itself. Caught explicitly (rather than
        // left to the generic cycle-detector, which WOULD also reject it, but
        // with a confusing "X already needs X" message) so the diagnosis is
        // immediate and unambiguous.
        if (task.eql(arc)) {
            var tb: [ulid.len]u8 = undefined;
            const ts = try self.shortId(task, &tb);
            try self.print("trk: refusing: {s} cannot be a member of itself\n", .{ts});
            return error.DependencyCycle;
        }
        self.store.append(.{ .in = .{ .task = task, .arc = arc, .seq = seq } }) catch |e| {
            if (e == error.DependencyCycle) {
                var tb: [ulid.len]u8 = undefined;
                var ab: [ulid.len]u8 = undefined;
                const ts = try self.shortId(task, &tb);
                const as = try self.shortId(arc, &ab);
                // The mirror of cmdDep's rejection: this membership would
                // close the SAME combined self-wait graph from the other
                // side — `task` already (directly or transitively) needs
                // `arc`, so making it a member too means `arc` can never
                // drain (it's waiting on a member that's waiting on it).
                // The single most common real-world cause of THIS specific
                // rejection is a swapped argument order (`trk in <arc>
                // <task>` instead of `<task> <arc>`) landing on top of an
                // edge the swap already created — so the hint is worth the
                // line even though it isn't always the cause.
                try self.print(
                    "trk: refusing: {s} in {s} would close a cycle — {s} already (directly or transitively) needs {s}, so {s} would wait on itself forever (it can never finish while depending on a member that's waiting on it)\n" ++
                        "trk: hint: if this looks backwards, double check argument order — it's `trk in <task> <arc>`, not <arc> <task>. `trk unin {s} {s}` removes a wrongly-directed edge.\n",
                    .{ ts, as, ts, as, as, ts, as },
                );
                return error.DependencyCycle;
            }
            if (e == error.UndeclaredArc) {
                var tb: [ulid.len]u8 = undefined;
                var ab: [ulid.len]u8 = undefined;
                const ts = try self.shortId(task, &tb);
                const as = try self.shortId(arc, &ab);
                // `arc` has never been declared (`trk arc`/`trk add --arc`)
                // — `in` no longer mints one on the fly (01KYTFRD7). The
                // single most common real-world cause is the SAME
                // argument-order slip cmdDep/the cycle branch above warn
                // about: `trk in <arc> <task>` instead of `<task> <arc>`,
                // where the intended arc ends up in the TASK position and
                // the intended task — never declared — ends up where an arc
                // is required.
                try self.print(
                    "trk: refusing: {s} is not a declared arc — declare it first with `trk arc {s}` (or `trk add --arc`), then retry `trk in {s} {s}`\n" ++
                        "trk: hint: if this looks backwards, double check argument order — it's `trk in <task> <arc>`, not <arc> <task>.\n",
                    .{ as, as, ts, as },
                );
                return error.UndeclaredArc;
            }
            return e;
        };
        var tb: [ulid.len]u8 = undefined;
        var ab: [ulid.len]u8 = undefined;
        try self.print("{s} in arc {s} (seq {d})\n", .{ try self.shortId(task, &tb), try self.shortId(arc, &ab), seq });
    }

    // ----------------------------------------------------------- unin

    fn cmdUnin(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk unin <task> <arc>\n");
            return error.UsageError;
        }
        const task = try self.resolve(args[0]);
        const arc = try self.resolve(args[1]);
        try self.store.append(.{ .unin = .{ .task = task, .arc = arc } });
        var tb: [ulid.len]u8 = undefined;
        var ab: [ulid.len]u8 = undefined;
        try self.print("{s} no longer in {s}\n", .{ try self.shortId(task, &tb), try self.shortId(arc, &ab) });
    }

    // ----------------------------------------------------------- arc

    /// If `tg` is the DEPRECATED `arc:<slug>` marker, nudge to stderr steering
    /// new usage at `trk arc`/`trk add --arc` instead — the whole point of
    /// unifying arc-ness is that nothing should keep silently writing the old,
    /// cosmetic marker. `Store.isArc` still HONORS an already-written tag
    /// read-only (back-compat: an un-migrated repo's arcs keep working); this
    /// is the write-path guard that stops NEW ones from accumulating. Never
    /// blocks the write (a warning, not an error) — the tag is still valid
    /// input, just steered away from.
    fn warnDeprecatedArcTag(self: *Cli, id: Ulid, tg: []const u8) Error!void {
        if (!std.mem.startsWith(u8, tg, "arc:")) return;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        try self.warn.print(
            self.gpa,
            "trk: warning: {s}: tag \"{s}\" is the DEPRECATED arc marker — use `trk arc {s}` (or `trk add --arc`) instead; `trk migrate-arcs` converts existing ones\n",
            .{ sid, tg, sid },
        );
    }

    /// `trk arc <id> [--undo] [--standing [--undo]]` — declare (or, with
    /// --undo, retract) <id> as an arc root independent of `in` membership;
    /// `--standing` additionally marks it a STANDING arc (a perpetual
    /// category, never a `next` close-out candidate — see `Store.isStanding`).
    /// See `Store.isArc`.
    fn cmdArc(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: usage: trk arc <id> [--undo] [--standing [--undo]]\n");
            return error.UsageError;
        }
        const id = try self.resolve(args[0]);
        var undo = false;
        var standing = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--undo")) {
                undo = true;
            } else if (std.mem.eql(u8, args[i], "--standing")) {
                standing = true;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }
        var sb: [ulid.len]u8 = undefined;

        if (standing and undo) {
            // Clear JUST the standing mark; leave the arc declaration intact.
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = false } });
            try self.print("{s} standing mark retracted (still an arc)\n", .{try self.shortId(id, &sb)});
            return;
        }
        if (standing) {
            // Standing implies arc-ness: declare in the same act (idempotent
            // last-write-wins if already declared).
            try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = true } });
            try self.print("{s} declared an arc and marked standing\n", .{try self.shortId(id, &sb)});
            return;
        }

        try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = !undo } });
        if (undo) {
            // Retracting the arc declaration also clears any orphaned standing
            // mark — a task that is no longer (declared) an arc has no
            // business staying "standing" (no-op if it never was one).
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = false } });
            try self.print("{s} arc declaration retracted\n", .{try self.shortId(id, &sb)});
        } else {
            try self.print("{s} declared an arc\n", .{try self.shortId(id, &sb)});
        }
    }

    // ----------------------------------------------------------- migrate-arcs

    /// `trk migrate-arcs` — one-time-but-idempotent backfill onto real
    /// `arcDeclare` events, in two independent passes:
    ///
    ///   1. Every legacy `arc:<slug>` tag → `arcDeclare` + strip the tag
    ///      (pre-existing).
    ///   2. Every id that is an arc ONLY because some task carries a direct
    ///      `in` edge naming it (01KYTFRD7, 2026-07-30 — added the same day
    ///      `Store.isArc`'s in-edge inference was deleted). This pass is what
    ///      makes deleting that inference SAFE rather than merely bypassed:
    ///      it backfills a real declaration for every arc that existed
    ///      because of it, so `isArc`'s answer for every arc that existed
    ///      BEFORE this landed is unchanged after — only a brand-new,
    ///      never-declared `in` target is affected going forward (and that
    ///      is now refused at `append`, not silently minted).
    ///
    /// Safe to re-run: pass 1 finds nothing once tags are stripped, pass 2
    /// finds nothing once every in-edge target carries a declaration — both
    /// are structural idempotency, not a separate "already migrated" check.
    fn cmdMigrateArcs(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: migrate-arcs takes no arguments\n");
            return error.UsageError;
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var migrated: usize = 0;

        // Pass 1: legacy `arc:` tags.
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (!hasArcTag(t)) continue;
            var arc_tags: std.ArrayList([]const u8) = .empty;
            defer arc_tags.deinit(self.gpa);
            for (t.tags.items) |tg| {
                if (std.mem.startsWith(u8, tg, "arc:")) try arc_tags.append(self.gpa, try self.gpa.dupe(u8, tg));
            }
            defer for (arc_tags.items) |tg| self.gpa.free(tg);
            if (arc_tags.items.len == 0) continue;

            try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
            for (arc_tags.items) |tg| try self.store.append(.{ .untag = .{ .id = id, .tag = tg } });

            var sb: [ulid.len]u8 = undefined;
            try self.print("migrated {s}  {s}  (declared; stripped {d} arc: tag(s))\n", .{
                try self.shortId(id, &sb), t.title, arc_tags.items.len,
            });
            migrated += 1;
        }

        // Pass 2: every UNIQUE `in.arc` id not already declared (by config,
        // by pass 1 above, or from before this migration ever ran). Iterates
        // `self.store.ins` directly — the same field the CLI already reaches
        // into elsewhere (render/tree) — rather than adding a new Store
        // query for a one-time migration pass.
        var seen: std.AutoHashMapUnmanaged([ulid.len]u8, void) = .empty;
        defer seen.deinit(self.gpa);
        for (self.store.ins.items) |e| {
            const gop = try seen.getOrPut(self.gpa, e.arc.text);
            if (gop.found_existing) continue;
            if (self.store.declared_arcs.contains(e.arc.text)) continue;

            try self.store.append(.{ .arcDeclare = .{ .id = e.arc, .declared = true } });

            var sb: [ulid.len]u8 = undefined;
            const title = if (self.store.get(e.arc)) |t| t.title else "";
            try self.print("migrated {s}  {s}  (declared; was in-edge-inferred only)\n", .{
                try self.shortId(e.arc, &sb), title,
            });
            migrated += 1;
        }

        if (migrated == 0) {
            try self.write("migrate-arcs: nothing to migrate\n");
        } else {
            try self.print("migrate-arcs: {d} task(s) migrated\n", .{migrated});
        }
    }

    // ----------------------------------------------------------- migrate-shorts

    /// `trk migrate-shorts [--min <n>]` — one-time-but-idempotent: freeze
    /// every task with no persisted `short` yet at its CURRENT dynamically-
    /// computed short id (a `setShort` event), so it never again moves on a
    /// future add/archive/compact. Safe to re-run: a task already frozen (and
    /// already >= `--min`, if given) is skipped, so a settled repo finds
    /// nothing.
    ///
    /// LIMITATION (stated here and in the help text): a freshly-frozen value
    /// is whatever `shortId` computes RIGHT NOW. If an earlier `compact`
    /// already shortened/changed a task's displayed prefix, that pre-compact
    /// value was never recorded anywhere and cannot be recovered — the
    /// current computed value is the only recoverable baseline.
    ///
    /// `--min <n>` is the one-time REPAIR path: every task (frozen or not) is
    /// frozen at `max(its current short length, n)`, collision-checked like
    /// any mint. Without `--min`, an already-frozen short is NEVER touched
    /// (today's default, unchanged); `--min` is the one exception that
    /// deliberately LENGTHENS an already-frozen short when it's shorter than
    /// `n` — this changes an id a prior run already froze, so it is gated
    /// behind the explicit flag and meant to be run once, on purpose (e.g. to
    /// bring a repo's ids up to a length that matches what's already been
    /// written down elsewhere).
    fn cmdMigrateShorts(self: *Cli, args: []const []const u8) Error!void {
        var min_len: ?usize = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--min")) {
                min_len = try self.parseUsize(try self.flagVal(args, &i, "--min"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var frozen: usize = 0;
        var lengthened: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            var sb: [ulid.len]u8 = undefined;

            if (t.short) |s| {
                const min_l = min_len orelse continue; // no --min: never re-touch a frozen short
                if (s.len >= min_l) continue; // already long enough
                // Repair: lengthen this already-frozen short to >= min_l
                // (still collision-checked — it may need to extend further).
                const longer = shortestPrefix(id, ids, min_l, 1, &sb);
                try self.store.append(.{ .setShort = .{ .id = id, .short = longer } });
                try self.print("lengthened {s} -> {s}  {s}\n", .{ s, longer, t.title });
                lengthened += 1;
                continue;
            }

            // Never frozen: freeze at max(the natural unambiguous floor, --min).
            const floor = @max(min_short, min_len orelse min_short);
            const short = shortestPrefix(id, ids, floor, 1, &sb);
            try self.store.append(.{ .setShort = .{ .id = id, .short = short } });
            try self.print("froze {s}  {s}\n", .{ short, t.title });
            frozen += 1;
        }

        if (frozen == 0 and lengthened == 0) {
            try self.write("migrate-shorts: nothing to migrate (every task already has a frozen short" ++
                " long enough)\n");
        } else {
            try self.print(
                "migrate-shorts: froze {d} new task(s), lengthened {d} existing short(s) — note this " ++
                    "is a best-effort baseline: any id already changed by an earlier `compact` cannot be " ++
                    "recovered to a prior value; going forward these ids are stable.\n",
                .{ frozen, lengthened },
            );
        }
    }

    // ----------------------------------------------------------- state

    fn cmdState(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk state <id> <open|done|blocked|dropped|claimed>\n");
            return error.UsageError;
        }
        const id = try self.resolve(args[0]);
        const st = State.fromString(args[1]) orelse {
            try self.print("trk: '{s}' is not a state (open|done|blocked|dropped|claimed)\n", .{args[1]});
            return error.BadState;
        };
        try self.store.append(.{ .setState = .{ .id = id, .state = st } });
        var sb: [ulid.len]u8 = undefined;
        try self.print("{s} -> {s}\n", .{ try self.shortId(id, &sb), st.toString() });
    }

    // ----------------------------------------------------------- compact

    /// `trk compact` — rewrite the snapshot from current in-memory state and
    /// truncate the log. Prints a one-line summary on success.
    fn cmdCompact(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: compact takes no arguments\n");
            return error.UsageError;
        }
        const result = try self.store.compact();
        try self.print(
            "compacted: {d} events -> {d} live tasks, log truncated\n",
            .{ result.log_events_before, result.live_tasks },
        );
    }

    // ----------------------------------------------------------- archive

    /// `trk archive [<term>...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]`
    /// — graduate completed work to the changelog. Selects `done` tasks (narrowed
    /// by the same term/arc/tag filters as `list`), emits them as changelog-ready
    /// markdown bullets, then flips each to `archived` so it leaves every working
    /// view — the recorded item can never be re-emitted (structural dedup). A file
    /// target (`--out` or config) is APPENDED to, under a `## YYYY-MM-DD` run
    /// heading. `--dry-run` previews the queue on stdout without archiving — it
    /// never touches the file (an appended preview would duplicate on the real run).
    fn cmdArchive(self: *Cli, args: []const []const u8) Error!void {
        var out_path: ?[]const u8 = null;
        var dry_run = false;
        var arc_filter: ?[]const u8 = null;
        var tag_filter: ?[]const u8 = null;
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_path = try self.flagVal(args, &i, "--out");
            } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--tag")) {
                tag_filter = try self.flagVal(args, &i, "--tag");
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                try words.append(self.gpa, args[i]);
            }
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| members = try self.store.membersOf(self.gpa, a);

        // Collect matching DONE tasks in deterministic id order.
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        var matched: std.ArrayList(Ulid) = .empty;
        defer matched.deinit(self.gpa);
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.state != .done) continue;
            if (members) |m| if (!containsId(m, id)) continue;
            if (tag_filter) |tf| if (!hasTag(t, tf)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            try matched.append(self.gpa, id);
        }

        if (matched.items.len == 0) {
            try self.write("(no done tasks to archive)\n");
            return;
        }

        // Build the changelog-bullet draft.
        var draft: std.ArrayList(u8) = .empty;
        defer draft.deinit(self.gpa);
        for (matched.items) |id| try self.appendArchiveBullet(&draft, id);

        // Emit the draft BEFORE flipping state so the records are out even if
        // the state writes fail partway. A real run APPENDS to the file target
        // under a dated run heading (a changelog accumulates — truncating here
        // once destroyed one); --dry-run previews on stdout and never touches
        // the file. Precedence: explicit --out > config archive.out > stdout.
        const effective_out = out_path orelse self.store.config.archive_out;
        if (effective_out != null and !dry_run) {
            var chunk: std.ArrayList(u8) = .empty;
            defer chunk.deinit(self.gpa);
            var ts_buf: [32]u8 = undefined;
            const ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
            try chunk.print(self.gpa, "## {s}\n\n", .{fmtTs(ms, &ts_buf)[0..10]});
            try chunk.appendSlice(self.gpa, draft.items);
            try self.appendOutFile(effective_out.?, chunk.items);
        } else {
            try self.write(draft.items);
        }

        // Flip to archived (unless previewing). Recoverable until `trk compact`.
        if (!dry_run) {
            for (matched.items) |id|
                try self.store.append(.{ .setState = .{ .id = id, .state = .archived } });
        }

        // A summary only when the draft went to a file (so a stdout draft stays
        // a clean paste). dry-run-to-stdout shows just the bullets.
        if (effective_out) |p| {
            if (dry_run) {
                try self.print("(dry run) {d} done task(s) would be archived; a real run appends to {s}\n", .{ matched.items.len, p });
            } else {
                try self.print("archived {d} task(s); appended -> {s}\n", .{ matched.items.len, p });
            }
        }
    }

    /// One changelog-draft bullet for a graduated task: `- <title> #tags
    /// (doc#sec) (<short-id>)`. No checkbox — it is completed; the short id is
    /// kept for traceability back to the tracker/log.
    fn appendArchiveBullet(self: *Cli, buf: *std.ArrayList(u8), id: Ulid) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        try buf.print(gpa, "- {s}", .{t.title});
        for (t.tags.items) |tg| try buf.print(gpa, " #{s}", .{tg});
        for (t.docrefs.items) |dr| {
            const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
            if (dr.section_id) |sec| {
                try buf.print(gpa, " ({s}#{s})", .{ display, sec });
            } else {
                try buf.print(gpa, " ({s})", .{display});
            }
        }
        var sb: [ulid.len]u8 = undefined;
        try buf.print(gpa, " ({s})\n", .{try self.shortId(id, &sb)});
    }

    // ----------------------------------------------------------- doc

    /// `trk doc <set|list|resolve> ...` — doc-id registry commands.
    fn cmdDoc(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: doc needs a subcommand: set, unset, list, resolve\n");
            return error.UsageError;
        }
        const sub = args[0];
        const rest = args[1..];
        if (std.mem.eql(u8, sub, "set")) return self.cmdDocSet(rest);
        if (std.mem.eql(u8, sub, "unset")) return self.cmdDocUnset(rest);
        if (std.mem.eql(u8, sub, "list")) return self.cmdDocList(rest);
        if (std.mem.eql(u8, sub, "resolve")) return self.cmdDocResolve(rest);
        try self.print("trk: doc: unknown subcommand '{s}' (set|unset|list|resolve)\n", .{sub});
        return error.UnknownCommand;
    }

    /// `trk doc set <doc_id> <path>` — register/update a doc_id → path.
    fn cmdDocSet(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk doc set <doc_id> <path>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        const path = args[1];
        try self.store.append(.{ .setDocPath = .{ .doc_id = doc_id, .path = path } });
        try self.print("doc {s} -> {s}\n", .{ doc_id, path });
    }

    /// `trk doc unset <doc_id>` — unregister a doc_id. Emits the empty-path
    /// tombstone the fold removes the mapping on. Idempotent: unsetting an
    /// unregistered id is a no-op append, like `untag`/`undep`.
    fn cmdDocUnset(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 1) {
            try self.write("trk: usage: trk doc unset <doc_id>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        try self.store.append(.{ .setDocPath = .{ .doc_id = doc_id, .path = "" } });
        try self.print("doc {s} unregistered\n", .{doc_id});
    }

    /// `trk doc list` — print all doc_id -> path entries, sorted by doc_id.
    fn cmdDocList(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: doc list takes no arguments\n");
            return error.UsageError;
        }
        const n = self.store.doc_paths.count();
        if (n == 0) {
            try self.write("(no doc paths registered)\n");
            return;
        }
        // Collect keys and sort for deterministic output.
        const doc_ids = try self.gpa.alloc([]const u8, n);
        defer self.gpa.free(doc_ids);
        var it = self.store.doc_paths.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) doc_ids[i] = k.*;
        std.sort.pdq([]const u8, doc_ids, {}, lessThanStrCli);
        for (doc_ids) |doc_id| {
            const path = self.store.doc_paths.get(doc_id).?;
            try self.print("{s}  ->  {s}\n", .{ doc_id, path });
        }
    }

    /// `trk doc resolve <doc_id>` — print the path, non-zero exit if unregistered.
    fn cmdDocResolve(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 1) {
            try self.write("trk: usage: trk doc resolve <doc_id>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        if (self.store.docPath(doc_id)) |path| {
            try self.print("{s}\n", .{path});
        } else {
            try self.print("trk: doc '{s}' is not registered\n", .{doc_id});
            return error.NoSuchId;
        }
    }

    // ----------------------------------------------------------- next

    fn cmdNext(self: *Cli, args: []const []const u8) Error!void {
        var arc_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var json = false;
        // Search terms: repeated `--word` AND bare positionals, ANDed — so
        // `trk next prism` is "the ready frontier, prism only".
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        // `--not-tag <t>` (repeatable, ANDed exclusion): drop any task carrying
        // ANY of these tags. The backfilled negative blocker-tag vocabulary
        // (`metal`/`scott-testing`/`scott-decision`) makes the autonomous-
        // eligible bucket one bare command:
        //   trk next --not-tag metal --not-tag scott-testing --not-tag scott-decision
        var not_tags: std.ArrayList([]const u8) = .empty;
        defer not_tags.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.eql(u8, args[i], "--not-tag")) {
                try not_tags.append(self.gpa, try self.flagVal(args, &i, "--not-tag"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                try words.append(self.gpa, args[i]);
            }
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;

        const ready = try self.store.next(self.gpa);
        defer self.gpa.free(ready);

        // If filtering by arc, precompute its member set once.
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| members = try self.store.membersOf(self.gpa, a);

        if (json) try self.write("[");
        var shown: usize = 0;
        for (ready) |id| {
            if (members) |m| {
                if (!containsId(m, id)) continue;
            }
            const t = self.store.get(id).?;
            if (hasAnyTag(t, not_tags.items)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            if (limit) |lim| {
                if (shown >= lim) break;
            }
            if (json) {
                if (shown != 0) try self.write(",");
                try self.appendTaskJson(id, arc_id);
            } else {
                try self.printTaskLine(id, arc_id);
            }
            shown += 1;
        }
        if (json) {
            try self.write("]\n");
        } else if (shown == 0) {
            try self.write("(nothing ready)\n");
        }
    }

    /// `<short-id>  [<arc-seq>/<prio>]  <title>` — `next`/`list` one-liner.
    /// `arc_id` (if given) selects which arc's seq to show; otherwise the best.
    fn printTaskLine(self: *Cli, id: Ulid, arc_id: ?Ulid) !void {
        const t = self.store.get(id).?;
        const seq = self.seqFor(id, arc_id);
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        if (seq) |s| {
            try self.print("{s}  [{d}/{d}]  {s}\n", .{ sid, s, t.priority, t.title });
        } else {
            try self.print("{s}  [-/{d}]  {s}\n", .{ sid, t.priority, t.title });
        }
    }

    /// The arc-seq to display for a task: if `arc_id` is given, that arc's seq;
    /// else the best (lowest) seq across all arcs the task carries an `in` for.
    fn seqFor(self: *Cli, id: Ulid, arc_id: ?Ulid) ?i32 {
        var best: ?i32 = null;
        for (self.store.ins.items) |e| {
            if (!e.task.eql(id)) continue;
            if (arc_id) |a| {
                if (!e.arc.eql(a)) continue;
                return e.seq;
            }
            if (best == null or e.seq < best.?) best = e.seq;
        }
        return best;
    }

    // ----------------------------------------------------------- list

    fn cmdList(self: *Cli, args: []const []const u8) Error!void {
        var arc_filter: ?[]const u8 = null;
        var no_arc = false;
        var state_filter: ?State = null;
        var tag_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var json = false;
        // Search terms: each repeated `--word` AND each bare positional. ANDed.
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        // `--not-tag <t>` (repeatable, ANDed exclusion) — see `cmdNext`'s copy
        // of this doc for the motivating case (the autonomous-eligible bucket).
        var not_tags: std.ArrayList([]const u8) = .empty;
        defer not_tags.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--no-arc")) {
                no_arc = true;
            } else if (std.mem.eql(u8, args[i], "--state")) {
                const sv = try self.flagVal(args, &i, "--state");
                state_filter = State.fromString(sv) orelse {
                    try self.print("trk: '{s}' is not a state\n", .{sv});
                    return error.BadState;
                };
            } else if (std.mem.eql(u8, args[i], "--tag")) {
                tag_filter = try self.flagVal(args, &i, "--tag");
            } else if (std.mem.eql(u8, args[i], "--not-tag")) {
                try not_tags.append(self.gpa, try self.flagVal(args, &i, "--not-tag"));
            } else if (std.mem.eql(u8, args[i], "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                // Bare positional = a search term (shorthand for `--word`).
                try words.append(self.gpa, args[i]);
            }
        }
        if (arc_filter != null and no_arc) {
            try self.write("trk: --arc and --no-arc are mutually exclusive\n");
            return error.UsageError;
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| {
            members = try self.store.membersOf(self.gpa, a);
        } else if (no_arc) {
            members = try self.store.arcless(self.gpa);
        }

        // Deterministic: iterate sorted ids (in-memory query over the fold).
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        if (json) try self.write("[");
        var shown: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (state_filter) |sf| {
                if (t.state != sf) continue;
            } else if (t.state == .archived) {
                // Archived = retired to the changelog; hidden unless asked for
                // explicitly (`--state archived`) so the live list stays clean.
                continue;
            }
            if (members) |m| if (!containsId(m, id)) continue;
            if (tag_filter) |tf| if (!hasTag(t, tf)) continue;
            if (hasAnyTag(t, not_tags.items)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            if (limit) |lim| if (shown >= lim) break;
            if (json) {
                if (shown != 0) try self.write(",");
                try self.appendTaskJson(id, arc_id);
            } else {
                try self.printListLine(id);
            }
            shown += 1;
        }
        if (json) {
            try self.write("]\n");
        } else if (shown == 0) {
            try self.write("(no matching tasks)\n");
        }
    }

    /// list one-liner: `<state-marker> <short-id>  <title>  #tags`.
    fn printListLine(self: *Cli, id: Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        try self.print("{s} {s}  {s}", .{ stateMarker(t.state), try self.shortId(id, &sb), t.title });
        for (t.tags.items) |tg| try self.print("  #{s}", .{tg});
        try self.write("\n");
    }

    // ----------------------------------------------------------- render (markdown)

    fn cmdRender(self: *Cli, args: []const []const u8) Error!void {
        var out_path: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_path = try self.flagVal(args, &i, "--out");
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(self.gpa);
        try self.renderMarkdown(&md);

        // Precedence: explicit --out > config render.out > stdout.
        const effective = out_path orelse self.store.config.render_out;
        if (effective) |p| {
            try self.writeOutFile(p, md.items);
            try self.print("wrote {d} bytes to {s}\n", .{ md.items.len, p });
        } else {
            try self.write(md.items);
        }
    }

    /// Build the TODO.md-style markdown projection into `buf`. Deterministic:
    /// arcs ordered by their root task's (priority, id); tasks within an arc in
    /// `next`/seq order (then id); a trailing "Arc-less" section. Writer-
    /// parameterized (a buffer) so it's testable without disk.
    pub fn renderMarkdown(self: *Cli, buf: *std.ArrayList(u8)) Error!void {
        const gpa = self.gpa;
        try buf.print(gpa,
            \\# TODO — remaining work
            \\
            \\> Generated by `trk render` from the in-repo issue tracker (`.tracker/`). Do not edit by hand —
            \\> mutate via `trk add`/`dep`/`in`/`edit`/`state` and regenerate.
            \\
            \\
        , .{});

        // Arc-less drift: surfaced every regeneration so it can't go unnoticed
        // for weeks (`trk list --no-arc` for the list itself).
        try buf.print(gpa, "> Arc-less drift: {d} remaining task(s) belong to no arc (`trk list --no-arc`).\n\n", .{
            try self.arclessRemainingCount(),
        });

        // Collect arcs = every id `isArc` is true for (declared, `in`-target, or
        // back-compat `arc:` tag). Sort by (root prio, id).
        const arcs = try self.collectArcs();
        defer gpa.free(arcs);

        // Track which tasks have been printed under some arc, to build Arc-less.
        var printed = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer printed.deinit(gpa);

        // Pre-count how many arc sections will list each task: a task shared by
        // several arcs is listed in full exactly once (anchored), and every
        // later listing links back to it instead of repeating the body. Arc
        // order is deterministic, so "first" is stable across renders.
        var listing_count = std.AutoHashMapUnmanaged([ulid.len]u8, u32){};
        defer listing_count.deinit(gpa);
        for (arcs) |arc| {
            const members = try self.store.membersOf(gpa, arc);
            defer gpa.free(members);
            for (members) |id| {
                if (!isRemaining(self.store.get(id).?.state)) continue;
                if (self.store.isArc(id)) continue;
                const gop = try listing_count.getOrPut(gpa, id.text);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }

        for (arcs) |arc| {
            const arc_t = self.store.get(arc).?;
            try buf.print(gpa, "## {s}", .{arc_t.title});
            var asb: [ulid.len]u8 = undefined;
            const arc_short = try self.shortId(arc, &asb);
            try buf.print(gpa, "  ({s})\n\n", .{arc_short});

            // Members in next/seq order: take next() order filtered to members,
            // then append any non-ready members (sorted by seq, id) so done/
            // blocked tasks still appear. Simpler + deterministic: sort all
            // members by (seq-in-this-arc, id).
            const members = try self.store.membersOf(gpa, arc);
            defer gpa.free(members);
            const ordered = try self.orderMembers(arc, members);
            defer gpa.free(ordered);

            for (ordered) |id| {
                // TODO = only not-yet-built work: show open/blocked, never the
                // finished/abandoned states (done graduates to the CHANGELOG via
                // `trk archive`; dropped is won't-do; archived is already recorded).
                if (!isRemaining(self.store.get(id).?.state)) continue;
                // An arc is always represented by its own section header, never a
                // bullet — skip any arc root here (its own section, or another arc
                // that reaches it via a `needs` edge). Mark printed so it doesn't
                // fall into the Arc-less section.
                if (self.store.isArc(id)) {
                    try printed.put(gpa, id.text, {});
                    continue;
                }
                const listing: Listing = if (printed.contains(id.text))
                    .repeat
                else if ((listing_count.get(id.text) orelse 1) > 1)
                    .anchored
                else
                    .plain;
                try self.renderTaskBullet(buf, id, arc, listing);
                try printed.put(gpa, id.text, {});
            }
            try buf.print(gpa, "\n", .{});
        }

        // Arc-less: every task printed by no arc section.
        const ids = try self.store.allIds(gpa);
        defer gpa.free(ids);
        var any_arcless = false;
        for (ids) |id| {
            if (printed.contains(id.text)) continue;
            if (!isRemaining(self.store.get(id).?.state)) continue;
            // An arc (declared, `in`-target, or back-compat `arc:` tag — the
            // unified `isArc`) is always represented by its own section above,
            // even with zero members — never list it as a stray Arc-less bullet.
            // (Belt-and-suspenders: `printed` already covers this for every
            // remaining-state arc root reachable from `collectArcs`, since it is
            // always its own first member; this check is the explicit backstop.)
            if (self.store.isArc(id)) continue;
            if (!any_arcless) {
                try buf.print(gpa, "## Arc-less\n\n", .{});
                any_arcless = true;
            }
            try self.renderTaskBullet(buf, id, null, .plain);
        }
        if (any_arcless) try buf.print(gpa, "\n", .{});
    }

    /// How a task appears in a render section. A task reachable from several
    /// arcs is listed everywhere it belongs, but its full detail (tags,
    /// doc-refs, body) appears exactly once: the first listing carries an HTML
    /// anchor (the full ULID — the only stable fragment target a markdown list
    /// item can have), and every repeat renders its short id as a link back.
    const Listing = enum { plain, anchored, repeat };

    /// One markdown bullet: `- [marker] <short-id> <title> #tags (doc#sec)`,
    /// followed by the body (if any) as a 2-space-indented block. The blank
    /// line before the block is load-bearing: without it, markdown lazy-
    /// continuation fuses the body's first line into the title paragraph.
    fn renderTaskBullet(self: *Cli, buf: *std.ArrayList(u8), id: Ulid, arc: ?Ulid, listing: Listing) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        const checkbox = stateCheckbox(t.state);
        const seq = self.seqFor(id, arc);
        switch (listing) {
            .plain => try buf.print(gpa, "- {s} `{s}`", .{ checkbox, sid }),
            .anchored => try buf.print(gpa, "- {s} <a id=\"{s}\"></a>`{s}`", .{ checkbox, &id.text, sid }),
            .repeat => {
                // Link back to the anchored first listing; keep the title (and
                // this arc's seq) for scanability, skip the repeated detail.
                try buf.print(gpa, "- {s} [`{s}`](#{s})", .{ checkbox, sid, &id.text });
                // seq 0 is the default (no explicit ordering) — omit it rather
                // than render the ABSENCE of ordering as noise. A genuine
                // non-zero seq uses "(seq N)", never bare "[N]": in markdown a
                // bare `[N]` is reference-link syntax with no definition, so it
                // rendered as an empty/broken anchor.
                if (seq) |s| if (s != 0) try buf.print(gpa, " (seq {d})", .{s});
                try buf.print(gpa, " {s}\n", .{t.title});
                return;
            },
        }
        if (seq) |s| if (s != 0) try buf.print(gpa, " (seq {d})", .{s});
        try buf.print(gpa, " {s}", .{t.title});
        for (t.tags.items) |tg| try buf.print(gpa, " #{s}", .{tg});
        for (t.docrefs.items) |dr| {
            // Resolve doc_id through the registry: use the path when registered,
            // fall back to the raw doc_id (so unregistered ids still render, no crash).
            const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
            if (dr.section_id) |sec| {
                try buf.print(gpa, " ({s}#{s})", .{ display, sec });
            } else {
                try buf.print(gpa, " ({s})", .{display});
            }
        }
        try buf.print(gpa, "\n", .{});

        const body = std.mem.trimEnd(u8, t.body, "\n");
        if (body.len != 0) {
            try buf.print(gpa, "\n", .{});
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |line| {
                if (line.len == 0) {
                    try buf.print(gpa, "\n", .{});
                } else {
                    try buf.print(gpa, "  ", .{});
                    // Neutralize a line-leading construct that would hijack the
                    // DOCUMENT's own heading structure (identical bug class to
                    // the seq-bracket fix above: field text landing in markdown
                    // without neutralizing markdown-significant syntax). Bodies
                    // are informally markdown by convention and that stays true
                    // for everything else — a leading `-` bullet list still
                    // renders as a list; only heading-shaped lines are escaped.
                    // Leading whitespace is skipped before testing: CommonMark
                    // allows up to 3 leading spaces on an ATX heading, and once
                    // this text sits inside the bullet's own indent + list-item
                    // continuation context, several MORE spaces of raw indent
                    // still parse as a heading rather than an indented code
                    // block — trying to model that column arithmetic is not
                    // worth it, so ANY amount of leading whitespace is hazard-
                    // checked past. The backslash is inserted right before the
                    // hazard character itself (after the preserved leading
                    // whitespace), not at the front of the line, so the line
                    // still reads naturally as plain, correctly-indented text.
                    const lead = leadingWhitespaceLen(line);
                    const rest = line[lead..];
                    if (isHeadingHazard(rest)) {
                        try buf.print(gpa, "{s}\\{s}\n", .{ line[0..lead], rest });
                    } else {
                        try buf.print(gpa, "{s}\n", .{line});
                    }
                }
            }
            try buf.print(gpa, "\n", .{});
        }
    }

    /// Index of the first non-space/tab byte in `line` (== `line.len` if the
    /// line is all whitespace). Used to find where a hazard character sits so
    /// the escaping backslash can be inserted AT that point, not at column 0.
    fn leadingWhitespaceLen(line: []const u8) usize {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        return i;
    }

    /// True if `rest` (a line with leading whitespace already stripped) would
    /// be parsed as markdown heading structure, outranking the render's own
    /// `#`/`##` hierarchy: an ATX heading (`#`...`######` at line-start), or a
    /// setext underline (a line consisting of ONLY `=` or ONLY `-`
    /// characters, CommonMark also permits trailing whitespace on that line)
    /// — which, following a non-blank line, retroactively turns THAT line
    /// into an H1/H2. A setext-shaped line is flagged unconditionally (not
    /// only when a preceding line is known) since escaping it is harmless
    /// either way. List markers (`- item`, which always carry a space +
    /// content after the dash) and inline formatting are deliberately left
    /// alone.
    fn isHeadingHazard(rest: []const u8) bool {
        if (rest.len == 0) return false;
        if (rest[0] == '#') return true;
        const setext = std.mem.trimEnd(u8, rest, " \t");
        return setext.len != 0 and (isAllChar(setext, '=') or isAllChar(setext, '-'));
    }

    fn isAllChar(s: []const u8, c: u8) bool {
        for (s) |ch| {
            if (ch != c) return false;
        }
        return true;
    }

    // ----------------------------------------------------------- tree (ASCII)

    fn cmdTree(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 1) {
            try self.write("trk: usage: trk tree <arc-or-task-id>\n");
            return error.UsageError;
        }
        const root = try self.resolve(args[0]);
        try self.renderTree(self.out, root);
    }

    /// ASCII prereq hierarchy rooted at `root`. If `root` is an arc (has direct
    /// `in` members), the arc's members nest under it as branches; each task's
    /// `needs`-prereqs nest recursively beneath it. DAG-safe via a visited set:
    /// a node reached a second time prints `(↑ seen)` instead of re-expanding,
    /// so a diamond/shared-prereq never loops. Writer-parameterized.
    pub fn renderTree(self: *Cli, buf: *std.ArrayList(u8), root: Ulid) Error!void {
        const gpa = self.gpa;
        var visited = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer visited.deinit(gpa);

        // Root line (no connector).
        const rt = self.store.get(root).?;
        var rsb: [ulid.len]u8 = undefined;
        const rsid = try self.shortId(root, &rsb);
        try buf.print(gpa, "{s} {s} {s}\n", .{ stateMarker(rt.state), rsid, rt.title });
        try visited.put(gpa, root.text, {});

        // Children = arc members (direct `in root`) ++ direct prereqs of root.
        // Members come first (the arc-as-root view), then prereqs.
        var children: std.ArrayList(Ulid) = .empty;
        defer children.deinit(gpa);
        var seen_child = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer seen_child.deinit(gpa);
        for (self.store.ins.items) |e| {
            if (e.arc.eql(root)) {
                const gop = try seen_child.getOrPut(gpa, e.task.text);
                if (!gop.found_existing) try children.append(gpa, e.task);
            }
        }
        for (self.directPrereqs(root)) |p| {
            const gop = try seen_child.getOrPut(gpa, p.text);
            if (!gop.found_existing) try children.append(gpa, p);
        }
        // Deterministic sibling order.
        sortByArcSeqThenId(self, root, children.items);

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(gpa);
        for (children.items, 0..) |child, idx| {
            const last = idx == children.items.len - 1;
            try self.treeNode(buf, &prefix, child, last, &visited);
        }
    }

    fn treeNode(
        self: *Cli,
        buf: *std.ArrayList(u8),
        prefix: *std.ArrayList(u8),
        id: Ulid,
        last: bool,
        visited: *std.AutoHashMapUnmanaged([ulid.len]u8, void),
    ) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        const connector = if (last) "└─ " else "├─ ";

        const already = visited.contains(id.text);
        try buf.print(gpa, "{s}{s}{s} {s} {s}", .{ prefix.items, connector, stateMarker(t.state), sid, t.title });
        if (already) {
            try buf.print(gpa, " (\u{2191} seen)\n", .{}); // ↑ seen — do not re-expand
            return;
        }
        try buf.print(gpa, "\n", .{});
        try visited.put(gpa, id.text, {});

        // Recurse into this task's direct prereqs.
        const prereqs = self.directPrereqs(id);
        if (prereqs.len == 0) return;

        // Extend the prefix: a vertical bar if this node has a following sibling,
        // else blank.
        const added: []const u8 = if (last) "   " else "\u{2502}  "; // "│  "
        const old_len = prefix.items.len;
        try prefix.appendSlice(gpa, added);
        defer prefix.shrinkRetainingCapacity(old_len);

        // Stable order of prereqs.
        const kids = try gpa.dupe(Ulid, prereqs);
        defer gpa.free(kids);
        std.sort.pdq(Ulid, kids, {}, Ulid.lessThan);
        for (kids, 0..) |k, idx| {
            const klast = idx == kids.len - 1;
            try self.treeNode(buf, prefix, k, klast, visited);
        }
    }

    /// `directPrereqs(id)` — the `to` of every `id needs to` edge. Returns a
    /// slice into a freshly-allocated array (caller-owned via the arena trick:
    /// we allocate on gpa but the caller in tree uses it transiently). To keep
    /// lifetimes simple we allocate + the caller dupes when recursing; here we
    /// return a gpa-owned slice the caller frees. Re-implemented as a helper
    /// returning a slice the caller must free is awkward across recursion, so we
    /// instead scan inline. NOTE: small graphs, O(E) per call is fine.
    fn directPrereqs(self: *Cli, id: Ulid) []const Ulid {
        // We can't return a stack array; reuse a scratch list owned by the Cli.
        self.prereq_scratch.clearRetainingCapacity();
        for (self.store.needs.items) |e| {
            if (e.from.eql(id)) self.prereq_scratch.append(self.gpa, e.to) catch return &.{};
        }
        return self.prereq_scratch.items;
    }

    // ----------------------------------------------------------- arc helpers

    /// Count of remaining (open/blocked) tasks in NO arc — the render header's
    /// drift number. Wraps `Store.arcless`, filtered to `isRemaining` (a
    /// done/dropped/archived arc-less task isn't "not yet sorted" drift, it's
    /// just finished).
    fn arclessRemainingCount(self: *Cli) Error!usize {
        const ids = try self.store.arcless(self.gpa);
        defer self.gpa.free(ids);
        var n: usize = 0;
        for (ids) |id| {
            if (isRemaining(self.store.get(id).?.state)) n += 1;
        }
        return n;
    }

    /// Every arc (every id `isArc` is true for — declared, an `in.arc` target,
    /// or a back-compat `arc:` tag), sorted by (root priority, id). This is
    /// what earns a task its own "## <title>" render section, INCLUDING a
    /// declared-but-zero-member arc (it renders as a header with no bullets).
    fn collectArcs(self: *Cli) Error![]Ulid {
        const gpa = self.gpa;
        const out = try self.store.arcRoots(gpa);
        const Ctx = struct {
            cli: *Cli,
            fn less(c: @This(), x: Ulid, y: Ulid) bool {
                const tx = c.cli.store.get(x).?;
                const ty = c.cli.store.get(y).?;
                if (tx.priority != ty.priority) return tx.priority < ty.priority;
                return x.order(y) == .lt;
            }
        };
        std.sort.pdq(Ulid, out, Ctx{ .cli = self }, Ctx.less);
        return out;
    }

    /// Order an arc's members by (seq-in-this-arc, id). Direct members carry an
    /// explicit seq; reachability-only members (a shared prereq) get the
    /// sentinel max so they sort after the explicitly-ordered ones.
    fn orderMembers(self: *Cli, arc: Ulid, members: []const Ulid) Error![]Ulid {
        const gpa = self.gpa;
        const out = try gpa.dupe(Ulid, members);
        const Ctx = struct {
            cli: *Cli,
            arc: Ulid,
            fn seqOf(c: @This(), id: Ulid) i64 {
                for (c.cli.store.ins.items) |e| {
                    if (e.task.eql(id) and e.arc.eql(c.arc)) return e.seq;
                }
                return std.math.maxInt(i64);
            }
            fn less(c: @This(), x: Ulid, y: Ulid) bool {
                const sx = c.seqOf(x);
                const sy = c.seqOf(y);
                if (sx != sy) return sx < sy;
                return x.order(y) == .lt;
            }
        };
        std.sort.pdq(Ulid, out, Ctx{ .cli = self, .arc = arc }, Ctx.less);
        return out;
    }

    // ----------------------------------------------------------- show

    /// `trk show <id>` — full task detail view.
    fn cmdShow(self: *Cli, args: []const []const u8) Error!void {
        var id_arg: ?[]const u8 = null;
        var raw_body = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--body")) {
                raw_body = true;
            } else if (id_arg == null) {
                id_arg = a;
            } else {
                try self.write("trk: usage: trk show <id> [--body]\n");
                return error.UsageError;
            }
        }
        const id = try self.resolve(id_arg orelse {
            try self.write("trk: usage: trk show <id> [--body]\n");
            return error.UsageError;
        });
        const t = self.store.get(id).?;

        if (raw_body) {
            // Verbatim body bytes, nothing else — the read half of a safe edit
            // round-trip: trk edit <id> --body "$(trk show <id> --body)".
            try self.write(t.body);
            if (t.body.len != 0 and t.body[t.body.len - 1] != '\n') try self.write("\n");
            return;
        }

        try self.print("id:       {s}\n", .{&id.text});
        try self.print("title:    {s}\n", .{t.title});
        try self.print("state:    {s}\n", .{t.state.toString()});
        try self.print("priority: {d}\n", .{t.priority});

        // Tags
        try self.write("tags:     ");
        if (t.tags.items.len == 0) {
            try self.write("(none)\n");
        } else {
            for (t.tags.items, 0..) |tg, i| {
                if (i != 0) try self.write(" ");
                try self.print("#{s}", .{tg});
            }
            try self.write("\n");
        }

        // Body
        try self.write("body:\n");
        if (t.body.len == 0) {
            try self.write("  (empty)\n");
        } else {
            // Indent each line by 2 spaces.
            var it = std.mem.splitScalar(u8, t.body, '\n');
            while (it.next()) |line| try self.print("  {s}\n", .{line});
        }

        // Prereqs (tasks this task needs)
        try self.write("\nprereqs (needs):\n");
        {
            var found = false;
            for (self.store.needs.items) |e| {
                if (!e.from.eql(id)) continue;
                found = true;
                const pre = self.store.get(e.to).?;
                var sb: [ulid.len]u8 = undefined;
                if (self.store.isArc(e.to)) {
                    // The gate is the ROOT's state (the completion judgment);
                    // drain progress is shown as context, not as the gate.
                    const p = self.store.arcProgress(e.to);
                    try self.print("  {s} {s}  arc: {s}  ({d}/{d} done)\n", .{
                        stateMarker(pre.state), try self.shortId(e.to, &sb), pre.title, p.done, p.total,
                    });
                } else {
                    try self.print("  {s} {s}  {s}\n", .{
                        stateMarker(pre.state), try self.shortId(e.to, &sb), pre.title,
                    });
                }
            }
            if (!found) try self.write("  (none)\n");
        }

        // Dependents (tasks that need this one)
        try self.write("\ndependents (needs this):\n");
        {
            const rdeps = try self.store.reverseDeps(self.gpa, id);
            defer self.gpa.free(rdeps);
            if (rdeps.len == 0) {
                try self.write("  (none)\n");
            } else {
                for (rdeps) |dep_id| {
                    const dep_t = self.store.get(dep_id).?;
                    var sb: [ulid.len]u8 = undefined;
                    try self.print("  {s} {s}  {s}\n", .{
                        stateMarker(dep_t.state), try self.shortId(dep_id, &sb), dep_t.title,
                    });
                }
            }
        }

        // Arcs
        try self.write("\narcs:\n");
        {
            const arcs = try self.store.arcsOf(self.gpa, id);
            defer self.gpa.free(arcs);
            if (arcs.len == 0) {
                try self.write("  (none)\n");
            } else {
                for (arcs) |arc_id| {
                    const arc_t = self.store.get(arc_id).?;
                    var sb: [ulid.len]u8 = undefined;
                    const seq = self.seqFor(id, arc_id);
                    if (seq) |s| {
                        try self.print("  {s}  {s}  seq={d}\n", .{
                            try self.shortId(arc_id, &sb), arc_t.title, s,
                        });
                    } else {
                        try self.print("  {s}  {s}\n", .{
                            try self.shortId(arc_id, &sb), arc_t.title,
                        });
                    }
                }
            }
        }

        // Doc-refs
        try self.write("\ndoc-refs:\n");
        if (t.docrefs.items.len == 0) {
            try self.write("  (none)\n");
        } else {
            for (t.docrefs.items) |dr| {
                const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
                if (dr.section_id) |sec| {
                    try self.print("  {s}#{s}\n", .{ display, sec });
                } else {
                    try self.print("  {s}\n", .{display});
                }
            }
        }
    }

    // ----------------------------------------------------------- edit

    /// `trk edit <id> [--title <s>] [--body <s>] [--add-tag <t>] [--rm-tag <t>] [--priority <n>]`
    fn cmdEdit(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: usage: trk edit <id> [--title <s>] [--body <s>] [--add-tag <t> ...] [--rm-tag <t> ...] [--priority <n>]\n");
            return error.MissingArgument;
        }
        const id = try self.resolve(args[0]);

        var new_title: ?[]const u8 = null;
        var new_body: ?[]const u8 = null;
        var priority: ?i32 = null;
        var add_tags: std.ArrayList([]const u8) = .empty;
        defer add_tags.deinit(self.gpa);
        var rm_tags: std.ArrayList([]const u8) = .empty;
        defer rm_tags.deinit(self.gpa);
        var add_docs: std.ArrayList([]const u8) = .empty;
        defer add_docs.deinit(self.gpa);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title")) {
                new_title = try self.flagVal(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body")) {
                new_body = try self.flagVal(args, &i, "--body");
            } else if (std.mem.eql(u8, arg, "--add-doc")) {
                try add_docs.append(self.gpa, try self.flagVal(args, &i, "--add-doc"));
            } else if (std.mem.eql(u8, arg, "--add-tag")) {
                try add_tags.append(self.gpa, try self.flagVal(args, &i, "--add-tag"));
            } else if (std.mem.eql(u8, arg, "--rm-tag")) {
                try rm_tags.append(self.gpa, try self.flagVal(args, &i, "--rm-tag"));
            } else if (std.mem.eql(u8, arg, "--priority")) {
                priority = try self.parseI32(try self.flagVal(args, &i, "--priority"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            }
        }

        // At least one flag required.
        if (new_title == null and new_body == null and priority == null and
            add_tags.items.len == 0 and rm_tags.items.len == 0 and add_docs.items.len == 0)
        {
            try self.write("trk: edit needs at least one flag (--title / --body / --add-tag / --rm-tag / --add-doc / --priority)\n");
            return error.UsageError;
        }

        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);

        if (new_title) |nt| {
            try self.store.append(.{ .setTitle = .{ .id = id, .title = nt } });
            try self.print("{s}: title -> {s}\n", .{ sid, nt });
        }
        if (new_body) |nb| {
            try self.store.append(.{ .setBody = .{ .id = id, .body = nb } });
            try self.print("{s}: body updated\n", .{sid});
        }
        for (add_tags.items) |tg| {
            try self.store.append(.{ .tag = .{ .id = id, .tag = tg } });
            try self.print("{s}: +#{s}\n", .{ sid, tg });
            try self.warnDeprecatedArcTag(id, tg);
        }
        for (rm_tags.items) |tg| {
            try self.store.append(.{ .untag = .{ .id = id, .tag = tg } });
            try self.print("{s}: -#{s}\n", .{ sid, tg });
        }
        if (priority) |p| {
            try self.store.append(.{ .setPriority = .{ .id = id, .priority = p } });
            try self.print("{s}: priority -> {d}\n", .{ sid, p });
        }
        for (add_docs.items) |d| {
            const ref = splitDocRef(d);
            try self.store.append(.{ .docref = .{ .id = id, .doc_id = ref.doc_id, .section_id = ref.section_id } });
            try self.print("{s}: +doc {s}\n", .{ sid, d });
        }
    }

    // ----------------------------------------------------------- log

    /// `trk log [<id>] [--limit <n>]` — event history, newest-last.
    fn cmdLog(self: *Cli, args: []const []const u8) Error!void {
        var id_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            } else {
                // Positional: the id filter.
                if (id_filter != null) {
                    try self.write("trk: log takes at most one <id> positional argument\n");
                    return error.UsageError;
                }
                id_filter = arg;
            }
        }

        // Resolve the id filter if given (will error cleanly on NoSuchId).
        const filter_id: ?Ulid = if (id_filter) |s| try self.resolve(s) else null;

        const entries = try self.store.readLogEntries(self.gpa);
        defer {
            for (entries) |e| self.gpa.free(e.summary);
            self.gpa.free(entries);
        }

        // Filter by task id.
        var filtered: std.ArrayList(tracker.Store.LogEntry) = .empty;
        defer filtered.deinit(self.gpa);
        for (entries) |e| {
            if (filter_id) |fid| {
                const matches = e.task_id != null and e.task_id.?.eql(fid);
                if (!matches) continue;
            }
            try filtered.append(self.gpa, e);
        }

        // Apply limit (take last N = most-recent-last view with tail truncation).
        var start: usize = 0;
        if (limit) |lim| {
            if (filtered.items.len > lim) start = filtered.items.len - lim;
        }
        const to_print = filtered.items[start..];

        if (to_print.len == 0) {
            try self.write("(no events)\n");
            return;
        }

        for (to_print) |e| {
            var ts_buf: [32]u8 = undefined;
            const ts_str = fmtTs(e.ts, &ts_buf);
            try self.print("{s}  {s}  {s}\n", .{ ts_str, @tagName(e.op), e.summary });
        }
    }

    // ----------------------------------------------------------- stale

    /// `trk stale` — cross-reference: which currently-`open` tasks have their
    /// id cited in a LANDED commit message, but were never closed? The
    /// evidence for the dominant rot found in the 2026-07-30 reconciliation:
    /// not "the work landed under a different id" (a minority case) but
    /// simply that the implementing commit NAMED the id and nobody ran `trk
    /// state done` — the evidence was sitting in `git log` the whole time.
    ///
    /// Scans `git log --oneline` on the CURRENT branch's ancestry, DELIBERATELY
    /// not `--all`: `--all` walks every ref, including a parallel fan-out's
    /// unmerged worktree branches, and a hit there is not proof the work is at
    /// HEAD (a commit can cite an id from a branch nobody has merged) — see
    /// the `git log --all --grep` false-positive finding. `--stale` wants only
    /// LANDED evidence. Runs `git` with cwd set to the store root (the repo
    /// that houses `.tracker/`, which may differ from where `trk` itself
    /// lives — `main.zig`'s `discover.findRoot` already resolved `self.dir`
    /// to exactly that repo).
    ///
    /// Matches by exact TOKEN (a maximal run of ASCII alphanumerics), not raw
    /// substring: the log text is scanned once, and each token is looked up
    /// against an index of every open task's full id AND its displayed short
    /// id. Token (not substring) matching means a short id can never
    /// accidentally match as part of some longer, unrelated token.
    ///
    /// `claimed` tasks are deliberately EXCLUDED from the report: a claim
    /// already IS the self-reported "this commit completes it" signal this
    /// verb exists to surface for an `open` task that never got one —
    /// flagging an already-claimed task again would just be noise on an
    /// item that is already in the awaiting-verification queue (`trk list
    /// --state claimed`), not the "invisible in the haystack" rot this
    /// targets. See `State.claimed`.
    fn cmdStale(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: usage: trk stale\n");
            return error.UsageError;
        }

        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "log", "--oneline" },
            .cwd = .{ .dir = self.dir },
        }) catch |e| {
            try self.print(
                "trk: stale: failed to run 'git log': {s} (is the store root a git repo, and is git on PATH?)\n",
                .{@errorName(e)},
            );
            return error.GitLogFailed;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const exited_ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!exited_ok) {
            try self.print("trk: stale: 'git log' failed: {s}\n", .{std.mem.trimEnd(u8, result.stderr, " \t\r\n")});
            return error.GitLogFailed;
        }

        // Citation index: every OPEN task's full id + its currently-displayed
        // short id -> the task id. gpa-owned keys (both `id.slice()` and
        // `shortId`'s buffer are transient).
        var index = std.StringHashMapUnmanaged(Ulid){};
        defer {
            var it = index.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            index.deinit(self.gpa);
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.state != .open) continue; // claimed/done/blocked/dropped/archived: not this report's concern
            try index.put(self.gpa, try self.gpa.dupe(u8, id.slice()), id);
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            if (!std.mem.eql(u8, sid, id.slice())) {
                try index.put(self.gpa, try self.gpa.dupe(u8, sid), id);
            }
        }

        // Tokenize the whole log text once; on each match keep the FIRST hit
        // per task (git log is newest-first, so that's the most recent citation).
        var hits = std.AutoHashMapUnmanaged([ulid.len]u8, []const u8){};
        defer hits.deinit(self.gpa);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var tok_start: ?usize = null;
            var ci: usize = 0;
            while (ci <= line.len) : (ci += 1) {
                const is_alnum = ci < line.len and std.ascii.isAlphanumeric(line[ci]);
                if (is_alnum) {
                    if (tok_start == null) tok_start = ci;
                } else if (tok_start) |s| {
                    if (index.get(line[s..ci])) |task_id| {
                        const gop = try hits.getOrPut(self.gpa, task_id.text);
                        if (!gop.found_existing) gop.value_ptr.* = line;
                    }
                    tok_start = null;
                }
            }
        }

        if (hits.count() == 0) {
            try self.write("trk: stale: nothing — no open task is cited in a landed commit\n");
            return;
        }

        // Deterministic report order.
        const stale_ids = try self.gpa.alloc(Ulid, hits.count());
        defer self.gpa.free(stale_ids);
        {
            var it = hits.keyIterator();
            var idx: usize = 0;
            while (it.next()) |k| : (idx += 1) stale_ids[idx] = .{ .text = k.* };
        }
        std.sort.pdq(Ulid, stale_ids, {}, Ulid.lessThan);

        try self.print("trk: stale: {d} open task(s) cited in a landed commit but never closed:\n", .{stale_ids.len});
        for (stale_ids) |id| {
            const t = self.store.get(id).?;
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            const line = hits.get(id.text).?;
            try self.print("{s} {s}  {s}\n    cited in: {s}\n", .{ stateMarker(t.state), sid, t.title, line });
        }
    }
};

// ----------------------------------------------------------- timestamp formatter

/// Format a Unix-epoch millisecond timestamp as "YYYY-MM-DD HH:MM:SS" (UTC).
/// ts=0 (unknown/legacy) renders as "????-??-?? ??:??:??".
/// `buf` must be at least 32 bytes; returns a slice into it.
/// Split a `--doc` value `doc_id` or `doc_id#section` into its parts.
fn splitDocRef(s: []const u8) struct { doc_id: []const u8, section_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, s, '#')) |h| {
        return .{ .doc_id = s[0..h], .section_id = s[h + 1 ..] };
    }
    return .{ .doc_id = s, .section_id = null };
}

fn fmtTs(ms: i64, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 32);
    if (ms == 0) {
        const s = "????-??-?? ??:??:??";
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    const secs = @divFloor(ms, 1000);
    const secs_in_day: u32 = @intCast(@mod(secs, 86400));
    const hour: u32 = secs_in_day / 3600;
    const min: u32 = (secs_in_day % 3600) / 60;
    const sec: u32 = secs_in_day % 60;

    // Civil-from-days algorithm (Hinnant): days since epoch -> year/month/day.
    const z: i64 = @divFloor(secs, 86400) + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const yr: i64 = y + if (m <= 2) @as(i64, 1) else 0;

    // Write into a fixed-size sub-buffer (19 chars for "YYYY-MM-DD HH:MM:SS").
    // Year is formatted unsigned: zero-padding a signed int prints an explicit
    // "+" sign (std.fmt since 0.15), which corrupted date slices like [0..10].
    var tmp: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&tmp, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(yr)), m, d, hour, min, sec,
    }) catch "0000-00-00 00:00:00";
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
}

// ----------------------------------------------------------- free helpers

fn containsId(haystack: []const Ulid, needle: Ulid) bool {
    for (haystack) |h| if (h.eql(needle)) return true;
    return false;
}

/// DEPRECATED: the cosmetic pre-`arcDeclare` arc marker. Not a definition of
/// arc-ness (that's `Store.isArc`, which already reads this same `arc:` prefix
/// as a backward-compat fallback) — this standalone helper survives only as
/// `trk migrate-arcs`'s "does this task need converting" check.
fn hasArcTag(t: Task) bool {
    for (t.tags.items) |tg| {
        if (std.mem.startsWith(u8, tg, "arc:")) return true;
    }
    return false;
}

fn hasTag(t: Task, tag: []const u8) bool {
    for (t.tags.items) |tg| if (std.mem.eql(u8, tg, tag)) return true;
    return false;
}

/// True iff `t` carries ANY tag in `tags` — the `--not-tag` exclusion test
/// (repeatable, ANDed as an exclusion: absence of every listed tag is
/// required to pass). An empty `tags` list matches nothing (no `--not-tag`
/// given), so the filter is a no-op by default.
fn hasAnyTag(t: Task, tags: []const []const u8) bool {
    for (tags) |tag| if (hasTag(t, tag)) return true;
    return false;
}

/// True iff `word` appears (case-insensitively) in the task's title, body, or
/// any tag. Tags are included so `--word prism` catches `#arc:display-prism`.
fn wordMatches(t: Task, word: []const u8) bool {
    if (containsSubCI(t.title, word)) return true;
    if (containsSubCI(t.body, word)) return true;
    for (t.tags.items) |tg| if (containsSubCI(tg, word)) return true;
    return false;
}

/// AND across terms: every word must match (each via `wordMatches`). An empty
/// term list matches everything (no `--word`/positional filter given).
fn allWordsMatch(t: Task, words: []const []const u8) bool {
    for (words) |w| if (!wordMatches(t, w)) return false;
    return true;
}

fn containsSubCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Is this task still not-yet-built work (shown in the TODO projection)?
/// open + blocked + claimed are pending (a claim is a commit's self-report,
/// pending the orchestrator's verify — see `State.claimed`); done/dropped/
/// archived are finished or abandoned.
fn isRemaining(s: State) bool {
    return s == .open or s == .blocked or s == .claimed;
}

/// One-char state marker for line output / the tree.
fn stateMarker(s: State) []const u8 {
    return switch (s) {
        .open => "[ ]",
        .done => "[x]",
        .blocked => "[~]",
        .dropped => "[-]",
        .archived => "[a]",
        // Distinct from plain `open` on purpose — a claim is not verified work
        // available to pick up (see `State.claimed`'s doc comment).
        .claimed => "[c]",
    };
}

/// Same set, used in the markdown bullet (kept identical for consistency).
fn stateCheckbox(s: State) []const u8 {
    return stateMarker(s);
}

/// Sort children of a tree root by (arc-seq under that root, id) for a stable,
/// priority-ordered sibling list. Standalone so the `tree` root can reuse it.
fn sortByArcSeqThenId(cli: *Cli, arc: Ulid, items: []Ulid) void {
    const Ctx = struct {
        cli: *Cli,
        arc: Ulid,
        fn seqOf(c: @This(), id: Ulid) i64 {
            for (c.cli.store.ins.items) |e| {
                if (e.task.eql(id) and e.arc.eql(c.arc)) return e.seq;
            }
            return std.math.maxInt(i64);
        }
        fn less(c: @This(), x: Ulid, y: Ulid) bool {
            const sx = c.seqOf(x);
            const sy = c.seqOf(y);
            if (sx != sy) return sx < sy;
            return x.order(y) == .lt;
        }
    };
    std.sort.pdq(Ulid, items, Ctx{ .cli = cli, .arc = arc }, Ctx.less);
}

fn lessThanStrCli(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
