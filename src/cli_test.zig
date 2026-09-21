// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! CLI + projection tests. Drive the `Cli` against a tmpDir-backed Store and
//! assert against the accumulated output buffer (no real stdout/TTY). Covers:
//! arg parsing (add with --in/--needs/--tag), prefix resolution (unique /
//! ambiguous / shortId), the `render` markdown projection (invariants +
//! determinism), and `tree` DAG cycle-safety (diamond prints D once + once as
//! seen, never loops).

const std = @import("std");
const testing = std.testing;
const tracker = @import("tracker");
const cli = @import("cli.zig");

const Store = tracker.Store;
const Ulid = tracker.Ulid;
const ulid = tracker.ulid;
const io = testing.io;

// Deterministic, time-ordered id minting for the fixtures.
var mint_ms: u48 = 2_000_000;
fn mintId() Ulid {
    mint_ms += 1;
    return ulid.mintAt(io, mint_ms);
}

/// Build a Cli over a fresh tmpDir store. Caller deinits via `Fixture.deinit`.
const Fixture = struct {
    tmp: testing.TmpDir,
    store: *Store,
    out: *std.ArrayList(u8),
    /// The separate stderr-bound buffer (arc-less `add` warnings). Cleared by
    /// `run`/`runExpectErr` just like `out` so each test call starts fresh.
    warn: *std.ArrayList(u8),
    c: *cli.Cli,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !Fixture {
        const tmp = testing.tmpDir(.{});
        const store = try alloc.create(Store);
        store.* = Store.open(alloc, io, tmp.dir);
        try store.load();
        const out = try alloc.create(std.ArrayList(u8));
        out.* = .empty;
        const warn = try alloc.create(std.ArrayList(u8));
        warn.* = .empty;
        const c = try alloc.create(cli.Cli);
        c.* = .{ .gpa = alloc, .io = io, .store = store, .dir = tmp.dir, .out = out, .warn = warn };
        return .{ .tmp = tmp, .store = store, .out = out, .warn = warn, .c = c, .alloc = alloc };
    }

    fn run(self: *Fixture, args: []const []const u8) !void {
        self.out.clearRetainingCapacity();
        self.warn.clearRetainingCapacity();
        try self.c.run(args);
    }

    /// Run expecting a CliError; returns the error so the test can match it.
    fn runExpectErr(self: *Fixture, args: []const []const u8) anyerror {
        self.out.clearRetainingCapacity();
        self.warn.clearRetainingCapacity();
        if (self.c.run(args)) |_| return error.TestUnexpectedSuccess else |e| return e;
    }

    /// Drop the in-memory fold and re-read the store from disk — what the NEXT
    /// `trk` invocation sees. Needed after `compact`, whose GC is a property of
    /// the files it wrote and NOT of the process that wrote them: the compacting
    /// process still holds every task it just removed, so asserting against it
    /// would prove nothing about what a reader finds. `self.c.store` keeps
    /// pointing at the same heap slot, so the Cli follows.
    fn reopen(self: *Fixture) !void {
        self.store.deinit();
        self.store.* = Store.open(self.alloc, io, self.tmp.dir);
        try self.store.load();
    }

    fn deinit(self: *Fixture) void {
        self.c.prereq_scratch.deinit(self.alloc);
        self.alloc.destroy(self.c);
        self.out.deinit(self.alloc);
        self.alloc.destroy(self.out);
        self.warn.deinit(self.alloc);
        self.alloc.destroy(self.warn);
        self.store.deinit();
        self.alloc.destroy(self.store);
        self.tmp.cleanup();
    }
};

// ----------------------------------------------------------- arg parsing

test "add with --tag/--in/--needs produces the right event sequence" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Seed an arc and a prereq directly (full ids).
    const arc = mintId();
    const pre = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc root" } });
    try f.store.append(.{ .add = .{ .id = pre, .title = "Prereq" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });

    // `trk add "New task" --tag wm --tag metal --in <arc> --seq 3 --needs <pre> --priority -5`
    try f.run(&.{ "add", "New task", "--tag", "wm", "--tag", "metal", "--in", &arc.text, "--seq", "3", "--needs", &pre.text, "--priority", "-5" });

    // The store should now have 3 tasks; find the new one (not arc/pre).
    try testing.expectEqual(@as(usize, 3), f.store.count());
    const ids = try f.store.allIds(alloc);
    defer alloc.free(ids);
    var new_id: ?Ulid = null;
    for (ids) |id| {
        if (!id.eql(arc) and !id.eql(pre)) new_id = id;
    }
    const nid = new_id.?;
    const t = f.store.get(nid).?;
    try testing.expectEqualStrings("New task", t.title);
    try testing.expectEqual(@as(i32, -5), t.priority);
    try testing.expectEqual(@as(usize, 2), t.tags.items.len);
    try testing.expectEqualStrings("wm", t.tags.items[0]);
    try testing.expectEqualStrings("metal", t.tags.items[1]);

    // The `in` edge with seq 3 exists.
    var found_in = false;
    for (f.store.ins.items) |e| {
        if (e.task.eql(nid) and e.arc.eql(arc)) {
            try testing.expectEqual(@as(i32, 3), e.seq);
            found_in = true;
        }
    }
    try testing.expect(found_in);

    // The `needs` edge new->pre exists.
    var found_dep = false;
    for (f.store.needs.items) |e| {
        if (e.from.eql(nid) and e.to.eql(pre)) found_dep = true;
    }
    try testing.expect(found_dep);

    // Quiet by default: output is exactly the new task's full ULID (+ newline),
    // scriptable with no parsing.
    try testing.expect(std.mem.indexOf(u8, f.out.items, &nid.text) != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "added ") == null);
}

test "add default prints ONLY the full ULID; -v prints the friendly form" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Default: bare 26-char ULID + newline, nothing else (ID=$(trk add ...)).
    try f.run(&.{ "add", "Quiet task" });
    try testing.expectEqual(@as(usize, ulid.len + 1), f.out.items.len);
    try testing.expectEqual(@as(u8, '\n'), f.out.items[ulid.len]);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "added ") == null);
    const nid = try ulid.parse(f.out.items[0..ulid.len]); // parses => a valid ULID
    try testing.expect(f.store.get(nid) != null);

    // -v: the human form.
    try f.run(&.{ "add", "Loud task", "-v" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "added ") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "  (") != null); // short (full)
}

test "add with a bad --needs id fails cleanly and adds nothing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const e = f.runExpectErr(&.{ "add", "T", "--needs", "ZZZZZZ" });
    try testing.expectEqual(cli.CliError.NoSuchId, e);
    try testing.expectEqual(@as(usize, 0), f.store.count()); // nothing minted
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no task matches prefix") != null);
}

test "unknown command and unknown flag error cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try testing.expectEqual(cli.CliError.UnknownCommand, f.runExpectErr(&.{"frobnicate"}));
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "add", "T", "--nope" }));
}

test "state rejects a bad state name cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    const e = f.runExpectErr(&.{ "state", &a.text, "frozen" });
    try testing.expectEqual(cli.CliError.BadState, e);
}

test "state submitted: settable, marked distinctly in list/render, absent from next" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "builder self-report" } });

    try f.run(&.{ "state", &a.text, "submitted" });
    try testing.expectEqual(tracker.State.submitted, f.store.get(a).?.state);

    // list: the marker distinguishes it from plain open, and it's the
    // default-visible bucket (no --state needed, unlike archived).
    try f.run(&.{"list"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[s] ") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "builder self-report") != null);

    // The explicit awaiting-verification queue.
    try f.run(&.{ "list", "--state", "submitted" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "builder self-report") != null);
    try f.run(&.{ "list", "--state", "claimed" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "builder self-report") == null);

    // render: still in TODO.md (isRemaining), with the same distinct marker.
    try f.run(&.{"render"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[s]") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "builder self-report") != null);

    // next: NOT offered as available work — the frontier stays exactly
    // "genuinely ready", not inflated with an unverified submission.
    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "builder self-report") == null);
}

test "state claimed: the lease hides a task from next, shows its holder, and release returns it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "handed out" } });

    try f.run(&.{ "state", &a.text, "claimed", "--holder", "lane-3" });
    try testing.expectEqual(tracker.State.claimed, f.store.get(a).?.state);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "held by lane-3") != null);

    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "handed out") == null);
    try f.run(&.{ "list", "--state", "claimed" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[c] ") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "(held by lane-3 since ") != null);
    try f.run(&.{ "show", &a.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "holder:   lane-3") != null);
    try f.run(&.{"render"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[c]") != null);
    try f.run(&.{ "list", "--json", "--state", "claimed" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"state\":\"claimed\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"holder\":\"lane-3\",\"lease_ts\":") != null);

    try f.run(&.{ "release", &a.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "released from lane-3") != null);
    try testing.expectEqual(tracker.State.open, f.store.get(a).?.state);
    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "handed out") != null);

    // Releasing again is a reported no-op, not an error.
    try f.run(&.{ "release", &a.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "not claimed") != null);
}

test "state claimed: --holder is required (the hint names `submitted`) and only valid for claimed" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "t" } });

    try testing.expectEqual(cli.CliError.HolderRequired, f.runExpectErr(&.{ "state", &a.text, "claimed" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--holder") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "submitted") != null);
    try testing.expectEqual(tracker.State.open, f.store.get(a).?.state);

    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "state", &a.text, "done", "--holder", "x" }));
    try testing.expectEqual(tracker.State.open, f.store.get(a).?.state);
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "state", &a.text, "claimed", "extra", "--holder", "x" }));
}

test "state claimed: refused on any non-open task, with a hint naming `submitted`" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // claimed -> claimed: the lease is held (and the old completion habit).
    const held = mintId();
    try f.store.append(.{ .add = .{ .id = held, .title = "held" } });
    try f.run(&.{ "state", &held.text, "claimed", "--holder", "lane-1" });
    try testing.expectEqual(cli.CliError.ClaimRequiresOpen, f.runExpectErr(&.{ "state", &held.text, "claimed", "--holder", "lane-2" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "already claimed by lane-1") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "submitted") != null);
    try testing.expectEqualStrings("lane-1", f.store.get(held).?.holder.?);

    // submitted -> claimed: would silently pull it out of the verification queue.
    const sub = mintId();
    try f.store.append(.{ .add = .{ .id = sub, .title = "sub" } });
    try f.store.append(.{ .setState = .{ .id = sub, .state = .submitted } });
    try testing.expectEqual(cli.CliError.ClaimRequiresOpen, f.runExpectErr(&.{ "state", &sub.text, "claimed", "--holder", "lane-2" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "already submitted") != null);
    try testing.expectEqual(tracker.State.submitted, f.store.get(sub).?.state);

    // done/blocked -> claimed: only open work can be leased.
    for ([_]tracker.State{ .done, .blocked }) |st| {
        const id = mintId();
        try f.store.append(.{ .add = .{ .id = id, .title = "x" } });
        try f.store.append(.{ .setState = .{ .id = id, .state = st } });
        try testing.expectEqual(cli.CliError.ClaimRequiresOpen, f.runExpectErr(&.{ "state", &id.text, "claimed", "--holder", "lane-2" }));
        try testing.expect(std.mem.indexOf(u8, f.out.items, "only an open task can be claimed") != null);
        try testing.expect(std.mem.indexOf(u8, f.out.items, "submitted") != null);
        try testing.expectEqual(st, f.store.get(id).?.state);
    }
}

test "release --holder releases exactly that holder's leases; a mismatched holder is refused" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    const d = mintId();
    for ([_]tracker.Ulid{ a, b, c, d }) |id| try f.store.append(.{ .add = .{ .id = id, .title = "t" } });
    try f.run(&.{ "state", &a.text, "claimed", "--holder", "lane-1" });
    try f.run(&.{ "state", &b.text, "claimed", "--holder", "lane-1" });
    try f.run(&.{ "state", &c.text, "claimed", "--holder", "lane-2" });
    try f.run(&.{ "state", &d.text, "claimed", "--holder", "lane-1" });
    try f.run(&.{ "state", &d.text, "submitted" });

    try testing.expectEqual(cli.CliError.LeaseHolderMismatch, f.runExpectErr(&.{ "release", &c.text, "--holder", "lane-1" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "held by lane-2, not lane-1") != null);
    try testing.expectEqual(tracker.State.claimed, f.store.get(c).?.state);

    try f.run(&.{ "release", "--holder", "lane-1" });
    try testing.expectEqual(tracker.State.open, f.store.get(a).?.state);
    try testing.expectEqual(tracker.State.open, f.store.get(b).?.state);
    try testing.expectEqual(tracker.State.claimed, f.store.get(c).?.state);
    try testing.expectEqual(tracker.State.submitted, f.store.get(d).?.state);

    try f.run(&.{ "release", "--holder", "lane-1" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing claimed by lane-1") != null);

    try f.run(&.{ "release", &c.text, "--holder", "lane-2" });
    try testing.expectEqual(tracker.State.open, f.store.get(c).?.state);

    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{"release"}));
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "release", &a.text, &b.text }));
}

// ----------------------------------------------------------- TRK_READONLY gate

test "read_only refuses every mutating verb cleanly and mutates nothing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    const before = f.store.count();
    f.c.read_only = true;

    const cases = [_][]const []const u8{
        &.{ "init", "--force" },
        &.{ "add", "T" },
        &.{ "dep", &a.text, "--needs", &a.text },
        &.{ "undep", &a.text, "--needs", &a.text },
        &.{ "in", &a.text, &a.text },
        &.{ "unin", &a.text, &a.text },
        &.{ "arc", &a.text },
        &.{"migrate-arcs"},
        &.{"migrate-shorts"},
        &.{ "state", &a.text, "done" },
        &.{"render"},
        &.{"compact"},
        &.{"archive"},
        &.{ "edit", &a.text, "--title", "X" },
        &.{ "doc", "set", "d1", "path.md" },
        &.{ "doc", "unset", "d1" },
    };
    for (cases) |args| {
        const e = f.runExpectErr(args);
        try testing.expectEqual(cli.CliError.ReadOnly, e);
        try testing.expect(std.mem.indexOf(u8, f.out.items, "TRK_READONLY") != null);
    }
    try testing.expectEqual(before, f.store.count());
    try testing.expectEqualStrings("A", f.store.get(a).?.title); // untouched by the "edit" attempt
}

test "read_only does not block read verbs, --help, or doc list/resolve" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    f.c.read_only = true;

    try f.run(&.{"next"});
    try f.run(&.{"list"});
    try f.run(&.{ "show", &a.text });
    try f.run(&.{ "tree", &a.text });
    try f.run(&.{"log"});
    try f.run(&.{ "doc", "list" });
    // Unregistered -> the normal NoSuchId error, NOT ReadOnly: proves the gate
    // let it through to cmdDocResolve rather than blocking it.
    try testing.expectEqual(cli.CliError.NoSuchId, f.runExpectErr(&.{ "doc", "resolve", "d1" }));
    try f.run(&.{ "add", "--help" }); // help routes BEFORE the read_only gate
    try testing.expect(std.mem.indexOf(u8, f.out.items, "trk add") != null);
}

// ----------------------------------------------------------- prefix resolution

test "prefix resolution: an EXACT frozen short resolves even when longer shorts extend it (01M2Y2JV5)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The measured shape: one task froze a 9-char short, and three later
    // mints froze 10-char shorts extending it.
    const a = try ulid.parse("0123456789ABCDEFGHJKMNPQRS");
    const b = try ulid.parse("0123456789BBCDEFGHJKMNPQRS");
    const c = try ulid.parse("0123456789CBCDEFGHJKMNPQRS");
    const g = try ulid.parse("01234567ZZZZCDEFGHJKMNPQRS");
    try f.store.append(.{ .add = .{ .id = a, .title = "Exact", .short = "012345678" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "LongerB", .short = "0123456789B" } });
    try f.store.append(.{ .add = .{ .id = c, .title = "LongerC", .short = "0123456789C" } });
    // A task whose frozen short is exact but whose id the prefix would ALSO
    // match: the exact tier alone must pick it.
    try f.store.append(.{ .add = .{ .id = g, .title = "Other", .short = "01234567Z" } });

    // POSITIVE: the printed short resolves to the task that printed it — in
    // either case, since prefixes are case-insensitive too.
    try f.run(&.{ "state", "012345678", "done" });
    try testing.expectEqual(tracker.State.done, f.store.get(a).?.state);
    try testing.expectEqual(tracker.State.open, f.store.get(b).?.state);
    try f.run(&.{ "state", "0123456789b", "blocked" });
    try testing.expectEqual(tracker.State.blocked, f.store.get(b).?.state);

    // NEGATIVE: prefix extension is untouched — a prefix that is nobody's
    // frozen short is still ambiguous, and still lists every candidate.
    const e = f.runExpectErr(&.{ "state", "0123456", "done" });
    try testing.expectEqual(cli.CliError.AmbiguousId, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Exact") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "LongerC") != null);

    // NEGATIVE: two tasks freezing the SAME short (parallel mints) stay
    // ambiguous — the exact tier never picks one arbitrarily.
    const d = try ulid.parse("0123456789CCCDEFGHJKMNPQRS");
    try f.store.append(.{ .add = .{ .id = d, .title = "TwinC", .short = "0123456789C" } });
    try testing.expectEqual(cli.CliError.AmbiguousId, f.runExpectErr(&.{ "state", "0123456789C", "done" }));
}

test "prefix resolution: a COMPACTED task's exact short names the tombstone, not a live task extending it (01M2Y2JV5)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gone = try ulid.parse("0123456789ABCDEFGHJKMNPQRS");
    const live = try ulid.parse("0123456789BBCDEFGHJKMNPQRS");
    try f.store.append(.{ .add = .{ .id = gone, .title = "graduated work", .short = "012345678" } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });
    try f.run(&.{"compact"});
    try f.reopen();
    try f.store.append(.{ .add = .{ .id = live, .title = "later mint", .short = "0123456789B" } });

    // Before the tier, the unique live prefix match silently answered with
    // `live` — a different task than the one the short was printed for.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", "012345678" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "graduated work") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "later mint") == null);
    // A write through it refuses rather than landing on `live`.
    try testing.expectEqual(cli.CliError.NoSuchId, f.runExpectErr(&.{ "state", "012345678", "done" }));
    try testing.expectEqual(tracker.State.open, f.store.get(live).?.state);
    // The live task's own short still resolves.
    try f.run(&.{ "state", "0123456789B", "done" });
    try testing.expectEqual(tracker.State.done, f.store.get(live).?.state);

    // Same tier inside the tombstone index: a second compacted task whose
    // short extends the first must not make the first's short ambiguous.
    const gone2 = try ulid.parse("0123456789CBCDEFGHJKMNPQRS");
    try f.store.append(.{ .add = .{ .id = gone2, .title = "second graduate", .short = "0123456789C" } });
    try f.store.append(.{ .setState = .{ .id = gone2, .state = .archived } });
    try f.run(&.{"compact"});
    try f.reopen();
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", "012345678" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "graduated work") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "second graduate") == null);
}

test "prefix resolution: unique resolves, ambiguous errors with candidates" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Two ids sharing a long common prefix so a short prefix is ambiguous.
    // mintAt with same ms differs only in the random tail; but the random tail
    // is the *low* bits, so the top chars (timestamp) collide. Construct two
    // ids that share the first 10 chars by parsing crafted text.
    var ta: [ulid.len]u8 = ("0123456789ABCDEFGHJKMNPQRS").*;
    var tb: [ulid.len]u8 = ("0123456789ABCDEFGHJKMNPQRT").*; // differs at last char
    const a = try ulid.parse(&ta);
    const b = try ulid.parse(&tb);
    try f.store.append(.{ .add = .{ .id = a, .title = "Alpha" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "Beta" } });
    _ = &ta;
    _ = &tb;

    // A short shared prefix is ambiguous.
    const e = f.runExpectErr(&.{ "state", "012345", "done" });
    try testing.expectEqual(cli.CliError.AmbiguousId, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "ambiguous") != null);
    // Both candidate titles listed.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Alpha") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Beta") != null);

    // The full id of `a` resolves uniquely.
    try f.run(&.{ "state", &a.text, "done" });
    try testing.expectEqual(tracker.State.done, f.store.get(a).?.state);

    // A prefix that uniquely picks b (the differing last chars) resolves.
    try f.run(&.{ "state", "0123456789ABCDEFGHJKMNPQRT", "blocked" });
    try testing.expectEqual(tracker.State.blocked, f.store.get(b).?.state);
}

test "no-match prefix errors cleanly on empty and single-task stores" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    // Empty store.
    try testing.expectEqual(cli.CliError.NoSuchId, f.runExpectErr(&.{ "state", "ABCDEF", "done" }));
    // Single task: a non-matching prefix still errors clean.
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Only" } });
    try testing.expectEqual(cli.CliError.NoSuchId, f.runExpectErr(&.{ "state", "ZZZZZZ", "done" }));
    // shortId on a single-task store returns the min-length prefix and resolves.
    var sbuf: [ulid.len]u8 = undefined;
    const sid = try f.c.shortId(a, &sbuf);
    try testing.expectEqual(@as(usize, cli.min_short), sid.len);
    try f.run(&.{ "state", sid, "done" });
    try testing.expectEqual(tracker.State.done, f.store.get(a).?.state);
}

test "shortId returns an unambiguous prefix" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = try ulid.parse("0123456789ABCDEFGHJKMNPQRS");
    const b = try ulid.parse("0123456789ABCDEFGHJKMNPQRT");
    try f.store.append(.{ .add = .{ .id = a } });
    try f.store.append(.{ .add = .{ .id = b } });
    var sbuf: [ulid.len]u8 = undefined;
    const sa = try f.c.shortId(a, &sbuf);
    // Must be long enough to distinguish a from b (full 26 here since they share
    // 25 chars), and must resolve back to exactly a.
    const resolved = try f.c.resolve(sa);
    try testing.expect(resolved.eql(a));
}

// ----------------------------------------------------------- short-id stability (frozen shorts)

test "add mints and freezes a persisted short id (>= min_short_mint), returned verbatim by shortId" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{ "add", "New" });
    const ids = try f.store.allIds(alloc);
    defer alloc.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    const t = f.store.get(ids[0]).?;
    try testing.expect(t.short != null);
    // No collisions in a fresh store -> exactly the mint floor.
    try testing.expectEqual(@as(usize, cli.min_short_mint), t.short.?.len);

    var buf: [ulid.len]u8 = undefined;
    const displayed = try f.c.shortId(ids[0], &buf);
    try testing.expectEqualStrings(t.short.?, displayed);
}

test "a task added directly to the store (no mint) has no frozen short — the back-compat path" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Legacy" } });
    try testing.expect(f.store.get(a).?.short == null);
}

test "THE PRODUCTION BUG: a minted short survives add/drop churn + compact byte-identical" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Mint the task whose short we track.
    try f.run(&.{ "add", "Keep me" });
    const kept = try ulid.parse(f.out.items[0..ulid.len]);
    var buf1: [ulid.len]u8 = undefined;
    const short_before = try alloc.dupe(u8, try f.c.shortId(kept, &buf1));
    defer alloc.free(short_before);

    // Churn: mint + drop a bunch of siblings. This is exactly the shape that
    // used to shrink the live id set and shorten `kept`'s dynamically-computed
    // prefix out from under it.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try f.run(&.{ "add", "churn" });
        const cid = try ulid.parse(f.out.items[0..ulid.len]);
        try f.run(&.{ "state", &cid.text, "dropped" });
    }

    // Compact: GCs the dropped churn tasks, shrinking the live id set (the
    // exact trigger of the production incident).
    try f.run(&.{"compact"});

    var buf2: [ulid.len]u8 = undefined;
    try testing.expectEqualStrings(short_before, try f.c.shortId(kept, &buf2));

    // Byte-identical across an on-disk reopen too — this is what actually
    // exercises `serializeState`'s rewrite of the `add` event, the exact spot
    // the bug bit (the short was silently dropped/recomputed on compact).
    {
        var reopened = Store.open(alloc, io, f.tmp.dir);
        defer reopened.deinit();
        try reopened.load();
        const t = reopened.get(kept).?;
        try testing.expect(t.short != null);
        try testing.expectEqualStrings(short_before, t.short.?);
    }
}

test "mintShortId: collision with an EXISTING id extends only the NEW candidate; the existing id is untouched" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Two crafted ids sharing their first 10 characters — well past
    // min_short_mint (9), so a naive 9-char mint would collide.
    const a = try ulid.parse("0123456789ABCDEFGHJKMNPQRS");
    const b = try ulid.parse("0123456789ABCDEFGHJKMNPQRT");
    try f.store.append(.{ .add = .{ .id = a, .title = "Existing" } });

    var buf: [ulid.len]u8 = undefined;
    const mint_short = try f.c.mintShortId(b, &buf);
    try testing.expect(mint_short.len > 10); // extended past the shared prefix
    try testing.expectEqualStrings(b.text[0..mint_short.len], mint_short);

    // One-sided: `a` (the already-present id) is never touched by minting `b`.
    try testing.expect(f.store.get(a).?.short == null);
}

test "migrate-shorts: freezes every un-frozen task at its CURRENT short; idempotent; then survives compact" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // A pre-existing (legacy) repo: tasks added directly, bypassing cmdAdd's
    // mint-time freeze — exactly what every task minted before this feature
    // shipped looks like.
    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Alpha" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "Beta" } });

    var buf: [ulid.len]u8 = undefined;
    const a_before = try alloc.dupe(u8, try f.c.shortId(a, &buf));
    defer alloc.free(a_before);
    const b_before = try alloc.dupe(u8, try f.c.shortId(b, &buf));
    defer alloc.free(b_before);

    try f.run(&.{"migrate-shorts"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "froze") != null);
    try testing.expectEqualStrings(a_before, f.store.get(a).?.short.?);
    try testing.expectEqualStrings(b_before, f.store.get(b).?.short.?);

    // Idempotent: a second run touches nothing.
    try f.run(&.{"migrate-shorts"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing to migrate") != null);

    // The whole point: churn + compact must not move a frozen short anymore.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try f.run(&.{ "add", "churn" });
        const cid = try ulid.parse(f.out.items[0..ulid.len]);
        try f.run(&.{ "state", &cid.text, "dropped" });
    }
    try f.run(&.{"compact"});
    try testing.expectEqualStrings(a_before, try f.c.shortId(a, &buf));
}

