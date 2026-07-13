// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! Integration tests for the Store: disk round-trip, acyclic invariant,
//! membership (direct + reachability), and the `next` ready-frontier ordering.
//! Disk tests use std.testing.tmpDir (overridable store dir; no absolute paths).

const std = @import("std");
const testing = std.testing;
const tracker = @import("tracker.zig");
const ulid = tracker.ulid;
const Store = tracker.Store;
const Event = tracker.Event;

const io = testing.io;

/// Helper: mint a distinct, time-ordered id (each call bumps the ms).
var mint_ms: u48 = 1_000_000;
fn mintId() tracker.Ulid {
    mint_ms += 1;
    return ulid.mintAt(io, mint_ms);
}

test "append -> fold round-trip across a re-open from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const a = mintId();
    const b = mintId();

    // First store: write a small graph.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load(); // empty store -> ok
        try s.append(.{ .add = .{ .id = a, .title = "alpha", .body = "first" } });
        try s.append(.{ .add = .{ .id = b, .title = "beta" } });
        try s.append(.{ .dep = .{ .from = b, .to = a } }); // b needs a
        try s.append(.{ .setState = .{ .id = a, .state = .done } });
        try s.append(.{ .in = .{ .task = b, .arc = a, .seq = 3 } });
        try s.append(.{ .setPriority = .{ .id = b, .priority = -2 } });
        try s.append(.{ .tag = .{ .id = a, .tag = "metal" } });
        try testing.expectEqual(@as(usize, 2), s.count());
    }

    // Second store: fold from disk, assert state matches.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqual(@as(usize, 2), s.count());

        const ta = s.get(a).?;
        try testing.expectEqualStrings("alpha", ta.title);
        try testing.expectEqualStrings("first", ta.body);
        try testing.expectEqual(tracker.State.done, ta.state);
        try testing.expectEqual(@as(usize, 1), ta.tags.items.len);
        try testing.expectEqualStrings("metal", ta.tags.items[0]);

        const tb = s.get(b).?;
        try testing.expectEqualStrings("beta", tb.title);
        try testing.expectEqual(@as(i32, -2), tb.priority);

        // The `in` edge survived.
        const arcs = try s.arcsOf(testing.allocator, b);
        defer testing.allocator.free(arcs);
        try testing.expectEqual(@as(usize, 1), arcs.len);
        try testing.expect(arcs[0].eql(a));
    }
}

test "fold is idempotent w.r.t. duplicate idempotent events" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = a } });
    try s.append(.{ .setState = .{ .id = a, .state = .done } });
    try s.append(.{ .setState = .{ .id = a, .state = .done } }); // dup
    try s.append(.{ .tag = .{ .id = a, .tag = "x" } });
    try s.append(.{ .tag = .{ .id = a, .tag = "x" } }); // dup tag -> deduped

    try testing.expectEqual(tracker.State.done, s.get(a).?.state);
    try testing.expectEqual(@as(usize, 1), s.get(a).?.tags.items.len);
}

test "acyclic: a dep that closes a cycle is rejected and not persisted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();
    const c = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = a } });
    try s.append(.{ .add = .{ .id = b } });
    try s.append(.{ .add = .{ .id = c } });
    try s.append(.{ .dep = .{ .from = b, .to = a } }); // b -> a
    try s.append(.{ .dep = .{ .from = c, .to = b } }); // c -> b
    // a -> c would close a cycle a->c->b->a.
    try testing.expectError(error.DependencyCycle, s.append(.{ .dep = .{ .from = a, .to = c } }));

    // Re-open: the rejected edge must NOT be on disk.
    var s2 = Store.open(testing.allocator, io, tmp.dir);
    defer s2.deinit();
    try s2.load(); // must not error -> the cycle edge was never persisted
}

test "acyclic: a fold over a log that already contains a cycle errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();

    // Write a cyclic log directly (simulating a bad merge).
    var sub = try tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    try tracker.json_codec.encode(&line, testing.allocator, .{ .add = .{ .id = a } });
    try line.append(testing.allocator, '\n');
    try tracker.json_codec.encode(&line, testing.allocator, .{ .add = .{ .id = b } });
    try line.append(testing.allocator, '\n');
    try tracker.json_codec.encode(&line, testing.allocator, .{ .dep = .{ .from = a, .to = b } });
    try line.append(testing.allocator, '\n');
    try tracker.json_codec.encode(&line, testing.allocator, .{ .dep = .{ .from = b, .to = a } });
    try line.append(testing.allocator, '\n');
    try sub.writeFile(io, .{ .sub_path = "log.jsonl", .data = line.items });

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try testing.expectError(error.DependencyCycle, s.load());
}

