// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! Store-root discovery: walk up from a starting directory looking for
//! `.tracker/`, git-style — with one hard boundary plain git discovery
//! doesn't need: a **linked git worktree's root**. A linked worktree's `.git`
//! is a plain FILE (`gitdir: <path/to/main/.git/worktrees/<id>>`), never a
//! directory — that's the on-disk marker `git worktree add` leaves, readable
//! with no git binary. The walk must never continue PAST that marker into the
//! enclosing repo, even when the worktree's own `.tracker` is missing (a
//! stale worktree, one checked out from a commit predating `.tracker`, or a
//! `.claude/worktrees/<id>/` scratch dir that isn't a real git worktree at
//! all and so never gets its own `.git`/`.tracker` — that last case is the
//! one that bit us: see docs/design.md's disjoint-writer section). Left
//! unbounded, a mutation issued from inside such a directory resolves to the
//! orchestrator's LIVE `.tracker/log.jsonl`, not an isolated copy — a
//! "revert" run there stomped a concurrent write in production
//! (2026-07-22).
//!
//! A plain (non-worktree) git submodule also marks its root with a `.git`
//! FILE, so the same boundary correctly stops there too — not just the
//! worktree case this was built for.

const std = @import("std");
const Io = std.Io;

/// A located store root + whether we opened it (and so must close it). The
/// starting dir itself is borrowed (no close); an opened ancestor must be
/// closed by the caller.
pub const Root = struct { dir: Io.Dir, owned: bool };

/// Walk up from `start` looking for a `.tracker/` dir. Returns:
///   1. the first ancestor that has `.tracker` (existing git-style discovery), or
///   2. the first linked-worktree-root boundary hit (`.git` present as a
///      FILE) if `.tracker` was never found before it — so a first-run
///      `trk add` there creates an ISOLATED `.tracker`, never one in the
///      enclosing repo, or
///   3. `start` itself, if neither is found within `max_depth` (the prior
///      fallback: a first-run `trk add` outside any worktree/repo still
///      creates `.tracker` under `start`).
pub fn findRoot(io: Io, start: Io.Dir) Root {
    const max_depth = 24; // a repo nests far shallower than this
    var buf: [3 * max_depth + 8]u8 = undefined;
    var depth: usize = 0;
    while (depth <= max_depth) : (depth += 1) {
        var len: usize = 0;
        for (0..depth) |_| {
            @memcpy(buf[len..][0..3], "../");
            len += 3;
        }
        const prefix_len = len;

        @memcpy(buf[len..][0..8], ".tracker");
        const tracker_probe = buf[0 .. len + 8];
        found: {
            start.access(io, tracker_probe, .{}) catch break :found; // not here — check the worktree boundary, then go up
            if (depth == 0) return .{ .dir = start, .owned = false };
            const opened = start.openDir(io, buf[0 .. prefix_len - 1], .{}) catch return .{ .dir = start, .owned = false };
            return .{ .dir = opened, .owned = true };
        }

        // No `.tracker` at this level. If this level IS a linked worktree
        // root (`.git` present and a plain FILE, not a directory), this is a
        // hard boundary: stop here, never walk past it into the enclosing
        // repo — even though it has no `.tracker` of its own yet.
        @memcpy(buf[prefix_len..][0..4], ".git");
        const git_probe = buf[0 .. prefix_len + 4];
        const git_stat = start.statFile(io, git_probe, .{ .follow_symlinks = false }) catch null;
        if (git_stat) |st| {
            if (st.kind == .file) {
                if (depth == 0) return .{ .dir = start, .owned = false };
                const opened = start.openDir(io, buf[0 .. prefix_len - 1], .{}) catch return .{ .dir = start, .owned = false };
                return .{ .dir = opened, .owned = true };
            }
        }
    }
    return .{ .dir = start, .owned = false };
}