test "migrate-shorts WITHOUT --min never lengthens an already-frozen short, even a very short one" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A", .short = a.text[0..6] } });

    try f.run(&.{"migrate-shorts"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing to migrate") != null);
    try testing.expectEqualStrings(a.text[0..6], f.store.get(a).?.short.?);
}

test "migrate-shorts --min: lengthens an already-frozen short below n; leaves a long-enough one alone; freezes a never-frozen task at >= n too" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const short8 = mintId();
    const already_long = mintId();
    const never_frozen = mintId();
    try f.store.append(.{ .add = .{ .id = short8, .title = "Short8", .short = short8.text[0..8] } });
    try f.store.append(.{ .add = .{ .id = already_long, .title = "AlreadyLong", .short = already_long.text[0..9] } });
    try f.store.append(.{ .add = .{ .id = never_frozen, .title = "NeverFrozen" } });

    try f.run(&.{ "migrate-shorts", "--min", "9" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "lengthened") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "froze") != null);

    // Lengthened past 8 -> at least 9, and still a genuine prefix of its own id.
    const s8 = f.store.get(short8).?.short.?;
    try testing.expect(s8.len >= 9);
    try testing.expectEqualStrings(short8.text[0..s8.len], s8);

    // Already long enough: untouched byte-for-byte (no spurious "lengthened" line for it).
    try testing.expectEqualStrings(already_long.text[0..9], f.store.get(already_long).?.short.?);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "AlreadyLong") == null);

    // A never-frozen task is frozen at >= --min too (not the legacy floor of 6).
    const nf = f.store.get(never_frozen).?.short.?;
    try testing.expect(nf.len >= 9);
}

test "migrate-shorts --min: collision-checks the repair, extending past a sibling's shared prefix" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Two ids sharing their first 25 characters (differ only at the last char).
    const a = try ulid.parse("0123456789ABCDEFGHJKMNPQRS");
    const b = try ulid.parse("0123456789ABCDEFGHJKMNPQRT");
    // `a` was migrated bare before (frozen at the legacy floor); `b` never frozen.
    try f.store.append(.{ .add = .{ .id = a, .title = "A", .short = a.text[0..6] } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B" } });

    try f.run(&.{ "migrate-shorts", "--min", "9" });

    const sa = f.store.get(a).?.short.?;
    const sb = f.store.get(b).?.short.?;
    // They share 25 of 26 chars, so only the FULL id distinguishes them.
    try testing.expectEqual(@as(usize, ulid.len), sa.len);
    try testing.expectEqual(@as(usize, ulid.len), sb.len);
    try testing.expectEqualStrings(a.text[0..sa.len], sa);
    try testing.expectEqualStrings(b.text[0..sb.len], sb);
}

test "migrate-shorts --min: idempotent — a second run at the same n touches nothing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.store.append(.{ .add = .{ .id = mintId(), .title = "Legacy" } });

    try f.run(&.{ "migrate-shorts", "--min", "9" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "froze") != null);

    try f.run(&.{ "migrate-shorts", "--min", "9" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing to migrate") != null);
}

test "migrate-shorts --min: missing value and unknown flags error cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try testing.expectEqual(cli.CliError.MissingArgument, f.runExpectErr(&.{ "migrate-shorts", "--min" }));
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "migrate-shorts", "--nope" }));
}

// ----------------------------------------------------------- render projection

test "render: arcs, shared prereq under both, markers, determinism" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // 2 arcs, a shared prereq reachable by both, an arc-less task.
    const arc1 = mintId();
    const arc2 = mintId();
    const m1 = mintId();
    const m2 = mintId();
    const shared = mintId();
    const lone = mintId();
    for ([_]Ulid{ arc1, arc2, m1, m2, shared, lone }) |id|
        try f.store.append(.{ .add = .{ .id = id } });
    // Titles to assert on.
    try f.store.append(.{ .add = .{ .id = arc1, .title = "Display arc" } });
    try f.store.append(.{ .add = .{ .id = arc2, .title = "Net arc" } });
    try f.store.append(.{ .add = .{ .id = m1, .title = "Member one" } });
    try f.store.append(.{ .add = .{ .id = m2, .title = "Member two" } });
    try f.store.append(.{ .add = .{ .id = shared, .title = "Shared prereq" } });
    try f.store.append(.{ .add = .{ .id = lone, .title = "Lonely task" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc1, .declared = true } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc2, .declared = true } });
    try f.store.append(.{ .in = .{ .task = m1, .arc = arc1, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = m2, .arc = arc2, .seq = 0 } });
    try f.store.append(.{ .dep = .{ .from = m1, .to = shared } });
    try f.store.append(.{ .dep = .{ .from = m2, .to = shared } });

    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(alloc);
    try f.c.renderMarkdown(&b1);

    // Arc headers present.
    try testing.expect(std.mem.indexOf(u8, b1.items, "## Display arc") != null);
    try testing.expect(std.mem.indexOf(u8, b1.items, "## Net arc") != null);
    // Arc-less section + the lone task.
    try testing.expect(std.mem.indexOf(u8, b1.items, "## Arc-less") != null);
    try testing.expect(std.mem.indexOf(u8, b1.items, "Lonely task") != null);
    // Shared prereq (open) appears under each arc.
    try testing.expectEqual(@as(usize, 2), countOccurrences(b1.items, "Shared prereq"));

    // Determinism: a second render is byte-identical.
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(alloc);
    try f.c.renderMarkdown(&b2);
    try testing.expectEqualStrings(b1.items, b2.items);
}

test "render: a task shared by two arcs is anchored once; the repeat links back, body once" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc1 = mintId();
    const arc2 = mintId();
    const m1 = mintId();
    const m2 = mintId();
    const shared = mintId();
    try f.store.append(.{ .add = .{ .id = arc1, .title = "First arc" } });
    try f.store.append(.{ .add = .{ .id = arc2, .title = "Second arc" } });
    try f.store.append(.{ .add = .{ .id = m1, .title = "Member one" } });
    try f.store.append(.{ .add = .{ .id = m2, .title = "Member two" } });
    try f.store.append(.{ .add = .{ .id = shared, .title = "Shared prereq", .body = "the shared body" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc1, .declared = true } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc2, .declared = true } });
    try f.store.append(.{ .in = .{ .task = m1, .arc = arc1, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = m2, .arc = arc2, .seq = 0 } });
    try f.store.append(.{ .dep = .{ .from = m1, .to = shared } });
    try f.store.append(.{ .dep = .{ .from = m2, .to = shared } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // Still listed under both arcs...
    try testing.expectEqual(@as(usize, 2), countOccurrences(b.items, "Shared prereq"));
    // ...but anchored + full exactly once, and linked back exactly once.
    var anchor_buf: [64]u8 = undefined;
    var link_buf: [64]u8 = undefined;
    var m1_buf: [64]u8 = undefined;
    const anchor = try std.fmt.bufPrint(&anchor_buf, "<a id=\"{s}\"></a>", .{&shared.text});
    try testing.expectEqual(@as(usize, 1), countOccurrences(b.items, anchor));
    const backlink = try std.fmt.bufPrint(&link_buf, "](#{s})", .{&shared.text});
    try testing.expectEqual(@as(usize, 1), countOccurrences(b.items, backlink));
    try testing.expectEqual(@as(usize, 1), countOccurrences(b.items, "the shared body"));
    // The anchored listing precedes the linked repeat (arc order is stable).
    try testing.expect(std.mem.indexOf(u8, b.items, anchor).? < std.mem.indexOf(u8, b.items, backlink).?);

    // A single-arc member gets neither anchor nor link.
    const m1_anchor = try std.fmt.bufPrint(&m1_buf, "<a id=\"{s}\"></a>", .{&m1.text});
    try testing.expectEqual(@as(usize, 0), countOccurrences(b.items, m1_anchor));

    // Determinism holds with anchors present.
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(alloc);
    try f.c.renderMarkdown(&b2);
    try testing.expectEqualStrings(b.items, b2.items);
}

test "render: a multi-line body folds into a <details>; a short one-liner stays inline" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const with = mintId();
    const short = mintId();
    const without = mintId();
    try f.store.append(.{ .add = .{ .id = with, .title = "Bodied task", .body = "first line\n\nsecond para\n" } });
    try f.store.append(.{ .add = .{ .id = short, .title = "Short task", .body = "one short line" } });
    try f.store.append(.{ .add = .{ .id = without, .title = "Bare task" } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // The disclosure: a blank line after the title bullet (so markdown doesn't
    // lazy-continue the title paragraph), the summary teaser = the body's first
    // line, a blank line after the opening tag (which is what puts the body back
    // into markdown parsing), the body lines 2-space indented with interior
    // blanks preserved, then a blank line and the 2-space-indented close (so the
    // disclosure stays inside the list item).
    try testing.expect(std.mem.indexOf(u8, b.items, "Bodied task\n\n  <details><summary>first line</summary>\n\n" ++
        "  first line\n\n  second para\n\n  </details>\n\n") != null);

    // A short single-line body is left INLINE — a disclosure whose summary is
    // the whole body hides nothing.
    try testing.expect(std.mem.indexOf(u8, b.items, "Short task\n\n  one short line\n\n") != null);
    // A body-less task stays a single line.
    try testing.expect(std.mem.indexOf(u8, b.items, "Bare task\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "Bare task\n\n  ") == null);
    // Exactly one disclosure in the whole projection, and it is balanced.
    try testing.expectEqual(@as(usize, 1), countOccurrences(b.items, "<details>"));
    try testing.expectEqual(@as(usize, 1), countOccurrences(b.items, "</details>"));
}

test "render: an ARC ROOT's own body renders under its ## heading, undented" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The defect this pins (2026-08-26): an arc renders as a `## title (id)`
    // section rather than a bullet, so it never reached renderTaskBullet -- the
    // only place that had ever printed a body -- and its body was dropped
    // silently. Measured then: 37 of 304 open tasks with a substantive body had
    // that body appear NOWHERE in the projection, and the sampled ones were all
    // arc roots. Those are precisely the tasks whose body states a goal's
    // RATIONALE, so the omission hit the highest-value prose in the file.
    const arc = mintId();
    const member = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Bodied arc", .body = "why this arc exists\n\nand the forces on it\n" } });
    try f.store.append(.{ .add = .{ .id = member, .title = "Member task" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 0 } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // The arc's body follows its heading and is NOT indented: a `##` section's
    // prose is document-level, so the 2-space list-item continuation prefix
    // would be meaningless at best and an indented code block at worst.
    const at = std.mem.indexOf(u8, b.items, "## Bodied arc") orelse return error.NoArcHeading;
    const tail = b.items[at..];
    try testing.expect(std.mem.indexOf(u8, tail, "<details><summary>why this arc exists</summary>") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\nwhy this arc exists\n") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "\nand the forces on it\n") != null);
    // Undented: the body must NOT arrive with a bullet's continuation indent.
    try testing.expect(std.mem.indexOf(u8, tail, "\n  why this arc exists") == null);
    // The member still renders after the arc's body, not before it.
    const body_at = std.mem.indexOf(u8, tail, "why this arc exists").?;
    const member_at = std.mem.indexOf(u8, tail, "Member task").?;
    try testing.expect(body_at < member_at);
}

test "render: an arc with zero renderable members is visibly marked, not a bare empty heading" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The recurring shape this pins (2026-08-27, 01M0ZC286): an arc whose only
    // member is done/dropped/archived (finished but the arc root never closed),
    // or that never had a slice filed at all, renders as `## title (id)` with
    // nothing under it -- indistinguishable from an omission. Two arcs here:
    // `empty` genuinely has no members at all; `finished` has one member, but
    // it is archived so nothing is left to render.
    const empty = mintId();
    const finished = mintId();
    const done_member = mintId();
    const populated = mintId();
    const open_member = mintId();
    try f.store.append(.{ .add = .{ .id = empty, .title = "Empty arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = empty, .declared = true } });

    try f.store.append(.{ .add = .{ .id = finished, .title = "Finished arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = finished, .declared = true } });
    try f.store.append(.{ .add = .{ .id = done_member, .title = "Done member" } });
    try f.store.append(.{ .in = .{ .task = done_member, .arc = finished, .seq = 0 } });
    try f.store.append(.{ .setState = .{ .id = done_member, .state = .archived } });

    try f.store.append(.{ .add = .{ .id = populated, .title = "Populated arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = populated, .declared = true } });
    try f.store.append(.{ .add = .{ .id = open_member, .title = "Open member" } });
    try f.store.append(.{ .in = .{ .task = open_member, .arc = populated, .seq = 0 } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    const marker = "*(no open members under this arc)*";
    const empty_at = std.mem.indexOf(u8, b.items, "## Empty arc").?;
    const finished_at = std.mem.indexOf(u8, b.items, "## Finished arc").?;
    const populated_at = std.mem.indexOf(u8, b.items, "## Populated arc").?;

    // Both zero-renderable-member arcs carry the marker between their own
    // heading and the NEXT one.
    const empty_section = b.items[empty_at..finished_at];
    const finished_section = b.items[finished_at..populated_at];
    try testing.expect(std.mem.indexOf(u8, empty_section, marker) != null);
    try testing.expect(std.mem.indexOf(u8, finished_section, marker) != null);

    // The populated arc has a real member, so no marker, and the member's
    // title still renders.
    const populated_section = b.items[populated_at..];
    try testing.expect(std.mem.indexOf(u8, populated_section, marker) == null);
    try testing.expect(std.mem.indexOf(u8, populated_section, "Open member") != null);
}

test "render: the <summary> teaser is cut at a word boundary and HTML-escaped" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{
        .id = t,
        .title = "Long-bodied task",
        .body = "needs a Foo<Bar> shim & a fallback before the loader resolves the vendored module\nmore",
    } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // Cut back to the last space before the 72-byte cap, ellipsis appended; `&`
    // and `<` entity-escaped, because inside <summary> the teaser is HTML, not
    // markdown — an unescaped `<` would be swallowed as a tag and eat the rest.
    try testing.expect(std.mem.indexOf(u8, b.items, "  <details><summary>needs a Foo&lt;Bar> shim &amp; a fallback before the loader resolves the…</summary>\n") != null);
    // The raw, unescaped form never reaches the summary line.
    try testing.expect(std.mem.indexOf(u8, b.items, "<summary>needs a Foo<Bar>") == null);
    // The body itself is still there in full, verbatim.
    try testing.expect(std.mem.indexOf(u8, b.items, "  needs a Foo<Bar> shim & a fallback before the loader resolves the vendored module\n") != null);
}

test "render: the <summary> teaser never splits a UTF-8 code point" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // 71 ASCII bytes, then a 2-byte code point straddling the 72-byte cap, and
    // no space anywhere (so the word-boundary backoff can't mask the bug).
    const filler = "x" ** 71;
    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "Wide task", .body = filler ++ "étail" } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    try testing.expect(std.unicode.utf8ValidateSlice(b.items));
    try testing.expect(std.mem.indexOf(u8, b.items, "<summary>" ++ filler ++ "…</summary>") != null);
}

test "render: arc seq renders as (seq N), never bare [N]; seq 0 is omitted entirely" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const default_seq = mintId(); // seq 0 (default) -> omitted entirely
    const ordered = mintId(); // seq 2 -> "(seq 2)"
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .add = .{ .id = default_seq, .title = "Default seq task" } });
    try f.store.append(.{ .add = .{ .id = ordered, .title = "Ordered task" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = default_seq, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = ordered, .arc = arc, .seq = 2 } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // No bare `[N]` anywhere — that's the broken-markdown-link shape (a bare
    // `[0]`/`[2]` is unresolved reference-link syntax and renders as an empty
    // or broken anchor).
    try testing.expect(std.mem.indexOf(u8, b.items, "[0]") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "[2]") == null);
    // A genuine non-zero seq uses a parenthesized, non-link form.
    try testing.expect(std.mem.indexOf(u8, b.items, "(seq 2)") != null);
    // seq 0 renders the ABSENCE of ordering — omitted, not "(seq 0)".
    try testing.expect(std.mem.indexOf(u8, b.items, "(seq 0)") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "Default seq task") != null);
}

test "render: the repeat-listing (shared task) also uses (seq N), never bare [N]" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc1 = mintId();
    const arc2 = mintId();
    const shared = mintId();
    try f.store.append(.{ .add = .{ .id = arc1, .title = "Arc one" } });
    try f.store.append(.{ .add = .{ .id = arc2, .title = "Arc two" } });
    try f.store.append(.{ .add = .{ .id = shared, .title = "Shared" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc1, .declared = true } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc2, .declared = true } });
    try f.store.append(.{ .in = .{ .task = shared, .arc = arc1, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = shared, .arc = arc2, .seq = 5 } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    try testing.expect(std.mem.indexOf(u8, b.items, "[5]") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "(seq 5)") != null);
}

test "render: a body line starting with # cannot hijack the heading outline; a leading - list still renders" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const hazard = mintId();
    const listy = mintId();
    try f.store.append(.{ .add = .{
        .id = hazard,
        .title = "Hazard task",
        .body = "intro\n# 01KWXRWA pm spawn fail phase=spawn.commit_refused\n## also heading-shaped\nparagraph\n---\nafter dashes\n===\nafter equals",
    } });
    try f.store.append(.{ .add = .{
        .id = listy,
        .title = "List task",
        .body = "- first item\n- second item",
    } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // ATX-shaped lines: escaped (a literal backslash breaks heading parsing),
    // and critically NO unescaped `#`/`##` starts a body line.
    try testing.expect(std.mem.indexOf(u8, b.items, "  \\# 01KWXRWA") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "  \\## also heading-shaped") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "\n# 01KWXRWA") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "\n## also heading-shaped") == null);

    // Setext-underline-shaped lines (a line of only `-` or only `=`, which
    // would retroactively turn the PRECEDING line into an H1/H2): also escaped.
    try testing.expect(std.mem.indexOf(u8, b.items, "  \\---\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "\n---\n") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "  \\===\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "\n===\n") == null);

    // A leading `-` LIST (dash + space + content) is untouched — still a list.
    try testing.expect(std.mem.indexOf(u8, b.items, "  - first item\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "  - second item\n") != null);
}

test "render: an INDENTED body line starting with # also cannot hijack the heading outline (production shape)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The exact production shape: the body line itself carries 2 leading
    // spaces (e.g. a quoted/continuation line), which lands under the
    // render's OWN 2-space bullet indent — 4 total leading spaces before the
    // `#`. Column-0 checking alone misses this (line[0] is a space, not '#').
    const hazard = mintId();
    try f.store.append(.{ .add = .{
        .id = hazard,
        .title = "Hazard task",
        .body = "intro\n  # 01KWXRWA pm spawn fail phase=spawn.commit_refused\n  --- \n  ---\nmore",
    } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);

    // Escaped right before the `#` — the ORIGINAL 2-space line indent plus the
    // render's own 2-space indent are both preserved verbatim, so it still
    // reads naturally as indented plain text; only the hazard char is escaped.
    try testing.expect(std.mem.indexOf(u8, b.items, "    \\# 01KWXRWA") != null);
    // No unescaped `#` starts anywhere on that line, at any indent.
    try testing.expect(std.mem.indexOf(u8, b.items, "  # 01KWXRWA") == null);

    // An indented setext-shaped line (only `-`, ignoring surrounding
    // whitespace) is escaped the same way.
    try testing.expect(std.mem.indexOf(u8, b.items, "    \\---\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "  ---\n") == null);
}

test "render: strict — done/archived excluded, open/blocked shown" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const o = mintId();
    const bl = mintId();
    const dn = mintId();
    const ar = mintId();
    try f.store.append(.{ .add = .{ .id = o, .title = "OPEN item" } });
    try f.store.append(.{ .add = .{ .id = bl, .title = "BLOCKED item" } });
    try f.store.append(.{ .add = .{ .id = dn, .title = "DONE item" } });
    try f.store.append(.{ .add = .{ .id = ar, .title = "ARCHIVED item" } });
    try f.store.append(.{ .setState = .{ .id = bl, .state = .blocked } });
    try f.store.append(.{ .setState = .{ .id = dn, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = ar, .state = .archived } });

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    try f.c.renderMarkdown(&b);
    try testing.expect(std.mem.indexOf(u8, b.items, "OPEN item") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "BLOCKED item") != null);
    try testing.expect(std.mem.indexOf(u8, b.items, "DONE item") == null);
    try testing.expect(std.mem.indexOf(u8, b.items, "ARCHIVED item") == null);
}

test "archive: emits done bullets, flips to archived, dedups, list hides archived" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "shipped feature", .tags = &.{"wm"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "also shipped" } });
    try f.store.append(.{ .add = .{ .id = c, .title = "still open" } });
    try f.store.append(.{ .setState = .{ .id = a, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = b, .state = .done } });

    // --dry-run: emits bullets, archives nothing.
    try f.run(&.{ "archive", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- shipped feature #wm") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- also shipped") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "still open") == null);
    try testing.expectEqual(tracker.State.done, f.store.get(a).?.state); // not flipped

    // Real archive (filtered to one): emits it, flips only it to archived.
    try f.run(&.{ "archive", "feature" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- shipped feature") != null);
    try testing.expectEqual(tracker.State.archived, f.store.get(a).?.state);
    try testing.expectEqual(tracker.State.done, f.store.get(b).?.state); // untouched

    // Structural dedup: a is archived, so a second archive won't re-emit it.
    try f.run(&.{ "archive", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "shipped feature") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "also shipped") != null);

    // list hides archived by default, reveals with --state archived.
    try f.run(&.{"list"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "shipped feature") == null);
    try f.run(&.{ "list", "--state", "archived" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "shipped feature") != null);

    // Nothing left in the done queue once the rest is archived.
    try f.run(&.{"archive"});
    try f.run(&.{ "archive", "--dry-run" });
    try testing.expectEqualStrings("(no done tasks to archive)\n", f.out.items);
}

// ----------------------------------------------------------- tree

test "tree: diamond DAG prints D once expanded + once as seen, never loops" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // A needs B and C; B and C both need D (the diamond).
    const a = mintId();
    const b = mintId();
    const c = mintId();
    const d = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A top" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B left" } });
    try f.store.append(.{ .add = .{ .id = c, .title = "C right" } });
    try f.store.append(.{ .add = .{ .id = d, .title = "D base" } });
    try f.store.append(.{ .dep = .{ .from = a, .to = b } });
    try f.store.append(.{ .dep = .{ .from = a, .to = c } });
    try f.store.append(.{ .dep = .{ .from = b, .to = d } });
    try f.store.append(.{ .dep = .{ .from = c, .to = d } });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try f.c.renderTree(&buf, a); // must terminate

    // D base appears exactly twice (once expanded, once as "seen").
    try testing.expectEqual(@as(usize, 2), countOccurrences(buf.items, "D base"));
    // Exactly one "seen" annotation (the second D path).
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "seen"));
    // Connectors present.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\u{251c}\u{2500}") != null or // ├─
        std.mem.indexOf(u8, buf.items, "\u{2514}\u{2500}") != null); // └─
    // Root line is A top with no connector at column 0.
    try testing.expect(std.mem.startsWith(u8, buf.items, "[ ] "));
    try testing.expect(std.mem.indexOf(u8, buf.items, "A top") != null);
}

test "tree rooted at an arc nests its members" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const arc = mintId();
    const m = mintId();
    const pre = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "The Arc" } });
    try f.store.append(.{ .add = .{ .id = m, .title = "Member" } });
    try f.store.append(.{ .add = .{ .id = pre, .title = "Prereq" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = m, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .dep = .{ .from = m, .to = pre } });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try f.c.renderTree(&buf, arc);
    try testing.expect(std.mem.indexOf(u8, buf.items, "The Arc") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Member") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Prereq") != null);
}

// ----------------------------------------------------------- next / list

test "next prints ready tasks; dep cycle rejected cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B" } });
    try f.run(&.{"next"});
    // Both ready (no prereqs).
    try testing.expect(std.mem.indexOf(u8, f.out.items, "A") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "B") != null);

    // dep a->b, then b->a closes a cycle -> clean DependencyCycle.
    try f.run(&.{ "dep", &a.text, "--needs", &b.text });
    const e = f.runExpectErr(&.{ "dep", &b.text, "--needs", &a.text });
    try testing.expectEqual(cli.CliError.DependencyCycle, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "cycle") != null);
}

// ------------------------------------------- self-wait (arc-membership cycle)
//
// A `needs` cycle isn't the only way a task can end up waiting on itself: an
// arc's own completion structurally depends on every DIRECT member finishing
// (it's never offered as the close-out prompt until drained), so a task that
// `needs` an arc it is itself a (direct or transitive) member of can never
// become ready — the arc can't finish while the member is open, and the
// member can't finish until the arc does. `dep`/`in` both reject whichever
// side would CLOSE that loop; see store.zig's `append`/`combinedReaches`.

test "dep: a task needing its own arc is rejected (self-wait, direct)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const arc = mintId();
    const t = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc root" } });
    try f.store.append(.{ .add = .{ .id = t, .title = "Member" } });
    try f.run(&.{ "arc", &arc.text });
    try f.run(&.{ "in", &t.text, &arc.text });

    // t is a direct member of arc; t needing arc closes the loop.
    const e = f.runExpectErr(&.{ "dep", &t.text, "--needs", &arc.text });
    try testing.expectEqual(cli.CliError.DependencyCycle, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "wait on itself forever") != null);
}

test "in: joining an arc a task already (transitively) needs is rejected (self-wait, mirror)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const arc = mintId();
    const t = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc root" } });
    try f.store.append(.{ .add = .{ .id = t, .title = "Member" } });
    try f.run(&.{ "arc", &arc.text });
    // t needs the arc BEFORE ever being a member of it — fine on its own,
    // since arc isn't yet a container t belongs to.
    try f.run(&.{ "dep", &t.text, "--needs", &arc.text });

    // Making t a direct member NOW closes the exact same loop from the
    // other side: `dep`/`in` must be mirror-rejected, not just `dep`.
    const e = f.runExpectErr(&.{ "in", &t.text, &arc.text });
    try testing.expectEqual(cli.CliError.DependencyCycle, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "wait on itself forever") != null);
}

test "dep: a legitimate cross-arc prereq is still accepted (over-rejection guard)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const arc_x = mintId();
    const arc_y = mintId();
    const tx = mintId();
    const ty = mintId();
    try f.store.append(.{ .add = .{ .id = arc_x, .title = "Arc X" } });
    try f.store.append(.{ .add = .{ .id = arc_y, .title = "Arc Y" } });
    try f.store.append(.{ .add = .{ .id = tx, .title = "Task in X" } });
    try f.store.append(.{ .add = .{ .id = ty, .title = "Task in Y" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc_x, .declared = true } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc_y, .declared = true } });
    try f.store.append(.{ .in = .{ .task = tx, .arc = arc_x, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = ty, .arc = arc_y, .seq = 0 } });

    // A task in arc X needing a task in an UNRELATED arc Y is normal
    // cross-arc ordering — must NOT be flagged as self-wait.
    try f.run(&.{ "dep", &tx.text, "--needs", &ty.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "now needs") != null);

    // Needing the whole of arc Y wholesale is likewise normal: tx is not a
    // member of Y, so there's no loop to close.
    try f.run(&.{ "dep", &tx.text, "--needs", &arc_y.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "now needs") != null);
}