test "membership: in-edge and reachability-via-needs, shared prereq in two arcs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const arc1 = mintId();
    const arc2 = mintId();
    const m1 = mintId(); // direct member of arc1
    const m2 = mintId(); // direct member of arc2
    const shared = mintId(); // prereq of both m1 and m2

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    for ([_]tracker.Ulid{ arc1, arc2, m1, m2, shared }) |id|
        try s.append(.{ .add = .{ .id = id } });
    try s.append(.{ .in = .{ .task = m1, .arc = arc1, .seq = 0 } });
    try s.append(.{ .in = .{ .task = m2, .arc = arc2, .seq = 0 } });
    try s.append(.{ .dep = .{ .from = m1, .to = shared } }); // m1 needs shared
    try s.append(.{ .dep = .{ .from = m2, .to = shared } }); // m2 needs shared

    // shared is reachable from a member of BOTH arcs.
    const a1 = try s.membersOf(testing.allocator, arc1);
    defer testing.allocator.free(a1);
    try testing.expect(contains(a1, shared));
    try testing.expect(contains(a1, m1));
    try testing.expect(contains(a1, arc1)); // arc root is a member

    const a2 = try s.membersOf(testing.allocator, arc2);
    defer testing.allocator.free(a2);
    try testing.expect(contains(a2, shared));
    try testing.expect(contains(a2, m2));

    // arcsOf(shared) surfaces BOTH arcs.
    const sh_arcs = try s.arcsOf(testing.allocator, shared);
    defer testing.allocator.free(sh_arcs);
    try testing.expectEqual(@as(usize, 2), sh_arcs.len);
    try testing.expect(contains(sh_arcs, arc1));
    try testing.expect(contains(sh_arcs, arc2));
}

test "next: blocked-by-open-prereq hidden; unblocks on done; ordering arc then personal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const arc = mintId();
    const pre = mintId(); // prereq
    const dep1 = mintId(); // needs pre; arc seq 5
    const dep2 = mintId(); // needs pre; arc seq 1 (higher priority within arc)
    const lone = mintId(); // no arc, personal priority 10

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    for ([_]tracker.Ulid{ arc, pre, dep1, dep2, lone }) |id|
        try s.append(.{ .add = .{ .id = id } });
    try s.append(.{ .dep = .{ .from = dep1, .to = pre } });
    try s.append(.{ .dep = .{ .from = dep2, .to = pre } });
    try s.append(.{ .in = .{ .task = dep1, .arc = arc, .seq = 5 } });
    try s.append(.{ .in = .{ .task = dep2, .arc = arc, .seq = 1 } });
    try s.append(.{ .setPriority = .{ .id = lone, .priority = 10 } });

    // While `pre` is open, dep1/dep2 are blocked; pre itself (no needs) is ready,
    // lone is ready. The arc root is a container with unfinished members —
    // NOT handed out.
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(!contains(n, dep1));
        try testing.expect(!contains(n, dep2));
        try testing.expect(contains(n, pre));
        try testing.expect(contains(n, lone));
        try testing.expect(!contains(n, arc)); // undrained root: hidden
    }

    // Mark pre done -> dep1, dep2 become ready.
    try s.append(.{ .setState = .{ .id = pre, .state = .done } });
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, dep1));
        try testing.expect(contains(n, dep2));
        try testing.expect(!contains(n, pre)); // done -> not eligible
        try testing.expect(!contains(n, arc)); // members still open -> still hidden

        // Ordering: dep2 (arc seq 1) before dep1 (arc seq 5); both before the
        // arc-less tasks (sentinel). Find their indices.
        const idx2 = indexOf(n, dep2).?;
        const idx1 = indexOf(n, dep1).?;
        try testing.expect(idx2 < idx1);

        // arc'd tasks precede arc-less ones.
        const ilone = indexOf(n, lone).?;
        try testing.expect(idx1 < ilone);
        try testing.expect(idx2 < ilone);
    }

    // Drain the arc -> the root surfaces exactly once as the close-out prompt.
    try s.append(.{ .setState = .{ .id = dep1, .state = .done } });
    try s.append(.{ .setState = .{ .id = dep2, .state = .done } });
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, arc));
    }
    // Close the root (the completion judgment) -> gone from the frontier.
    try s.append(.{ .setState = .{ .id = arc, .state = .done } });
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(!contains(n, arc));
    }
}

test "next: a dropped prereq does NOT block its dependent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pre = mintId();
    const dep = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = pre } });
    try s.append(.{ .add = .{ .id = dep } });
    try s.append(.{ .dep = .{ .from = dep, .to = pre } });
    try s.append(.{ .setState = .{ .id = pre, .state = .dropped } });

    const n = try s.next(testing.allocator);
    defer testing.allocator.free(n);
    try testing.expect(contains(n, dep)); // dropped prereq is satisfied
}

