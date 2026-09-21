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
const discover = @import("discover.zig");
const mcp = @import("mcp.zig");

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

    // `trk mcp-serve` (without --help) runs the MCP server instead of one
    // command: it opens a store per call, for the tree each call names, so no
    // store is discovered or loaded here.
    if (args.items.len >= 1 and std.mem.eql(u8, args.items[0], "mcp-serve") and !wantsHelp(args.items[1..])) {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        var server = try mcp.Server.init(gpa, io, cwd, isReadOnly(init.minimal.environ, gpa));
        defer server.deinit();
        var in_buf: [64 * 1024]u8 = undefined;
        var in = std.Io.File.stdin().reader(io, &in_buf);
        var out_buf: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        server.serve(&in.interface, &out.interface) catch |e| {
            try printErr(io, gpa, "trk: mcp-serve: {s}\n", .{@errorName(e)});
            return 1;
        };
        return 0;
    }

    // Locate the store root: the nearest ancestor (cwd first, then up) that
    // holds a `.tracker/` dir — git-style, so `trk` runs from any subdirectory
    // of the repo, not just its root. Bounded at a linked git-worktree's root
    // (see discover.zig) so an agent worktree's discovery can never escape
    // into an enclosing repo's live tracker.
    const root = discover.findRoot(io, std.Io.Dir.cwd());
    const dir = root.dir;
    defer if (root.owned) dir.close(io);

    var store = tracker.Store.open(gpa, io, dir);
    defer store.deinit();
    store.load() catch |e| {
        try printErr(io, gpa, "trk: failed to load store: {s}\n", .{@errorName(e)});
        return 1;
    };
    // Everything the fold tolerated but a human should see (malformed config,
    // self-wait cycles, ghosts, withheld stale events, unknown ops) — non-fatal,
    // one warning each. See `cli.appendLoadWarnings`.
    {
        var load_warn: std.ArrayList(u8) = .empty;
        defer load_warn.deinit(gpa);
        cli.appendLoadWarnings(gpa, &store, &load_warn) catch {};
        std.Io.File.stderr().writeStreamingAll(io, load_warn.items) catch {};
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Separate stderr-bound buffer (currently: the `trk add` arc-less
    // warning) so it can never land on stdout, which stays scriptable
    // (`ID=$(trk add "x")`).
    var warn: std.ArrayList(u8) = .empty;
    defer warn.deinit(gpa);

    // `TRK_READONLY=1` (any non-empty value) refuses every mutating verb —
    // the belt-and-suspenders layer over the worktree-boundary discovery fix
    // above: the orchestrator sets this in a dispatched agent's env so a
    // mutation can't land in the live tracker regardless of which root
    // discovery resolves to.
    const read_only = isReadOnly(init.minimal.environ, gpa);

    var c = cli.Cli{
        .gpa = gpa,
        .io = io,
        .store = &store,
        .dir = dir,
        .out = &out,
        .warn = &warn,
        .read_only = read_only,
        // Only ever read when a `--body -` is actually parsed, so an ordinary
        // command never blocks waiting on a terminal that will not send EOF.
        .stdin = std.Io.File.stdin(),
    };
    defer c.prereq_scratch.deinit(gpa);

    const result = c.run(args.items);

    // Flush whatever the CLI produced. Error messages are appended to `out` by
    // the CLI itself, so a failed command still has a clean message to print.
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
    std.Io.File.stderr().writeStreamingAll(io, warn.items) catch {};

    if (result) |_| {
        return 0;
    } else |e| {
        // `trk show <compacted-id>` gets its OWN exit status (01M2M2K1J). The
        // id RESOLVED — in the tombstone index rather than the live store — and
        // its record is already in `out`, flushed above. That is neither a
        // success (a caller branching on 0 would read a graduated task as live)
        // nor a plain failure (1 is "no such id", the exact wrong verdict this
        // closes). Three answers, three statuses: 0 live, 2 compacted, 1 gone.
        if (e == error.CompactedId) return 2;
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
            error.ReadOnly,
            error.NoArc,
            error.UndeclaredArc,
            error.ClaimRequiresOpen,
            error.HolderRequired,
            error.DecisionNotWork,
            error.DecisionNotArc,
            error.LeaseHolderMismatch,
            error.GitLogFailed,
            error.CompactVerifyFailed,
            error.TombstoneIndexIncomplete,
            error.StaleRulings,
            => {},
            else => try printErr(io, gpa, "trk: error: {s}\n", .{@errorName(e)}),
        }
        return 1;
    }
}

fn wantsHelp(rest: []const []const u8) bool {
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

/// True iff `TRK_READONLY` is set in the environment to any non-empty value.
/// Cross-platform (works on Windows too) via `Environ.getAlloc`; the looked-up
/// value itself is never needed, only its presence, so it's freed immediately.
fn isReadOnly(environ: std.process.Environ, gpa: std.mem.Allocator) bool {
    const val = environ.getAlloc(gpa, "TRK_READONLY") catch return false;
    defer gpa.free(val);
    return val.len != 0;
}

/// Format + write a message to stderr. gpa-allocated (not a fixed stack
/// buffer) so a longer message — e.g. the self-wait warning, whose two
/// 26-char ULIDs alone push it past a 256-byte buffer, which is exactly the
/// bug that made `Store.self_wait_cycles` silently produce NO visible output
/// (found 2026-07-29): `std.fmt.bufPrint` returns `error.NoSpaceLeft` on
/// overflow, and a `catch return;` on a fixed buffer swallows that error,
/// eating the entire message rather than truncating or growing it. A
/// visibility mechanism that can silently fail to print is worse than no
/// mechanism — allocating avoids the size class of bug outright, and this
/// path only runs on the console-error tail, not a hot loop.
fn printErr(io: std.Io, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    std.Io.File.stderr().writeStreamingAll(io, s) catch {};
}