test "list filters by tag, state, and word" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "fix the kernel", .tags = &.{"wm"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "write docs" } });
    try f.store.append(.{ .setState = .{ .id = b, .state = .done } });

    try f.run(&.{ "list", "--tag", "wm" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "kernel") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs") == null);

    try f.run(&.{ "list", "--state", "done" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "kernel") == null);

    try f.run(&.{ "list", "--word", "fix" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "kernel") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs") == null);
}

test "list --not-tag: repeatable, ANDed exclusion — the autonomous-eligible bucket" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    const d = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "needs the rig", .tags = &.{"metal"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "needs a ruling", .tags = &.{"scott-decision"} } });
    try f.store.append(.{ .add = .{ .id = c, .title = "needs BOTH", .tags = &.{ "metal", "scott-decision" } } });
    try f.store.append(.{ .add = .{ .id = d, .title = "unblocked host work" } });

    // A single --not-tag drops any task carrying it.
    try f.run(&.{ "list", "--not-tag", "metal" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the rig") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "BOTH") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "a ruling") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unblocked host work") != null);

    // Two --not-tags AND (both excluded independently): only the fully
    // unblocked task survives — this is the autonomous-eligible bucket.
    try f.run(&.{ "list", "--not-tag", "metal", "--not-tag", "scott-decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the rig") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "a ruling") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "BOTH") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unblocked host work") != null);

    // Composes with --tag (a positive filter) and bare-term search.
    try f.run(&.{ "list", "--tag", "metal", "--not-tag", "scott-decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the rig") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "BOTH") == null);
}

test "list: multi-term AND, bare positionals, case-insensitive, tag match" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Prism windowed present polish", .tags = &.{"arc:display-prism"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "Prism TTF rasterizer", .tags = &.{} } });
    try f.store.append(.{ .add = .{ .id = c, .title = "kernel windowed input", .tags = &.{} } });

    // Two ANDed terms (one bare, one --word): only the task matching BOTH.
    try f.run(&.{ "list", "prism", "--word", "windowed" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "polish") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "rasterizer") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "kernel windowed") == null);

    // Case-insensitive: lowercase "prism" matches "Prism".
    try f.run(&.{ "list", "prism" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "polish") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "rasterizer") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "kernel windowed") == null);

    // Tag match: the term lives only in a tag (#arc:display-prism).
    try f.run(&.{ "list", "display-prism" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "polish") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "rasterizer") == null);

    // An unknown --flag still errors (positionals are terms, flags are not).
    const e = f.runExpectErr(&.{ "list", "--bogus" });
    try testing.expectEqual(cli.CliError.UnknownFlag, e);
}

test "list: --limit caps output, --json emits a valid escaped array" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    // A title with a quote + backslash to exercise JSON escaping.
    try f.store.append(.{ .add = .{ .id = a, .title = "say \"hi\" \\ done", .tags = &.{"wm"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "second" } });
    try f.store.append(.{ .add = .{ .id = c, .title = "third" } });

    // --limit caps the number of lines shown.
    try f.run(&.{ "list", "--limit", "2" });
    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, f.out.items, '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 2), lines);

    // --json: escapes embedded quotes/backslashes, carries full + short id, tags.
    try f.run(&.{ "list", "--json", "wm" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\\\\ done") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, &a.text) != null); // full id
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"tags\":[\"wm\"]") != null);
    try testing.expect(f.out.items[0] == '[');
    try testing.expect(std.mem.indexOf(u8, f.out.items, "second") == null); // filtered out

    // Empty json result is a well-formed empty array.
    try f.run(&.{ "list", "--json", "nomatchxyz" });
    try testing.expectEqualStrings("[]\n", f.out.items);
}

test "next: positional term filters the ready frontier" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "prism windowed present" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "kernel scheduler fix" } });
    // Both are ready (no prereqs); the term narrows to the prism one.
    try f.run(&.{ "next", "prism" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "prism windowed") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "scheduler") == null);
}

test "next --not-tag: repeatable, ANDed exclusion, composes with --arc" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();
    const c = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "metal-blocked", .tags = &.{"metal"} } });
    try f.store.append(.{ .add = .{ .id = b, .title = "scott-blocked", .tags = &.{"scott-decision"} } });
    try f.store.append(.{ .add = .{ .id = c, .title = "clean host work" } });

    try f.run(&.{ "next", "--not-tag", "metal", "--not-tag", "scott-decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "metal-blocked") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "scott-blocked") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "clean host work") != null);
}

// ----------------------------------------------------------- compact CLI

test "trk compact: prints summary line, rejects extra args" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    // Add a couple tasks.
    try f.run(&.{ "add", "Task one" });
    try f.run(&.{ "add", "Task two" });

    // Compact: should print the summary line.
    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted:") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "live tasks") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "log truncated") != null);

    // A stray token is an error. UnknownFlag, not UsageError: `compact` now
    // takes a flag (--dry-run), which puts it under the same convention as
    // cmdArc/cmdIn/migrate-shorts — a token the flag loop cannot place.
    const e = f.runExpectErr(&.{ "compact", "extra" });
    try testing.expectEqual(error.UnknownFlag, e);
}

test "trk compact: a sabotaged write is REFUSED, names the diverged id on stdout, and restores the files" {
    var f = try Fixture.init(testing.allocator);
    defer f.deinit();

    const keep_id = mintId();
    const hit_id = mintId();
    try f.store.append(.{ .add = .{ .id = keep_id, .title = "Keep", .body = "keep's real body" } });
    try f.store.append(.{ .add = .{ .id = hit_id, .title = "Hit", .body = "hit's real body" } });

    try f.run(&.{"compact"}); // baseline compact: both survive, files established

    // Sabotage the NEXT compact's write for "Hit" only.
    f.store.test_sabotage_body = .{ .id = hit_id, .replacement = "CORRUPTED" };

    const e = f.runExpectErr(&.{"compact"});
    try testing.expectEqual(error.CompactVerifyFailed, e);

    // The CLI's own message (stdout) names the diverged id and says the
    // files were restored — not just a bare error name.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "REFUSED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "RESTORED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, &hit_id.text) != null);

    // The real on-disk state (reloaded fresh) still shows Hit's TRUE body.
    var check = Store.open(testing.allocator, io, f.tmp.dir);
    defer check.deinit();
    try check.load();
    try testing.expectEqualStrings("hit's real body", check.get(hit_id).?.body);
}

// ----------------------------------------------------------- doc subcommand (Wave 4)

test "trk doc set/list/resolve: basic registry operations" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // doc list on empty store.
    try f.run(&.{ "doc", "list" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no doc paths") != null);

    // Register a path.
    try f.run(&.{ "doc", "set", "issue-tracker", "docs/design/issue-tracker.md" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "issue-tracker") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs/design/issue-tracker.md") != null);

    // doc list now shows the entry.
    try f.run(&.{ "doc", "list" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "issue-tracker") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "->") != null);

    // doc resolve returns the path.
    try f.run(&.{ "doc", "resolve", "issue-tracker" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs/design/issue-tracker.md") != null);

    // doc resolve of unknown id -> NoSuchId error with clean message.
    const e = f.runExpectErr(&.{ "doc", "resolve", "no-such-doc" });
    try testing.expectEqual(error.NoSuchId, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "not registered") != null);

    // Usage errors.
    try testing.expectEqual(error.UsageError, f.runExpectErr(&.{ "doc", "set" }));
    try testing.expectEqual(error.UsageError, f.runExpectErr(&.{ "doc", "list", "extra" }));
    try testing.expectEqual(error.UsageError, f.runExpectErr(&.{ "doc", "resolve" }));
    try testing.expectEqual(error.UnknownCommand, f.runExpectErr(&.{ "doc", "frobnicate" }));
}

test "trk doc: render shows resolved path#section for registered docref, raw id for unregistered" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    const arc = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .add = .{ .id = task, .title = "My task" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = task, .arc = arc, .seq = 0 } });

    // Two docrefs: one registered, one not.
    try f.store.append(.{ .docref = .{ .id = task, .doc_id = "registered-doc", .section_id = "design" } });
    try f.store.append(.{ .docref = .{ .id = task, .doc_id = "unknown-doc", .section_id = "impl" } });

    // Register only the first.
    try f.store.append(.{ .setDocPath = .{ .doc_id = "registered-doc", .path = "docs/design/registered.md" } });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try f.c.renderMarkdown(&buf);

    // Registered: rendered as path#section.
    try testing.expect(std.mem.indexOf(u8, buf.items, "docs/design/registered.md#design") != null);
    // Unregistered: rendered as raw doc_id#section (falls back, no crash).
    try testing.expect(std.mem.indexOf(u8, buf.items, "unknown-doc#impl") != null);
    // The raw "registered-doc" string must NOT appear (it was resolved to the path).
    try testing.expect(std.mem.indexOf(u8, buf.items, "(registered-doc#") == null);
}

test "trk doc list output is sorted by doc_id" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Register in reverse alphabetical order.
    try f.run(&.{ "doc", "set", "zebra", "docs/z.md" });
    try f.run(&.{ "doc", "set", "alpha", "docs/a.md" });
    try f.run(&.{ "doc", "set", "mango", "docs/m.md" });

    try f.run(&.{ "doc", "list" });
    const out = f.out.items;

    // "alpha" must precede "mango" which must precede "zebra" in the output.
    const pos_alpha = std.mem.indexOf(u8, out, "alpha").?;
    const pos_mango = std.mem.indexOf(u8, out, "mango").?;
    const pos_zebra = std.mem.indexOf(u8, out, "zebra").?;
    try testing.expect(pos_alpha < pos_mango);
    try testing.expect(pos_mango < pos_zebra);
}

// ----------------------------------------------------------- show (Wave 5)

test "trk show: full detail with prereqs, dependents, arc, docrefs" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const pre = mintId();
    const task = mintId();
    const dep = mintId();

    try f.store.append(.{ .add = .{ .id = arc, .title = "My Arc" } });
    try f.store.append(.{ .add = .{ .id = pre, .title = "Prereq task" } });
    try f.store.append(.{ .add = .{ .id = task, .title = "The Task", .body = "body text", .tags = &.{"wm"} } });
    try f.store.append(.{ .add = .{ .id = dep, .title = "Dep task" } });
    try f.store.append(.{ .setState = .{ .id = pre, .state = .done } });
    try f.store.append(.{ .dep = .{ .from = task, .to = pre } }); // task needs pre
    try f.store.append(.{ .dep = .{ .from = dep, .to = task } }); // dep needs task
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = task, .arc = arc, .seq = 2 } });
    try f.store.append(.{ .docref = .{ .id = task, .doc_id = "myref", .section_id = "s1" } });
    try f.store.append(.{ .setDocPath = .{ .doc_id = "myref", .path = "docs/myref.md" } });

    try f.run(&.{ "show", &task.text });
    const out = f.out.items;

    // Core fields
    try testing.expect(std.mem.indexOf(u8, out, "id:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "The Task") != null);
    try testing.expect(std.mem.indexOf(u8, out, "body text") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#wm") != null);

    // Prereqs section
    try testing.expect(std.mem.indexOf(u8, out, "prereqs (needs):") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Prereq task") != null);

    // Dependents section
    try testing.expect(std.mem.indexOf(u8, out, "dependents (needs this):") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Dep task") != null);

    // Arcs section
    try testing.expect(std.mem.indexOf(u8, out, "arcs:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "My Arc") != null);
    try testing.expect(std.mem.indexOf(u8, out, "seq=2") != null);

    // Doc-refs section: resolved path#section
    try testing.expect(std.mem.indexOf(u8, out, "doc-refs:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "docs/myref.md#s1") != null);
}

test "trk show: unknown id errors cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const e = f.runExpectErr(&.{ "show", "ZZZZZZ" });
    try testing.expectEqual(cli.CliError.NoSuchId, e);
}

test "trk next: unset priority prints `-`, and an explicit one leads the frontier" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const member = mintId(); // arc'd, priority unset
    const urgent = mintId(); // arcless, priority -5

    try f.store.append(.{ .add = .{ .id = arc, .title = "The Arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = member, .title = "Arc member" } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .add = .{ .id = urgent, .title = "Urgent standalone" } });
    try f.store.append(.{ .setPriority = .{ .id = urgent, .priority = -5 } });

    try f.run(&.{"next"});
    const out = f.out.items;

    // Both columns print `-` when unset; a set priority prints its number.
    try testing.expect(std.mem.indexOf(u8, out, "[0/-]  Arc member") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[-/-5]  Urgent standalone") != null);

    // The arcless, deliberately-raised task leads the arc'd default one.
    const iu = std.mem.indexOf(u8, out, "Urgent standalone").?;
    const im = std.mem.indexOf(u8, out, "Arc member").?;
    try testing.expect(iu < im);

    // `show` spells the sentinel out rather than printing a bare 0.
    try f.run(&.{ "show", &member.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "priority: unset (ranks 100)") != null);
    try f.run(&.{ "show", &urgent.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "priority: -5") != null);
}

test "trk compact: a ghost is GC'd and reported by id, not refused" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const live = mintId();
    const ghost = mintId();
    try f.store.append(.{ .add = .{ .id = live, .title = "real task" } });
    // An event for an id with no `add` — what a union-merged log looks like
    // after a compact GC'd the original (01M0EJGYH).
    try f.store.append(.{ .setBody = .{ .id = ghost, .body = "orphaned body" } });

    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted:") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "ghost id(s) GC'd") != null);
    // The report must NAME the id: it is the only handle a recovery has.
    try testing.expect(std.mem.indexOf(u8, f.out.items, &ghost.text) != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "quarantine.jsonl") != null);

    // `--force` is gone with the refusal it existed to bypass.
    const e = f.runExpectErr(&.{ "compact", "--force" });
    try testing.expectEqual(@as(anyerror, error.UnknownFlag), e);
    // And it is refused as an unknown flag, not quietly near-matched onto the
    // one flag compact does take — those two mean opposite things.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean") == null);
}

test "trk edit --replace-body -: reads stdin, round-trips byte-stable, never stores a literal dash" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "t", .body = "old body" } });

    // Wire a file as stdin — the same read path main.zig gives the real one.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = "stdin.txt",
        // Trailing newline is what `trk show <id> --body` emits.
        .data = "para one\n\npara two with \"quotes\" and $dollars\n",
    });
    const in = try f.tmp.dir.openFile(io, "stdin.txt", .{});
    defer in.close(io);
    f.c.stdin = in;

    try f.run(&.{ "edit", &task.text, "--replace-body", "-" });

    // Exactly one trailing newline trimmed — the one `show --body` added — so
    // the body is what was piped, not a literal "-" (the old silent behavior).
    try testing.expectEqualStrings(
        "para one\n\npara two with \"quotes\" and $dollars",
        f.store.get(task).?.body,
    );

    // And `show --body` re-adds exactly that newline, so the pipe round-trips.
    try f.run(&.{ "show", &task.text, "--body" });
    try testing.expectEqualStrings(
        "para one\n\npara two with \"quotes\" and $dollars\n",
        f.out.items,
    );
}

test "trk edit --replace-body -: refuses an empty stdin and an unwired one, leaving the body intact" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "t", .body = "precious body" } });

    // No stdin wired at all: refuse rather than store "-".
    {
        const e = f.runExpectErr(&.{ "edit", &task.text, "--replace-body", "-" });
        try testing.expectEqual(@as(anyerror, error.UsageError), e);
        try testing.expect(std.mem.indexOf(u8, f.out.items, "no stdin to read") != null);
        try testing.expectEqualStrings("precious body", f.store.get(task).?.body);
    }

    // Wired but empty — a pipe whose upstream produced nothing. Blanking the
    // body here is the same data loss under a different name.
    {
        try f.tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
        const in = try f.tmp.dir.openFile(io, "empty.txt", .{});
        defer in.close(io);
        f.c.stdin = in;

        const e = f.runExpectErr(&.{ "edit", &task.text, "--replace-body", "-" });
        try testing.expectEqual(@as(anyerror, error.UsageError), e);
        try testing.expect(std.mem.indexOf(u8, f.out.items, "stdin was empty") != null);
        try testing.expectEqualStrings("precious body", f.store.get(task).?.body);
    }

    // `--replace-body ""` remains the explicit way to clear it.
    try f.run(&.{ "edit", &task.text, "--replace-body", "" });
    try testing.expectEqualStrings("", f.store.get(task).?.body);
}

test "trk add --body -: the same stdin path on the create half" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.tmp.dir.writeFile(io, .{ .sub_path = "stdin.txt", .data = "piped body\n" });
    const in = try f.tmp.dir.openFile(io, "stdin.txt", .{});
    defer in.close(io);
    f.c.stdin = in;

    try f.run(&.{ "add", "piped", "--arc", "--body", "-" });
    const id = try tracker.ulid.parse(std.mem.trim(u8, f.out.items, " \n"));
    try testing.expectEqualStrings("piped body", f.store.get(id).?.body);
}

// ----------------------------------------------------------- edit (Wave 5)

test "trk edit: title/body/add-tag/priority all apply; rm-tag removes" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "old title", .body = "old body", .tags = &.{"foo"} } });

    // Edit: change title, body, add tag, set priority.
    try f.run(&.{ "edit", &task.text, "--title", "new title", "--replace-body", "new body", "--add-tag", "bar", "--priority", "5" });

    const t = f.store.get(task).?;
    try testing.expectEqualStrings("new title", t.title);
    try testing.expectEqualStrings("new body", t.body);
    try testing.expectEqual(@as(i32, 5), t.priority);

    // Both tags present: foo (from add) and bar (from --add-tag).
    var found_foo = false;
    var found_bar = false;
    for (t.tags.items) |tg| {
        if (std.mem.eql(u8, tg, "foo")) found_foo = true;
        if (std.mem.eql(u8, tg, "bar")) found_bar = true;
    }
    try testing.expect(found_foo);
    try testing.expect(found_bar);

    // Now remove "foo".
    try f.run(&.{ "edit", &task.text, "--rm-tag", "foo" });
    const t2 = f.store.get(task).?;
    var has_foo = false;
    for (t2.tags.items) |tg| if (std.mem.eql(u8, tg, "foo")) {
        has_foo = true;
    };
    try testing.expect(!has_foo);
}

// --------------------------------------------- init + config (plugin-packaging)

test "trk init scaffolds .tracker/, config.json, and a starter TODO.md" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{"init"});

    // All three artifacts exist under the tmp dir.
    try f.tmp.dir.access(io, ".tracker/log.jsonl", .{});
    try f.tmp.dir.access(io, ".tracker/config.json", .{});
    try f.tmp.dir.access(io, "docs/TODO.md", .{});

    // config.json carries the default render.out.
    const cfg = try f.tmp.dir.readFileAlloc(io, ".tracker/config.json", alloc, .unlimited);
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "\"out\": \"docs/TODO.md\"") != null);

    // The seeded TODO.md is a valid projection (carries the generated header).
    const todo = try f.tmp.dir.readFileAlloc(io, "docs/TODO.md", alloc, .unlimited);
    defer alloc.free(todo);
    try testing.expect(std.mem.indexOf(u8, todo, "TODO — remaining work") != null);
}

test "trk init is idempotent and never clobbers an existing TODO.md" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{"init"});
    // Hand-edit the projection out from under the tracker.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "docs/TODO.md", .data = "HAND EDIT\n", .flags = .{} });

    // Second init: reports the artifacts exist, leaves the file byte-for-byte intact.
    try f.run(&.{"init"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "already exists") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "never overwrites") != null);

    const todo = try f.tmp.dir.readFileAlloc(io, "docs/TODO.md", alloc, .unlimited);
    defer alloc.free(todo);
    try testing.expectEqualStrings("HAND EDIT\n", todo);
}

test "trk init writes .tracker/.gitattributes with all three pins; --no-gitattributes skips it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{"init"});
    const ga = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitattributes", alloc, .unlimited);
    defer alloc.free(ga);

    // The log union-merges (parallel-worktree appends combine); the two
    // whole-file baselines are pinned to the default text driver so a raced
    // compact SURFACES as a conflict instead of being silently combined.
    try testing.expect(std.mem.indexOf(u8, ga, "\nlog.jsonl merge=union\n") != null);
    try testing.expect(std.mem.indexOf(u8, ga, "\nsnapshot.jsonl merge=text\n") != null);
    try testing.expect(std.mem.indexOf(u8, ga, "\nquarantine.jsonl merge=text\n") != null);
    // Patterns are RELATIVE to .tracker/ — a repo-root-anchored path here would
    // silently match nothing, since the file lives inside the directory.
    try testing.expect(std.mem.indexOf(u8, ga, "/.tracker/") == null);

    // Opt out: no file at all, and init still succeeds.
    var f2 = try Fixture.init(alloc);
    defer f2.deinit();
    try f2.run(&.{ "init", "--no-gitattributes" });
    try testing.expectError(error.FileNotFound, f2.tmp.dir.access(io, ".tracker/.gitattributes", .{}));
    try f2.tmp.dir.access(io, ".tracker/log.jsonl", .{});
}

test "trk init never clobbers a tuned .gitattributes" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{"init"});

    // A project may have tuned it (an extra pin, a house comment). Same ruling
    // as TODO.md: init creates, it never overwrites.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data = "log.jsonl merge=union\n# house rule\n",
        .flags = .{},
    });
    try f.run(&.{"init"});
    const ga = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitattributes", alloc, .unlimited);
    defer alloc.free(ga);
    try testing.expectEqualStrings("log.jsonl merge=union\n# house rule\n", ga);
    try testing.expect(std.mem.indexOf(u8, f.out.items, ".gitattributes already exists") != null);
}

test "trk init writes .tracker/.gitignore covering backup/; --no-gitignore skips it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{"init"});
    const gi = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitignore", alloc, .unlimited);
    defer alloc.free(gi);

    // compact's pre-rewrite backup runs are what makes an ignore rule
    // necessary in the first place — assert the line is actually present,
    // not merely that the file exists.
    try testing.expect(std.mem.indexOf(u8, gi, "\nbackup/\n") != null);
    // log.jsonl/snapshot.jsonl/config.json/quarantine.jsonl are meant to be
    // committed — none of them may appear as an ignored pattern.
    try testing.expect(std.mem.indexOf(u8, gi, "log.jsonl\n") == null);
    try testing.expect(std.mem.indexOf(u8, gi, "snapshot.jsonl\n") == null);
    try testing.expect(std.mem.indexOf(u8, gi, "quarantine.jsonl\n") == null);

    // Opt out: no file at all, and init still succeeds.
    var f2 = try Fixture.init(alloc);
    defer f2.deinit();
    try f2.run(&.{ "init", "--no-gitignore" });
    try testing.expectError(error.FileNotFound, f2.tmp.dir.access(io, ".tracker/.gitignore", .{}));
    try f2.tmp.dir.access(io, ".tracker/log.jsonl", .{});
}

test "trk init never clobbers a tuned .gitignore" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{"init"});

    // Same non-destructive contract as .gitattributes/TODO.md: init creates,
    // it never overwrites.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitignore",
        .data = "backup/\n# house rule\n",
        .flags = .{},
    });
    try f.run(&.{"init"});
    const gi = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitignore", alloc, .unlimited);
    defer alloc.free(gi);
    try testing.expectEqualStrings("backup/\n# house rule\n", gi);
    try testing.expect(std.mem.indexOf(u8, f.out.items, ".gitignore already exists") != null);
}

test "re-running trk init in an existing repo backfills a missing .gitignore without touching .gitattributes" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Simulate a repo that ran an OLDER `trk init` (before .gitignore
    // existed): write everything init writes except .tracker/.gitignore.
    try f.run(&.{"init"});
    try f.tmp.dir.deleteFile(io, ".tracker/.gitignore");
    const ga_before = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitattributes", alloc, .unlimited);
    defer alloc.free(ga_before);

    // Re-running init is the migration: it backfills the missing file and
    // leaves every other artifact byte-for-byte alone.
    try f.run(&.{"init"});
    try f.tmp.dir.access(io, ".tracker/.gitignore", .{});
    const ga_after = try f.tmp.dir.readFileAlloc(io, ".tracker/.gitattributes", alloc, .unlimited);
    defer alloc.free(ga_after);
    try testing.expectEqualStrings(ga_before, ga_after);
}

test "trk compact warns (on stderr) when the .gitattributes pins are missing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.store.append(.{ .add = .{ .id = mintId(), .title = "a task" } });

    // No .tracker/.gitattributes at all (the Fixture scaffolds the store
    // directly, without going through `init`).
    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.warn.items, ".gitattributes is absent") != null);
    // The warning is stderr-bound: stdout stays scriptable.
    try testing.expect(std.mem.indexOf(u8, f.out.items, ".gitattributes") == null);

    // A file that exists but has lost a pin names the missing line specifically.
    f.warn.clearRetainingCapacity();
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data = "log.jsonl merge=union\nsnapshot.jsonl merge=text\n",
        .flags = .{},
    });
    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "quarantine.jsonl merge=text") != null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "log.jsonl merge=union") == null);

    // All three present -> silent.
    f.warn.clearRetainingCapacity();
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data = tracker.store.gitattributes_text,
        .flags = .{},
    });
    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.warn.items, ".gitattributes") == null);
}

test "compact's pin check matches whole lines, not comment mentions" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // One append so `.tracker/` exists on disk (the Fixture creates it lazily).
    try f.store.append(.{ .add = .{ .id = mintId(), .title = "a task" } });

    // The shipped file NAMES every pattern in its comments. A substring check
    // would pass on a file that only talks about the pins without setting them.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data = "# we should add log.jsonl merge=union and snapshot.jsonl merge=text someday\n",
        .flags = .{},
    });
    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "log.jsonl merge=union") != null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "snapshot.jsonl merge=text") != null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "quarantine.jsonl merge=text") != null);
}

test "compact warns for tombstones.jsonl specifically on a PRE-EXISTING store's legacy 3-pin .gitattributes (01M2N0QW2)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.store.append(.{ .add = .{ .id = mintId(), .title = "a task" } });

    // The exact byte-for-byte content `trk init` wrote BEFORE the tombstones
    // pin was added to the template (eb427ca) — what every store created
    // before that commit still carries today, verbatim (confirmed against
    // both this repo's own .tracker/.gitattributes and Enix's). `init` never
    // rewrites an existing .gitattributes, so this file can never self-heal;
    // `compact`'s check is what has to catch it.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data =
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
        \\
        ,
        .flags = .{},
    });
    try f.run(&.{"compact"});
    // POSITIVE: the one pin this legacy file lacks is named.
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "tombstones.jsonl merge=union") != null);
    // NEGATIVE: the three pins the legacy file already carries are NOT
    // re-flagged — a check that warned on everything regardless of content
    // would pass this same assertion for the wrong reason.
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "log.jsonl merge=union` line") == null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "snapshot.jsonl merge=text` line") == null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "quarantine.jsonl merge=text` line") == null);
}

