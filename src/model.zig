// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! The data model: tasks (nodes), the two edge kinds, and the on-disk event
//! shapes. Pure data + small helpers; no I/O, no fold logic (that's store.zig).

const std = @import("std");
const ulid = @import("ulid.zig");

pub const Ulid = ulid.Ulid;

/// Task lifecycle. `open`/`done` are the only states `next` reasons about
/// (a `done` prereq unblocks dependents; an `open` one blocks). `blocked` and
/// `dropped` are authoring conveniences: `dropped` is excluded from `next` (it
/// is not eligible) and, like `done`, does NOT block dependents — a dropped
/// prereq is gone, not pending. `blocked` is an explicit human annotation that
/// `next` treats as not-eligible (you would not hand it out) but, unlike `done`,
/// it still blocks its dependents (it isn't finished).
pub const State = enum {
    open,
    done,
    blocked,
    dropped,
    /// Completed AND recorded in the changelog — the graduation tombstone. Set by
    /// `trk archive`, which emits the task as a changelog bullet then flips it here.
    /// Excluded from every working view (`next`, `list` by default, `render`) so a
    /// recorded item can never be re-listed or re-changelogged (structural dedup);
    /// retained in the log for audit until `compact` physically GCs it. Like
    /// `done`/`dropped` it satisfies a prereq (it is finished).
    archived,
    /// A CLAIM, not a verdict: "the commit I'm riding completes this task, pending
    /// verification." Exists so a task close can ride the implementing commit even
    /// for GATED work, where a compile-only builder cannot know whether the boot
    /// gate passed and so is barred from ever asserting `done` (`done` means
    /// "passed its gate"). Deliberately weaker than `done` in both directions:
    /// - does NOT satisfy a `needs` edge (`satisfiesPrereq` is false) — a
    ///   dependent must wait for the real, verified `done`, not an unverified claim.
    /// - does NOT appear in `next`'s ready frontier (`isEligible` is false) — it
    ///   is not available work, so surfacing it there would let a second builder
    ///   pick it up and redo already-claimed work (the "inflate the frontier
    ///   ambiguously" failure this state exists to avoid).
    /// It DOES count as remaining/not-yet-built for `trk render`'s TODO.md
    /// projection (`isRemaining` in cli.zig), with its own marker distinct from
    /// `open` — a short, explicit "awaiting verification" queue a human or a hook
    /// can scan (`trk list --state claimed`), rather than silently blending into
    /// ordinary open work. The orchestrator's post-gate reconcile promotes it to
    /// `done` (gate passed) or demotes it back to `open` with a note (gate
    /// failed) — the existing "orchestrator alone verifies" rule is unchanged;
    /// only what a builder agent may itself write changes.
    claimed,

    /// Does this task's state satisfy a `needs` edge pointing at it?
    /// (i.e. may a dependent become eligible because of it.)
    pub fn satisfiesPrereq(self: State) bool {
        return self == .done or self == .dropped or self == .archived;
    }

    /// Is a task in this state itself eligible to appear in `next`?
    pub fn isEligible(self: State) bool {
        return self == .open;
    }

    pub fn toString(self: State) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?State {
        return std.meta.stringToEnum(State, s);
    }
};

/// A doc-ref: indirect `doc_id` (through a future id->path registry) plus an
/// optional stable `section_id` anchor for a focused read.
pub const DocRef = struct {
    doc_id: []const u8,
    section_id: ?[]const u8 = null,
};