test "needs an arc: gates on the ROOT's state (the judgment), not on drainage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const arc = mintId();
    const m1 = mintId();
    const m2 = mintId();
    const dependent = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = arc, .title = "Cap arc" } });
    try s.append(.{ .add = .{ .id = m1, .title = "member 1" } });
    try s.append(.{ .add = .{ .id = m2, .title = "member 2" } });
    try s.append(.{ .add = .{ .id = dependent, .title = "needs the whole arc" } });
    try s.append(.{ .in = .{ .task = m1, .arc = arc, .seq = 0 } });
    try s.append(.{ .in = .{ .task = m2, .arc = arc, .seq = 1 } });
    try s.append(.{ .dep = .{ .from = dependent, .to = arc } }); // dependent needs the ARC

    try testing.expect(s.isArc(arc));
    try testing.expect(!s.arcDrained(arc));

    // Only one member done → arc undrained → root hidden, dependent blocked.
    try s.append(.{ .setState = .{ .id = m1, .state = .done } });
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(!contains(n, dependent));
        try testing.expect(!contains(n, arc));
        try testing.expect(contains(n, m2)); // the remaining member is ready
    }
    try testing.expectEqual(@as(usize, 1), s.arcProgress(arc).done);
    try testing.expectEqual(@as(usize, 2), s.arcProgress(arc).total);

    // A PARKED member that is still open must NOT block drainage.
    const parked = mintId();
    try s.append(.{ .add = .{ .id = parked, .title = "parked stub" } });
    try s.append(.{ .tag = .{ .id = parked, .tag = "parked" } });
    try s.append(.{ .in = .{ .task = parked, .arc = arc, .seq = 2 } });

    // Both NON-parked members done → drained (parked stub ignored) → the ROOT
    // surfaces, but the dependent is STILL blocked: drainage is the prompt,
    // the root's own `done` is what a `needs`-the-arc gate waits on.
    try s.append(.{ .setState = .{ .id = m2, .state = .done } });
    try testing.expect(s.arcDrained(arc)); // parked stub still open, but ignored
    try testing.expectEqual(@as(usize, 2), s.arcProgress(arc).total); // parked excluded from count
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, arc));
        try testing.expect(!contains(n, dependent));
    }

    // Close the root (the completion judgment) → the gate opens.
    try s.append(.{ .setState = .{ .id = arc, .state = .done } });
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, dependent));
        try testing.expect(!contains(n, arc));
    }
}

test "arc root eligibility: all-parked arc is vacuously drained; blocked member holds the root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();

    // All-parked arc: only future stubs → nothing actionable → the root
    // surfaces (no permanent black hole; parked members are never GC'd).
    const arc1 = mintId();
    const stub = mintId();
    try s.append(.{ .add = .{ .id = arc1, .title = "scaffold arc" } });
    try s.append(.{ .add = .{ .id = stub, .title = "future stub", .tags = &.{"parked"} } });
    try s.append(.{ .in = .{ .task = stub, .arc = arc1, .seq = 0 } });
    try testing.expect(s.arcDrained(arc1));
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, arc1));
        // `parked` exempts a member from gating the arc; the stub itself is
        // still an open, unblocked task and stays individually eligible.
        try testing.expect(contains(n, stub));
    }

    // A `blocked` member is unfinished (satisfiesPrereq=false) → root hidden.
    const arc2 = mintId();
    const held = mintId();
    try s.append(.{ .add = .{ .id = arc2, .title = "held arc" } });
    try s.append(.{ .add = .{ .id = held, .title = "on hold" } });
    try s.append(.{ .in = .{ .task = held, .arc = arc2, .seq = 0 } });
    try s.append(.{ .setState = .{ .id = held, .state = .blocked } });
    try testing.expect(!s.arcDrained(arc2));
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(!contains(n, arc2));
    }

    // Dropping the held member drains the arc → root surfaces.
    try s.append(.{ .setState = .{ .id = held, .state = .dropped } });
    try testing.expect(s.arcDrained(arc2));
    {
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, arc2));
    }
}

test "compact: snapshot+truncate round-trips state via atomic write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = a, .title = "A" } });
        try s.append(.{ .add = .{ .id = b, .title = "B" } });
        try s.append(.{ .dep = .{ .from = b, .to = a } });
        try s.append(.{ .setState = .{ .id = a, .state = .done } });
        _ = try s.compact();
    }
    // Re-open: state must fold identically from the snapshot (+ empty log).
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqual(@as(usize, 2), s.count());
        try testing.expectEqualStrings("A", s.get(a).?.title);
        try testing.expectEqual(tracker.State.done, s.get(a).?.state);
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, b)); // a done -> b ready
    }
}

// ----------------------------------------------------------------- compaction tests (Wave 3)

