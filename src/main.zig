// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! `trk` — the issue-tracker CLI entry point.
//!
//! Thin shell: build an `Io`, open the store rooted at cwd, parse argv (minus
//! the program name), run the CLI core (`cli.zig`), flush its accumulated output
//! to stdout, and map a `CliError` to a clean non-zero exit (no stack trace on
//! user error). All logic + the projections live in cli.zig so they're testable
//! against an in-memory buffer.

const std = @import("std");
const tracker = @import("tracker");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // argv minus the program name.
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.skip(); // program name
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }
    while (it.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));

    // Locate the store root: the nearest ancestor (cwd first, then up) that
    // holds a `.tracker/` dir — git-style, so `trk` runs from any subdirectory
    // of the repo, not just its root.
    const root = findRoot(io);
    const dir = root.dir;
    defer if (root.owned) dir.close(io);

    var store = tracker.Store.open(gpa, io, dir);
    defer store.deinit();
    store.load() catch |e| {
        try printErr(io, "trk: failed to load store: {s}\n", .{@errorName(e)});
        return 1;
    };
    // Best-effort config is non-fatal: warn but proceed on a malformed file.
    if (store.config_malformed)
        printErr(io, "trk: warning: {s}/{s} is malformed — using default config\n", .{ tracker.store.tracker_subdir, tracker.store.config_name }) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var c = cli.Cli{ .gpa = gpa, .io = io, .store = &store, .dir = dir, .out = &out };
    defer c.prereq_scratch.deinit(gpa);

    const result = c.run(args.items);

    // Flush whatever the CLI produced. Error messages are appended to `out` by
    // the CLI itself, so a failed command still has a clean message to print.
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};

    if (result) |_| {
        return 0;
    } else |e| {
        // CliError variants already emitted a clean message into `out` (flushed
        // above). For anything unexpected (OOM, write failure) emit a terse note
        // to stderr so it isn't silent.
        switch (e) {
            error.UsageError,
            error.UnknownCommand,
            error.MissingArgument,
            error.UnknownFlag,
            error.BadId,
            error.AmbiguousId,
            error.NoSuchId,
            error.BadState,
            error.BadNumber,
            error.DependencyCycle,
            => {},
            else => try printErr(io, "trk: error: {s}\n", .{@errorName(e)}),
        }
        return 1;
    }
}

/// A located store root + whether we opened it (and so must close it). cwd
/// itself is borrowed (no close); an opened ancestor must be closed.
const Root = struct { dir: std.Io.Dir, owned: bool };

/// Walk up from cwd looking for a `.tracker/` dir, like git's `.git` discovery.
/// Returns the first ancestor that has one; falls back to cwd (so a first-run
/// `trk add` still creates `.tracker/` under cwd, the prior behavior).
fn findRoot(io: std.Io) Root {
    const cwd = std.Io.Dir.cwd();
    const max_depth = 24; // a repo nests far shallower than this
    var buf: [3 * max_depth + 8]u8 = undefined;
    var depth: usize = 0;
    while (depth <= max_depth) : (depth += 1) {
        var len: usize = 0;
        for (0..depth) |_| {
            @memcpy(buf[len..][0..3], "../");
            len += 3;
        }
        @memcpy(buf[len..][0..8], ".tracker");
        const probe = buf[0 .. len + 8];
        cwd.access(io, probe, .{}) catch continue; // not here — go up one
        if (depth == 0) return .{ .dir = cwd, .owned = false };
        // The ancestor path is the "../"* prefix without the ".tracker" tail
        // and without its trailing slash (openDir wants "../.." not "../../").
        const opened = cwd.openDir(io, buf[0 .. len - 1], .{}) catch return .{ .dir = cwd, .owned = false };
        return .{ .dir = opened, .owned = true };
    }
    return .{ .dir = cwd, .owned = false };
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}
