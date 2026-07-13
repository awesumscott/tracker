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
    c: *cli.Cli,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !Fixture {
        const tmp = testing.tmpDir(.{});
        const store = try alloc.create(Store);
        store.* = Store.open(alloc, io, tmp.dir);
        try store.load();
        const out = try alloc.create(std.ArrayList(u8));
        out.* = .empty;
        const c = try alloc.create(cli.Cli);
        c.* = .{ .gpa = alloc, .io = io, .store = store, .dir = tmp.dir, .out = out };
        return .{ .tmp = tmp, .store = store, .out = out, .c = c, .alloc = alloc };
    }

    fn run(self: *Fixture, args: []const []const u8) !void {
        self.out.clearRetainingCapacity();
        try self.c.run(args);
    }

    /// Run expecting a CliError; returns the error so the test can match it.
    fn runExpectErr(self: *Fixture, args: []const []const u8) anyerror {
        self.out.clearRetainingCapacity();
        if (self.c.run(args)) |_| return error.TestUnexpectedSuccess else |e| return e;
    }

    fn deinit(self: *Fixture) void {
        self.c.prereq_scratch.deinit(self.alloc);
        self.alloc.destroy(self.c);
        self.out.deinit(self.alloc);
        self.alloc.destroy(self.out);
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

// ----------------------------------------------------------- prefix resolution

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
    try f.run(&.{ "dep", &a.text, &b.text });
    const e = f.runExpectErr(&.{ "dep", &b.text, &a.text });
    try testing.expectEqual(cli.CliError.DependencyCycle, e);
    try testing.expect(std.mem.indexOf(u8, f.out.items, "cycle") != null);
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

    // Extra args are an error.
    const e = f.runExpectErr(&.{ "compact", "extra" });
    try testing.expectEqual(error.UsageError, e);
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

// ----------------------------------------------------------- edit (Wave 5)

test "trk edit: title/body/add-tag/priority all apply; rm-tag removes" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    const task = mintId();
    try f.store.append(.{ .add = .{ .id = task, .title = "old title", .body = "old body", .tags = &.{"foo"} } });

    // Edit: change title, body, add tag, set priority.
    try f.run(&.{ "edit", &task.text, "--title", "new title", "--body", "new body", "--add-tag", "bar", "--priority", "5" });

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
    for (t2.tags.items) |tg| if (std.mem.eql(u8, tg, "foo")) { has_foo = true; };
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

// --------------------------------------------- per-verb --help (agent exploration)

test "every verb supports --help/-h and add --help mints no task" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc);
    defer f.deinit();

    // The full dispatch set. Kept in lockstep with the `verb_help` table via the
    // count assertion below, so a new verb without a help entry is caught.
    const verbs = [_][]const u8{
        "init",   "add",  "dep",     "undep", "in",   "state", "next", "list",
        "render", "tree", "compact", "archive", "doc", "show",  "edit", "log",
    };
    try testing.expectEqual(verbs.len, cli.Cli.verb_help.len);

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
    for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) { found = true; };
    try testing.expect(found);

    // undep removes it.
    try f.run(&.{ "undep", &a.text, &b.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer needs") != null);

    var still = false;
    for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) { still = true; };
    try testing.expect(!still);

    // a is now unblocked (no prereqs).
    const ready = try f.store.next(alloc);
    defer alloc.free(ready);
    var a_ready = false;
    for (ready) |id| if (id.eql(a)) { a_ready = true; };
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
        for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) { edge_present = true; };
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
        try f.store.append(.{ .dep = .{ .from = a, .to = b } });   // dep after — blocked
        var edge_present = false;
        for (f.store.needs.items) |e| if (e.from.eql(a) and e.to.eql(b)) { edge_present = true; };
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
    try f.run(&.{ "undep", &a.text, &b.text });
    try testing.expect(std.mem.indexOf(u8, f.out.items, "no longer needs") != null);
    try testing.expectEqual(@as(usize, 0), f.store.needs.items.len);
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
    try f.run(&.{ "edit", &id.text, "--body", body });
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