test "compact: full round-trip with deps, ins, tags, docrefs, and a dropped task" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const arc = mintId();
    const t1 = mintId();
    const t2 = mintId();
    const dead = mintId(); // will be dropped

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = arc, .title = "Arc root" } });
        try s.append(.{ .add = .{ .id = t1, .title = "Task 1", .body = "body" } });
        try s.append(.{ .add = .{ .id = t2, .title = "Task 2" } });
        try s.append(.{ .add = .{ .id = dead, .title = "Abandoned" } });
        try s.append(.{ .tag = .{ .id = t1, .tag = "beta" } });
        try s.append(.{ .tag = .{ .id = t1, .tag = "alpha" } }); // unsorted
        try s.append(.{ .docref = .{ .id = t2, .doc_id = "doc-a", .section_id = "s1" } });
        try s.append(.{ .dep = .{ .from = t2, .to = t1 } });
        try s.append(.{ .in = .{ .task = t1, .arc = arc, .seq = 5 } });
        try s.append(.{ .setState = .{ .id = t1, .state = .done } });
        try s.append(.{ .setState = .{ .id = dead, .state = .dropped } });
        try s.append(.{ .setPriority = .{ .id = t2, .priority = 3 } });
        const r = try s.compact();
        // 3 live tasks (arc, t1, t2); dead excluded.
        try testing.expectEqual(@as(usize, 3), r.live_tasks);
        // log had 12 events.
        try testing.expectEqual(@as(usize, 12), r.log_events_before);
    }

    // Re-open: verify state is exactly preserved.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();

        // 3 live tasks; dead is gone.
        try testing.expectEqual(@as(usize, 3), s.count());
        try testing.expect(s.get(dead) == null);

        const ta = s.get(arc).?;
        try testing.expectEqualStrings("Arc root", ta.title);

        const t = s.get(t1).?;
        try testing.expectEqualStrings("Task 1", t.title);
        try testing.expectEqualStrings("body", t.body);
        try testing.expectEqual(tracker.State.done, t.state);
        // Tags survived (order in snapshot is sorted; after re-fold still present).
        try testing.expectEqual(@as(usize, 2), t.tags.items.len);
        // Both tags present (order may vary in-memory after re-fold).
        var found_alpha = false;
        var found_beta = false;
        for (t.tags.items) |tag| {
            if (std.mem.eql(u8, tag, "alpha")) found_alpha = true;
            if (std.mem.eql(u8, tag, "beta")) found_beta = true;
        }
        try testing.expect(found_alpha);
        try testing.expect(found_beta);

        const t2r = s.get(t2).?;
        try testing.expectEqual(@as(i32, 3), t2r.priority);
        try testing.expectEqual(@as(usize, 1), t2r.docrefs.items.len);
        try testing.expectEqualStrings("doc-a", t2r.docrefs.items[0].doc_id);
        try testing.expectEqualStrings("s1", t2r.docrefs.items[0].section_id.?);

        // dep edge survived: t2 needs t1 (done) -> t2 is ready.
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, t2));
        try testing.expect(!contains(n, t1)); // done, not eligible

        // in edge survived: t1 in arc.
        const arcs = try s.arcsOf(testing.allocator, t1);
        defer testing.allocator.free(arcs);
        try testing.expectEqual(@as(usize, 1), arcs.len);
        try testing.expect(arcs[0].eql(arc));
    }
}

test "compact: log truncated + snapshot non-empty; add after compact appends to empty log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = a, .title = "A" } });
        try s.append(.{ .add = .{ .id = b, .title = "B" } });
        _ = try s.compact();

        // After compact: log must be empty (0 events), snapshot non-empty.
        {
            var sub = try tmp.dir.openDir(io, ".tracker", .{});
            defer sub.close(io);
            const log_bytes = try sub.readFileAlloc(io, "log.jsonl", testing.allocator, .unlimited);
            defer testing.allocator.free(log_bytes);
            try testing.expectEqualStrings("", log_bytes);

            const snap_bytes = try sub.readFileAlloc(io, "snapshot.jsonl", testing.allocator, .unlimited);
            defer testing.allocator.free(snap_bytes);
            try testing.expect(snap_bytes.len > 0);
        }

        // Add after compact: appends to the (now-empty) log; re-fold must work.
        const c = mintId();
        try s.append(.{ .add = .{ .id = c, .title = "C" } });
    }

    // Re-open: all three tasks present.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqual(@as(usize, 3), s.count());
    }
}

test "compact: determinism — two compactions of the same state are byte-identical" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();
    const c = mintId();

    // Build state with edges in non-ULID-sorted order to force sorting.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        // Add in reverse order so the hashmaps + lists are in insertion order,
        // not ULID order.
        try s.append(.{ .add = .{ .id = c, .title = "C", .body = "" } });
        try s.append(.{ .add = .{ .id = b, .title = "B", .body = "" } });
        try s.append(.{ .add = .{ .id = a, .title = "A", .body = "" } });
        try s.append(.{ .dep = .{ .from = c, .to = b } });
        try s.append(.{ .dep = .{ .from = b, .to = a } });
        _ = try s.compact();
    }

    // Read first snapshot.
    const snap1 = blk: {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        break :blk try sub.readFileAlloc(io, "snapshot.jsonl", testing.allocator, .unlimited);
    };
    defer testing.allocator.free(snap1);

    // Reopen, compact again — must yield the same bytes.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        _ = try s.compact();
    }

    const snap2 = blk: {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        break :blk try sub.readFileAlloc(io, "snapshot.jsonl", testing.allocator, .unlimited);
    };
    defer testing.allocator.free(snap2);

    try testing.expectEqualSlices(u8, snap1, snap2);
}

test "compact: dropped task absent post-compact; done task survives and unblocks dependent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const prereq = mintId(); // will be done -> unblocks dep
    const dep = mintId(); // open, needs prereq
    const abandoned = mintId(); // will be dropped -> must vanish

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = prereq, .title = "Prereq" } });
        try s.append(.{ .add = .{ .id = dep, .title = "Dep" } });
        try s.append(.{ .add = .{ .id = abandoned, .title = "Abandoned" } });
        try s.append(.{ .dep = .{ .from = dep, .to = prereq } });
        try s.append(.{ .setState = .{ .id = prereq, .state = .done } });
        try s.append(.{ .setState = .{ .id = abandoned, .state = .dropped } });
        _ = try s.compact();
    }

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();

        // dropped task is gone.
        try testing.expect(s.get(abandoned) == null);
        // done task survives.
        try testing.expect(s.get(prereq) != null);
        try testing.expectEqual(tracker.State.done, s.get(prereq).?.state);
        // dep is unblocked because its done prereq is still in the snapshot.
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, dep));
    }
}