/// An in-memory task node. Strings/lists are owned by the Store's arena.
pub const Task = struct {
    id: Ulid,
    title: []const u8 = "",
    body: []const u8 = "",
    state: State = .open,
    /// Global cross-arc tiebreaker. Lower sorts first. Default 0.
    priority: i32 = 0,
    tags: std.ArrayList([]const u8) = .empty,
    docrefs: std.ArrayList(DocRef) = .empty,
    /// The FROZEN short id, set once (at mint time, or by `trk migrate-shorts`
    /// for a pre-existing task) and never recomputed. `null` means "never
    /// frozen" — the display falls back to the legacy dynamically-computed
    /// prefix (`Cli.shortId`), which is UNSTABLE (moves as the id set moves —
    /// see design.md "short-id stability"). Once set, this is the only value
    /// `Cli.shortId` ever returns for this task, across adds/archives/compacts.
    short: ?[]const u8 = null,
};

/// `from needs to` — `from` depends on prerequisite `to`. Forms the DAG.
pub const Needs = struct {
    from: Ulid,
    to: Ulid,
};

/// `task in arc` with per-arc priority `seq`. `arc` is itself a task id (an arc
/// is a goal-root task). `seq`: an i32, **lower = higher priority** (sorts
/// first), matching the global `priority` convention so the two compose.
pub const In = struct {
    task: Ulid,
    arc: Ulid,
    seq: i32,
};

/// The op discriminator for a log event. Adding a variant here is a
/// forward-compat event for every OLDER binary, not just a new feature for
/// this one (01KYT2QET): an unrecognized op is skipped-and-warned by
/// `Store.load`, not fatal, so decide whether that default is SAFE for the
/// new op's semantics — see `json_codec.zig`'s file-level doc comment and
/// `peekUnknownOp`'s `"breaking"` escape hatch before adding one.
pub const Op = enum {
    add,
    setState,
    dep,
    in,
    setPriority,
    tag,
    docref,
    /// Registry: map a stable doc_id to a repo-relative file path. Last-write-wins
    /// on fold; re-setting the same doc_id updates the path so every task's docref
    /// survives a doc move without touching the task's event.
    setDocPath,
    /// Replace a task's title (last-write-wins on fold).
    setTitle,
    /// Replace a task's body (last-write-wins on fold).
    setBody,
    /// Remove a tag from a task (idempotent: no-op if tag not present).
    untag,
    /// Remove a `needs` edge (edge tombstone; no-op if edge not present).
    /// Under the union-merge model, an `undep` for edge (from,to) beats any
    /// concurrent `dep` for the same edge: the tombstone wins regardless of
    /// append order on fold.
    undep,
    /// Remove an `in` membership edge (edge tombstone; no-op if edge not
    /// present) — the exact mirror of `undep`, for the OTHER edge kind. Under
    /// the union-merge model, a `unin` for edge (task,arc) beats any
    /// concurrent `in` for the same edge: the tombstone wins regardless of
    /// append order on fold. Exists so an argument-order slip on `trk in`
    /// (task/arc swapped) is correctable through the tool instead of
    /// permanently uncorrectable structural debris (01KYSYBVK).
    unin,
    /// Declare (or retract) a task as an arc root, independent of whether any
    /// task is `in` it. `declared: true` makes `isArc` true even with zero
    /// members (expresses a real goal with no work filed yet); `declared:
    /// false` retracts it (`trk arc --undo`). Single-task, last-write-wins on
    /// fold — same commutation shape as `setState`/`setPriority`. This is the
    /// unification of what used to be three non-agreeing arc definitions
    /// (a direct `in`-edge, `in`+reachability, and a cosmetic `arc:` tag);
    /// see `Store.isArc`.
    arcDeclare,
    /// Mark (or unmark) `id` as a STANDING arc: a goal container that names a
    /// perpetual category (housekeeping, the debug/observability substrate)
    /// rather than a completable goal. `declared: true` (`standing: true`)
    /// excludes it from `next`'s ready frontier UNCONDITIONALLY — even once
    /// drained, it never surfaces as the ordinary close-out prompt, because
    /// closing it would assert a completion that never happens — while still
    /// accepting new `in` members like any other arc. Last-write-wins on fold,
    /// same commutation shape as `arcDeclare`; see `Store.isStanding`. A task
    /// need not already be a declared arc for this to be set (harmless no-op
    /// until it also is one — the only place `isStanding` is consulted is
    /// alongside `isArc`), but `trk arc --standing` always declares the arc in
    /// the same act for ergonomics.
    arcStanding,
    /// Freeze a task's short id (last-write-wins on fold, but in practice
    /// written exactly once per task — by `trk migrate-shorts` for a
    /// pre-existing task that has no persisted short yet). A freshly-minted
    /// task instead gets its short via the `add` event's own `short` field;
    /// this op exists for the retrofit path where `add` already happened.
    setShort,
};

