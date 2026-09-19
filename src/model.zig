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
    /// A LEASE: "this task is taken — someone is working it." Written when work
    /// is handed out, so a second writer (another lane, another session) is not
    /// offered it. Not a completion claim of any kind:
    /// - does NOT satisfy a `needs` edge — the work is not done.
    /// - is NOT `next`-eligible — handing a leased task out again is the
    ///   double-work the lease exists to prevent.
    /// - counts as remaining in `trk render` (marker `[c]`), and a leased member
    ///   keeps its arc undrained.
    /// Only an `open` task can be claimed, and only by a named holder
    /// (`claimRefusal` and the holder check, enforced by `Store.append`). Those
    /// refusals are both the mutual exclusion (a second claim on a held task
    /// fails) and the fail-loud for the pre-rename habit of writing `claimed`
    /// to mean completion, which is now `submitted` — the habit never names a
    /// holder. The fold mirrors the rule: a lease that reaches a non-open task
    /// (a merge delivering it after a submission) is a no-op.
    /// Release is the `release` op (conditional on this holder still holding
    /// it) or a plain `setState open`; completion is `claimed -> submitted|done`.
    ///
    /// WIRE TOKEN IS `leased`, NOT `claimed` (see `json_codec.stateToWire`). Every
    /// `"state":"claimed"` ever serialized means `submitted` — written by the
    /// pre-rename binary — and a long-lived branch can union-merge more of them
    /// in at any time, so that token is permanently the legacy spelling of
    /// `submitted` and is never written again.
    claimed,
    /// A SUBMISSION, not a verdict: "the commit I'm riding completes this task,
    /// pending verification." (Named `claimed` before the lease existed.) Exists
    /// so a task close can ride the implementing commit even for GATED work,
    /// where a compile-only builder cannot know whether the boot gate passed and
    /// so is barred from ever asserting `done` (`done` means "passed its gate").
    /// Deliberately weaker than `done` in both directions:
    /// - does NOT satisfy a `needs` edge (`satisfiesPrereq` is false) — a
    ///   dependent must wait for the real, verified `done`, not an unverified
    ///   submission.
    /// - does NOT appear in `next`'s ready frontier (`isEligible` is false) — it
    ///   is not available work, so surfacing it there would let a second builder
    ///   pick it up and redo already-submitted work.
    /// It DOES count as remaining/not-yet-built for `trk render`'s TODO.md
    /// projection (`isRemaining` in cli.zig), with its own marker (`[s]`) — a
    /// short, explicit "awaiting verification" queue a human or a hook can scan
    /// (`trk list --state submitted`), rather than silently blending into
    /// ordinary open work. The orchestrator's post-gate reconcile promotes it to
    /// `done` (gate passed) or demotes it back to `open` with a note (gate
    /// failed) — the "orchestrator alone verifies" rule is unchanged; only what
    /// a builder agent may itself write changes.
    submitted,

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

    /// The CLI/JSON-output spelling. NOT the on-disk token for every state —
    /// see `json_codec.stateFromWire`.
    pub fn fromString(s: []const u8) ?State {
        return std.meta.stringToEnum(State, s);
    }

    /// Why `from -> claimed` must be refused, or null when the lease may be
    /// taken. Only `open` work can be leased. Pure policy for the write path
    /// (`Store.append`); the fold itself accepts any transition, because a
    /// union merge can deliver any sequence.
    pub fn claimRefusal(from: State) ?ClaimRefusal {
        return switch (from) {
            .open => null,
            .claimed => .already_claimed,
            .submitted => .already_submitted,
            .done, .archived, .dropped => .finished,
            .blocked => .blocked,
        };
    }

    pub const ClaimRefusal = enum { already_claimed, already_submitted, finished, blocked };
};

/// The rank an UNSET priority carries in every ordering. Stored `0` is the
/// "never set" sentinel — `Store.compact` already declines to emit it — so it
/// must not also be the STRONGEST value, which is what silently buried every
/// task a user tried to raise (`--priority 10` sorting below 257 untouched
/// zeroes; task 01KZD94QX). Ranking substitutes this value instead, which needs
/// no migration: stored data is untouched and an explicit priority now moves a
/// task in the direction the sign says, both ways.
pub const default_priority: i32 = 100;

/// Priority as ORDERING sees it. Display and JSON keep the stored value.
pub fn effectivePriority(stored: i32) i32 {
    return if (stored == 0) default_priority else stored;
}

/// A doc-ref: indirect `doc_id` (through a future id->path registry) plus an
/// optional stable `section_id` anchor for a focused read.
pub const DocRef = struct {
    doc_id: []const u8,
    section_id: ?[]const u8 = null,
};