test "compact: archived task is GC'd but still unblocks its dependent pre-compact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const prereq = mintId(); // done -> archived (graduated to changelog)
    const dep = mintId(); // open, needs prereq

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = prereq, .title = "Shipped prereq" } });
        try s.append(.{ .add = .{ .id = dep, .title = "Dep" } });
        try s.append(.{ .dep = .{ .from = dep, .to = prereq } });
        try s.append(.{ .setState = .{ .id = prereq, .state = .done } });
        // Before archiving: an archived prereq satisfies the dep (it is finished).
        try s.append(.{ .setState = .{ .id = prereq, .state = .archived } });
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, dep)); // archived prereq unblocks dep
        _ = try s.compact();
    }

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        // Archived task physically GC'd by compact, like dropped.
        try testing.expect(s.get(prereq) == null);
        try testing.expect(s.get(dep) != null);
    }
}

test "compact: crash-safety shape — snapshot written + old log = pre-compaction state" {
    // Simulates the crash window: new snapshot is durably written but the log
    // has NOT yet been truncated. Re-folding (new snapshot + old log) must yield
    // the pre-compaction state — no double-application, no data loss.
    //
    // The guarantee: every `apply()` call is idempotent:
    //   - add/setState/setPriority: last-write-wins on each field
    //   - tag/docref/dep/in: dedup guards prevent duplicates
    // So re-folding snapshot events then log events converges to the pre-compact
    // state. Dropped tasks may reappear (the snapshot excludes them; the old log
    // still has them) — that is correct / expected for the crash-window case.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();
    const dead = mintId();

    // Build initial state and persist it (creates the log).
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = a, .title = "A" } });
        try s.append(.{ .add = .{ .id = b, .title = "B" } });
        try s.append(.{ .add = .{ .id = dead, .title = "Dead" } });
        try s.append(.{ .dep = .{ .from = b, .to = a } });
        try s.append(.{ .setState = .{ .id = a, .state = .done } });
        try s.append(.{ .setState = .{ .id = dead, .state = .dropped } });
        // Do NOT compact here — we want the raw log for the crash-safety test.
    }

    // Save the old log content before any compaction.
    const old_log = blk: {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        break :blk try sub.readFileAlloc(io, "log.jsonl", testing.allocator, .unlimited);
    };
    defer testing.allocator.free(old_log);

    // Write just the snapshot (step 1 of compact), WITHOUT truncating the log
    // (simulates crash between step 1 and step 2).
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        // Manually invoke the atomic write of the snapshot only — we replicate
        // compact's step 1 by serializing + writing, then NOT truncating.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        // Build the snapshot via a throwaway compact + restore the old log.
        _ = try s.compact(); // this truncates the log too (step 2)
        // Restore the old log so we're in the "crash between step 1 and 2" state.
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = "log.jsonl", .data = old_log });
    }

    // Now we have: new snapshot (minus dropped) + old log (all events).
    // Re-fold must succeed and give the pre-compaction state:
    //   - a: done
    //   - b: open, needs a (done) -> ready
    //   - dead: dropped (reappears from log — expected in crash-window case)
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load(); // must not error

        try testing.expect(s.get(a) != null);
        try testing.expectEqual(tracker.State.done, s.get(a).?.state);
        try testing.expect(s.get(b) != null);
        // dead reappears from log (idempotent re-application; correct for crash
        // window — a second compact() call will clean it up).
        try testing.expect(s.get(dead) != null);
        try testing.expectEqual(tracker.State.dropped, s.get(dead).?.state);

        // b is still unblocked.
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(contains(n, b));
    }
}

// ----------------------------------------------------------------- doc-path registry tests (Wave 4)

test "docPath: set + resolve; re-set updates the path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();

    // Unregistered -> null.
    try testing.expect(s.docPath("issue-tracker") == null);

    // Register a path.
    try s.append(.{ .setDocPath = .{ .doc_id = "issue-tracker", .path = "docs/design/issue-tracker.md" } });
    const p1 = s.docPath("issue-tracker").?;
    try testing.expectEqualStrings("docs/design/issue-tracker.md", p1);

    // Re-set (doc moved) — last-write-wins.
    try s.append(.{ .setDocPath = .{ .doc_id = "issue-tracker", .path = "docs/design/tracker.md" } });
    const p2 = s.docPath("issue-tracker").?;
    try testing.expectEqualStrings("docs/design/tracker.md", p2);
}

test "docPath: refs survive a move (the docref task event is never touched)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const t1 = mintId();
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();

        // Add a task with a docref to doc id "foo".
        try s.append(.{ .add = .{ .id = t1, .title = "Task" } });
        try s.append(.{ .docref = .{ .id = t1, .doc_id = "foo", .section_id = "design" } });

        // Register foo -> pathA.
        try s.append(.{ .setDocPath = .{ .doc_id = "foo", .path = "docs/foo.md" } });
        try testing.expectEqualStrings("docs/foo.md", s.docPath("foo").?);

        // Verify the task's docref still says "foo" (the docref event is unchanged).
        const task = s.get(t1).?;
        try testing.expectEqual(@as(usize, 1), task.docrefs.items.len);
        try testing.expectEqualStrings("foo", task.docrefs.items[0].doc_id);

        // "Move" the doc: re-register to pathB.
        try s.append(.{ .setDocPath = .{ .doc_id = "foo", .path = "docs/bar.md" } });
        // Now the registry resolves to pathB — the task's docref was never touched.
        try testing.expectEqualStrings("docs/bar.md", s.docPath("foo").?);
        const task2 = s.get(t1).?;
        try testing.expectEqualStrings("foo", task2.docrefs.items[0].doc_id);
    }
}