test "trk init --force rewrites config with a custom --out; leaves an existing TODO.md" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{"init"});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "docs/TODO.md", .data = "KEEP\n", .flags = .{} });

    try f.run(&.{ "init", "--force", "--out", "custom/PLAN.md" });
    const cfg = try f.tmp.dir.readFileAlloc(io, ".tracker/config.json", alloc, .unlimited);
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "custom/PLAN.md") != null);

    // The pre-existing default TODO.md is untouched (force rewrites config only).
    const todo = try f.tmp.dir.readFileAlloc(io, "docs/TODO.md", alloc, .unlimited);
    defer alloc.free(todo);
    try testing.expectEqualStrings("KEEP\n", todo);
}

test "trk render honors config render.out with no --out; --out overrides" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "ready task" } });

    // Config points render at a nested path; render with no --out writes there
    // (and mkdir -p's the parent).
    f.store.config.render_out = "out/A.md";
    try f.run(&.{"render"});
    const a = try f.tmp.dir.readFileAlloc(io, "out/A.md", alloc, .unlimited);
    defer alloc.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "ready task") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "wrote ") != null);

    // Explicit --out beats config.
    try f.run(&.{ "render", "--out", "B.md" });
    try f.tmp.dir.access(io, "B.md", .{});
}

test "trk render with no config and no --out goes to stdout" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{"render"});
    // The projection landed in the out buffer (stdout), not written to a file.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "TODO — remaining work") != null);
}

test "trk archive APPENDS to config archive.out under a dated heading; dry-run never touches the file" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const t = mintId();
    const u = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "done item" } });
    try f.store.append(.{ .add = .{ .id = u, .title = "later item" } });
    try f.store.append(.{ .setState = .{ .id = t, .state = .done } });

    // Pre-existing content (a changelog header) must survive every run.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = "# Changelog\n", .flags = .{} });
    f.store.config.archive_out = "CHANGELOG.md";

    // dry-run: bullets preview on stdout, file untouched, nothing flipped.
    try f.run(&.{ "archive", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- done item") != null);
    try testing.expectEqual(tracker.State.done, f.store.get(t).?.state);
    {
        const d = try f.tmp.dir.readFileAlloc(io, "CHANGELOG.md", alloc, .unlimited);
        defer alloc.free(d);
        try testing.expectEqualStrings("# Changelog\n", d);
    }

    // Real run: appended after the header, under a `## YYYY-MM-DD` heading.
    try f.run(&.{"archive"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "archived 1 task") != null);
    {
        const d = try f.tmp.dir.readFileAlloc(io, "CHANGELOG.md", alloc, .unlimited);
        defer alloc.free(d);
        try testing.expect(std.mem.startsWith(u8, d, "# Changelog\n\n## "));
        try testing.expect(std.mem.indexOf(u8, d, "- done item") != null);
    }

    // A second run appends again — the first run's records survive.
    try f.store.append(.{ .setState = .{ .id = u, .state = .done } });
    try f.run(&.{"archive"});
    {
        const d = try f.tmp.dir.readFileAlloc(io, "CHANGELOG.md", alloc, .unlimited);
        defer alloc.free(d);
        try testing.expect(std.mem.indexOf(u8, d, "- done item") != null);
        try testing.expect(std.mem.indexOf(u8, d, "- later item") != null);
    }
}

// --------------------------------------------- 01M2F8GBQ: per-task changelog destinations

test "archive: archive.routes sends a matching-tagged task to its own file; an unmatched task still lands in archive.out" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Shaped after CLAUDE.md's ruled split (Enix): prism-LIBRARY work
    // (gated by host tests + a cross-build) graduates to its own changelog,
    // while ordinary Enix-side adoption work graduates to the main one --
    // in the SAME archive run, with no manual --tag split.
    const lib = mintId();
    const adoption = mintId();
    try f.store.append(.{ .add = .{ .id = lib, .title = "prism library fix", .tags = &.{"prism-lib"} } });
    try f.store.append(.{ .add = .{ .id = adoption, .title = "wire prism into the WM demo" } });
    try f.store.append(.{ .setState = .{ .id = lib, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = adoption, .state = .done } });

    f.store.config.archive_out = "docs/CHANGELOG.md";
    f.store.config.archive_routes = &.{
        .{ .tag = "prism-lib", .out = "annex/prism/CHANGELOG.md" },
    };

    try f.run(&.{"archive"});
    try testing.expectEqual(tracker.State.archived, f.store.get(lib).?.state);
    try testing.expectEqual(tracker.State.archived, f.store.get(adoption).?.state);

    {
        const d = try f.tmp.dir.readFileAlloc(io, "annex/prism/CHANGELOG.md", alloc, .unlimited);
        defer alloc.free(d);
        try testing.expect(std.mem.indexOf(u8, d, "- prism library fix") != null);
        try testing.expect(std.mem.indexOf(u8, d, "wire prism") == null);
    }
    {
        const d = try f.tmp.dir.readFileAlloc(io, "docs/CHANGELOG.md", alloc, .unlimited);
        defer alloc.free(d);
        try testing.expect(std.mem.indexOf(u8, d, "- wire prism into the WM demo") != null);
        try testing.expect(std.mem.indexOf(u8, d, "prism library fix") == null);
    }
}

test "archive: an explicit --out overrides every configured route -- everything lands in one file" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const lib = mintId();
    try f.store.append(.{ .add = .{ .id = lib, .title = "prism library fix", .tags = &.{"prism-lib"} } });
    try f.store.append(.{ .setState = .{ .id = lib, .state = .done } });

    f.store.config.archive_routes = &.{
        .{ .tag = "prism-lib", .out = "annex/prism/CHANGELOG.md" },
    };

    try f.run(&.{ "archive", "--out", "ONE.md" });
    try f.tmp.dir.access(io, "ONE.md", .{});
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "annex/prism/CHANGELOG.md", .{}));
}

test "archive: a task matching TWO configured routes is a hard error naming both -- nothing is archived" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const both = mintId();
    const clean = mintId();
    try f.store.append(.{ .add = .{ .id = both, .title = "ambiguous task", .tags = &.{ "prism-lib", "cabi-lib" } } });
    try f.store.append(.{ .add = .{ .id = clean, .title = "clean one" } });
    try f.store.append(.{ .setState = .{ .id = both, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = clean, .state = .done } });

    f.store.config.archive_routes = &.{
        .{ .tag = "prism-lib", .out = "annex/prism/CHANGELOG.md" },
        .{ .tag = "cabi-lib", .out = "annex/cabi/CHANGELOG.md" },
    };

    const e = f.runExpectErr(&.{"archive"});
    try testing.expectEqual(@as(anyerror, error.UsageError), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "ambiguous task") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "prism-lib") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "cabi-lib") != null);
    try testing.expectEqual(tracker.State.done, f.store.get(both).?.state);
    try testing.expectEqual(tracker.State.done, f.store.get(clean).?.state);
}

test "archive --dry-run with routes: each destination previews separately labeled; no file is touched" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const lib = mintId();
    const adoption = mintId();
    try f.store.append(.{ .add = .{ .id = lib, .title = "prism library fix", .tags = &.{"prism-lib"} } });
    try f.store.append(.{ .add = .{ .id = adoption, .title = "wire prism into the WM demo" } });
    try f.store.append(.{ .setState = .{ .id = lib, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = adoption, .state = .done } });

    f.store.config.archive_out = "docs/CHANGELOG.md";
    f.store.config.archive_routes = &.{
        .{ .tag = "prism-lib", .out = "annex/prism/CHANGELOG.md" },
    };

    try f.run(&.{ "archive", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "annex/prism/CHANGELOG.md") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs/CHANGELOG.md") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- prism library fix") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "- wire prism into the WM demo") != null);

    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "annex/prism/CHANGELOG.md", .{}));
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "docs/CHANGELOG.md", .{}));
    try testing.expectEqual(tracker.State.done, f.store.get(lib).?.state);
    try testing.expectEqual(tracker.State.done, f.store.get(adoption).?.state);
}

test "loadConfig parses render/archive out; malformed sets config_malformed" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var sub = try f.tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);

    // A valid config round-trips into the typed fields.
    try sub.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{ \"render\": { \"out\": \"R.md\" }, \"archive\": { \"out\": \"C.md\" } }",
        .flags = .{},
    });
    f.store.loadConfig();
    try testing.expect(!f.store.config_malformed);
    try testing.expectEqualStrings("R.md", f.store.config.render_out.?);
    try testing.expectEqualStrings("C.md", f.store.config.archive_out.?);

    // Junk sets the flag and never faults the command.
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{ not json", .flags = .{} });
    f.store.config_malformed = false;
    f.store.loadConfig();
    try testing.expect(f.store.config_malformed);
}

test "loadConfig parses archive.routes; a non-string value is skipped, not fatal; absent section is empty" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var sub = try f.tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);

    try sub.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{ \"archive\": { \"out\": \"C.md\", \"routes\": { \"prism-lib\": \"annex/prism/CHANGELOG.md\", \"bad\": 5 } } }",
        .flags = .{},
    });
    f.store.loadConfig();
    try testing.expect(!f.store.config_malformed);
    try testing.expectEqual(@as(usize, 1), f.store.config.archive_routes.len);
    try testing.expectEqualStrings("prism-lib", f.store.config.archive_routes[0].tag);
    try testing.expectEqualStrings("annex/prism/CHANGELOG.md", f.store.config.archive_routes[0].out);

    // Absent section -> empty, not an error -- the "no extra destinations
    // configured" default that keeps a single-changelog repo unchanged.
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{}", .flags = .{} });
    f.store.loadConfig();
    try testing.expectEqual(@as(usize, 0), f.store.config.archive_routes.len);
}

test "loadConfig: add.arcless — absent/warn/typo default to false (warn); exactly \"error\" is true" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var sub = try f.tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);

    // No config at all: the safe default.
    try testing.expect(!f.store.config.add_arcless_error);

    // Explicit "warn" -> false.
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{ \"add\": { \"arcless\": \"warn\" } }", .flags = .{} });
    f.store.loadConfig();
    try testing.expect(!f.store.config.add_arcless_error);

    // A typo/unknown value degrades to the safe default, not a hard error.
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{ \"add\": { \"arcless\": \"eror\" } }", .flags = .{} });
    f.store.loadConfig();
    try testing.expect(!f.store.config.add_arcless_error);

    // Exactly "error" escalates.
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{ \"add\": { \"arcless\": \"error\" } }", .flags = .{} });
    f.store.loadConfig();
    try testing.expect(f.store.config.add_arcless_error);
}

// --------------------------------------------- per-verb --help (agent exploration)

test "every verb supports --help/-h and add --help mints no task" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The full dispatch set. Kept in lockstep with the `verbs` table via the
    // count assertion below, so a new verb without a help entry is caught.
    const verbs = [_][]const u8{
        "init",              "add",  "dep",  "undep",  "in",            "unin",    "arc",        "migrate-arcs", "migrate-shorts",
        "state",             "next", "list", "render", "tree",          "compact", "archive",    "doc",          "show",
        "edit",              "rule", "log",  "stale",  "stale-rulings", "release", "tombstones", "mcp-serve",    "decision",
        "migrate-decisions", "lost-appends",
    };
    try testing.expectEqual(verbs.len, cli.Cli.verbs.len);

    for (verbs) |v| {
        // `trk <verb> --help` prints that verb's synopsis (starts "trk <verb>"),
        // NOT the generic overview.
        var buf: [64]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&buf, "trk {s}", .{v});
        try f.run(&.{ v, "--help" });
        try testing.expect(std.mem.indexOf(u8, f.out.items, prefix) != null);
        try testing.expect(std.mem.indexOf(u8, f.out.items, "an in-repo issue tracker") == null);
        // `-h` is identical.
        try f.run(&.{ v, "-h" });
        try testing.expect(std.mem.indexOf(u8, f.out.items, prefix) != null);
    }

    // The trap this closes: `trk add --help` explains, it does NOT mint a task
    // titled "--help".
    try f.run(&.{ "add", "--help" });
    try testing.expectEqual(@as(usize, 0), f.store.count());

    // `trk help <verb>` routes to the same per-verb help.
    try f.run(&.{ "help", "render" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "trk render") != null);

    // Bare `trk help` / `trk --help` still shows the overview.
    try f.run(&.{"help"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "an in-repo issue tracker") != null);

    // An unknown verb's help falls back to the overview (never errors).
    try f.run(&.{ "help", "nonsense" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "an in-repo issue tracker") != null);
}

test "trk edit: no flags is a usage error" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "T" } });
    const e = f.runExpectErr(&.{ "edit", &task.text });
    try testing.expectEqual(cli.CliError.UsageError, e);
}

test "trk edit: last-write-wins on title — two setTitle events, final is second" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "v1" } });
    try f.run(&.{ "edit", &task.text, "--title", "v2" });
    try f.run(&.{ "edit", &task.text, "--title", "v3" });
    try testing.expectEqualStrings("v3", f.store.get(task).?.title);
}

// ----------------------------------------------------------- log (Wave 5)

test "trk log: shows events; per-id filter; --limit" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Task A" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "Task B" } });
    try f.store.append(.{ .setState = .{ .id = b, .state = .done } });

    // trk log: shows all events (at least one entry per append above).
    try f.run(&.{"log"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "add:") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Task A") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Task B") != null);

    // trk log <b>: shows only Task B events.
    try f.run(&.{ "log", &b.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Task B") != null);
    // "Task A" must NOT appear (it's a different task's add event).
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Task A") == null);

    // trk log --limit 1: shows exactly 1 line.
    try f.run(&.{ "log", "--limit", "1" });
    const line_count = countOccurrences(f.out.items, "\n");
    try testing.expectEqual(@as(usize, 1), line_count);
}

test "trk log: empty store prints (no events)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{"log"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no events") != null);
}

test "trk log: unknown id errors cleanly" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const e = f.runExpectErr(&.{ "log", "ZZZZZZ" });
    try testing.expectEqual(cli.CliError.NoSuchId, e);
}

test "add --doc and edit --add-doc attach doc-refs; resolved via registry" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "doc", "set", "ds", "docs/design/issue-tracker.md" });

    // add with an inline doc-ref carrying a section anchor
    try f.run(&.{ "add", "task one", "--doc", "ds#storage" });
    try f.run(&.{"render"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs/design/issue-tracker.md#storage") != null);

    // edit --add-doc on a second task (its full id is the quiet add output)
    try f.run(&.{ "add", "task two" });
    var idbuf: [ulid.len]u8 = undefined;
    @memcpy(&idbuf, f.out.items[0..ulid.len]);
    try f.run(&.{ "edit", &idbuf, "--add-doc", "ds" });
    try f.run(&.{ "show", &idbuf });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "docs/design/issue-tracker.md") != null);

    // edit with no flags still errors
    const e = f.runExpectErr(&.{ "edit", &idbuf });
    try testing.expectEqual(cli.CliError.UsageError, e);
}

// ----------------------------------------------------------- undep

test "undep: removes an existing needs edge" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B" } });
    try f.store.append(.{ .dep = .{ .from = a, .to = b } }); // a needs b

    // Confirm edge present.
    var found = false;
    for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) {
        found = true;
    };
    try testing.expect(found);

    // undep removes it.
    try f.run(&.{ "undep", &a.text, "--needs", &b.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer needs") != null);

    var still = false;
    for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) {
        still = true;
    };
    try testing.expect(!still);

    // a is now unblocked (no prereqs).
    const ready = try f.store.next(alloc);
    defer alloc.free(ready);
    var a_ready = false;
    for (ready) |id| if (id.eql(a)) {
        a_ready = true;
    };
    try testing.expect(a_ready);
}

test "undep: tombstone beats a same-edge dep regardless of append order" {
    const alloc = testing.allocator;

    // Case 1: dep then undep (normal order) — edge absent after fold.
    {
        var f = try Fixture.init(alloc);
        defer f.deinit();
        const a = mintId();
        const b = mintId();
        try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
        try f.store.append(.{ .add = .{ .id = b, .title = "B" } });
        try f.store.append(.{ .dep = .{ .from = a, .to = b } });
        try f.store.append(.{ .undep = .{ .from = a, .to = b } });
        var edge_present = false;
        for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) {
            edge_present = true;
        };
        try testing.expect(!edge_present); // tombstone wins
    }

    // Case 2: undep then dep (union-merge reversed order) — tombstone still wins.
    {
        var f = try Fixture.init(alloc);
        defer f.deinit();
        const a = mintId();
        const b = mintId();
        try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
        try f.store.append(.{ .add = .{ .id = b, .title = "B" } });
        try f.store.append(.{ .undep = .{ .from = a, .to = b } }); // tombstone first
        try f.store.append(.{ .dep = .{ .from = a, .to = b } }); // dep after — blocked
        var edge_present = false;
        for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) {
            edge_present = true;
        };
        try testing.expect(!edge_present); // tombstone still wins
    }
}

test "undep: no-op on a non-existent edge" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B" } });
    // No dep edge — undep is a no-op, must not error.
    try f.run(&.{ "undep", &a.text, "--needs", &b.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer needs") != null);
    try testing.expectEqual(@as(usize, 0), f.store.needs.items.len);
}

// ----------------------------------------------------------- unin

test "unin: removes an existing in edge" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    const arc = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "T" } });
    try f.store.append(.{ .add = .{ .id = arc, .title = "A" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = task, .arc = arc, .seq = 0 } });

    var found = false;
    for (f.store.ins.items) |e| if (e.task.eql(task) and e.arc.eql(arc)) {
        found = true;
    };
    try testing.expect(found);

    try f.run(&.{ "unin", &task.text, &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer in") != null);

    var still = false;
    for (f.store.ins.items) |e| if (e.task.eql(task) and e.arc.eql(arc)) {
        still = true;
    };
    try testing.expect(!still);
}

test "unin: leaves an UNRELATED in edge alone (no over-removal)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t1 = mintId();
    const t2 = mintId();
    const arc = mintId();
    try f.store.append(.{ .add = .{ .id = t1, .title = "T1" } });
    try f.store.append(.{ .add = .{ .id = t2, .title = "T2" } });
    try f.store.append(.{ .add = .{ .id = arc, .title = "A" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = t1, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .in = .{ .task = t2, .arc = arc, .seq = 0 } });

    try f.run(&.{ "unin", &t1.text, &arc.text });

    var t1_present = false;
    var t2_present = false;
    for (f.store.ins.items) |e| {
        if (e.task.eql(t1) and e.arc.eql(arc)) t1_present = true;
        if (e.task.eql(t2) and e.arc.eql(arc)) t2_present = true;
    }
    try testing.expect(!t1_present);
    try testing.expect(t2_present); // untouched
}

test "unin: no-op on a non-existent edge" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    const arc = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "T" } });
    try f.store.append(.{ .add = .{ .id = arc, .title = "A" } });
    // No in edge — unin is a no-op, must not error.
    try f.run(&.{ "unin", &task.text, &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer in") != null);
    try testing.expectEqual(@as(usize, 0), f.store.ins.items.len);
}

test "unin: wrong argument count is a usage error" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const e = f.runExpectErr(&.{"unin"});
    try testing.expectEqual(cli.CliError.UsageError, e);
}

// ------------------------------------------------- in: self-membership + swap recovery

test "in: rejects task == arc with a clear self-membership message (not the generic cycle text)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const x = mintId();
    try f.store.append(.{ .add = .{ .id = x, .title = "X" } });

    const e = f.runExpectErr(&.{ "in", &x.text, &x.text });
    try testing.expectEqual(cli.CliError.DependencyCycle, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "cannot be a member of itself") != null);
    try testing.expectEqual(@as(usize, 0), f.store.ins.items.len);
}

test "in: a swapped-argument mistake against an UNDECLARED target now fails outright (01KYTFRD7) — no unin needed" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc_id = mintId();
    const task_id = mintId();
    try f.store.append(.{ .add = .{ .id = arc_id, .title = "Arc" } });
    try f.store.append(.{ .add = .{ .id = task_id, .title = "Task" } });

    // The mistake: `trk in <arc> <task>` instead of `<task> <arc>`. Under the
    // OLD in-edge inference this silently minted task_id as a spurious arc;
    // now it is refused — task_id was never declared.
    const e = f.runExpectErr(&.{ "in", &arc_id.text, &task_id.text });
    try testing.expectEqual(cli.CliError.UndeclaredArc, e);
    try testing.expect(!f.store.isArc(task_id)); // never wrongly became an arc
    try testing.expectEqual(@as(usize, 0), f.store.ins.items.len); // no edge to recover from

    // Declaring the REAL arc first, then the correct edge, applies cleanly —
    // no `unin` recovery step needed for this shape.
    try f.run(&.{ "arc", &arc_id.text });
    try f.run(&.{ "in", &task_id.text, &arc_id.text });
    var found = false;
    for (f.store.ins.items) |ev| if (ev.task.eql(task_id) and ev.arc.eql(arc_id)) {
        found = true;
    };
    try testing.expect(found);
}

test "unin: still needed for a wrong-direction `in` BETWEEN TWO ALREADY-DECLARED arcs" {
    // The declared-arc gate closes the "mint a spurious arc" shape (above),
    // but not every swap: if BOTH ids already independently satisfy isArc
    // (legitimate nested-arc authoring), a swapped `trk in <B> <A>` instead
    // of `<A> <B>` still passes the gate and still writes the wrong-direction
    // edge — `unin` remains the general recovery mechanism for that case.
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const outer = mintId();
    const inner = mintId();
    try f.store.append(.{ .add = .{ .id = outer, .title = "Outer arc" } });
    try f.store.append(.{ .add = .{ .id = inner, .title = "Inner arc" } });
    try f.run(&.{ "arc", &outer.text });
    try f.run(&.{ "arc", &inner.text });

    // Intended: inner in outer. Mistake: outer in inner (swapped) — passes,
    // since both ids are declared arcs.
    try f.run(&.{ "in", &outer.text, &inner.text });
    var wrong_direction = false;
    for (f.store.ins.items) |ev| if (ev.task.eql(outer) and ev.arc.eql(inner)) {
        wrong_direction = true;
    };
    try testing.expect(wrong_direction);

    // Recovery: unin with the SAME (wrong-order) args, then the correct edge.
    try f.run(&.{ "unin", &outer.text, &inner.text });
    try testing.expectEqual(@as(usize, 0), f.store.ins.items.len);

    try f.run(&.{ "in", &inner.text, &outer.text });
    var found = false;
    for (f.store.ins.items) |ev| if (ev.task.eql(inner) and ev.arc.eql(outer)) {
        found = true;
    };
    try testing.expect(found);
}

// ----------------------------------------------------------- show --body

test "show --body prints the raw body verbatim: no header, no indent" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // A body that would be corrupted by de-indenting display output: blank
    // lines and lines that already start with spaces.
    const body = "line one\n  already indented\n\nlast";
    try f.run(&.{ "add", "Bodied", "--body", body });
    const id = try ulid.parse(f.out.items[0..ulid.len]);

    try f.run(&.{ "show", &id.text, "--body" });
    try testing.expectEqualStrings("line one\n  already indented\n\nlast\n", f.out.items);

    // The round-trip is lossless: `$(trk show <id> --body)` strips the trailing
    // newline, and re-editing with that value leaves the body unchanged.
    try f.run(&.{ "edit", &id.text, "--replace-body", body });
    try f.run(&.{ "show", &id.text, "--body" });
    try testing.expectEqualStrings("line one\n  already indented\n\nlast\n", f.out.items);
}

test "show --body on an empty body prints nothing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "add", "Empty" });
    const id = try ulid.parse(f.out.items[0..ulid.len]);
    try f.run(&.{ "show", &id.text, "--body" });
    try testing.expectEqualStrings("", f.out.items);
}

// ----------------------------------------------------------- doc unset

test "doc unset unregisters: resolve fails, list hides, re-set revives" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "doc", "set", "design", "docs/design.md" });
    try f.run(&.{ "doc", "resolve", "design" });
    try testing.expectEqualStrings("docs/design.md\n", f.out.items);

    try f.run(&.{ "doc", "unset", "design" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unregistered") != null);

    try testing.expectEqual(cli.CliError.NoSuchId, f.runExpectErr(&.{ "doc", "resolve", "design" }));
    try f.run(&.{ "doc", "list" });
    try testing.expectEqualStrings("(no doc paths registered)\n", f.out.items);

    // Idempotent: unsetting an unregistered id is a clean no-op.
    try f.run(&.{ "doc", "unset", "design" });

    // A later set revives the mapping (last-write-wins).
    try f.run(&.{ "doc", "set", "design", "docs/new.md" });
    try f.run(&.{ "doc", "resolve", "design" });
    try testing.expectEqualStrings("docs/new.md\n", f.out.items);
}

// ----------------------------------------------------------- arc declaration

test "trk arc declares a zero-member arc; --undo retracts it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Goal, no work yet" } });
    try testing.expect(!f.store.isArc(a));

    try f.run(&.{ "arc", &a.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "declared an arc") != null);
    try testing.expect(f.store.isArc(a));

    // It renders its own section even with zero members.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try f.c.renderMarkdown(&buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Goal, no work yet") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Arc-less") == null);

    try f.run(&.{ "arc", &a.text, "--undo" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "retracted") != null);
    try testing.expect(!f.store.isArc(a));

    // Unknown flag / usage errors.
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "arc", &a.text, "--bogus" }));
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{"arc"}));
}

test "trk arc --standing: declares in the same act, excludes from next, --standing --undo keeps the arc" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Housekeeping / held branches" } });
    try testing.expect(!f.store.isArc(a));
    try testing.expect(!f.store.isStanding(a));

    // --standing on a not-yet-declared task declares it AND marks standing.
    try f.run(&.{ "arc", &a.text, "--standing" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "declared an arc and marked standing") != null);
    try testing.expect(f.store.isArc(a));
    try testing.expect(f.store.isStanding(a));

    // A drained standing arc never surfaces in `next`.
    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Housekeeping") == null);

    // It still renders its own section (not "reading as unfinished" via a
    // stray Arc-less bullet, and not silently omitted either).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try f.c.renderMarkdown(&buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Housekeeping / held branches") != null);

    // --standing --undo clears JUST the standing mark; the arc declaration survives.
    try f.run(&.{ "arc", &a.text, "--standing", "--undo" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "standing mark retracted") != null);
    try testing.expect(f.store.isArc(a));
    try testing.expect(!f.store.isStanding(a));
    // Now a drained (still zero-member) arc surfaces as the ordinary close-out prompt.
    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Housekeeping") != null);

    // Re-mark standing, then retract the arc declaration outright: the
    // standing mark must not survive orphaned.
    try f.run(&.{ "arc", &a.text, "--standing" });
    try f.run(&.{ "arc", &a.text, "--undo" });
    try testing.expect(!f.store.isArc(a));
    try testing.expect(!f.store.isStanding(a));
}