/// One log event — a tagged union over the op kinds. Fields mirror the JSON
/// schema in store.zig (one JSON object per line, `"op"` discriminator).
/// Every variant carries `ts: i64 = 0` — wall-clock ms at append time.
/// ts=0 means unknown (legacy log lines without a ts field).
pub const Event = union(Op) {
    add: struct {
        id: Ulid,
        title: []const u8 = "",
        body: []const u8 = "",
        tags: []const []const u8 = &.{},
        /// The short id frozen at mint time (`Cli.mintShortId`), or the value
        /// `compact`'s `serializeState` re-emits to carry an already-frozen
        /// short through the snapshot rewrite. `null` on a legacy add (no
        /// short was ever frozen) — the display then falls back to the
        /// dynamically-computed prefix. See `Task.short`.
        short: ?[]const u8 = null,
        /// Original creation ms (the ULID also carries it; kept explicit for the
        /// human face and so a re-mint scheme could decouple later). Optional.
        ts: i64 = 0,
    },
    setState: struct { id: Ulid, state: State, ts: i64 = 0 },
    dep: struct { from: Ulid, to: Ulid, ts: i64 = 0 },
    in: struct { task: Ulid, arc: Ulid, seq: i32 = 0, ts: i64 = 0 },
    setPriority: struct { id: Ulid, priority: i32, ts: i64 = 0 },
    tag: struct { id: Ulid, tag: []const u8, ts: i64 = 0 },
    docref: struct { id: Ulid, doc_id: []const u8, section_id: ?[]const u8 = null, ts: i64 = 0 },
    /// Register or update a doc_id → repo-relative path mapping.
    setDocPath: struct { doc_id: []const u8, path: []const u8, ts: i64 = 0 },
    /// Replace a task's title (last-write-wins on fold).
    setTitle: struct { id: Ulid, title: []const u8, ts: i64 = 0 },
    /// Replace a task's body (last-write-wins on fold).
    setBody: struct { id: Ulid, body: []const u8, ts: i64 = 0 },
    /// Remove a tag from a task (idempotent: no-op if tag not present).
    untag: struct { id: Ulid, tag: []const u8, ts: i64 = 0 },
    /// Remove a `needs` edge — the inverse of `dep`. No-op if the edge is not
    /// present. Tombstone beats add: applied after a `dep` on fold it removes
    /// the edge; applied before a `dep` (in union-merge order) the `dep` dedup
    /// guard re-checks and skips re-adding it. Both orderings converge.
    undep: struct { from: Ulid, to: Ulid, ts: i64 = 0 },
    /// Remove an `in` membership edge — the inverse of `in`, mirroring `undep`
    /// exactly (same tombstone-beats-add fold semantics, same union-merge
    /// convergence, just over `(task, arc)` instead of `(from, to)`).
    unin: struct { task: Ulid, arc: Ulid, ts: i64 = 0 },
    /// Declare/retract `id` as an arc root. Last-write-wins on fold.
    arcDeclare: struct { id: Ulid, declared: bool, ts: i64 = 0 },
    /// Mark/unmark `id` as a standing arc. See `Op.arcStanding`.
    arcStanding: struct { id: Ulid, standing: bool, ts: i64 = 0 },
    /// Freeze a task's short id. See `Op.setShort`.
    setShort: struct { id: Ulid, short: []const u8, ts: i64 = 0 },
};
