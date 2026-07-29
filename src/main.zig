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
    // Best-effort config is non-fatal: warn but proceed on a malformed file.
    if (store.config_malformed)
        printErr(io, gpa, "trk: warning: {s}/{s} is malformed — using default config\n", .{ tracker.store.tracker_subdir, tracker.store.config_name }) catch {};
    // Every self-wait cycle already baked into the log (mediated by `in` arc
    // membership — see Store.load's doc comment) is likewise non-fatal: warn
    // on EACH one but keep going, since refusing to load would brick the
    // repo. Looping (not just the first) matters: a log can carry more than
    // one independent stuck pair, and reporting only one would leave every
    // other cycled task exactly as silently invisible as the bug this
    // warning exists to kill.
    for (store.self_wait_cycles.items) |p|
        printErr(
            io,
            gpa,
            "trk: warning: {s} and {s} form a self-wait cycle across needs + arc-membership edges — " ++
                "neither can ever complete while depending on the other; fix with `trk undep` or by " ++
                "re-parenting the membership (`trk in`)\n",
            .{ &p.from.text, &p.to.text },
        ) catch {};

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

    var c = cli.Cli{ .gpa = gpa, .io = io, .store = &store, .dir = dir, .out = &out, .warn = &warn, .read_only = read_only };
    defer c.prereq_scratch.deinit(gpa);

    const result = c.run(args.items);

    // Flush whatever the CLI produced. Error messages are appended to `out` by
    // the CLI itself, so a failed command still has a clean message to print.
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {};
    std.Io.File.stderr().writeStreamingAll(io, warn.items) catch {};

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
            error.ReadOnly,
            error.NoArc,
            => {},
            else => try printErr(io, gpa, "trk: error: {s}\n", .{@errorName(e)}),
        }
        return 1;
    }
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