test "trk add --arc declares the new task itself in one step" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "add", "Ship v2", "--arc" });
    const id = try ulid.parse(f.out.items[0..ulid.len]);
    try testing.expect(f.store.isArc(id));
    // --arc needs no other arc to exist -> no arc-less warning either.
    try testing.expectEqual(@as(usize, 0), f.warn.items.len);
}

test "trk add with neither --in nor --arc warns to stderr, NEVER pollutes stdout" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "add", "Orphan task" });
    // stdout (`out`) is EXACTLY the scriptable ULID + newline — the warning
    // must not have leaked in.
    try testing.expectEqual(@as(usize, ulid.len + 1), f.out.items.len);
    const id = try ulid.parse(f.out.items[0..ulid.len]);
    // The warning lands on the separate stderr-bound buffer instead, naming
    // the new task by its (short) id.
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "no arc") != null);
    var sb: [ulid.len]u8 = undefined;
    const short = try f.c.shortId(id, &sb);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, short) != null);

    // --in or --arc silences it.
    const arc = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.run(&.{ "add", "Sorted task", "--in", &arc.text });
    try testing.expectEqual(@as(usize, 0), f.warn.items.len);
}

test "config add.arcless = \"error\" refuses an arc-less add outright; no task minted" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var sub = try f.tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "config.json", .data = "{ \"add\": { \"arcless\": \"error\" } }", .flags = .{} });
    f.store.loadConfig();

    const before = f.store.count();
    const e = f.runExpectErr(&.{ "add", "Would be orphaned" });
    try testing.expectEqual(cli.CliError.NoArc, e);
    try testing.expectEqual(before, f.store.count()); // nothing minted
    try testing.expectEqual(@as(usize, 0), f.warn.items.len); // error path, not warn

    // --arc still succeeds under the same config.
    try f.run(&.{ "add", "Declared fine", "--arc" });
    try testing.expectEqual(before + 1, f.store.count());
}

test "trk add --tag arc: / trk edit --add-tag arc: warn to stderr but still write the tag" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "add", "Legacy-style", "--tag", "arc:legacy", "--arc" });
    const id = try ulid.parse(f.out.items[0..ulid.len]);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "DEPRECATED") != null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "trk arc") != null);
    try testing.expectEqualStrings("arc:legacy", f.store.get(id).?.tags.items[0]); // still written

    try f.run(&.{ "edit", &id.text, "--add-tag", "arc:other" });
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "DEPRECATED") != null);

    // A normal tag never triggers it.
    try f.run(&.{ "edit", &id.text, "--add-tag", "priority-1" });
    try testing.expectEqual(@as(usize, 0), f.warn.items.len);
}

test "trk list --no-arc: composes with --state/--tag, mutually exclusive with --arc" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const member = mintId();
    const orphan_open = mintId();
    const orphan_done = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .add = .{ .id = member, .title = "Member" } });
    try f.store.append(.{ .add = .{ .id = orphan_open, .title = "Orphan open", .tags = &.{"net"} } });
    try f.store.append(.{ .add = .{ .id = orphan_done, .title = "Orphan done" } });
    try f.store.append(.{ .setState = .{ .id = orphan_done, .state = .done } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 0 } });

    try f.run(&.{ "list", "--no-arc" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan open") != null);
    // Completed work is hidden by default now (01M2VPC6K) — `--all` is the union.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan done") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Member") == null);

    try f.run(&.{ "list", "--no-arc", "--all" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan done") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc") == null);

    // Composes with --state.
    try f.run(&.{ "list", "--no-arc", "--state", "open" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan done") == null);

    // Composes with --tag.
    try f.run(&.{ "list", "--no-arc", "--tag", "net" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Orphan done") == null);

    // Mutually exclusive with --arc.
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "list", "--no-arc", "--arc", &arc.text }));
}

test "render header: arc-less drift count matches actual arc-less remaining tasks" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var buf0: std.ArrayList(u8) = .empty;
    defer buf0.deinit(alloc);
    try f.c.renderMarkdown(&buf0);
    try testing.expect(std.mem.indexOf(u8, buf0.items, "Arc-less drift: 0 remaining task") != null);

    const arc = mintId();
    const member = mintId();
    const orphan = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .add = .{ .id = member, .title = "Member" } });
    try f.store.append(.{ .add = .{ .id = orphan, .title = "Orphan" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 0 } });

    var buf1: std.ArrayList(u8) = .empty;
    defer buf1.deinit(alloc);
    try f.c.renderMarkdown(&buf1);
    try testing.expect(std.mem.indexOf(u8, buf1.items, "Arc-less drift: 1 remaining task") != null);

    // A done arc-less task is finished, not drift — doesn't bump the count.
    try f.store.append(.{ .setState = .{ .id = orphan, .state = .done } });
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(alloc);
    try f.c.renderMarkdown(&buf2);
    try testing.expect(std.mem.indexOf(u8, buf2.items, "Arc-less drift: 0 remaining task") != null);
}

test "trk migrate-arcs converts arc: tags to declarations, strips the tag, is idempotent" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    const b = mintId();
    const plain = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "Legacy A", .tags = &.{ "arc:display", "keep-me" } } });
    try f.store.append(.{ .add = .{ .id = b, .title = "Legacy B", .tags = &.{"arc:net"} } });
    try f.store.append(.{ .add = .{ .id = plain, .title = "Plain", .tags = &.{"keep-me"} } });

    // Already an arc pre-migration, via the legacy tag back-compat path in
    // `isArc` — exactly why the migration exists (to move it off that path).
    try testing.expect(f.store.isArc(a));
    try testing.expect(!f.store.declared_arcs.contains(a.text)); // not YET a real declaration

    try f.run(&.{"migrate-arcs"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "2 task(s) migrated") != null);

    // Still an arc post-migration, but now via a REAL declaration — the tag
    // that used to carry it is gone (checked below), so this can't be the
    // legacy fallback path anymore.
    try testing.expect(f.store.isArc(a));
    try testing.expect(f.store.declared_arcs.contains(a.text));
    try testing.expect(f.store.isArc(b));
    // The legacy tag is stripped; an unrelated tag survives.
    const ta = f.store.get(a).?;
    try testing.expectEqual(@as(usize, 1), ta.tags.items.len);
    try testing.expectEqualStrings("keep-me", ta.tags.items[0]);
    // `plain` was never tagged arc: — untouched.
    try testing.expect(!f.store.isArc(plain));

    // Idempotent: a second run finds nothing (the tags are already gone).
    try f.run(&.{"migrate-arcs"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing to migrate") != null);
    // Declarations (and the survivor tag) are untouched by the no-op re-run.
    try testing.expect(f.store.isArc(a));
    try testing.expectEqualStrings("keep-me", f.store.get(a).?.tags.items[0]);

    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "migrate-arcs", "extra" }));
}

test "trk migrate-shorts rejects an unrecognized argument (it now optionally takes --min, so this is UnknownFlag, matching cmdArc/cmdIn's convention for a stray token)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "migrate-shorts", "extra" }));
}

// ----------------------------------------------------------- trk stale (git-log cross-reference)

/// Run a git command against `dir` (via the SAME `Cwd.dir` mechanism
/// `cmdStale` itself uses), asserting success. Frees stdout/stderr.
fn runGitOk(alloc: std.mem.Allocator, dir: std.Io.Dir, argv: []const []const u8) !void {
    const r = try std.process.run(alloc, io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.GitCommandFailed;
}

test "trk stale: finds open and leased tasks cited in a landed commit; excludes submitted and never-cited" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const cited_open = mintId();
    const cited_submitted = mintId();
    const cited_leased = mintId();
    const uncited_open = mintId();
    try f.store.append(.{ .add = .{ .id = cited_open, .title = "orphaned close" } });
    try f.store.append(.{ .add = .{ .id = cited_submitted, .title = "already submitted" } });
    try f.store.append(.{ .setState = .{ .id = cited_submitted, .state = .submitted } });
    try f.store.append(.{ .add = .{ .id = cited_leased, .title = "stranded lease" } });
    try f.store.append(.{ .setState = .{ .id = cited_leased, .state = .claimed, .holder = "lane-1" } });
    try f.store.append(.{ .add = .{ .id = uncited_open, .title = "never mentioned" } });

    var sb1: [ulid.len]u8 = undefined;
    const short1 = try alloc.dupe(u8, try f.c.shortId(cited_open, &sb1));
    defer alloc.free(short1);
    var sb2: [ulid.len]u8 = undefined;
    const short2 = try alloc.dupe(u8, try f.c.shortId(cited_submitted, &sb2));
    defer alloc.free(short2);
    var sb3: [ulid.len]u8 = undefined;
    const short3 = try alloc.dupe(u8, try f.c.shortId(cited_leased, &sb3));
    defer alloc.free(short3);

    // A real git repo rooted at the fixture's own tmpDir — the SAME dir
    // `cmdStale` resolves via `self.dir`, so this exercises the real spawn.
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "--allow-empty", "-m", "unrelated setup commit" });
    const msg1 = try std.fmt.allocPrint(alloc, "merge({s}): completes the orphaned close", .{short1});
    defer alloc.free(msg1);
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "--allow-empty", "-m", msg1 });
    const msg2 = try std.fmt.allocPrint(alloc, "feat({s}): work that was already submitted", .{short2});
    defer alloc.free(msg2);
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "--allow-empty", "-m", msg2 });
    const msg3 = try std.fmt.allocPrint(alloc, "merge({s}): lane merged without submitting", .{short3});
    defer alloc.free(msg3);
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "--allow-empty", "-m", msg3 });

    try f.run(&.{"stale"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "orphaned close") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[c] ") != null); // leased: included, marked
    try testing.expect(std.mem.indexOf(u8, f.out.items, "stranded lease") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "already submitted") == null); // submitted: excluded
    try testing.expect(std.mem.indexOf(u8, f.out.items, "never mentioned") == null); // never cited
    try testing.expect(std.mem.indexOf(u8, f.out.items, "2 open or claimed task(s)") != null);

    // Extra args rejected cleanly.
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "stale", "extra" }));
}

test "trk stale: reports nothing when no open task is cited" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "never mentioned anywhere" } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "--allow-empty", "-m", "totally unrelated" });

    try f.run(&.{"stale"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing") != null);
}

// ----- trk stale-rulings (01M31D03S) -----

test "trk stale-rulings: SABOTAGE PAIR -- flags a raiser unreconciled since its decision was ruled (the 01M2GTWS2 shape), clears once its BODY is touched after; a TITLE-only touch does NOT clear it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The raiser: an ordinary open task, never touched again after it raises.
    const raiser = mintId();
    try f.store.append(.{ .add = .{ .id = raiser, .title = "THROW THE SWITCH", .body = "what is still open is only the timing" } });

    // PAIRED NEGATIVE, wired first so it can't be the reason the positive
    // passes: an unrelated open task raising a decision that is NOT yet
    // ruled must never be flagged -- an open fork is not this check's business.
    const unrelated = mintId();
    try f.store.append(.{ .add = .{ .id = unrelated, .title = "unrelated carrier, fork still open" } });
    try f.run(&.{ "decision", "an unrelated, still-open fork", "--from", &unrelated.text });

    // Raise and rule the decision on `raiser` via the REAL `trk decision` +
    // `trk rule` sequence a session runs -- exercises cmdRule's actual
    // setBody+setState(done) pair rather than a hand-built fixture.
    try f.run(&.{ "decision", "throw when, and is the day-one loss acceptable?", "--from", &raiser.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    try f.run(&.{ "rule", &d.text, "RULED: when the work is done." });

    // RED: `raiser` has not touched its own body since -- exactly 01M2GTWS2's
    // shape. Reported AND a nonzero exit (error.StaleRulings), not just text;
    // the unrelated still-open fork's carrier must NOT appear.
    const e = f.runExpectErr(&.{"stale-rulings"});
    try testing.expectEqual(@as(anyerror, error.StaleRulings), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "THROW THE SWITCH") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 raiser task") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unrelated carrier") == null);

    // A TITLE-only touch is NOT enough to clear it -- the false-green this
    // check must avoid. Measured live: 01M2GTWS2's title WAS edited 23h after
    // its decision was ruled, and the carrier stayed unreconciled anyway (the
    // very failure 01M31D03S was filed over), so a title-inclusive form would
    // have missed the exact case that motivated this check.
    try f.run(&.{ "edit", &raiser.text, "--title", "THROW THE SWITCH (retitled, body untouched)" });
    const e2 = f.runExpectErr(&.{"stale-rulings"});
    try testing.expectEqual(@as(anyerror, error.StaleRulings), e2);

    // GREEN: an explicit BODY touch strictly after the ruling reconciles it.
    // The sleep guarantees a real clock gap -- `Store.append` stamps `ts` off
    // the wall clock, and two calls this close together can otherwise land in
    // the same millisecond, which this check's same-millisecond-still-stale
    // rule (see `cmdStaleRulings`) would then still flag.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real);
    try f.run(&.{ "edit", &raiser.text, "--append-body", "RECONCILED: ruled by the decision above -- thrown when the work is done, not on a date." });
    try f.run(&.{"stale-rulings"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing") != null);
}

test "trk stale-rulings: rejects an unknown flag; --json emits the structured fields; a later `archive` does not hide the ruling" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "stale-rulings", "--bogus" }));

    const raiser = mintId();
    try f.store.append(.{ .add = .{ .id = raiser, .title = "carrier", .body = "orig" } });
    try f.run(&.{ "decision", "a fork", "--from", &raiser.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    try f.run(&.{ "rule", &d.text, "RULED: x." });

    const e = f.runExpectErr(&.{ "stale-rulings", "--json" });
    try testing.expectEqual(@as(anyerror, error.StaleRulings), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"raiser\":") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"body_ts\":0") != null);

    // A ruled decision later graduating to `archived` (what `trk archive`
    // does) must not erase or move the ruled-at moment `scanRulingEvents`
    // recorded off the `setState -> done` event -- `archived` is a SECOND,
    // LATER transition on the same id, and the guard in `scanRulingEvents`
    // exists precisely so it can't overwrite the first.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real);
    try f.store.append(.{ .setState = .{ .id = d, .state = .archived } });
    const e2 = f.runExpectErr(&.{"stale-rulings"});
    try testing.expectEqual(@as(anyerror, error.StaleRulings), e2);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "carrier") != null);
}

// ----------------------------------------------------------- helpers

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
}

// --------------------------------------------- body edits name their direction (01M0QJ8K4)

test "edit --body is REMOVED: a hard error naming both replacements, body untouched" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t", .body = "precious" } });

    // Removal, not deprecation: honoring it with a warning would still destroy
    // the body while the warning scrolls past in an agent's tool output.
    const e = f.runExpectErr(&.{ "edit", &t.text, "--body", "clobber" });
    try testing.expectEqual(@as(anyerror, error.UnknownFlag), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--replace-body") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--append-body") != null);
    try testing.expectEqualStrings("precious", f.store.get(t).?.body);
}

test "edit --append-body: appends after a blank line, and never separates from an empty body" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const empty = mintId();
    try f.store.append(.{ .add = .{ .id = empty, .title = "e", .body = "" } });
    try f.run(&.{ "edit", &empty.text, "--append-body", "first note" });
    // No leading separator when there was nothing to separate from.
    try testing.expectEqualStrings("first note", f.store.get(empty).?.body);

    // Second append gets exactly one blank line between entries.
    try f.run(&.{ "edit", &empty.text, "--append-body", "second note" });
    try testing.expectEqualStrings("first note\n\nsecond note", f.store.get(empty).?.body);

    // Trailing newlines on the existing body are normalized to exactly one
    // blank line, not stacked on top of the separator.
    const messy = mintId();
    try f.store.append(.{ .add = .{ .id = messy, .title = "m", .body = "line\n\n\n" } });
    try f.run(&.{ "edit", &messy.text, "--append-body", "added" });
    try testing.expectEqualStrings("line\n\nadded", f.store.get(messy).?.body);
}

test "edit --append-body from two worktrees on one base: the union merge keeps BOTH appends (01M32AHNQ)" {
    const alloc = testing.allocator;
    var lane_a = try Fixture.init(alloc);
    defer lane_a.deinit();
    var lane_b = try Fixture.init(alloc);
    defer lane_b.deinit();
    var main = try Fixture.init(alloc);
    defer main.deinit();

    // The shared base both lanes fork from.
    const t = mintId();
    try lane_a.store.append(.{ .add = .{ .id = t, .title = "t", .body = "original filing" } });
    const base = try lane_a.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(base);
    try lane_b.tmp.dir.createDirPath(io, ".tracker");
    try lane_b.tmp.dir.writeFile(io, .{ .sub_path = ".tracker/log.jsonl", .data = base });
    try lane_b.reopen();

    // Each lane appends from its own frozen fold of that base.
    try lane_a.run(&.{ "edit", &t.text, "--append-body", "lane A: sub-task WAS built" });
    try lane_b.run(&.{ "edit", &t.text, "--append-body", "lane B: witness still owed" });

    // `merge=union` of the two logs: base once, then each side's new lines —
    // lane B's region first, the order that made lane A's text vanish.
    const log_a = try lane_a.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(log_a);
    const log_b = try lane_b.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(log_b);
    const merged = try std.mem.concat(alloc, u8, &.{ base, log_b[base.len..], log_a[base.len..] });
    defer alloc.free(merged);
    try main.tmp.dir.createDirPath(io, ".tracker");
    try main.tmp.dir.writeFile(io, .{ .sub_path = ".tracker/log.jsonl", .data = merged });
    try main.reopen();

    const body = main.store.get(t).?.body;
    try testing.expect(std.mem.startsWith(u8, body, "original filing\n\n"));
    try testing.expect(std.mem.indexOf(u8, body, "lane A: sub-task WAS built") != null);
    try testing.expect(std.mem.indexOf(u8, body, "lane B: witness still owed") != null);
}

test "lost-appends: names every append a whole-body write discarded, with its text (01M32AHNQ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The measured history, as the pre-fix `--append-body` wrote it: whole
    // bodies. Lane A appended to the filing; lane B appended to the same
    // filing (A's text gone); lane C appended to A's body (B's text gone).
    const t = mintId();
    const base = "original filing";
    const a_body = base ++ "\n\nA: sub-task WAS built";
    try f.store.append(.{ .add = .{ .id = t, .title = "clobbered", .body = base } });
    try f.store.append(.{ .setBody = .{ .id = t, .body = a_body } });
    try f.store.append(.{ .setBody = .{ .id = t, .body = base ++ "\n\nB: witness owed" } });
    try f.store.append(.{ .setBody = .{ .id = t, .body = a_body ++ "\n\nC: re-verified" } });

    // NEGATIVES that must stay silent: ordinary appends, a --replace-body
    // unrelated to any earlier body, and appends onto an EMPTY body.
    const quiet = mintId();
    try f.store.append(.{ .add = .{ .id = quiet, .title = "quiet", .body = "x" } });
    try f.store.append(.{ .setBody = .{ .id = quiet, .body = "x\n\ny" } });
    try f.store.append(.{ .setBody = .{ .id = quiet, .body = "rewritten from scratch" } });
    try f.store.append(.{ .appendBody = .{ .id = quiet, .text = "delta" } });
    const empty = mintId();
    try f.store.append(.{ .add = .{ .id = empty, .title = "empty" } });
    try f.store.append(.{ .setBody = .{ .id = empty, .body = "p" } });
    try f.store.append(.{ .setBody = .{ .id = empty, .body = "q" } });

    try testing.expectEqual(@as(anyerror, error.LostAppends), f.runExpectErr(&.{"lost-appends"}));
    // Only B's text is lost TODAY: C's write carried A's back.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 append(s)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "| B: witness owed") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "A: sub-task") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "quiet") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "empty") == null);

    try testing.expectEqual(@as(anyerror, error.LostAppends), f.runExpectErr(&.{ "lost-appends", "--json" }));
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        const rows = parsed.value.array.items;
        try testing.expectEqual(@as(usize, 1), rows.len);
        try testing.expectEqualStrings(&t.text, rows[0].object.get("id").?.string);
        try testing.expectEqualStrings("B: witness owed", rows[0].object.get("text").?.string);
        try testing.expect(rows[0].object.get("lost_ts").?.integer < rows[0].object.get("clobber_ts").?.integer);
    }

    // Putting the text back is the remedy, and clears the report.
    try f.run(&.{ "edit", &t.text, "--append-body", "B: witness owed" });
    try f.run(&.{"lost-appends"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing") != null);
}

test "edit --append-body reads a body that lives ONLY in the snapshot (the truncation this verb exists to stop)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t", .body = "original diagnosis" } });
    try f.store.append(.{ .setState = .{ .id = t, .state = .open } });

    // Compact moves the body into snapshot.jsonl and TRUNCATES the log. An
    // external helper scanning only log.jsonl for the last setBody now sees
    // NOTHING and reports "0 existing chars" — which is exactly how a
    // hand-built read-modify-write destroyed two real task bodies.
    try f.run(&.{"compact"});
    const log = try f.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "original diagnosis") == null);

    // trk reads its own fold, so the append keeps the pre-compact text.
    try f.run(&.{ "edit", &t.text, "--append-body", "2026-08-23: reproduced" });
    try testing.expectEqualStrings(
        "original diagnosis\n\n2026-08-23: reproduced",
        f.store.get(t).?.body,
    );

    // And it survives an on-disk reopen, so the merged text is what was written.
    var reopened = Store.open(alloc, io, f.tmp.dir);
    defer reopened.deinit();
    try reopened.load();
    try testing.expectEqualStrings(
        "original diagnosis\n\n2026-08-23: reproduced",
        reopened.get(t).?.body,
    );
}

test "edit --replace-body warns on a byte-identical write; --append-body never does" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t", .body = "same text" } });

    // The 2026-08-21 case: the write "succeeds" and adds nothing, and the
    // silence is what let the task be re-worked twice.
    try f.run(&.{ "edit", &t.text, "--replace-body", "same text" });
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "BYTE-IDENTICAL") != null);

    // A genuine change is silent.
    try f.run(&.{ "edit", &t.text, "--replace-body", "different text" });
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "BYTE-IDENTICAL") == null);

    // Scoped to --replace-body ONLY: an append that produces no change is a
    // different and far less interesting event, so warning there is noise.
    try f.run(&.{ "edit", &t.text, "--append-body", "" });
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "BYTE-IDENTICAL") == null);
}

test "edit: --replace-body and --append-body together is a usage error" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t", .body = "orig" } });

    const e = f.runExpectErr(&.{ "edit", &t.text, "--replace-body", "a", "--append-body", "b" });
    try testing.expectEqual(@as(anyerror, error.UsageError), e);
    try testing.expectEqualStrings("orig", f.store.get(t).?.body);
}

// --------------------------------------------- --rm-doc, the missing inverse (01M0QK1C4)

test "edit --rm-doc: removes a doc-ref, clears every section ref, and says so when absent" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t" } });

    // The originating symptom: a typo'd doc id was permanent short of hand
    // editing .tracker/, which every consuming runbook forbids.
    try f.run(&.{ "edit", &t.text, "--add-doc", "design", "--add-doc", "none" });
    try testing.expectEqual(@as(usize, 2), f.store.get(t).?.docrefs.items.len);

    try f.run(&.{ "edit", &t.text, "--rm-doc", "none" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "-doc none") != null);
    const refs = f.store.get(t).?.docrefs.items;
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("design", refs[0].doc_id);

    // Idempotent like --rm-tag, but never silently reports a removal that did
    // not happen — a silent success on a typo reads as "removed" when nothing was.
    try f.run(&.{ "edit", &t.text, "--rm-doc", "none" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no such ref") != null);

    // One --rm-doc clears every section ref to that doc; a `#section` suffix on
    // the flag is accepted and ignored, so it round-trips an --add-doc value.
    try f.run(&.{ "edit", &t.text, "--add-doc", "spec#one", "--add-doc", "spec#two" });
    try testing.expectEqual(@as(usize, 3), f.store.get(t).?.docrefs.items.len);
    try f.run(&.{ "edit", &t.text, "--rm-doc", "spec#one" });
    const left = f.store.get(t).?.docrefs.items;
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("design", left[0].doc_id);
}

test "rule: SABOTAGE PAIR -- records the ruling and CLOSES a decision; refuses (untouched) on a non-decision (01M2VFV83)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // POSITIVE half: a genuinely pending fork, with work waiting on it.
    const work = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "the display fix" } });
    const pending = mintId();
    try f.store.append(.{ .add = .{ .id = pending, .title = "fork", .body = "(a) or (b)?" } });
    try f.store.append(.{ .decisionDeclare = .{ .id = pending, .declared = true } });
    try f.store.append(.{ .tag = .{ .id = pending, .tag = "net" } });
    try f.store.append(.{ .dep = .{ .from = work, .to = pending } });

    try f.run(&.{ "rule", &pending.text, "RULED: (a), see design.md" });
    const p = f.store.get(pending).?;
    try testing.expectEqualStrings("(a) or (b)?\n\nRULED: (a), see design.md", p.body);
    // CLOSING is the point: `done` satisfies a prereq, so the work waiting on
    // this fork is released by the ruling itself, with no second command.
    try testing.expectEqual(tracker.State.done, p.state);
    try testing.expect(f.store.get(work).?.state.satisfiesPrereq() == false);
    // And it says what it released, so nobody has to go looking.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unblocks 1 task") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the display fix") != null);

    // DECLARATION IS NATURE: ruling must never clear it. If it did, the
    // answered question would become an ordinary open task and `next` would
    // hand it out as work to go build.
    try testing.expect(f.store.isDecision(pending));
    // Unrelated tags survive untouched.
    var kept_net = false;
    for (p.tags.items) |tg| {
        if (std.mem.eql(u8, tg, "net")) kept_net = true;
    }
    try testing.expect(kept_net);

    // PAIRED NEGATIVE half: ordinary work is refused outright, body untouched.
    // `rule` closes its target, so using it on a non-decision would close real
    // work on the strength of a note.
    const ordinary = mintId();
    try f.store.append(.{ .add = .{ .id = ordinary, .title = "unrelated", .body = "security note" } });

    const e = f.runExpectErr(&.{ "rule", &ordinary.text, "RULED: nope" });
    try testing.expectEqual(@as(anyerror, error.UsageError), e);
    const u = f.store.get(ordinary).?;
    try testing.expectEqualStrings("security note", u.body);
    try testing.expectEqual(tracker.State.open, u.state);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "is not a decision") != null);

    // An ALREADY-ruled decision is refused too, rather than appended to
    // silently -- a second ruling on a settled fork is a mistake, not an edit.
    const e2 = f.runExpectErr(&.{ "rule", &pending.text, "RULED: actually (b)" });
    try testing.expectEqual(@as(anyerror, error.UsageError), e2);
    try testing.expectEqualStrings("(a) or (b)?\n\nRULED: (a), see design.md", f.store.get(pending).?.body);

    // A SECOND decision is untouched by ruling the first.
    const other = mintId();
    try f.store.append(.{ .add = .{ .id = other, .title = "other fork" } });
    try f.store.append(.{ .decisionDeclare = .{ .id = other, .declared = true } });
    try testing.expectEqual(tracker.State.open, f.store.get(other).?.state);
}