/// An in-memory task node. Strings/lists are owned by the Store's arena.
pub const Task = struct {
    id: Ulid,
    /// The `ts` of the newest event folded into this task. Feeds `compact`'s
    /// per-task watermark (`Event.add.wm`). Not persisted directly.
    last_ts: i64 = 0,
    /// The watermark this task arrived with from the snapshot (`Event.add.wm`),
    /// or `0` when there was none. See that field.
    watermark: i64 = 0,
    /// False = this node was materialized by `Store.ensureNode` from an event
    /// that merely REFERENCES the id (a `dep`/`in`/`setBody`/...), and no `add`
    /// for it was ever folded. Mid-replay that is normal — a union-merged log
    /// legitimately interleaves an edge ahead of its `add`. Still false AFTER
    /// the whole fold, it is a GHOST: the add is gone (compacted away, then the
    /// surviving events union-merged back in) and the node's title/tags/arcs are
    /// silently lost while a body survives. `load` collects these into
    /// `Store.ghost_tasks`; see task 01M0EJGYH.
    has_add: bool = false,
    title: []const u8 = "",
    body: []const u8 = "",
    state: State = .open,
    /// Who holds the lease, and since when (the claiming event's `ts`). Set only
    /// while `state == .claimed`; every other state clears both.
    holder: ?[]const u8 = null,
    lease_ts: i64 = 0,
    /// Global rank, lower first. Stored `0` means UNSET, not "strongest" —
    /// ordering substitutes `default_priority` for it (see `effectivePriority`).
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

/// `task` raised `decision` — provenance, carrying no dependency. See
/// `Op.raises`. No `seq`: there is no ordering among a task's forks.
pub const Raises = struct {
    task: Ulid,
    decision: Ulid,
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
    /// Remove a docref from a task (idempotent: no-op if the ref is absent) —
    /// the inverse of `docref`, mirroring `untag` exactly. Matching is by
    /// `doc_id` alone: a task's refs to the same doc differ only by section,
    /// and the removal verb takes the doc id the caller typed, so one
    /// `undocref` clears every section ref to that doc. Safe for an older
    /// binary to miss (it would show a stale, already-cosmetic ref), so it
    /// needs no `breaking` marker — see `json_codec.zig`.
    undocref,
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
    /// Release a lease: `claimed -> open`, applied on fold ONLY if the task is
    /// still `claimed` by exactly `holder`. The condition is what makes it safe
    /// under ts-ordered replay: a lane's `submitted` written before the release
    /// but merged after it sorts first, so the release finds a submitted task
    /// and does nothing — a plain `setState open` would win and silently drop
    /// the submission. Likewise a stale release can never undo a newer lease
    /// taken by someone else. Safe for an older binary to skip (it cannot load
    /// the `leased` state this op acts on anyway).
    release,
    /// Declare (or retract) `id` as a DECISION: a fork that only the repo owner
    /// can rule on. Last-write-wins on fold, the exact commutation shape as
    /// `arcDeclare`, and for the same reason: it is a single-task boolean about
    /// the task's NATURE, not its lifecycle.
    ///
    /// Nature, not lifecycle, is the whole point (design.md "Decisions"). An arc
    /// stays an arc once it is done; a decision stays a decision once it is
    /// ruled. `trk rule` resolves one by setting `done` — it must NEVER clear
    /// this flag, or the ruled question becomes an ordinary open task and
    /// surfaces in `next` as work to go build.
    ///
    /// This replaces a TAG convention (`#scott-decision`) plus a body-text grep
    /// in `archive`. Both were archaeology: a fork had no representation in the
    /// model, so intent was destroyed at authoring time and every downstream
    /// mechanism was left guessing at it from prose.
    ///
    /// Safe for an older binary to skip, with a recorded caveat: it would see
    /// the task as ordinary and surface it in `next`. A wasted dispatch the
    /// agent corrects on reading the body; bricking every read would be worse.
    decisionDeclare,
    /// `task` raised `decision` — pure PROVENANCE, carrying no dependency and
    /// no scheduling effect. Whether the decision also BLOCKS that task is a
    /// separate, ordinary `dep` edge, because "raised by" and "blocks" are
    /// genuinely different facts: a fork noticed while doing T usually does not
    /// stop T.
    ///
    /// Many-to-many in both directions: several tasks legitimately hit the same
    /// fork, and one task raises several.
    ///
    /// An EDGE rather than prose in the raiser's body, because a body is a
    /// `setBody` last-write-wins scalar — recording it there is a read-modify-
    /// write on a task other lanes may be appending to, and two concurrent
    /// appends lose one. An edge is additive and commutes.
    ///
    /// EXCLUDED from the combined acyclic graph (`Store.combinedReaches`,
    /// `checkAcyclic`): it encodes no waiting, so it cannot close a self-wait,
    /// and walking it would reject the ordinary shape where T both raised D and
    /// needs D.
    raises,
    /// Remove a `raises` edge — the inverse of `raises`, mirroring `undep`/
    /// `unin` exactly: a fold-time tombstone that beats its add regardless of
    /// append order, so a mis-attributed origin is correctable rather than only
    /// overwritable. An EDGE needs a tombstone map (rather than `untag`'s plain
    /// list removal) because it is authorable from either endpoint and so can
    /// genuinely be raced.
    unraises,
};

/// One log event — a tagged union over the op kinds. Fields mirror the JSON
/// schema in store.zig (one JSON object per line, `"op"` discriminator).
/// The append-time `ts` of any event, without a per-op switch at every call
/// site. `0` = unknown (a legacy line written before `ts` existed, or a
/// hand-authored one) — those sort FIRST on replay, which is right for the
/// legacy case they come from. See `Store.replayFile`.
pub fn eventTs(ev: Event) i64 {
    return switch (ev) {
        inline else => |x| x.ts,
    };
}

/// Every TASK id an event references: one for a scalar/tag/docref op, two for
/// an edge (`dep`/`undep`/`in`/`unin`), none for `setDocPath` (it names a doc,
/// not a task). Unused slots are `null`. Distinct from `eventTs`'s `inline
/// else` shape because the field NAMES differ per op — the point of the helper
/// is to keep that per-op knowledge in one place. Used by `Store.compact` to
/// decide which raw log lines belong to a ghost id.
pub fn eventTaskIds(ev: Event) [2]?Ulid {
    return switch (ev) {
        .add => |x| .{ x.id, null },
        .setState => |x| .{ x.id, null },
        .setPriority => |x| .{ x.id, null },
        .setTitle => |x| .{ x.id, null },
        .setBody => |x| .{ x.id, null },
        .setShort => |x| .{ x.id, null },
        .tag => |x| .{ x.id, null },
        .untag => |x| .{ x.id, null },
        .docref => |x| .{ x.id, null },
        .undocref => |x| .{ x.id, null },
        .arcDeclare => |x| .{ x.id, null },
        .arcStanding => |x| .{ x.id, null },
        .release => |x| .{ x.id, null },
        .decisionDeclare => |x| .{ x.id, null },
        .dep => |x| .{ x.from, x.to },
        .undep => |x| .{ x.from, x.to },
        .in => |x| .{ x.task, x.arc },
        .unin => |x| .{ x.task, x.arc },
        // Both endpoints, like every other edge: this is what lets
        // `quarantineGhosts` and `tombstones --rebuild`'s history scan see the
        // edge at all.
        .raises => |x| .{ x.task, x.decision },
        .unraises => |x| .{ x.task, x.decision },
        .setDocPath => .{ null, null },
    };
}

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
        /// SNAPSHOT ONLY: this task's watermark — the `ts` of the newest event
        /// `compact` had folded into the state it is writing out. Replay skips
        /// any later-merged log event for this task whose `ts` predates it: such
        /// an event is provably older than the snapshot's own value, so applying
        /// it would revert the task (task 01M0EM3G6). `0` = unknown (a legacy
        /// snapshot, or a task whose events all predate `ts`), which disables
        /// the check for that task. Never written by `append` — only by
        /// `serializeState`, as an extra JSON key an older binary simply
        /// ignores, so the format stays backward AND forward compatible.
        wm: i64 = 0,
    },
    /// `holder` is required for (and only written with) `state == .claimed`.
    setState: struct { id: Ulid, state: State, holder: ?[]const u8 = null, ts: i64 = 0 },
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
    /// Remove a docref from a task — the inverse of `docref`. No-op if the
    /// task carries no ref to `doc_id`. Mirrors `untag`'s fold shape (a plain
    /// list removal, no tombstone map): a docref is a per-TASK attribute, and
    /// under the disjoint-writer rule two lanes never edit the same task, so
    /// the only ordering that matters is a single lane's own append order —
    /// which a union merge preserves within each side. Contrast `undep`/`unin`,
    /// which DO need tombstone maps because an EDGE is authored from either
    /// endpoint and so genuinely can be raced.
    undocref: struct { id: Ulid, doc_id: []const u8, ts: i64 = 0 },
    /// Declare/retract `id` as an arc root. Last-write-wins on fold.
    arcDeclare: struct { id: Ulid, declared: bool, ts: i64 = 0 },
    /// Mark/unmark `id` as a standing arc. See `Op.arcStanding`.
    arcStanding: struct { id: Ulid, standing: bool, ts: i64 = 0 },
    /// Freeze a task's short id. See `Op.setShort`.
    setShort: struct { id: Ulid, short: []const u8, ts: i64 = 0 },
    /// Release `holder`'s lease on `id`. See `Op.release`.
    release: struct { id: Ulid, holder: []const u8, ts: i64 = 0 },
    /// Declare/retract `id` as a decision. Last-write-wins on fold. See
    /// `Op.decisionDeclare` — declaration is NATURE, never cleared by ruling.
    decisionDeclare: struct { id: Ulid, declared: bool, ts: i64 = 0 },
    /// `task` raised `decision`. Provenance only. See `Op.raises`.
    raises: struct { task: Ulid, decision: Ulid, ts: i64 = 0 },
    /// Remove a `raises` edge. See `Op.unraises`.
    unraises: struct { task: Ulid, decision: Ulid, ts: i64 = 0 },
};