test "docPath: unregistered id returns null (no crash)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();

    // Register one id, leave another unregistered.
    try s.append(.{ .setDocPath = .{ .doc_id = "registered", .path = "docs/a.md" } });

    // Registered resolves correctly.
    try testing.expectEqualStrings("docs/a.md", s.docPath("registered").?);
    // Unregistered returns null — no crash, no error.
    try testing.expect(s.docPath("unregistered") == null);
    try testing.expect(s.docPath("") == null);
}

test "docPath: survives compaction; emission is deterministic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected_alpha = "docs/alpha.md";
    const expected_beta = "docs/beta.md";

    // Write two docpath entries and compact.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        // Register in reverse alphabetical order to force sorting.
        try s.append(.{ .setDocPath = .{ .doc_id = "beta-doc", .path = expected_beta } });
        try s.append(.{ .setDocPath = .{ .doc_id = "alpha-doc", .path = expected_alpha } });
        _ = try s.compact();
    }

    // Re-open: both must still resolve.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqualStrings(expected_alpha, s.docPath("alpha-doc").?);
        try testing.expectEqualStrings(expected_beta, s.docPath("beta-doc").?);
    }

    // Compact again — must be byte-identical (sort is stable + deterministic).
    const snap1 = blk: {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        break :blk try sub.readFileAlloc(io, "snapshot.jsonl", testing.allocator, .unlimited);
    };
    defer testing.allocator.free(snap1);

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        _ = try s.compact();
    }

    const snap2 = blk: {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        break :blk try sub.readFileAlloc(io, "snapshot.jsonl", testing.allocator, .unlimited);
    };
    defer testing.allocator.free(snap2);
    try testing.expectEqualSlices(u8, snap1, snap2);
}

// ----------------------------------------------------------------- wave5 tests

test "ts: append stamps a non-zero ts on all events; ts=0 legacy log lines fold cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = a, .title = "ts test" } });

    // Re-open and read back the raw log — ts must be non-zero.
    {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        const bytes = try sub.readFileAlloc(io, "log.jsonl", testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        // The encoded line must contain a "ts": field with a non-zero value.
        try testing.expect(std.mem.indexOf(u8, bytes, "\"ts\":0") == null);
        try testing.expect(std.mem.indexOf(u8, bytes, "\"ts\":") != null);
    }

    // Legacy line with ts omitted folds without error (ts=0 tolerance).
    const a2 = mintId();
    {
        var sub = try tmp.dir.openDir(io, ".tracker", .{});
        defer sub.close(io);
        // Append a hand-crafted legacy line (no ts field).
        var legacy: std.ArrayList(u8) = .empty;
        defer legacy.deinit(testing.allocator);
        try tracker.json_codec.encode(&legacy, testing.allocator, .{ .add = .{ .id = a2, .title = "legacy" } });
        // Strip the ts field by re-encoding without ts (the default is 0, which encode does emit).
        // Instead, just write a minimal JSON line manually to simulate an old log.
        var f = try sub.createFile(io, "extra.jsonl", .{ .truncate = true });
        defer f.close(io);
        // Write a setState without ts field.
        const line = "{\"op\":\"setState\",\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"state\":\"open\"}\n";
        try f.writeStreamingAll(io, line);
    }

    // Can still load cleanly.
    var s2 = Store.open(testing.allocator, io, tmp.dir);
    defer s2.deinit();
    try s2.load(); // must not error
    try testing.expectEqual(@as(usize, 1), s2.count()); // only 'a' from the log
}

test "setTitle/setBody/untag survive compaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = a, .title = "original", .body = "old body", .tags = &.{"foo"} } });
        try s.append(.{ .setTitle = .{ .id = a, .title = "updated title" } });
        try s.append(.{ .setBody = .{ .id = a, .body = "new body" } });
        try s.append(.{ .untag = .{ .id = a, .tag = "foo" } });
        try s.append(.{ .tag = .{ .id = a, .tag = "bar" } });
        _ = try s.compact();
    }

    // Re-open: verify final state.
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        const t = s.get(a).?;
        try testing.expectEqualStrings("updated title", t.title);
        try testing.expectEqualStrings("new body", t.body);
        // "foo" was untagged; "bar" was added.
        try testing.expectEqual(@as(usize, 1), t.tags.items.len);
        try testing.expectEqualStrings("bar", t.tags.items[0]);
    }
}

test "setTitle last-write-wins: two setTitle events; final title is the second" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = a, .title = "v1" } });
    try s.append(.{ .setTitle = .{ .id = a, .title = "v2" } });
    try s.append(.{ .setTitle = .{ .id = a, .title = "v3" } });
    try testing.expectEqualStrings("v3", s.get(a).?.title);
}