test "rule: too few or too many positional args is a usage error, task untouched" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t", .body = "orig" } });
    try f.store.append(.{ .tag = .{ .id = t, .tag = "scott-decision" } });

    try testing.expectEqual(@as(anyerror, error.MissingArgument), f.runExpectErr(&.{"rule"}));
    try testing.expectEqual(@as(anyerror, error.MissingArgument), f.runExpectErr(&.{ "rule", &t.text }));
    try testing.expectEqual(
        @as(anyerror, error.UsageError),
        f.runExpectErr(&.{ "rule", &t.text, "RULED: a", "extra" }),
    );
    try testing.expectEqualStrings("orig", f.store.get(t).?.body);
    try testing.expectEqual(@as(usize, 1), f.store.get(t).?.tags.items.len);
}

test "rule: `-` reads the ruling from stdin, same as --append-body" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t" } });
    try f.store.append(.{ .decisionDeclare = .{ .id = t, .declared = true } });

    try f.tmp.dir.writeFile(io, .{ .sub_path = "ruling.txt", .data = "RULED: piped\n" });
    const stdin_file = try f.tmp.dir.openFile(io, "ruling.txt", .{});
    defer stdin_file.close(io);
    f.c.stdin = stdin_file;

    try f.run(&.{ "rule", &t.text, "-" });
    try testing.expectEqualStrings("RULED: piped", f.store.get(t).?.body);
    try testing.expectEqual(tracker.State.done, f.store.get(t).?.state);
}

// DELETED with the tag-based `rule` (01M2VFV83) and the `rule.tag` config key
// itself (01M2VFX25): `rule` no longer looks for or removes any tag, so there is
// nothing for the knob to override. The legacy tag a repo used is now an
// argument to `trk migrate-decisions --from-tag`, so trk ships no name for it
// and stores none.

test "undocref survives a reopen and a compact (it is a real event, not a display filter)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const t = mintId();
    try f.store.append(.{ .add = .{ .id = t, .title = "t" } });
    try f.run(&.{ "edit", &t.text, "--add-doc", "bad" });
    try f.run(&.{ "edit", &t.text, "--rm-doc", "bad" });

    {
        var reopened = Store.open(alloc, io, f.tmp.dir);
        defer reopened.deinit();
        try reopened.load();
        try testing.expectEqual(@as(usize, 0), reopened.get(t).?.docrefs.items.len);
    }

    // compact GCs the removal for free: serializeState simply never emits a ref
    // that is no longer there, so the tombstone costs nothing long-term.
    try f.run(&.{"compact"});
    var after = Store.open(alloc, io, f.tmp.dir);
    defer after.deinit();
    try after.load();
    try testing.expectEqual(@as(usize, 0), after.get(t).?.docrefs.items.len);
    const snap = try f.tmp.dir.readFileAlloc(io, ".tracker/snapshot.jsonl", alloc, .unlimited);
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "undocref") == null);
}

// --------------------------------------------- dep/undep name the direction (01M0QKHWQ)

test "dep/undep: the bare two-positional form is a hard error naming the fix" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const a = mintId();
    const b = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "B" } });

    // Tolerating the legacy spelling would keep the exact footgun: two bare
    // positionals of the same type, whose swap wires a VALID backwards edge.
    const e = f.runExpectErr(&.{ "dep", &a.text, &b.text });
    try testing.expectEqual(@as(anyerror, error.UsageError), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--needs") != null);
    try testing.expectEqual(@as(usize, 0), f.store.needs.items.len);

    const e2 = f.runExpectErr(&.{ "undep", &a.text, &b.text });
    try testing.expectEqual(@as(anyerror, error.UsageError), e2);

    // A lone positional is a usage error too, not a silent no-op.
    const e3 = f.runExpectErr(&.{ "dep", &a.text });
    try testing.expectEqual(@as(anyerror, error.MissingArgument), e3);
}

test "dep <id> --needs <id>: wires the edge, repeats, and undep undoes it in the same shape" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const needer = mintId();
    const p1 = mintId();
    const p2 = mintId();
    for ([_]Ulid{ needer, p1, p2 }) |id|
        try f.store.append(.{ .add = .{ .id = id, .title = "t" } });

    // Repeats allowed for the same reason `trk add --needs` allows them.
    try f.run(&.{ "dep", &needer.text, "--needs", &p1.text, "--needs", &p2.text });
    try testing.expectEqual(@as(usize, 2), f.store.needs.items.len);
    for (f.store.needs.items) |e| try testing.expect(e.from.eql(needer));

    // Same sentence, one verb changed.
    try f.run(&.{ "undep", &needer.text, "--needs", &p1.text });
    try testing.expectEqual(@as(usize, 1), f.store.needs.items.len);
    try testing.expect(f.store.needs.items[0].to.eql(p2));
}

// DELETED: archive's decision guard (01M2VFX25). The guard, its two override
// flags, the hit-set digest protocol and every arm asserting them are gone with
// the mechanism they protected — a fork is now its own node, so archiving the
// task that raised it cannot bury it, and there is nothing left for a body scan
// to defend. What the scan could still find (prose written before decisions
// existed) moved to `trk migrate-decisions` as a one-shot finder, and is tested
// there. The id-shape refusal below SURVIVES: its original occasion was a second
// id typed after --allow-buried-decisions-for, but `archive`'s positional is a
// SEARCH TERM, so a bare id there still matches nothing and reports an empty run.

// -------------------------- 01M13JXWS: the id-shape refusal must not eat English

test "archive: 9+ letter English words are search terms, not ids -- the id refusal only fires on a digit-leading token" {
    // Crockford base32 excludes only I/L/O/U, so ordinary English words of 9+
    // letters all satisfy the alphabet test. Before the leading-digit gate,
    // every word below hard-errored with "looks like a task id, not a search
    // word" on archive's ONLY search surface.
    const words = [_][]const u8{
        "statement", "namespace",  "webserver",  "watermark",
        "regressed", "parameters", "assessment", "management",
    };
    for (words) |w| {
        const alloc = testing.allocator;
        var f = try Fixture.init(alloc);
        defer f.deinit();

        const a = mintId();
        try f.store.append(.{ .add = .{ .id = a, .title = "unrelated", .body = "plain" } });
        try f.store.append(.{ .setState = .{ .id = a, .state = .done } });

        // `try` IS the assertion: a UsageError here is the bug.
        try f.run(&.{ "archive", w });
        // ...and it was taken as a SEARCH term, not ignored: nothing matched,
        // so the done task is untouched.
        try testing.expect(std.mem.indexOf(u8, f.out.items, "(no done tasks to archive)") != null);
        try testing.expectEqual(tracker.State.done, f.store.get(a).?.state);
    }
}

test "archive: an id-shaped English word still FILTERS, while a real task id in the same slot is still a hard error" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const hit = mintId();
    try f.store.append(.{ .add = .{ .id = hit, .title = "namespace collision in the render projection", .body = "done" } });
    const miss = mintId();
    try f.store.append(.{ .add = .{ .id = miss, .title = "unrelated", .body = "done" } });
    try f.store.append(.{ .setState = .{ .id = hit, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = miss, .state = .done } });

    var sb: [ulid.len]u8 = undefined;
    const miss_s = try f.c.shortId(miss, &sb);

    // EXCLUDES correctly: a digit-leading id in the positional slot is still
    // refused outright -- the finding-7 guarantee is not weakened by the gate.
    {
        const e = f.runExpectErr(&.{ "archive", miss_s });
        try testing.expectEqual(@as(anyerror, error.UsageError), e);
        try testing.expectEqual(tracker.State.done, f.store.get(hit).?.state);
        try testing.expectEqual(tracker.State.done, f.store.get(miss).?.state);
    }
    // INCLUDES correctly: the word narrows the run to the one task it matches.
    {
        try f.run(&.{ "archive", "namespace" });
        try testing.expectEqual(tracker.State.archived, f.store.get(hit).?.state);
        try testing.expectEqual(tracker.State.done, f.store.get(miss).?.state);
    }
}

// ----------------------------------------------------------- compacted-id resolution (01M2M2K1J)
//
// The defect these close: `compact` is the only thing that destroys an id, and
// afterwards `trk show` answered "no task matches" — the SAME words it gives an
// id that never existed. Every arm below is therefore PAIRED: whatever proves a
// compacted id now resolves sits beside a proof that a genuinely unknown id
// still does not, or the "fix" is just a lookup that says yes to everything.

/// A full-length, well-formed ULID that no fixture ever mints: all-Z after the
/// leading `01`, so it cannot collide with `mintId`'s stream. The NEGATIVE half
/// of every arm below — the id that must keep reporting missing.
const never_id = "01ZZZZZZZZZZZZZZZZZZZZZZZZ";

test "show: a COMPACTED id resolves as COMPACTED — a live one stays live and an unknown one stays missing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const live = mintId();
    // Minted far from the others in TIME on purpose: a ULID's first 10
    // characters are its millisecond stamp, so two ids minted a millisecond
    // apart share a 9-char prefix. A short prefix of a task minted next to the
    // live ones would be ambiguous against the LIVE set and never reach the
    // tombstone lookup at all — the arm would pass for the wrong reason.
    const gone = ulid.mintAt(io, 5_000_001);
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc root" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = gone, .title = "graduated work", .short = gone.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = gone, .arc = arc } });
    try f.store.append(.{ .add = .{ .id = live, .title = "still open" } });
    // `archived` is what `trk archive` leaves behind, and what compact collects.
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });

    try f.run(&.{"compact"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "entombed") != null);
    try f.reopen();

    // The task really is GONE from the live store — otherwise the arm below
    // would be resolving a live task and proving nothing.
    try testing.expect(f.store.get(gone) == null);

    // POSITIVE: the compacted id resolves, by its frozen SHORT id (the shape
    // citations actually use), and says COMPACTED.
    const short = gone.text[0..9];
    const e = f.runExpectErr(&.{ "show", short });
    try testing.expectEqual(@as(anyerror, error.CompactedId), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "graduated work") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "archived") != null);
    // The arc it belonged to is on the record — the membership edge compact
    // deleted along with the task.
    try testing.expect(std.mem.indexOf(u8, f.out.items, &arc.text) != null);
    // And it must not read as a live task at a glance.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "prereqs (needs)") == null);

    // Same answer by full id and by a bare prefix of it.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", &gone.text }));
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", gone.text[0..12] }));

    // NEGATIVE 1: an id that was never real is STILL missing. Without this the
    // arm above would pass just as well on a lookup that says yes to anything.
    const miss = f.runExpectErr(&.{ "show", never_id });
    try testing.expectEqual(@as(anyerror, error.NoSuchId), miss);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);

    // NEGATIVE 2: a LIVE task is untouched — no tombstone, no COMPACTED banner.
    try f.run(&.{ "show", &live.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "still open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "prereqs (needs)") != null);
}

test "compact entombs ONLY what it collects — a live task never gets a tombstone" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const live = mintId();
    const archived = mintId();
    const dropped = mintId();
    const ghost = mintId();
    try f.store.append(.{ .add = .{ .id = live, .title = "live" } });
    try f.store.append(.{ .add = .{ .id = archived, .title = "archived one" } });
    try f.store.append(.{ .add = .{ .id = dropped, .title = "dropped one" } });
    try f.store.append(.{ .setState = .{ .id = archived, .state = .archived } });
    try f.store.append(.{ .setState = .{ .id = dropped, .state = .dropped } });
    // An id with events but no `add` anywhere: a ghost, the third collectable
    // class. Its `open` state is a default, not a judgment — so the record must
    // say "ghost", never "open".
    try f.store.append(.{ .setBody = .{ .id = ghost, .body = "orphan" } });

    try f.run(&.{"compact"});
    try f.reopen();

    try testing.expectEqual(@as(usize, 3), f.store.tombstones.items.len);
    // The one that matters: the LIVE task must not be in the index. A tombstone
    // for a live id would make `show` report a live task as gone — the same
    // class of wrong verdict, pointing the other way.
    try testing.expect(f.store.lookupTombstone(&live.text) == .none);

    switch (f.store.lookupTombstone(&archived.text)) {
        .one => |tb| try testing.expectEqualStrings("archived", tb.reason),
        else => return error.TestExpectedTombstone,
    }
    switch (f.store.lookupTombstone(&dropped.text)) {
        .one => |tb| try testing.expectEqualStrings("dropped", tb.reason),
        else => return error.TestExpectedTombstone,
    }
    switch (f.store.lookupTombstone(&ghost.text)) {
        .one => |tb| try testing.expectEqualStrings("ghost", tb.reason),
        else => return error.TestExpectedTombstone,
    }
    try testing.expect(f.store.lookupTombstone(never_id) == .none);

    // The listing verb reports the same three, and only those.
    try f.run(&.{"tombstones"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "3 compacted task(s)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, &live.text) == null);
}

test "show --json/--body on a compacted id: a machine-readable flag, and an EMPTY stdout for the pipe" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gone = mintId();
    const live = mintId();
    try f.store.append(.{ .add = .{ .id = gone, .title = "graduated", .body = "a real body" } });
    try f.store.append(.{ .add = .{ .id = live, .title = "kept", .body = "live body" } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });
    try f.run(&.{"compact"});
    try f.reopen();

    // POSITIVE: --json carries a key the live view never emits.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", &gone.text, "--json" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"compacted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "graduated") != null);
    // NEGATIVE: a live task's --json must NOT carry it, or the flag is noise.
    try f.run(&.{ "show", &live.text, "--json" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted") == null);

    // POSITIVE: `--body` is the read half of `... | trk edit --replace-body -`.
    // A tombstone has no body, so stdout stays EMPTY (which that flag refuses)
    // and the explanation goes to stderr — never plausible body bytes.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", &gone.text, "--body" }));
    try testing.expectEqual(@as(usize, 0), f.out.items.len);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "COMPACTED") != null);
    // NEGATIVE: a live task's --body still emits its bytes, on stdout.
    try f.run(&.{ "show", &live.text, "--body" });
    try testing.expectEqualStrings("live body\n", f.out.items);
}

test "show: a prefix matching two COMPACTED ids is ambiguous, not silently one of them" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Two ids one millisecond apart share their first 9 timestamp characters.
    const a = ulid.mintAt(io, 3_000_001);
    const b = ulid.mintAt(io, 3_000_002);
    try f.store.append(.{ .add = .{ .id = a, .title = "first gone" } });
    try f.store.append(.{ .add = .{ .id = b, .title = "second gone" } });
    try f.store.append(.{ .setState = .{ .id = a, .state = .archived } });
    try f.store.append(.{ .setState = .{ .id = b, .state = .archived } });
    try f.run(&.{"compact"});
    try f.reopen();

    const shared = a.text[0..9];
    try testing.expectEqualStrings(shared, b.text[0..9]); // the premise, asserted
    const e = f.runExpectErr(&.{ "show", shared });
    try testing.expectEqual(@as(anyerror, error.AmbiguousId), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "first gone") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "second gone") != null);

    // The unambiguous halves still resolve to the right record.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", &a.text }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "first gone") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "second gone") == null);
}

test "tombstones --rebuild: recovers an id compacted BEFORE the index existed, and only a real one" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gone = mintId();
    const live = mintId();
    try f.store.append(.{ .add = .{ .id = gone, .title = "pre-index work", .short = gone.text[0..9] } });
    try f.store.append(.{ .add = .{ .id = live, .title = "kept" } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });

    // A real repo at the store root, with the log COMMITTED — the only place a
    // compacted id survives once the working tree no longer has it.
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    try f.run(&.{"compact"});
    try f.reopen();

    // Simulate the PRE-INDEX era: the compact happened, but no tombstone was
    // ever written for it. That is the state every already-compacted id in a
    // real repo is in, and it is this test's own RED baseline — asserted, not
    // assumed, one line below.
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);
    try testing.expectEqual(@as(anyerror, error.NoSuchId), f.runExpectErr(&.{ "show", &gone.text }));

    // The recovery.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 new tombstone(s) recorded") != null);

    // POSITIVE: the same citation that reported missing one call ago now
    // resolves, with the title recovered out of the history.
    const e = f.runExpectErr(&.{ "show", &gone.text });
    try testing.expectEqual(@as(anyerror, error.CompactedId), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "pre-index work") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "git-history") != null);
    // The state at the end of its life, not the state it was born in.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "archived") != null);

    // NEGATIVE 1: a never-existed id is NOT recovered — a history scan that
    // resolved anything id-shaped would be worse than no scan at all.
    try testing.expectEqual(@as(anyerror, error.NoSuchId), f.runExpectErr(&.{ "show", never_id }));
    // NEGATIVE 2: the LIVE task was in that same history and must NOT have been
    // entombed — a tombstone for it would make `show` call a live task gone.
    try testing.expectEqual(@as(usize, 1), f.store.tombstones.items.len);
    try testing.expect(f.store.lookupTombstone(&live.text) == .none);
    try f.run(&.{ "show", &live.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);

    // Idempotent: a second run records nothing new.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 new tombstone(s) recorded") != null);
}

test "tombstones --rebuild warns on an unpinned .gitattributes too (01M2N0QW2) — it can be the FIRST write to tombstones.jsonl, before any compact ever runs" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gone = mintId();
    try f.store.append(.{ .add = .{ .id = gone, .title = "pre-index work", .short = gone.text[0..9] } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    try f.run(&.{"compact"});
    try f.reopen();
    // This store has never had a tombstones.jsonl at all — `--rebuild` below
    // is its first-ever write to that file, and there is deliberately NO
    // .tracker/.gitattributes on disk (the Fixture scaffolds the store
    // directly, without going through `init`).
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);

    f.warn.clearRetainingCapacity();
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 new tombstone(s) recorded") != null);
    try testing.expect(std.mem.indexOf(u8, f.warn.items, ".gitattributes is absent") != null);

    // Pin it, and the warning goes silent on the next rebuild — proves the
    // check is live (not a permanent nag) and that `--rebuild` itself is the
    // call site being exercised, not some other command run in between.
    try f.tmp.dir.writeFile(io, .{
        .sub_path = ".tracker/.gitattributes",
        .data = tracker.store.gitattributes_text,
        .flags = .{},
    });
    f.warn.clearRetainingCapacity();
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.warn.items, ".gitattributes") == null);
}

test "tombstones --rebuild: recovers a GHOST whose full committed history is setBody+dep only — no add/setTitle/setShort/setState anywhere (01M2N8WMD's exact shape)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // `gone` is NEVER `add`ed — only referenced by a `setBody` and a `dep`
    // edge to `live`. This is `compact`'s own "ghost" class (`!t.has_add`,
    // `isCollectable` unconditionally), and it is the real shape of
    // 01KVR2E1KTXC65HD5175N373AH's committed history, confirmed by a direct
    // `git log --all -p` read of the Enix tracker (01M2N8WMD): no naming
    // event ever landed for it, only a body and an edge.
    const gone = mintId();
    const live = mintId();
    try f.store.append(.{ .add = .{ .id = live, .title = "kept" } });
    try f.store.append(.{ .setBody = .{ .id = gone, .body = "ghost's only recoverable content" } });
    try f.store.append(.{ .dep = .{ .from = gone, .to = live } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    // `compact` collects `gone` as a ghost (has_add=false) regardless of
    // state, and — under TODAY's code — would entomb it with reason "ghost"
    // (verified live by the sibling test above this one). We are about to
    // ERASE that entombment to simulate the pre-index era, so this run's own
    // "ghost" classification is not what --rebuild has to work with below.
    try f.run(&.{"compact"});
    try f.reopen();

    // Simulate the PRE-INDEX era, exactly as the sibling test above does:
    // the compact happened, but (as it would have before 01M2M2K1J) no
    // tombstone survives for it. RED baseline, asserted not assumed.
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);
    try testing.expectEqual(@as(anyerror, error.NoSuchId), f.runExpectErr(&.{ "show", &gone.text }));

    // The recovery: a ghost's committed history holds no add/setTitle/
    // setShort/setState event, so the narrow op-switch that predates this fix
    // would build no `recs` entry for it at all and `--rebuild` would report
    // it recovered nothing. With `model.eventTaskIds` seeding an entry from
    // the `setBody`/`dep` events themselves, it is found.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 new tombstone(s) recorded") != null);

    // POSITIVE: resolves as COMPACTED. Reason is "unknown", not "ghost" — the
    // git-history scan can only recover what a NAMING event says, and this
    // id's history holds none (its `--rebuild`-time original "ghost" verdict
    // from `compact` was the very tombstone line this test erased above to
    // simulate the pre-index era, so it is not available here either — the
    // real-world case, 01KVR2E1KTXC65HD5175N373AH, is in exactly this state
    // permanently, its `compact` having predated the index outright). Title
    // "(not recorded)" for the same reason: a `setBody` is not title-bearing.
    const e = f.runExpectErr(&.{ "show", &gone.text });
    try testing.expectEqual(@as(anyerror, error.CompactedId), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unknown") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "(not recorded)") != null);

    // The live edge target is untouched.
    try testing.expectEqual(@as(usize, 1), f.store.tombstones.items.len);
    try testing.expect(f.store.lookupTombstone(&live.text) == .none);

    // Idempotent.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 new tombstone(s) recorded") != null);
}

test "tombstones --verify: FAILS naming the gap while the index is incomplete, PASSES once --rebuild closes it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gone = mintId();
    const live = mintId();
    try f.store.append(.{ .add = .{ .id = live, .title = "kept" } });
    try f.store.append(.{ .setBody = .{ .id = gone, .body = "ghost body" } });
    try f.store.append(.{ .dep = .{ .from = gone, .to = live } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    try f.run(&.{"compact"});
    try f.reopen();
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();

    // POSITIVE (of the gap): the index is genuinely incomplete (the ghost is
    // gone from the live store and entombed nowhere) — `--verify` must FAIL
    // and name it, never report a bare "OK" over a gap it didn't look for.
    const e = f.runExpectErr(&.{ "tombstones", "--verify" });
    try testing.expectEqual(@as(anyerror, error.TombstoneIndexIncomplete), e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "verify FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, &gone.text) != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "unknown") != null);
    // NEGATIVE (paired): the LIVE edge target must never be reported as a
    // gap — it is still in the live store, so it is not what "neither live
    // nor entombed" means, and flagging it would be exactly the false
    // "dangling" verdict 01M2N6RQJ's incident was about, just moved to a new
    // command.
    try testing.expect(std.mem.indexOf(u8, f.out.items, &live.text) == null);
    // It must NEVER write — a verify that also repairs stops being a check
    // that can fail.
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);

    // POSITIVE: once `--rebuild` closes the gap, `--verify` passes clean.
    try f.run(&.{ "tombstones", "--rebuild" });
    try f.run(&.{ "tombstones", "--verify" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "verify OK") != null);
}

test "a REFUSED compact restores the tombstone index too — no tombstone for a task that is still live" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const keep = mintId();
    const gone = mintId();
    try f.store.append(.{ .add = .{ .id = keep, .title = "Keep", .body = "keep's real body" } });
    try f.store.append(.{ .add = .{ .id = gone, .title = "Gone" } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });

    // Sabotage the round-trip self-verify: the compact is REFUSED and the
    // pre-compact files restored. The tombstone for `gone` was already written
    // by then (it is durable BEFORE the destructive rewrite), so if it is not
    // rolled back with the rest, the store is left claiming a task is compacted
    // while it is still live and still archivable.
    f.store.test_sabotage_body = .{ .id = keep, .replacement = "CORRUPTED" };
    try testing.expectEqual(@as(anyerror, error.CompactVerifyFailed), f.runExpectErr(&.{"compact"}));

    try f.reopen();
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);
    try testing.expect(f.store.get(gone) != null); // still live, as the refusal promises
    // ...and `show` still answers as a LIVE task, not as a compacted one.
    try f.run(&.{ "show", &gone.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);

    // The POSITIVE half: with the sabotage cleared, the same compact DOES
    // entomb it — so the arm above measures the rollback, not a write path that
    // never fires in the first place.
    f.store.test_sabotage_body = null;
    try f.run(&.{"compact"});
    try f.reopen();
    try testing.expectEqual(@as(usize, 1), f.store.tombstones.items.len);
    try testing.expect(f.store.lookupTombstone(&gone.text) == .one);
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "show", &gone.text }));
}

// --------------------------------------------- tree: graduated arc members
//
// 01M29P5T7. The measured incident: `trk tree <arc>` on an arc whose members
// had all been archived + compacted printed a well-formed one-line tree, which
// is exactly what a never-sliced arc prints — and a lane was dispatched to
// "design and slice" work that had already shipped. `show` on a collected id
// at least said something distinctive; `tree` said something NORMAL.
//
// Every test below is paired on purpose. Making absence speak is only a fix if
// PRESENCE still reads as presence: an arc with graduated members must show
// them, AND an arc that genuinely has none must still render as genuinely
// empty. A change satisfying only the first half would swap one
// indistinguishable pair for another, pointing the other way.

