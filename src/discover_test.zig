// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! Store-root discovery tests: the plain git-style walk-up, and the
//! worktree-boundary hardening (a linked worktree's `.git` FILE stops the
//! walk cold — it must never resolve into an enclosing repo's `.tracker`,
//! the 2026-07-22 incident this module exists to close). Disk-backed via
//! `std.testing.tmpDir`, matching store_test.zig's convention.

const std = @import("std");
const testing = std.testing;
const discover = @import("discover.zig");

const io = testing.io;

/// Write a small marker file through `dir` (as `findRoot` would resolve a
/// store root, before `Store` ever gets involved), then assert it landed at
/// `expected_rel_path` relative to `tmp_root` and NOWHERE else plausible —
/// pinning down exactly which directory `findRoot` actually resolved to.
fn assertResolvedTo(tmp_root: std.Io.Dir, root: discover.Root, expected_rel_path: []const u8) !void {
    try root.dir.writeFile(io, .{ .sub_path = "PROBE", .data = "x" });
    var buf: [256]u8 = undefined;
    const expected_probe = try std.fmt.bufPrint(&buf, "{s}/PROBE", .{expected_rel_path});
    try tmp_root.access(io, expected_probe, .{});
}

test "findRoot: .tracker at start itself (depth 0) is used directly, unowned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".tracker");

    const root = discover.findRoot(io, tmp.dir);
    defer if (root.owned) root.dir.close(io);

    try testing.expect(!root.owned);
    try assertResolvedTo(tmp.dir, root, ".");
}

test "findRoot: walks up several levels to find .tracker, ancestor is owned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".tracker");
    try tmp.dir.createDirPath(io, "a/b/c");
    var start = try tmp.dir.openDir(io, "a/b/c", .{});
    defer start.close(io);

    const root = discover.findRoot(io, start);
    defer if (root.owned) root.dir.close(io);

    try testing.expect(root.owned);
    try assertResolvedTo(tmp.dir, root, ".");
}

// Note: a "no .tracker and no worktree boundary ANYWHERE up to max_depth"
// case can't be tested deterministically against `testing.tmpDir` -- it roots
// under the real process cwd (this repo, `/mnt/c/dev/zig/trk`, which walking
// up would legitimately reach and find ITS OWN dev `.tracker` a few levels
// above `.zig-cache/tmp/<rand>/` -- correctly, since that's the exact
// "runs from any subdirectory of a project" behavior for a plain,
// non-worktree tree). The case below instead pins the depth-0 branch of the
// same fallback: a boundary hit with nothing there returns itself, unowned,
// rather than climbing further (whatever real ancestry sits above it).
test "findRoot: a worktree root with no .tracker of its own, queried directly, uses itself -- unowned, no climb" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /fake/main/.git/worktrees/x\n" });

    const root = discover.findRoot(io, tmp.dir);
    defer if (root.owned) root.dir.close(io);

    try testing.expect(!root.owned);
    try assertResolvedTo(tmp.dir, root, ".");
}

test "findRoot: a linked worktree's .git FILE stops the walk even without its own .tracker -- never escapes to the enclosing repo's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The "main repo": has its own live .tracker.
    try tmp.dir.createDirPath(io, ".tracker");
    // The "worktree": a `.git` FILE (the linked-worktree marker), no .tracker
    // of its own -- e.g. a stale worktree, or a `.claude/worktrees/<id>/`
    // scratch dir predating .tracker's introduction. `sub` is a deeper dir an
    // agent might actually be cd'd into.
    try tmp.dir.createDirPath(io, "worktree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "worktree/.git", .data = "gitdir: /fake/main/.git/worktrees/x\n" });
    var start = try tmp.dir.openDir(io, "worktree/sub", .{});
    defer start.close(io);

    const root = discover.findRoot(io, start);
    defer if (root.owned) root.dir.close(io);

    // Must resolve to the worktree root (isolated), never `.` (the main
    // repo's live .tracker) -- that escape is exactly the incident.
    try testing.expect(root.owned);
    try assertResolvedTo(tmp.dir, root, "worktree");
}

test "findRoot: a worktree WITH its own .tracker uses it directly, never the enclosing repo's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".tracker"); // main repo's (must be ignored)
    try tmp.dir.createDirPath(io, "worktree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "worktree/.git", .data = "gitdir: /fake/main/.git/worktrees/x\n" });
    try tmp.dir.createDirPath(io, "worktree/.tracker"); // the worktree's own, isolated copy
    var start = try tmp.dir.openDir(io, "worktree/sub", .{});
    defer start.close(io);

    const root = discover.findRoot(io, start);
    defer if (root.owned) root.dir.close(io);

    try testing.expect(root.owned);
    try assertResolvedTo(tmp.dir, root, "worktree");
}

test "findRoot: a plain (non-worktree) .git DIRECTORY is not a boundary -- walk continues past it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".tracker"); // enclosing ancestor's
    try tmp.dir.createDirPath(io, "repo/.git"); // ordinary repo root: .git is a DIRECTORY
    try tmp.dir.createDirPath(io, "repo/sub");
    var start = try tmp.dir.openDir(io, "repo/sub", .{});
    defer start.close(io);

    const root = discover.findRoot(io, start);
    defer if (root.owned) root.dir.close(io);

    // No boundary here (a plain repo root doesn't stop the walk, only a
    // linked-worktree/submodule .git FILE does) -- so it finds the ancestor
    // .tracker, same as pre-fix behavior for a non-worktree tree.
    try testing.expect(root.owned);
    try assertResolvedTo(tmp.dir, root, ".");
}