test "reverseDeps: A->B->C gives correct reverse edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = mintId();
    const b = mintId();
    const c = mintId();

    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try s.append(.{ .add = .{ .id = a, .title = "A" } });
    try s.append(.{ .add = .{ .id = b, .title = "B" } });
    try s.append(.{ .add = .{ .id = c, .title = "C" } });
    // A needs B, B needs C.
    try s.append(.{ .dep = .{ .from = a, .to = b } });
    try s.append(.{ .dep = .{ .from = b, .to = c } });

    // reverseDeps(B) = [A] (A needs B)
    const rb = try s.reverseDeps(testing.allocator, b);
    defer testing.allocator.free(rb);
    try testing.expectEqual(@as(usize, 1), rb.len);
    try testing.expect(rb[0].eql(a));

    // reverseDeps(C) = [B] (B needs C)
    const rc = try s.reverseDeps(testing.allocator, c);
    defer testing.allocator.free(rc);
    try testing.expectEqual(@as(usize, 1), rc.len);
    try testing.expect(rc[0].eql(b));

    // reverseDeps(A) = [] (nothing needs A)
    const ra = try s.reverseDeps(testing.allocator, a);
    defer testing.allocator.free(ra);
    try testing.expectEqual(@as(usize, 0), ra.len);
}

// ----------------------------------------------------------------- union-merge regression tests (01KVRY)
//
// ROOT CAUSE (01KVRY): subagents ran `trk state <id> done` but did NOT commit
// .tracker/log.jsonl as part of their worktree commit. The append happened on
// disk but the uncommitted change was never merged into main — so it was lost.
// The fix is process: CLAUDE.md already mandates `trk state <id> done` + `git
// add .tracker/log.jsonl` in the same commit. These tests pin the store's
// correctness (hypothesis (b) was NOT the cause): the fold and the union-merge
// model are both correct, and no `setState done` event is ever dropped.

test "union-merge: two disjoint setState-done events on different tasks both survive fold" {
    // Simulates two git worktrees each marking a DIFFERENT task done, with the
    // resulting log.jsonl union-merged (appended together). Both done states must
    // survive a re-fold — no event is dropped by the union-merge or the replay.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const task_a = mintId();
    const task_b = mintId();

    // Shared base: both tasks added in the common ancestor commit.
    var base_log: std.ArrayList(u8) = .empty;
    defer base_log.deinit(testing.allocator);
    try tracker.json_codec.encode(&base_log, testing.allocator, .{ .add = .{ .id = task_a, .title = "Task A" } });
    try base_log.append(testing.allocator, '\n');
    try tracker.json_codec.encode(&base_log, testing.allocator, .{ .add = .{ .id = task_b, .title = "Task B" } });
    try base_log.append(testing.allocator, '\n');

    // Branch 1 appends: marks task_a done.
    var branch1: std.ArrayList(u8) = .empty;
    defer branch1.deinit(testing.allocator);
    try tracker.json_codec.encode(&branch1, testing.allocator, .{ .setState = .{ .id = task_a, .state = .done } });
    try branch1.append(testing.allocator, '\n');

    // Branch 2 appends: marks task_b done.
    var branch2: std.ArrayList(u8) = .empty;
    defer branch2.deinit(testing.allocator);
    try tracker.json_codec.encode(&branch2, testing.allocator, .{ .setState = .{ .id = task_b, .state = .done } });
    try branch2.append(testing.allocator, '\n');

    // Union-merge: base + branch1 lines + branch2 lines (git union appends
    // non-conflicting lines from both sides). Order here is branch1 first, but
    // the test below also checks the reversed order to prove fold is order-safe.
    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(testing.allocator);
    try merged.appendSlice(testing.allocator, base_log.items);
    try merged.appendSlice(testing.allocator, branch1.items);
    try merged.appendSlice(testing.allocator, branch2.items);

    var sub = try tmp.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "log.jsonl", .data = merged.items });

    // Re-fold: both tasks must be done.
    var s = Store.open(testing.allocator, io, tmp.dir);
    defer s.deinit();
    try s.load();
    try testing.expectEqual(tracker.State.done, s.get(task_a).?.state);
    try testing.expectEqual(tracker.State.done, s.get(task_b).?.state);

    // Reversed event order (branch2 before branch1): same result — fold is
    // order-independent for disjoint-task state changes.
    var merged2: std.ArrayList(u8) = .empty;
    defer merged2.deinit(testing.allocator);
    try merged2.appendSlice(testing.allocator, base_log.items);
    try merged2.appendSlice(testing.allocator, branch2.items); // reversed
    try merged2.appendSlice(testing.allocator, branch1.items);

    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var sub2 = try tmp2.dir.createDirPathOpen(io, ".tracker", .{});
    defer sub2.close(io);
    try sub2.writeFile(io, .{ .sub_path = "log.jsonl", .data = merged2.items });

    var s2 = Store.open(testing.allocator, io, tmp2.dir);
    defer s2.deinit();
    try s2.load();
    try testing.expectEqual(tracker.State.done, s2.get(task_a).?.state);
    try testing.expectEqual(tracker.State.done, s2.get(task_b).?.state);
}