test "tree: an arc whose members were compacted reports them — one with none stays genuinely empty" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Built-and-graduated arc: one live member, two collected ones.
    const built = mintId();
    const still_open = mintId();
    const d1 = ulid.mintAt(io, 6_000_001);
    const d2 = ulid.mintAt(io, 6_500_001);
    // Never-sliced arc, and an arc with a live member only. Both are the
    // negative half: neither may grow a compacted-members block.
    const bare = mintId();
    const live_only = mintId();
    const live_member = mintId();

    try f.store.append(.{ .add = .{ .id = built, .title = "Arc: the reshape" } });
    try f.store.append(.{ .arcDeclare = .{ .id = built, .declared = true } });
    try f.store.append(.{ .add = .{ .id = still_open, .title = "the unfinished remainder" } });
    try f.store.append(.{ .in = .{ .task = still_open, .arc = built, .seq = 2 } });
    try f.store.append(.{ .add = .{ .id = d1, .title = "D1 the first slice", .short = d1.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = d1, .arc = built, .seq = 0 } });
    try f.store.append(.{ .add = .{ .id = d2, .title = "D2 the second slice", .short = d2.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = d2, .arc = built, .seq = 1 } });
    try f.store.append(.{ .setState = .{ .id = d1, .state = .archived } });
    try f.store.append(.{ .setState = .{ .id = d2, .state = .archived } });

    try f.store.append(.{ .add = .{ .id = bare, .title = "Arc: never sliced" } });
    try f.store.append(.{ .arcDeclare = .{ .id = bare, .declared = true } });
    try f.store.append(.{ .add = .{ .id = live_only, .title = "Arc: all live" } });
    try f.store.append(.{ .arcDeclare = .{ .id = live_only, .declared = true } });
    try f.store.append(.{ .add = .{ .id = live_member, .title = "a live slice" } });
    try f.store.append(.{ .in = .{ .task = live_member, .arc = live_only, .seq = 0 } });

    try f.run(&.{"compact"});
    try f.reopen();

    // The premise of the whole test: the members really are gone from the live
    // store AND their membership edges went with them. Without this the
    // positive arm below could be reading live `ins` rows and proving nothing.
    try testing.expect(f.store.get(d1) == null);
    try testing.expect(f.store.get(d2) == null);
    for (f.store.ins.items) |e| try testing.expect(!e.task.eql(d1) and !e.task.eql(d2));

    // POSITIVE: the built arc names its graduated members.
    try f.run(&.{ "tree", &built.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members (2)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "D1 the first slice") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "D2 the second slice") != null);
    // Live members are untouched — the block is an addition, not a replacement.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the unfinished remainder") != null);

    // A graduated member must not be skimmable as a live one: its row carries
    // the `compacted:` prefix and no `[ ]`/`[x]`-style state marker. Checked by
    // building the exact row rather than by searching for the title alone,
    // which would pass on a row rendered like any other tree node.
    const row1 = try std.fmt.allocPrint(alloc, "compacted: {s}  was archived  D1 the first slice", .{d1.text[0..9]});
    defer alloc.free(row1);
    try testing.expect(std.mem.indexOf(u8, f.out.items, row1) != null);
    const row2 = try std.fmt.allocPrint(alloc, "compacted: {s}  was archived  D2 the second slice", .{d2.text[0..9]});
    defer alloc.free(row2);
    try testing.expect(std.mem.indexOf(u8, f.out.items, row2) != null);
    try testing.expectEqual(@as(usize, 2), countOccurrences(f.out.items, "compacted: "));

    // NEGATIVE 1: an arc that was genuinely never sliced still renders as a
    // bare one-line tree. This is the arm a block printed unconditionally (or a
    // membership filter matching too widely) fails.
    try f.run(&.{ "tree", &bare.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc: never sliced") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted: ") == null);

    // NEGATIVE 2: an arc with live members and no graduated ones likewise says
    // nothing about compaction — the block appears for the arc that HAS them,
    // not for every arc.
    try f.run(&.{ "tree", &live_only.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "a live slice") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members") == null);
}

test "tree: a COMPACTED root answers COMPACTED with its graduated members, not \"no task matches\"" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // Minted far apart in time so a short prefix of one is not a prefix of
    // another (a ULID's first 10 chars are its ms stamp).
    const arc = ulid.mintAt(io, 7_000_001);
    const member = ulid.mintAt(io, 7_500_001);
    const live_arc = mintId();

    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc: finished and graduated", .short = arc.text[0..9] } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = member, .title = "its one slice", .short = member.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .setState = .{ .id = member, .state = .archived } });
    try f.store.append(.{ .setState = .{ .id = arc, .state = .archived } });
    try f.store.append(.{ .add = .{ .id = live_arc, .title = "Arc: still here" } });
    try f.store.append(.{ .arcDeclare = .{ .id = live_arc, .declared = true } });

    try f.run(&.{"compact"});
    try f.reopen();
    try testing.expect(f.store.get(arc) == null);

    // POSITIVE: the same three-way verdict `show` gives — exit 2, COMPACTED —
    // and the arc's graduated members under the record, so the reader learns
    // both that the arc was real and what was in it.
    try testing.expectEqual(@as(anyerror, error.CompactedId), f.runExpectErr(&.{ "tree", arc.text[0..9] }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc: finished and graduated") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members (1)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "its one slice") != null);

    // NEGATIVE 1: an id that never existed is still absent — error.NoSuchId,
    // no COMPACTED banner. Without this the arm above would pass on a lookup
    // that says yes to anything.
    try testing.expectEqual(@as(anyerror, error.NoSuchId), f.runExpectErr(&.{ "tree", never_id }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);

    // NEGATIVE 2: a LIVE arc still renders as a live tree, exit 0.
    try f.run(&.{ "tree", &live_arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc: still here") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "COMPACTED") == null);
}

test "tree --json: compacted_members is always at the root, empty when there are none" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const live = mintId();
    const prereq = mintId();
    const gone = ulid.mintAt(io, 8_000_001);
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc J" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = live, .title = "live J" } });
    try f.store.append(.{ .in = .{ .task = live, .arc = arc, .seq = 1 } });
    try f.store.append(.{ .add = .{ .id = prereq, .title = "prereq J" } });
    try f.store.append(.{ .dep = .{ .from = live, .to = prereq } });
    try f.store.append(.{ .add = .{ .id = gone, .title = "graduated J", .short = gone.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = gone, .arc = arc, .seq = 0 } });
    try f.store.append(.{ .setState = .{ .id = gone, .state = .archived } });

    try f.run(&.{"compact"});
    try f.reopen();

    // POSITIVE: one entry, carrying the `"compacted":true` discriminator the
    // live node shape never emits, so a reader branches on a key rather than on
    // a missing one.
    try f.run(&.{ "tree", &arc.text, "--json" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"compacted_members\":[{\"compacted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"title\":\"graduated J\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"was\":\"archived\"") != null);
    // Root only: a child's `children` is its prereq list, never a place a
    // graduated arc member belongs.
    try testing.expectEqual(@as(usize, 1), countOccurrences(f.out.items, "\"compacted_members\":"));

    // NEGATIVE: a node with no graduated members still carries the key, with an
    // EMPTY array — the schema is stable, and "none" is stated rather than
    // inferred from a key that is not there.
    try f.run(&.{ "tree", &prereq.text, "--json" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"compacted_members\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"compacted\":true") == null);
}

test "show: an arc prereq's progress counts its compacted members separately, and stays quiet with none" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // `dependent` needs two arcs: `drained` was fully built and compacted,
    // `fresh` has a live member and nothing graduated.
    const dependent = mintId();
    const drained = mintId();
    const fresh = mintId();
    const fresh_member = mintId();
    const g1 = ulid.mintAt(io, 9_000_001);
    const g2 = ulid.mintAt(io, 9_500_001);

    try f.store.append(.{ .add = .{ .id = dependent, .title = "needs both" } });
    try f.store.append(.{ .add = .{ .id = drained, .title = "Arc drained" } });
    try f.store.append(.{ .arcDeclare = .{ .id = drained, .declared = true } });
    try f.store.append(.{ .add = .{ .id = fresh, .title = "Arc fresh" } });
    try f.store.append(.{ .arcDeclare = .{ .id = fresh, .declared = true } });
    try f.store.append(.{ .dep = .{ .from = dependent, .to = drained } });
    try f.store.append(.{ .dep = .{ .from = dependent, .to = fresh } });
    try f.store.append(.{ .add = .{ .id = fresh_member, .title = "fresh slice" } });
    try f.store.append(.{ .in = .{ .task = fresh_member, .arc = fresh, .seq = 0 } });
    for ([_]Ulid{ g1, g2 }) |g| {
        try f.store.append(.{ .add = .{ .id = g, .title = "drained slice", .short = g.text[0..9] } });
        try f.store.append(.{ .in = .{ .task = g, .arc = drained, .seq = 0 } });
        try f.store.append(.{ .setState = .{ .id = g, .state = .archived } });
    }

    try f.run(&.{"compact"});
    try f.reopen();

    // POSITIVE: the drained arc reads `(0/0 done, +2 compacted)` — the bare
    // `(0/0 done)` it printed before is what an unsliced arc prints too.
    try f.run(&.{ "show", &dependent.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc drained  (0/0 done, +2 compacted)") != null);
    // NEGATIVE, in the SAME output: the arc with nothing graduated keeps the
    // plain line. A suffix appended unconditionally fails here.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "Arc fresh  (0/1 done)") != null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(f.out.items, "compacted)"));

    // The machine view states BOTH, because a stable schema is worth more to a
    // reader that branches than a quiet line is.
    try f.run(&.{ "show", &dependent.text, "--json" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"arc_progress\":{\"done\":0,\"total\":0,\"compacted\":2}") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"arc_progress\":{\"done\":0,\"total\":1,\"compacted\":0}") != null);
}

// ----- unknown-flag diagnostics (01M1FMMFZ) -----

test "add blames the flag that failed to parse, never the title (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The reported line, verbatim in shape: the ONE argument that is correct is
    // the title, and it used to be the one named. `--tags=a,b` must be.
    const title = "Fixture title that should not be blamed";
    try testing.expectEqual(
        cli.CliError.UnknownFlag,
        f.runExpectErr(&.{ "add", "--tags=a,b", title }),
    );
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--tags=a,b") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, title) == null);
    // And it names the spelling that was meant — the whole class of error is
    // reaching for the plural of a repeatable option.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean '--tag'?") != null);

    // Nothing was minted: the refusal happens before any append.
    try testing.expectEqual(@as(usize, 0), f.store.count());
}

test "a near-miss flag is named on every verb, not just add (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "next", "--limt", "3" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean '--limit'?") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "trk next --help") != null);

    // Far enough away to suggest nothing — a wrong guess is worse than none.
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "next", "--frobnicate" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--frobnicate") != null);
}

test "an =-joined value on a REAL flag says so instead of `unknown flag` (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "add", "--tag=ui", "T" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "=-joined") != null);
    // The repair is spelled out, values and all.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "--tag ui") != null);
}

test "add takes its title from the first BARE token, so flags may come first (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "add", "--tag", "ui", "Flags first", "--arc" });
    try testing.expectEqual(@as(usize, 1), f.store.count());
    const ids = try f.store.allIds(alloc);
    defer alloc.free(ids);
    const t = f.store.get(ids[0]).?;
    try testing.expectEqualStrings("Flags first", t.title);
    try testing.expectEqual(@as(usize, 1), t.tags.items.len);
    try testing.expectEqualStrings("ui", t.tags.items[0]);
    try testing.expect(f.store.isArc(ids[0]));
}

test "a SECOND bare token on add is an unquoted-title report, not `unknown flag` (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The shape a lost quote produces. It is a usage error, and the message has
    // to say which mistake it was — "unknown flag 'Two'" is exactly the
    // misdirection this task is about.
    try testing.expectEqual(cli.CliError.UsageError, f.runExpectErr(&.{ "add", "One", "Two" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "exactly one positional") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "'Two'") != null);
    try testing.expectEqual(@as(usize, 0), f.store.count());
}

test "add with no bare token at all reports a MISSING title, not an unknown flag (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try testing.expectEqual(cli.CliError.MissingArgument, f.runExpectErr(&.{ "add", "--arc" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "needs a \"<title>\"") != null);
}

// Every flag in `Verb.flags` has to be documented in that verb's own help text,
// because the help text is what the diagnostic points the reader at ("trk <verb>
// --help lists the flags it takes") and what the MCP tool descriptions are built
// from. Same rule mcp_test.zig enforces for the tool schemas, one level up.
test "every Verb.flags entry appears in its verb's help text" {
    for (&cli.Cli.verbs) |*v| {
        for (v.flags) |fl| {
            if (std.mem.indexOf(u8, v.text, fl) == null) {
                std.debug.print("verb '{s}': flag '{s}' is not in its help text\n", .{ v.name, fl });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "a dash-leading token in an ID slot reads as a misspelled flag, not a missing task (01M1FMMFZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    try f.store.append(.{ .add = .{ .id = a, .title = "A" } });

    // `trk edit --titel x` used to answer "no task matches prefix '--titel'",
    // which sends the reader hunting for a task. No id begins with a dash.
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "edit", "--titel", "x" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean '--title'?") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no task matches") == null);

    // Verbs whose only positional is an id are covered by the same route.
    try testing.expectEqual(cli.CliError.UnknownFlag, f.runExpectErr(&.{ "show", "--jsn" }));
    try testing.expect(std.mem.indexOf(u8, f.out.items, "did you mean '--json'?") != null);

    // A real id in the same slot is untouched.
    try f.run(&.{ "show", &a.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "A") != null);
}

// ----- --json carries the body (01M1FMN25) -----

test "next/list --json carry the full body, always, escaped (01M1FMN25)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const a = mintId();
    const b = mintId();

    // The shape that made this matter: the discriminator is APPENDED, so it sits
    // at the tail of a body whose opening still reads like buildable work.
    const body =
        "First paragraph reads like ordinary buildable work.\n\nRULED: \"do not\" start this — \\ see above.";
    try f.store.append(.{ .add = .{ .id = a, .title = "alpha", .body = body } });
    try f.store.append(.{ .add = .{ .id = b, .title = "beta" } }); // no body at all

    for ([_][]const u8{ "next", "list" }) |verb| {
        try f.run(&.{ verb, "--json" });
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        const arr = parsed.value.array;
        try testing.expectEqual(@as(usize, 2), arr.items.len);

        var saw_a = false;
        var saw_b = false;
        for (arr.items) |row| {
            const o = row.object;
            // Present on EVERY row, empty string included — a consumer indexes
            // it without a guard, which a sometimes-omitted key would not allow.
            const got = o.get("body") orelse return error.TestUnexpectedResult;
            if (std.mem.eql(u8, o.get("title").?.string, "alpha")) {
                saw_a = true;
                // Round-trips byte-for-byte through the hand-rolled escaper:
                // newlines, quotes and a backslash all survive.
                try testing.expectEqualStrings(body, got.string);
            } else {
                saw_b = true;
                try testing.expectEqualStrings("", got.string);
            }
        }
        try testing.expect(saw_a and saw_b);
    }
}

// ----- tombstones --rebuild recovers arc memberships (01M2V2TYC) -----

test "tombstones --rebuild recovers ARC MEMBERSHIPS, so tree's compacted-members block works for pre-index compactions too (01M2V2TYC)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const member = mintId();
    const dropped_member = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "the arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = member, .title = "graduated slice", .short = member.text[0..9] } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 1 } });
    try f.store.append(.{ .setState = .{ .id = member, .state = .archived } });
    // A member whose membership was RETRACTED before it graduated. `unin` is a
    // permanent tombstone in the fold regardless of append order, so the
    // reconstruction must not resurrect it just because an `in` is in history.
    try f.store.append(.{ .add = .{ .id = dropped_member, .title = "never really in it" } });
    try f.store.append(.{ .in = .{ .task = dropped_member, .arc = arc, .seq = 2 } });
    try f.store.append(.{ .unin = .{ .task = dropped_member, .arc = arc } });
    try f.store.append(.{ .setState = .{ .id = dropped_member, .state = .archived } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    try f.run(&.{"compact"});
    try f.reopen();

    // The pre-index era, asserted rather than assumed: the compact happened,
    // no tombstone was ever written, and `tree` says nothing about the member.
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();
    try testing.expectEqual(@as(usize, 0), f.store.tombstones.items.len);
    try f.run(&.{ "tree", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members") == null);
    // And in THAT state — no index at all — the emptiness says so rather than
    // passing itself off as "this arc had no graduated members".
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no tombstone index in this store") != null);

    // The recovery. This is what used to come back with "arcs":[] for every row.
    try f.run(&.{ "tombstones", "--rebuild" });
    try f.run(&.{ "tree", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members (1)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "graduated slice") != null);
    // The `unin`'d one is NOT a member — same rule the fold applies.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "never really in it") == null);
    // It is still entombed, though: it existed, and `show` must still answer.
    try testing.expectEqual(
        @as(anyerror, error.CompactedId),
        f.runExpectErr(&.{ "show", &dropped_member.text }),
    );

    // The hint is gone now that the index has something in it: a populated
    // index with no hit for THIS arc is a real answer, not a silence. Asserted
    // on a second, never-compacted arc in the same store, which is the only
    // shape that distinguishes the two.
    const quiet_arc = mintId();
    try f.store.append(.{ .add = .{ .id = quiet_arc, .title = "never compacted" } });
    try f.store.append(.{ .arcDeclare = .{ .id = quiet_arc, .declared = true } });
    try f.run(&.{ "tree", &quiet_arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no tombstone index") == null);
}

test "tombstones --rebuild UPGRADES a membership-less record left by the older reconstruction (01M2V2TYC)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const member = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "the arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = member, .title = "graduated slice" } });
    try f.store.append(.{ .in = .{ .task = member, .arc = arc, .seq = 1 } });
    try f.store.append(.{ .setState = .{ .id = member, .state = .archived } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "tracker log before the compact" });

    try f.run(&.{"compact"});
    try f.tmp.dir.deleteFile(io, ".tracker/tombstones.jsonl");
    try f.reopen();
    try f.run(&.{ "tombstones", "--rebuild" });

    // Reproduce EXACTLY what the older `--rebuild` wrote, by taking what the
    // new one wrote and blanking the memberships. Doing it this way rather than
    // hand-rolling a line keeps the fixture honest if the record format moves.
    {
        const bytes = try f.tmp.dir.readFileAlloc(io, ".tracker/tombstones.jsonl", alloc, .unlimited);
        defer alloc.free(bytes);
        var stale: std.ArrayList(u8) = .empty;
        defer stale.deinit(alloc);
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const open_at = std.mem.indexOf(u8, line, "\"arcs\":[").?;
            const close_at = std.mem.indexOfScalarPos(u8, line, open_at, ']').?;
            try stale.appendSlice(alloc, line[0 .. open_at + "\"arcs\":[".len]);
            try stale.appendSlice(alloc, line[close_at..]);
            try stale.append(alloc, '\n');
        }
        try f.tmp.dir.writeFile(io, .{ .sub_path = ".tracker/tombstones.jsonl", .data = stale.items, .flags = .{} });
    }
    try f.reopen();

    // RED baseline: the record is there, the membership is not, and `tree` is
    // silent — the measured Enix state after the one-time rebuild (2521 records,
    // every one with "arcs":[]).
    try testing.expect(f.store.tombstones.items.len != 0);
    try f.run(&.{ "tree", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members") == null);

    // Re-running the rebuild repairs it in place of skipping it. Without the
    // upgrade rule this reports "0 new, 0 upgraded" and the block stays empty
    // forever — the fix would only ever reach stores that had never rebuilt.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 new tombstone(s) recorded") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 existing record(s) upgraded") != null);
    try f.run(&.{ "tree", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted members (1)") != null);

    // And now it settles: a third run has nothing left to improve.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 existing record(s) upgraded") != null);
}

// ----- compact --dry-run (01M1FMNSZ) -----

test "compact --dry-run names exactly what the real run would collect, and writes nothing (01M1FMNSZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const keeper = mintId();
    const done_one = mintId();
    const goner = mintId();
    const ghost = mintId();
    try f.store.append(.{ .add = .{ .id = keeper, .title = "still open" } });
    // `done` is NOT collectable — it is a satisfied prereq and the un-graduated
    // changelog queue. A preview that listed it would be a lie about the run.
    try f.store.append(.{ .add = .{ .id = done_one, .title = "finished, not graduated" } });
    try f.store.append(.{ .setState = .{ .id = done_one, .state = .done } });
    try f.store.append(.{ .add = .{ .id = goner, .title = "graduated work", .short = goner.text[0..9] } });
    try f.store.append(.{ .setState = .{ .id = goner, .state = .archived } });
    // A ghost: events about an id that was never `add`ed. Collectable too, and
    // classified by what it is rather than by its placeholder `open` state.
    try f.store.append(.{ .setBody = .{ .id = ghost, .body = "residue" } });

    const before = try f.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(before);

    try f.run(&.{ "compact", "--dry-run" });
    const preview = try alloc.dupe(u8, f.out.items);
    defer alloc.free(preview);

    try testing.expect(std.mem.indexOf(u8, preview, "2 task(s) WOULD be collected") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "graduated work") != null);
    try testing.expect(std.mem.indexOf(u8, preview, &goner.text) != null);
    try testing.expect(std.mem.indexOf(u8, preview, &ghost.text) != null);
    try testing.expect(std.mem.indexOf(u8, preview, "ghost") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "still open") == null);
    try testing.expect(std.mem.indexOf(u8, preview, "finished, not graduated") == null);
    // It says the part a tombstone cannot answer, which is the whole reason the
    // external-citation problem survives the tombstone index.
    try testing.expect(std.mem.indexOf(u8, preview, "does NOT keep is the BODY") != null);

    // Nothing was written: not the log, not a snapshot, not a tombstone file.
    const after = try f.tmp.dir.readFileAlloc(io, ".tracker/log.jsonl", alloc, .unlimited);
    defer alloc.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, ".tracker/snapshot.jsonl", .{}));
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, ".tracker/tombstones.jsonl", .{}));

    // And the preview agreed with the run: the same two ids, now actually gone
    // and actually entombed. This is the assertion the shared `collectableRows`
    // exists for — a preview that can disagree with the run is unusable.
    try f.run(&.{"compact"});
    try f.reopen();
    try testing.expectEqual(@as(usize, 2), f.store.tombstones.items.len);
    try testing.expect(f.store.lookupTombstone(&goner.text) == .one);
    try testing.expect(f.store.lookupTombstone(&ghost.text) == .one);
    try testing.expect(f.store.get(keeper) != null);
    try testing.expect(f.store.get(done_one) != null);
}

test "compact --dry-run on a store with nothing to collect says so (01M1FMNSZ)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    try f.run(&.{ "add", "still open" });

    try f.run(&.{ "compact", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "nothing to collect") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "WOULD be collected") == null);
}

// ----- list --arc reports compacted members (01M2V2TSA) -----

test "list --arc reports an arc's compacted members; next and render deliberately do not (01M2V2TSA)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const graduated = mintId();
    const live = mintId();
    const finished = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Ship v2" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = graduated, .title = "graduated slice" } });
    try f.store.append(.{ .in = .{ .task = graduated, .arc = arc, .seq = 1 } });
    try f.store.append(.{ .add = .{ .id = live, .title = "live slice" } });
    try f.store.append(.{ .in = .{ .task = live, .arc = arc, .seq = 2 } });
    // A `done` member: proof that `list` already shows closed work, which is
    // what makes the compacted one's absence an inconsistency and not a policy.
    try f.store.append(.{ .add = .{ .id = finished, .title = "finished slice" } });
    try f.store.append(.{ .in = .{ .task = finished, .arc = arc, .seq = 3 } });
    try f.store.append(.{ .setState = .{ .id = finished, .state = .done } });
    try f.store.append(.{ .setState = .{ .id = graduated, .state = .archived } });

    try f.run(&.{"compact"});
    try f.reopen();

    try f.run(&.{ "list", "--arc", &arc.text, "--all" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "live slice") != null);
    // `--all`, because completed work is hidden by default (01M2VPC6K). The
    // `done` member is the point of this assertion: it is what makes the
    // COMPACTED member's absence an inconsistency rather than a policy — even
    // asked for explicitly, a compacted member never appears as a row.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "finished slice") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "+1 compacted member(s) not shown") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "names them") != null);

    // --json: the same fact, as a row a consumer filters on one key.
    try f.run(&.{ "list", "--arc", &arc.text, "--json", "--all" });
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        const rows = parsed.value.array;
        var compacted: usize = 0;
        var seen_graduated = false;
        for (rows.items) |row| {
            if (row.object.get("compacted")) |c| {
                if (c.bool) {
                    compacted += 1;
                    if (std.mem.eql(u8, row.object.get("title").?.string, "graduated slice"))
                        seen_graduated = true;
                }
            }
        }
        try testing.expectEqual(@as(usize, 1), compacted);
        try testing.expect(seen_graduated);
        // Filtering that one key yields exactly the pre-fix output.
        try testing.expectEqual(@as(usize, 4), rows.items.len);
    }

    // BOTH DIRECTIONS, the shape 01M29P5T7 used: an arc that never had a
    // graduated member must read differently from one that did. Otherwise the
    // footer proves nothing about the arc it is attached to.
    const quiet = mintId();
    try f.store.append(.{ .add = .{ .id = quiet, .title = "Never sliced" } });
    try f.store.append(.{ .arcDeclare = .{ .id = quiet, .declared = true } });
    try f.run(&.{ "list", "--arc", &quiet.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted member") == null);

    // And the two views Scott scoped OUT stay silent (2026-09-18): `next` is a
    // ready frontier, `render` projects only not-yet-built work.
    try f.run(&.{ "next", "--arc", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted") == null);
    try f.run(&.{ "render", "--out", "TODO.md" });
    const md = try f.tmp.dir.readFileAlloc(io, "TODO.md", alloc, .unlimited);
    defer alloc.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "compacted") == null);
}

test "list --arc: compacted members pass the same filters as live rows, never widening them (01M31H1JA)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const arc = mintId();
    const open_q = mintId();
    const open_work = mintId();
    const gone_a = mintId();
    const gone_d = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Arc" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = open_q, .title = "open fork", .tags = &.{"t"} } });
    try f.store.append(.{ .decisionDeclare = .{ .id = open_q, .declared = true } });
    try f.store.append(.{ .add = .{ .id = open_work, .title = "open work" } });
    try f.store.append(.{ .add = .{ .id = gone_a, .title = "archived work", .tags = &.{"t"} } });
    try f.store.append(.{ .add = .{ .id = gone_d, .title = "dropped work" } });
    for ([_]Ulid{ open_q, open_work, gone_a, gone_d }) |m| try f.store.append(.{ .in = .{ .task = m, .arc = arc } });
    try f.store.append(.{ .setState = .{ .id = gone_a, .state = .archived } });
    try f.store.append(.{ .setState = .{ .id = gone_d, .state = .dropped } });
    try f.run(&.{"compact"});
    try f.reopen();

    // Rows below count the arc root too: it is its own member.
    const Case = struct { args: []const []const u8, rows: usize, compacted: usize };
    const cases = [_]Case{
        // The measured shape: `--state open` returned the tombstones too.
        .{ .args = &.{ "--state", "open" }, .rows = 3, .compacted = 0 },
        .{ .args = &.{ "--decision", "--state", "open" }, .rows = 1, .compacted = 0 },
        // The default hides completed work; a tombstone is always completed.
        .{ .args = &.{}, .rows = 3, .compacted = 0 },
        // Asked for by end state, they come back — just the matching one.
        .{ .args = &.{ "--state", "archived" }, .rows = 1, .compacted = 1 },
        .{ .args = &.{ "--state", "dropped" }, .rows = 1, .compacted = 1 },
        .{ .args = &.{"--all"}, .rows = 5, .compacted = 2 },
        // A record that keeps no tags or decision flag cannot satisfy them.
        .{ .args = &.{ "--all", "--decision" }, .rows = 1, .compacted = 0 },
        .{ .args = &.{ "--all", "--tag", "t" }, .rows = 1, .compacted = 0 },
        // Search terms: its title is what it keeps.
        .{ .args = &.{ "--all", "archived" }, .rows = 1, .compacted = 1 },
        .{ .args = &.{ "--all", "--limit", "4" }, .rows = 4, .compacted = 1 },
    };
    for (cases) |cs| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "list", "--arc", &arc.text, "--json" });
        try argv.appendSlice(alloc, cs.args);
        try f.run(argv.items);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        var compacted: usize = 0;
        for (parsed.value.array.items) |row| {
            if (row.object.get("compacted") != null) compacted += 1;
        }
        testing.expectEqual(cs.rows, parsed.value.array.items.len) catch |e| {
            std.debug.print("case {any}: {s}\n", .{ cs.args, f.out.items });
            return e;
        };
        try testing.expectEqual(cs.compacted, compacted);
    }

    // The human footer counts the same admitted set.
    try f.run(&.{ "list", "--arc", &arc.text, "--state", "open" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted member") == null);
    try f.run(&.{ "list", "--arc", &arc.text, "--state", "dropped" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "+1 compacted member(s)") != null);
    try f.run(&.{ "list", "--arc", &arc.text, "--all" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "+2 compacted member(s)") != null);
}

test "list/next --json rows carry every edge, so a client-side join is never vacuous (01M32AJ90)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const gated = mintId();
    const free = mintId();
    try f.store.append(.{ .add = .{ .id = gated, .title = "gated work" } });
    try f.store.append(.{ .add = .{ .id = free, .title = "free work" } });
    try f.run(&.{ "decision", "which way?", "--from", &gated.text });
    const did = try ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));

    // The measured join: open decisions x their `raised_by`, to drop the tasks
    // that raised one. With the field absent it matched 0 of 221.
    try f.run(&.{ "list", "--json", "--decision", "--state", "open" });
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        const rows = parsed.value.array.items;
        try testing.expectEqual(@as(usize, 1), rows.len);
        try testing.expect(rows[0].object.get("decision").?.bool);
        const by = rows[0].object.get("raised_by").?.array.items;
        try testing.expectEqual(@as(usize, 1), by.len);
        try testing.expectEqualStrings(&gated.text, by[0].string);
    }
    // And from the other side, on a `next` row; every edge key is PRESENT on a
    // task with no edges at all — an empty array, never an absent field.
    try f.run(&.{ "next", "--json" });
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        var saw_gated = false;
        for (parsed.value.array.items) |row| {
            const o = row.object;
            for ([_][]const u8{ "raises", "raised_by", "prereqs", "dependents", "arcs", "docrefs" }) |k| {
                try testing.expect(o.get(k) != null);
            }
            if (std.mem.eql(u8, o.get("id").?.string, &gated.text)) {
                saw_gated = true;
                try testing.expectEqualStrings(&did.text, o.get("raises").?.array.items[0].string);
            } else {
                try testing.expectEqual(@as(usize, 0), o.get("raises").?.array.items.len);
            }
        }
        try testing.expect(saw_gated);
    }
}

