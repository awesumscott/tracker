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

/// The op discriminator for a log event.
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
};