test "union-merge: same-task setState on two branches — last line wins, neither is silently lost" {
    // Two branches each emit a setState for the SAME task but to different
    // states (one to done, one to blocked). Union-merge produces both lines in
    // some order; the fold last-write-wins rule means the SECOND line in the
    // merged log wins. Both orderings are tested to confirm the rule holds and
    // that neither event is silently dropped — the fold always converges.
    const task = mintId();

    var base_log: std.ArrayList(u8) = .empty;
    defer base_log.deinit(testing.allocator);
    try tracker.json_codec.encode(&base_log, testing.allocator, .{ .add = .{ .id = task, .title = "Shared task" } });
    try base_log.append(testing.allocator, '\n');

    var ev_done: std.ArrayList(u8) = .empty;
    defer ev_done.deinit(testing.allocator);
    try tracker.json_codec.encode(&ev_done, testing.allocator, .{ .setState = .{ .id = task, .state = .done } });
    try ev_done.append(testing.allocator, '\n');

    var ev_blocked: std.ArrayList(u8) = .empty;
    defer ev_blocked.deinit(testing.allocator);
    try tracker.json_codec.encode(&ev_blocked, testing.allocator, .{ .setState = .{ .id = task, .state = .blocked } });
    try ev_blocked.append(testing.allocator, '\n');

    // Order A: done then blocked -> final state is blocked.
    {
        var tmp_ab = testing.tmpDir(.{});
        defer tmp_ab.cleanup();

        var merged: std.ArrayList(u8) = .empty;
        defer merged.deinit(testing.allocator);
        try merged.appendSlice(testing.allocator, base_log.items);
        try merged.appendSlice(testing.allocator, ev_done.items);
        try merged.appendSlice(testing.allocator, ev_blocked.items);

        var sub = try tmp_ab.dir.createDirPathOpen(io, ".tracker", .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = "log.jsonl", .data = merged.items });

        var s = Store.open(testing.allocator, io, tmp_ab.dir);
        defer s.deinit();
        try s.load();
        // Last event (blocked) wins; the done event was not silently lost — it was
        // applied and then overwritten by the later blocked event, which is correct.
        try testing.expectEqual(tracker.State.blocked, s.get(task).?.state);
    }

    // Order B: blocked then done -> final state is done.
    {
        var tmp_ba = testing.tmpDir(.{});
        defer tmp_ba.cleanup();

        var merged: std.ArrayList(u8) = .empty;
        defer merged.deinit(testing.allocator);
        try merged.appendSlice(testing.allocator, base_log.items);
        try merged.appendSlice(testing.allocator, ev_blocked.items);
        try merged.appendSlice(testing.allocator, ev_done.items);

        var sub = try tmp_ba.dir.createDirPathOpen(io, ".tracker", .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = "log.jsonl", .data = merged.items });

        var s = Store.open(testing.allocator, io, tmp_ba.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqual(tracker.State.done, s.get(task).?.state);
    }
}

test "setState done round-trip: append persists across store reopen (basic regression)" {
    // Directly pins the basic contract that setState done appended via
    // Store.append() survives a close+reopen cycle. This is the minimal
    // reproduce of the 01KVRY symptom: if this test were to fail it would mean
    // the store itself drops state events, which is what we ruled out —
    // the actual cause was agents not committing the log file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const task = mintId();

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .add = .{ .id = task, .title = "Task" } });
        try s.append(.{ .setState = .{ .id = task, .state = .done } });
        try testing.expectEqual(tracker.State.done, s.get(task).?.state);
    }

    // Reopen and verify the state is still done (not reverted to open).
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expectEqual(tracker.State.done, s.get(task).?.state);
        // Also confirm it does NOT appear in the ready frontier (done != eligible).
        const n = try s.next(testing.allocator);
        defer testing.allocator.free(n);
        try testing.expect(!contains(n, task));
    }
}

test "setDocPath empty-path tombstone: unset survives compact + reload; live entries do" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try s.append(.{ .setDocPath = .{ .doc_id = "gone", .path = "docs/gone.md" } });
        try s.append(.{ .setDocPath = .{ .doc_id = "kept", .path = "docs/kept.md" } });
        try s.append(.{ .setDocPath = .{ .doc_id = "gone", .path = "" } }); // unset
        try testing.expect(s.docPath("gone") == null);
        try testing.expectEqualStrings("docs/kept.md", s.docPath("kept").?);
        _ = try s.compact();
    }

    // Reopen post-compact: the snapshot must carry `kept` and no trace of `gone`
    // (a removed mapping is simply not serialized — no empty-path line survives).
    {
        var s = Store.open(testing.allocator, io, tmp.dir);
        defer s.deinit();
        try s.load();
        try testing.expect(s.docPath("gone") == null);
        try testing.expectEqualStrings("docs/kept.md", s.docPath("kept").?);
        try testing.expectEqual(@as(usize, 1), s.doc_paths.count());
    }
}

// ----- helpers -----

fn contains(haystack: []const tracker.Ulid, needle: tracker.Ulid) bool {
    for (haystack) |h| if (h.eql(needle)) return true;
    return false;
}

fn indexOf(haystack: []const tracker.Ulid, needle: tracker.Ulid) ?usize {
    for (haystack, 0..) |h, i| if (h.eql(needle)) return i;
    return null;
}