test "list/next: --not-word excludes by title+body+tags, --offset pages, --no-body swaps body for body_len (01M32AJ90)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var ids: [5]Ulid = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = mintId();
        const body: []const u8 = if (i % 2 == 0) "REC-BOT: annotated" else "not yet";
        try f.store.append(.{ .add = .{ .id = id.*, .title = "task", .body = body } });
    }

    // --not-word: "body does NOT contain X", the sweep that needed a shell.
    for ([_][]const u8{ "list", "next" }) |verb| {
        try f.run(&.{ verb, "--json", "--not-word", "rec-bot" });
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
        for (parsed.value.array.items) |row| {
            try testing.expectEqualStrings("not yet", row.object.get("body").?.string);
        }
    }

    // --offset + --limit: pages cover the whole set once, in order, and a
    // short page is the last.
    for ([_][]const u8{ "list", "next" }) |verb| {
        var seen: std.ArrayList([]const u8) = .empty;
        defer {
            for (seen.items) |x| alloc.free(x);
            seen.deinit(alloc);
        }
        // Bounded: a broken --offset returns full pages forever, and that
        // must fail here, not hang the suite.
        var off: usize = 0;
        while (off <= 10) : (off += 2) {
            var buf: [8]u8 = undefined;
            const o = try std.fmt.bufPrint(&buf, "{d}", .{off});
            try f.run(&.{ verb, "--json", "--limit", "2", "--offset", o });
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
            defer parsed.deinit();
            for (parsed.value.array.items) |row| try seen.append(alloc, try alloc.dupe(u8, row.object.get("id").?.string));
            if (parsed.value.array.items.len < 2) break;
        }
        try testing.expectEqual(@as(usize, 5), seen.items.len);
        for (seen.items, 0..) |a, i| for (seen.items[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }

    // --no-body: no body key, and body_len still says there is one.
    try f.run(&.{ "list", "--json", "--no-body" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"body\":") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"body_len\":18") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "\"body_len\":7") != null);
}

// ----- trk decision (01M2VFV83) -----

test "trk decision: raises a node, separates provenance from blocking, prints only the id" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const work = mintId();
    const other = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "the display fix" } });
    try f.store.append(.{ .add = .{ .id = other, .title = "unrelated work" } });

    try f.run(&.{ "decision", "does TODO.md want the annotation?", "--from", &work.text, "--blocks", &work.text });
    // Scriptable like `add`: stdout is the id and nothing else.
    const printed = std.mem.trimEnd(u8, f.out.items, "\n");
    try testing.expectEqual(@as(usize, 26), printed.len);
    const d = try tracker.ulid.parse(printed);

    try testing.expect(f.store.isDecision(d));
    try testing.expectEqualStrings("does TODO.md want the annotation?", f.store.get(d).?.title);

    // Provenance and blocking are SEPARATE relations that happen to coincide
    // here — and coinciding is exactly the shape that would be a cycle if
    // provenance were spelled as a dep.
    const raisers = try f.store.raisersOf(alloc, d);
    defer alloc.free(raisers);
    try testing.expectEqual(@as(usize, 1), raisers.len);
    try testing.expect(raisers[0].eql(work));
    const rdeps = try f.store.reverseDeps(alloc, d);
    defer alloc.free(rdeps);
    try testing.expectEqual(@as(usize, 1), rdeps.len);
    try testing.expect(rdeps[0].eql(work));

    // --from alone must NOT block: a fork noticed while doing a task usually
    // does not stop it, which is why blocking is opt-in.
    try f.run(&.{ "decision", "should trk support multi-user?", "--from", &other.text });
    const d2 = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    const rdeps2 = try f.store.reverseDeps(alloc, d2);
    defer alloc.free(rdeps2);
    try testing.expectEqual(@as(usize, 0), rdeps2.len);
    // ...and it says so, on stderr, so a blocking fork filed without --blocks
    // is not silently inert.
    try testing.expect(std.mem.indexOf(u8, f.warn.items, "blocks nothing") != null);

    // A standalone decision is legal: not every fork comes out of a task.
    try f.run(&.{ "decision", "what should the release cadence be?" });
    try testing.expect(f.store.isDecision(try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"))));
}

test "trk decision: a bad --from/--blocks/--in fails BEFORE minting (no half-built decision)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const work = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "work" } });

    try testing.expectEqual(
        cli.CliError.NoSuchId,
        f.runExpectErr(&.{ "decision", "q?", "--from", "ZZZZZZZZZ" }),
    );
    try testing.expectEqual(
        cli.CliError.NoSuchId,
        f.runExpectErr(&.{ "decision", "q?", "--blocks", "ZZZZZZZZZ" }),
    );
    // --in must name an ALREADY-DECLARED arc, same rule as `add`.
    try testing.expectEqual(
        cli.CliError.UndeclaredArc,
        f.runExpectErr(&.{ "decision", "q?", "--in", &work.text }),
    );
    // Nothing was minted by any of the three.
    try testing.expectEqual(@as(usize, 1), f.store.count());
}

test "trk decision: a decision cannot be leased, submitted, or made an arc" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    try f.run(&.{ "decision", "a fork" });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));

    // A question is not work: leasing one would start stale/release bookkeeping
    // on something nobody is building.
    try testing.expectEqual(
        @as(anyerror, error.DecisionNotWork),
        f.runExpectErr(&.{ "state", &d.text, "claimed", "--holder", "lane-1" }),
    );
    try testing.expect(std.mem.indexOf(u8, f.out.items, "is a DECISION, not work") != null);
    try testing.expectEqual(
        @as(anyerror, error.DecisionNotWork),
        f.runExpectErr(&.{ "state", &d.text, "submitted" }),
    );

    // An arc contains work; a decision is a question about it. `rule` closes its
    // target, so a task that were both would close an arc with members open.
    try testing.expectEqual(
        @as(anyerror, error.DecisionNotArc),
        f.runExpectErr(&.{ "arc", &d.text }),
    );
    try testing.expect(std.mem.indexOf(u8, f.out.items, "cannot also be an arc") != null);
}

// ----- decisions in the views (01M2VFV84) -----

test "next excludes decisions AND says what it withheld; both halves, because exclusion alone is a regression" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const work = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "the display fix" } });

    try f.run(&.{ "decision", "does TODO.md want the annotation?", "--from", &work.text, "--blocks", &work.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));

    try f.run(&.{"next"});
    // The question is not offered as work...
    try testing.expect(std.mem.indexOf(u8, f.out.items, "does TODO.md want") == null);
    // ...and neither is the work it blocks...
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the display fix") == null);
    // ...but the frontier does NOT go silently empty. This is the half that
    // makes the exclusion an improvement rather than a hidden hole: the old
    // --not-tag convention was opt-in and left the fork visible in a bare next.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 task(s) withheld") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 pending decision(s)") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "list --decision --state open") != null);

    // Ruling it releases the work and the tail goes away — no second command.
    try f.run(&.{ "rule", &d.text, "RULED: list --arc only" });
    try f.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the display fix") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "withheld") == null);
    // A RULED decision still never surfaces: exclusion tracks the declaration,
    // which is nature and survives the ruling.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "does TODO.md want") == null);
}

test "the withheld tail counts only work blocked SOLELY by decisions, and is silent otherwise" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const also_waiting = mintId();
    const unfinished = mintId();
    try f.store.append(.{ .add = .{ .id = also_waiting, .title = "waits on both" } });
    try f.store.append(.{ .add = .{ .id = unfinished, .title = "ordinary unfinished work" } });
    try f.store.append(.{ .dep = .{ .from = also_waiting, .to = unfinished } });

    try f.run(&.{ "decision", "a fork", "--blocks", &also_waiting.text });

    try f.run(&.{"next"});
    // `also_waiting` is blocked by BOTH a decision and unfinished work, so
    // ruling the fork would not release it — claiming it as withheld-by-decision
    // would overstate what a ruling buys.
    try testing.expect(std.mem.indexOf(u8, f.out.items, "withheld") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "ordinary unfinished work") != null);

    // And with no decisions in play at all the tail never appears.
    var g = try Fixture.init(alloc);
    defer g.deinit();
    const plain = mintId();
    try g.store.append(.{ .add = .{ .id = plain, .title = "just work" } });
    try g.run(&.{"next"});
    try testing.expect(std.mem.indexOf(u8, g.out.items, "withheld") == null);
}

test "a decision reads as [?] in list, tree and TODO.md — never as an ordinary work bullet" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const arc = mintId();
    const work = mintId();
    try f.store.append(.{ .add = .{ .id = arc, .title = "Ship v2" } });
    try f.store.append(.{ .arcDeclare = .{ .id = arc, .declared = true } });
    try f.store.append(.{ .add = .{ .id = work, .title = "the display fix" } });
    try f.store.append(.{ .in = .{ .task = work, .arc = arc, .seq = 1 } });

    // No --in: this decision reaches the arc purely by needs-REACHABILITY
    // (membersOf closes over needs), which is exactly the path that would have
    // put a question into TODO.md looking like a slice.
    try f.run(&.{ "decision", "does TODO.md want the annotation?", "--from", &work.text, "--blocks", &work.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));

    try f.run(&.{"list"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[?] ") != null);

    try f.run(&.{ "tree", &arc.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[?]") != null);

    try f.run(&.{ "render", "--out", "TODO.md" });
    const md = try f.tmp.dir.readFileAlloc(io, "TODO.md", alloc, .unlimited);
    defer alloc.free(md);
    // It IS in the projection (reachability put it there) — the point is that
    // it does not read as buildable work.
    try testing.expect(std.mem.indexOf(u8, md, "does TODO.md want") != null);
    try testing.expect(std.mem.indexOf(u8, md, "[?]") != null);

    // Once ruled it is `done` and reads like anything else finished: the marker
    // tracks "awaiting a call", not the declaration.
    try f.run(&.{ "rule", &d.text, "RULED: no" });
    try f.run(&.{ "list", "--state", "done" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[?]") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "[x]") != null);
}

// ----- decisions survive compaction (01M2VFW5F) -----

test "a compacted RAISER's provenance survives on the task side, and a live decision can still find it" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The case the task-side `raised` field exists for: the raiser graduates
    // and is collected while the decision it raised is STILL LIVE.
    // `serializeState` drops every edge with a collected endpoint, so without
    // the tombstone recording it on the raiser's own record, the surviving
    // decision silently loses all trace of where it came from.
    const raiser = mintId();
    try f.store.append(.{ .add = .{ .id = raiser, .title = "the display fix", .short = raiser.text[0..9] } });
    try f.run(&.{ "decision", "does TODO.md want the annotation?", "--from", &raiser.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));

    try f.store.append(.{ .setState = .{ .id = raiser, .state = .archived } });
    try f.run(&.{"compact"});
    try f.reopen();

    // The raiser is gone from the live graph...
    try testing.expect(f.store.get(raiser) == null);
    // ...the decision is still live, and still knows who asked.
    try testing.expect(f.store.get(d) != null);
    const live_raisers = try f.store.raisersOf(alloc, d);
    defer alloc.free(live_raisers);
    try testing.expectEqual(@as(usize, 0), live_raisers.len); // the edge died with the raiser
    const gone = try f.store.compactedRaisers(alloc, d);
    defer alloc.free(gone);
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expect(gone[0].id.eql(raiser));

    try f.run(&.{ "show", &d.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "DECISION") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "compacted:") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "the display fix") != null);

    try f.run(&.{ "show", &d.text, "--json" });
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, f.out.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("decision").?.bool);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("raised_by").?.array.items.len);
}

test "tombstones --rebuild recovers `raised` too, and UPGRADES a record written without it (01M2VFW5F)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const raiser = mintId();
    const retracted = mintId();
    try f.store.append(.{ .add = .{ .id = raiser, .title = "the raiser", .short = raiser.text[0..9] } });
    try f.run(&.{ "decision", "a live fork", "--from", &raiser.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    // A provenance edge that was RETRACTED: `unraises` is a permanent tombstone
    // for the pair, so the reconstruction must not resurrect it just because a
    // `raises` exists somewhere in history — the same rule as `in`/`unin`.
    try f.store.append(.{ .add = .{ .id = retracted, .title = "mis-attributed" } });
    try f.store.append(.{ .raises = .{ .task = retracted, .decision = d } });
    try f.store.append(.{ .unraises = .{ .task = retracted, .decision = d } });
    try f.store.append(.{ .setState = .{ .id = raiser, .state = .archived } });

    try runGitOk(alloc, f.tmp.dir, &.{ "git", "init", "-q" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "config", "user.name", "trk test" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "add", ".tracker/log.jsonl" });
    try runGitOk(alloc, f.tmp.dir, &.{ "git", "commit", "-q", "-m", "before the compact" });

    try f.run(&.{"compact"});
    // Reproduce a record written by a reconstruction that predates `raised`, by
    // blanking the field the real one just wrote.
    {
        const bytes = try f.tmp.dir.readFileAlloc(io, ".tracker/tombstones.jsonl", alloc, .unlimited);
        defer alloc.free(bytes);
        var stale: std.ArrayList(u8) = .empty;
        defer stale.deinit(alloc);
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const open_at = std.mem.indexOf(u8, line, "\"raised\":[").?;
            const close_at = std.mem.indexOfScalarPos(u8, line, open_at, ']').?;
            try stale.appendSlice(alloc, line[0 .. open_at + "\"raised\":[".len]);
            try stale.appendSlice(alloc, line[close_at..]);
            // src=compact would be authoritative and never upgraded; the state
            // being repaired is a git-history reconstruction.
            const out = try std.mem.replaceOwned(u8, alloc, stale.items, "\"src\":\"compact\"", "\"src\":\"git-history\"");
            defer alloc.free(out);
            stale.clearRetainingCapacity();
            try stale.appendSlice(alloc, out);
            try stale.append(alloc, '\n');
        }
        try f.tmp.dir.writeFile(io, .{ .sub_path = ".tracker/tombstones.jsonl", .data = stale.items, .flags = .{} });
    }
    try f.reopen();

    // RED baseline: the record exists, the provenance does not.
    const before = try f.store.compactedRaisers(alloc, d);
    defer alloc.free(before);
    try testing.expectEqual(@as(usize, 0), before.len);

    // The rebuild repairs it in place instead of skipping it by id.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "1 existing record(s) upgraded") != null);
    const after = try f.store.compactedRaisers(alloc, d);
    defer alloc.free(after);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expect(after[0].id.eql(raiser));

    // The retracted edge was NOT resurrected.
    for (f.store.tombstones.items) |tb| {
        if (tb.id.eql(retracted)) try testing.expectEqual(@as(usize, 0), tb.raised.len);
    }

    // And it settles: nothing left to improve.
    try f.run(&.{ "tombstones", "--rebuild" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 existing record(s) upgraded") != null);
}

// ----- trk migrate-decisions (01M2VFX26) -----

test "migrate-decisions splits a tagged CARRIER without guessing which sentence is the fork" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const carrier = mintId();
    try f.store.append(.{ .add = .{
        .id = carrier,
        .title = "the display fix",
        .body = "Built it. OPEN QUESTION: does TODO.md want the annotation?",
        .short = carrier.text[0..9],
    } });
    try f.store.append(.{ .tag = .{ .id = carrier, .tag = "scott-decision" } });
    try f.store.append(.{ .tag = .{ .id = carrier, .tag = "ui" } });

    try f.run(&.{ "migrate-decisions", "--from-tag", "scott-decision" });

    // The CARRIER stays work, untouched apart from losing the tag. Declaring it
    // a decision outright would let `rule` close unbuilt work.
    const c = f.store.get(carrier).?;
    try testing.expect(!f.store.isDecision(carrier));
    try testing.expectEqualStrings("Built it. OPEN QUESTION: does TODO.md want the annotation?", c.body);
    try testing.expectEqual(tracker.State.open, c.state);
    for (c.tags.items) |tg| try testing.expect(!std.mem.eql(u8, tg, "scott-decision"));
    var kept_ui = false;
    for (c.tags.items) |tg| {
        if (std.mem.eql(u8, tg, "ui")) kept_ui = true;
    }
    try testing.expect(kept_ui);

    // A decision node now exists, declared, and wired back by provenance.
    const raised = try f.store.raisedBy(alloc, carrier);
    defer alloc.free(raised);
    try testing.expectEqual(@as(usize, 1), raised.len);
    const d = raised[0];
    try testing.expect(f.store.isDecision(d));
    // A SCAFFOLD: no body text copied, nothing parsed out of the carrier. The
    // title points back at where it came from so a human can retitle it.
    try testing.expectEqualStrings("", f.store.get(d).?.body);
    try testing.expect(std.mem.indexOf(u8, f.store.get(d).?.title, "the display fix") != null);

    // Idempotent: the tag is gone, so a second run splits nothing.
    try f.run(&.{ "migrate-decisions", "--from-tag", "scott-decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "0 tagged task(s) split") != null);
    const raised2 = try f.store.raisedBy(alloc, carrier);
    defer alloc.free(raised2);
    try testing.expectEqual(@as(usize, 1), raised2.len);
}

test "migrate-decisions REPORTS prose forks and files nothing from the scan" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const prose = mintId();
    const clean = mintId();
    try f.store.append(.{
        .add = .{
            .id = prose,
            .title = "other work",
            // Not colon-glued: the shape the old guard's classifier called
            // "prose-shaped" and would have let through if its refusal had ever
            // been narrowed. The finder is case-insensitive over hand-written prose.
            .body = "Done.\nfix note — the seq ordering under a standing arc is still wrong.",
        },
    });
    try f.store.append(.{ .add = .{ .id = clean, .title = "ordinary", .body = "nothing to see" } });

    const before = f.store.count();
    try f.run(&.{ "migrate-decisions", "--from-tag", "scott-decision" });

    try testing.expect(std.mem.indexOf(u8, f.out.items, "prose fork?") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "seq ordering under a standing arc") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "other work") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "ordinary") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "REPORTED, never filed") != null);

    // FILES NOTHING. Only a human knows which sentence is the fork, and
    // guessing is the failure the whole mechanism exists to end.
    try testing.expectEqual(before, f.store.count());
    try testing.expect(!f.store.isDecision(prose));
}

test "migrate-decisions: --from-tag is required (trk ships no project's vocabulary), and --dry-run writes nothing" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const carrier = mintId();
    try f.store.append(.{ .add = .{ .id = carrier, .title = "carrier" } });
    try f.store.append(.{ .tag = .{ .id = carrier, .tag = "needs-alice" } });

    try testing.expectEqual(
        cli.CliError.MissingArgument,
        f.runExpectErr(&.{"migrate-decisions"}),
    );
    try testing.expect(std.mem.indexOf(u8, f.out.items, "trk ships no default") != null);

    // Any repo's own tag works — the vocabulary is the caller's.
    const before = f.store.count();
    try f.run(&.{ "migrate-decisions", "--from-tag", "needs-alice", "--dry-run" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "would split") != null);
    try testing.expectEqual(before, f.store.count());
    try testing.expectEqual(@as(usize, 1), f.store.get(carrier).?.tags.items.len);

    try f.run(&.{ "migrate-decisions", "--from-tag", "needs-alice" });
    try testing.expectEqual(before + 1, f.store.count());
    try testing.expectEqual(@as(usize, 0), f.store.get(carrier).?.tags.items.len);
}

// ----- a ruled decision graduates, and the RULING is what graduates (01M2VPC6K) -----

test "archiving a ruled decision publishes the RULING, not just the question" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const work = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "real work" } });

    try f.run(&.{ "decision", "way A or way B?", "--blocks", &work.text });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    try f.run(&.{ "rule", &d.text, "RULED: way A, because B cannot express the standing case." });

    try f.run(&.{ "archive", "--out", "CL.md" });
    const cl = try f.tmp.dir.readFileAlloc(io, "CL.md", alloc, .unlimited);
    defer alloc.free(cl);

    // The ANSWER is the record. Before this, the bullet was built from the
    // title — so archiving a decision published the question and destroyed the
    // ruling, which is the node's entire value.
    try testing.expect(std.mem.indexOf(u8, cl, "RULED: way A, because B cannot express") != null);
    try testing.expect(std.mem.indexOf(u8, cl, "way A or way B?") != null);

    // And it did graduate — decisions are disposable BECAUSE the ruling landed.
    try f.reopen();
    try testing.expectEqual(tracker.State.archived, f.store.get(d).?.state);
}

test "archive.decisions_out routes a decision by NATURE, with no tag to forget" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    var sub = try f.tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{ \"archive\": { \"out\": \"CHANGELOG.md\", \"decisions_out\": \"DECISIONS.md\" } }",
        .flags = .{},
    });
    f.store.loadConfig();

    const work = mintId();
    try f.store.append(.{ .add = .{ .id = work, .title = "shipped work" } });
    try f.store.append(.{ .setState = .{ .id = work, .state = .done } });
    try f.run(&.{ "decision", "way A or way B?" });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    try f.run(&.{ "rule", &d.text, "RULED: way A." });

    try f.run(&.{"archive"});
    const dec = try f.tmp.dir.readFileAlloc(io, "DECISIONS.md", alloc, .unlimited);
    defer alloc.free(dec);
    const chg = try f.tmp.dir.readFileAlloc(io, "CHANGELOG.md", alloc, .unlimited);
    defer alloc.free(chg);

    // Split on nature alone — neither task carries a tag, and none was needed.
    try testing.expect(std.mem.indexOf(u8, dec, "way A or way B?") != null);
    try testing.expect(std.mem.indexOf(u8, dec, "shipped work") == null);
    try testing.expect(std.mem.indexOf(u8, chg, "shipped work") != null);
    try testing.expect(std.mem.indexOf(u8, chg, "way A or way B?") == null);
}

test "list hides completed work by default; --all and --state reach it (01M2VPC6K)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();
    const open_t = mintId();
    const done_t = mintId();
    const dropped_t = mintId();
    try f.store.append(.{ .add = .{ .id = open_t, .title = "still open" } });
    try f.store.append(.{ .add = .{ .id = done_t, .title = "finished" } });
    try f.store.append(.{ .setState = .{ .id = done_t, .state = .done } });
    try f.store.append(.{ .add = .{ .id = dropped_t, .title = "abandoned" } });
    try f.store.append(.{ .setState = .{ .id = dropped_t, .state = .dropped } });

    try f.run(&.{"list"});
    try testing.expect(std.mem.indexOf(u8, f.out.items, "still open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "finished") == null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "abandoned") == null);

    // Asked for specifically, they are all still reachable — nothing became
    // invisible, only un-defaulted.
    try f.run(&.{ "list", "--state", "done" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "finished") != null);
    try f.run(&.{ "list", "--all" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "still open") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "finished") != null);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "abandoned") != null);

    // A RULED decision is `done`, so it leaves the default listing the same way
    // — which is the accumulation this ruling exists to prevent.
    try f.run(&.{ "decision", "way A or B?" });
    const d = try tracker.ulid.parse(std.mem.trimEnd(u8, f.out.items, "\n"));
    try f.run(&.{ "list", "--decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "way A or B?") != null);
    try f.run(&.{ "rule", &d.text, "RULED: A." });
    try f.run(&.{ "list", "--decision" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "way A or B?") == null);
    try f.run(&.{ "list", "--decision", "--state", "done" });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "way A or B?") != null);
}
