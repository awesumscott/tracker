// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! The Store: in-memory task graph folded from an append-only JSONL event log,
//! plus the queries (`membersOf`, `arcsOf`, `next`) and the write/atomic-write
//! helpers.
//!
//! Layout under the store dir (overridable — tests pass a tmp dir):
//!   <dir>/.tracker/snapshot.jsonl   optional full-state baseline (absent in v1)
//!   <dir>/.tracker/log.jsonl        the append-only event log
//!
//! Load = fold: replay snapshot (if any) then log, in file order, applying each
//! event. Append = open log, append one JSON line at end-of-file (O(1) via a
//! positional write at the current length). Compaction (stubbed) rewrites the
//! whole snapshot via write-temp + rename (atomic on the same filesystem).
//!
//! NOTE (Zig 0.16): the filesystem is `Io`-threaded. `Store` holds an `Io` and
//! an `Io.Dir` (the store dir) so tests can drive it against a `tmpDir` and
//! main.zig against a real cwd. No absolute paths are baked in.

const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");
const ulid = @import("ulid.zig");
const codec = @import("json_codec.zig");

const Ulid = model.Ulid;
const Task = model.Task;
const Event = model.Event;
const State = model.State;

/// Map key: the 26-byte ULID text (a fixed array auto-hashes cleanly, unlike a
/// wrapping struct in some Zig versions).
const Key = [ulid.len]u8;

fn key(u: Ulid) Key {
    return u.text;
}

/// Composite key for a (from, to) edge tombstone: concatenate both ULID texts.
fn edgeKey(from: Ulid, to: Ulid) [ulid.len * 2]u8 {
    var k: [ulid.len * 2]u8 = undefined;
    @memcpy(k[0..ulid.len], &from.text);
    @memcpy(k[ulid.len..], &to.text);
    return k;
}

pub const tracker_subdir = ".tracker";
pub const log_name = "log.jsonl";
pub const snapshot_name = "snapshot.jsonl";
pub const config_name = "config.json";

/// Persisted per-repo config (`.tracker/config.json`). Purely optional: a repo
/// with no config file behaves exactly as before (every field null → callers
/// fall back to their prior default, which is stdout for render/archive). The
/// only job today is to persist the render/archive output path so `trk render`
/// need not be handed `--out docs/TODO.md` on every call. Fields are arena-owned.
pub const Config = struct {
    /// `render.out` — where `trk render` writes with no `--out`. null → stdout.
    render_out: ?[]const u8 = null,
    /// `archive.out` — where `trk archive` writes its draft with no `--out`. null → stdout.
    archive_out: ?[]const u8 = null,
};

pub const Error = error{
    DependencyCycle,
} || std.mem.Allocator.Error;

/// A `needs` edge in memory.
pub const Needs = model.Needs;
/// An `in` membership edge in memory.
pub const In = model.In;

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Arena owning all task strings/tags/docrefs/edges — freed wholesale on deinit.
    arena: std.heap.ArenaAllocator,
    io: Io,
    dir: Io.Dir,

    tasks: std.AutoHashMapUnmanaged(Key, Task) = .empty,
    needs: std.ArrayList(Needs) = .empty,
    ins: std.ArrayList(In) = .empty,
    /// Tombstone set for `undep` ops: every (from,to) pair for which an `undep`
    /// has been applied. A `dep` for the same pair is a no-op if this set
    /// contains it, so a tombstone beats a `dep` regardless of fold order (the
    /// union-merge determinism requirement).
    dep_tombstones: std.AutoHashMapUnmanaged([ulid.len * 2]u8, void) = .empty,
    /// Doc-id registry: maps stable doc_id strings to repo-relative paths.
    /// Keys and values are arena-owned. Last-write-wins: a second setDocPath for
    /// the same doc_id replaces the path in the map (old key/value stay in the
    /// arena — cheap and correct since the arena only grows until deinit).
    doc_paths: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Parsed `.tracker/config.json` (defaults when the file is absent). Loaded
    /// by `load` alongside the event fold; best-effort (a malformed file yields
    /// defaults and sets `config_malformed` rather than failing the command).
    config: Config = .{},
    /// True iff a `config.json` was present but could not be parsed as the
    /// expected JSON object. main.zig surfaces a one-line stderr warning; the
    /// command still runs with default config.
    config_malformed: bool = false,

    /// Open a store rooted at `dir`. Does NOT load — call `load` for that, or
    /// `openAndLoad`. `dir` is borrowed; the caller keeps ownership/closes it.
    pub fn open(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) Store {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .io = io,
            .dir = dir,
        };
    }

    pub fn deinit(self: *Store) void {
        self.tasks.deinit(self.gpa);
        self.needs.deinit(self.gpa);
        self.ins.deinit(self.gpa);
        self.dep_tombstones.deinit(self.gpa);
        self.doc_paths.deinit(self.gpa);
        self.arena.deinit();
    }

    fn a(self: *Store) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ----------------------------------------------------------------- fold

    /// Get-or-create a task node by id. Out-of-order tolerance: an event that
    /// references an id we haven't `add`ed yet (a `dep`/`in`/`setState` whose
    /// endpoints precede their `add`) creates a **placeholder** node (empty
    /// title, default state). A later `add` fills it in. We tolerate rather than
    /// require add-first because a textual log union-merge can legitimately
    /// interleave lines from two worktrees out of add-order, and rejecting that
    /// would make a merge-safe log unloadable.
    fn ensureNode(self: *Store, id: Ulid) !*Task {
        const gop = try self.tasks.getOrPut(self.gpa, key(id));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = id };
        }
        return gop.value_ptr;
    }

    /// Apply one event to in-memory state. Idempotent where the doc requires:
    /// re-applying `add`/`setState`/`setPriority` for the same id converges to
    /// the same value; a duplicate `dep`/`in`/`tag`/`docref` is de-duplicated so
    /// replaying a log twice is a no-op.
    pub fn apply(self: *Store, ev: Event) !void {
        switch (ev) {
            .add => |x| {
                const t = try self.ensureNode(x.id);
                // Last add wins for scalar fields (idempotent for a replay; a
                // genuine re-add with new text is a deliberate overwrite).
                t.title = try self.a().dupe(u8, x.title);
                t.body = try self.a().dupe(u8, x.body);
                // Reset tags to exactly the add's set (idempotent on replay).
                t.tags = .empty;
                for (x.tags) |tg| try t.tags.append(self.a(), try self.a().dupe(u8, tg));
            },
            .setState => |x| {
                const t = try self.ensureNode(x.id);
                t.state = x.state;
            },
            .setPriority => |x| {
                const t = try self.ensureNode(x.id);
                t.priority = x.priority;
            },
            .tag => |x| {
                const t = try self.ensureNode(x.id);
                for (t.tags.items) |existing| {
                    if (std.mem.eql(u8, existing, x.tag)) return; // dedup
                }
                try t.tags.append(self.a(), try self.a().dupe(u8, x.tag));
            },
            .docref => |x| {
                const t = try self.ensureNode(x.id);
                for (t.docrefs.items) |dr| {
                    const same_doc = std.mem.eql(u8, dr.doc_id, x.doc_id);
                    const same_sec = (dr.section_id == null and x.section_id == null) or
                        (dr.section_id != null and x.section_id != null and
                            std.mem.eql(u8, dr.section_id.?, x.section_id.?));
                    if (same_doc and same_sec) return; // dedup
                }
                try t.docrefs.append(self.a(), .{
                    .doc_id = try self.a().dupe(u8, x.doc_id),
                    .section_id = if (x.section_id) |s| try self.a().dupe(u8, s) else null,
                });
            },
            .dep => |x| {
                _ = try self.ensureNode(x.from);
                _ = try self.ensureNode(x.to);
                // Tombstone check: if an `undep` for this edge exists (in any
                // fold-order position), the edge stays absent — tombstone beats add.
                if (self.dep_tombstones.contains(edgeKey(x.from, x.to))) return;
                for (self.needs.items) |e| {
                    if (e.from.eql(x.from) and e.to.eql(x.to)) return; // dedup
                }
                try self.needs.append(self.gpa, .{ .from = x.from, .to = x.to });
            },
            .in => |x| {
                _ = try self.ensureNode(x.task);
                _ = try self.ensureNode(x.arc);
                // An `in` (task,arc) pair is a set member; a repeat updates seq
                // (last-write-wins on the priority attribute, idempotent on replay).
                for (self.ins.items) |*e| {
                    if (e.task.eql(x.task) and e.arc.eql(x.arc)) {
                        e.seq = x.seq;
                        return;
                    }
                }
                try self.ins.append(self.gpa, .{ .task = x.task, .arc = x.arc, .seq = x.seq });
            },
            .setDocPath => |x| {
                // Last-write-wins: dup both key and value into the arena each time.
                // The old arena strings are never freed (arena-only), which is fine.
                const k = try self.a().dupe(u8, x.doc_id);
                const v = try self.a().dupe(u8, x.path);
                try self.doc_paths.put(self.gpa, k, v);
            },
            .setTitle => |x| {
                const t = try self.ensureNode(x.id);
                t.title = try self.a().dupe(u8, x.title);
            },
            .setBody => |x| {
                const t = try self.ensureNode(x.id);
                t.body = try self.a().dupe(u8, x.body);
            },
            .untag => |x| {
                const t = try self.ensureNode(x.id);
                // Find and remove the tag if present. Shift-remove to preserve order.
                var idx: ?usize = null;
                for (t.tags.items, 0..) |tg, i| {
                    if (std.mem.eql(u8, tg, x.tag)) { idx = i; break; }
                }
                if (idx) |i| _ = t.tags.orderedRemove(i);
            },
            .undep => |x| {
                // Record the tombstone so a later `dep` for the same edge (in
                // union-merge order) is blocked. This makes the tombstone win
                // regardless of which event appears first in the merged log.
                try self.dep_tombstones.put(self.gpa, edgeKey(x.from, x.to), {});
                // Also remove the edge if it is already present in the needs list
                // (handles the case where the `dep` precedes the `undep` in fold order).
                var idx: ?usize = null;
                for (self.needs.items, 0..) |e, i| {
                    if (e.from.eql(x.from) and e.to.eql(x.to)) { idx = i; break; }
                }
                if (idx) |i| _ = self.needs.orderedRemove(i);
            },
        }
    }

    /// Replay snapshot (if present) then the log, then verify the DAG invariant.
    /// A cycle anywhere in the folded `needs` set is a loud `error.DependencyCycle`
    /// — re-checked here (not only on append) because a merge could introduce a
    /// cycle neither side had.
    pub fn load(self: *Store) !void {
        try self.replayFile(snapshot_name);
        try self.replayFile(log_name);
        try self.checkAcyclic();
        self.loadConfig();
    }

    /// Read `.tracker/config.json` into `self.config`. Best-effort and never
    /// fatal: an absent file (or no `.tracker/` yet) leaves the defaults; a file
    /// present but unparseable sets `config_malformed` and still leaves defaults,
    /// so a broken config can never block a mutating command. Strings are dup'd
    /// into the store arena so they outlive the parse tree.
    pub fn loadConfig(self: *Store) void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch return;
        defer sub.close(self.io);
        const bytes = sub.readFileAlloc(self.io, config_name, self.gpa, .unlimited) catch return;
        defer self.gpa.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch {
            self.config_malformed = true;
            return;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => {
                self.config_malformed = true;
                return;
            },
        };
        self.config.render_out = self.readNestedOut(root, "render");
        self.config.archive_out = self.readNestedOut(root, "archive");
    }

    /// Pull `<section>.out` (a string) from the config root, arena-dup'd. Returns
    /// null when the section, the `out` key, or its string type is absent — a
    /// `null` JSON value or a missing key both mean "unset" (fall back to stdout).
    fn readNestedOut(self: *Store, root: std.json.ObjectMap, section: []const u8) ?[]const u8 {
        const sv = root.get(section) orelse return null;
        const so = switch (sv) {
            .object => |o| o,
            else => return null,
        };
        const ov = so.get("out") orelse return null;
        const s = switch (ov) {
            .string => |str| str,
            else => return null,
        };
        return self.a().dupe(u8, s) catch null;
    }

    fn replayFile(self: *Store, name: []const u8) !void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return, // no store yet -> empty fold
            else => return e,
        };
        defer sub.close(self.io);

        const bytes = sub.readFileAlloc(self.io, name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.gpa.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const ev = try codec.decode(self.gpa, trimmed);
            // Free the codec's gpa-dup'd transient strings after apply re-dups
            // into the arena.
            defer freeEvent(self.gpa, ev);
            try self.apply(ev);
        }
    }

    fn freeEvent(gpa: std.mem.Allocator, ev: Event) void {
        switch (ev) {
            .add => |x| {
                gpa.free(x.title);
                gpa.free(x.body);
                for (x.tags) |t| gpa.free(t);
                gpa.free(x.tags);
            },
            .tag => |x| gpa.free(x.tag),
            .docref => |x| {
                gpa.free(x.doc_id);
                if (x.section_id) |s| gpa.free(s);
            },
            .setDocPath => |x| {
                gpa.free(x.doc_id);
                gpa.free(x.path);
            },
            .setTitle => |x| gpa.free(x.title),
            .setBody => |x| gpa.free(x.body),
            .untag => |x| gpa.free(x.tag),
            else => {},
        }
    }

    // ----------------------------------------------------------------- acyclic

    const Color = enum { white, gray, black };

    /// DFS three-color cycle detection over the `needs` edges. `from needs to`
    /// is a directed edge from -> to; a back-edge (to a gray node) is a cycle.
    pub fn checkAcyclic(self: *Store) Error!void {
        var color = std.AutoHashMapUnmanaged(Key, Color){};
        defer color.deinit(self.gpa);

        // Build adjacency: from -> [to...].
        var adj = std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)){};
        defer {
            var vit = adj.valueIterator();
            while (vit.next()) |list| list.deinit(self.gpa);
            adj.deinit(self.gpa);
        }
        for (self.needs.items) |e| {
            const gop = try adj.getOrPut(self.gpa, key(e.from));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, e.to);
        }

        // Iterative DFS (explicit stack) over every task to catch disjoint cycles.
        var task_it = self.tasks.keyIterator();
        while (task_it.next()) |k| {
            if ((color.get(k.*) orelse .white) != .white) continue;
            try self.dfsVisit(k.*, &adj, &color);
        }
    }

    const Frame = struct { node: Key, idx: usize };

    fn dfsVisit(
        self: *Store,
        start: Key,
        adj: *std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)),
        color: *std.AutoHashMapUnmanaged(Key, Color),
    ) Error!void {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, .{ .node = start, .idx = 0 });
        try color.put(self.gpa, start, .gray);

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const neighbors: []const Ulid = if (adj.get(top.node)) |list| list.items else &.{};
            if (top.idx < neighbors.len) {
                const next_id = neighbors[top.idx];
                top.idx += 1;
                const nk = key(next_id);
                switch (color.get(nk) orelse .white) {
                    .white => {
                        try color.put(self.gpa, nk, .gray);
                        try stack.append(self.gpa, .{ .node = nk, .idx = 0 });
                    },
                    .gray => return error.DependencyCycle, // back-edge
                    .black => {},
                }
            } else {
                try color.put(self.gpa, top.node, .black);
                _ = stack.pop();
            }
        }
    }

    // ----------------------------------------------------------------- writes

    /// Append a single event to the log (creating .tracker/log.jsonl as needed),
    /// applying it to in-memory state. For a `dep` event we re-verify the DAG and
    /// reject `error.DependencyCycle` *before* persisting, so the log never holds
    /// a write that closes a cycle.
    ///
    /// Stamps a real wall-clock ts (ms since Unix epoch) on every event at append
    /// time using comptime field injection. ts=0 on a loaded event means unknown /
    /// legacy (tolerated by the codec's getIntDefault fallback).
    pub fn append(self: *Store, ev_in: Event) !void {
        // Stamp ts on whichever variant has the field (all do now, via comptime check).
        var ev = ev_in;
        const ts_now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        switch (ev) {
            inline else => |*x| if (@hasField(@TypeOf(x.*), "ts")) {
                x.ts = ts_now;
            },
        }

        // Snapshot enough to roll back the in-memory mutation if the cycle check
        // fails: simplest correct approach is to apply, check, and on cycle undo
        // by removing the just-added needs edge.
        const is_dep = ev == .dep;
        try self.apply(ev);
        if (is_dep) {
            self.checkAcyclic() catch |e| {
                if (e == error.DependencyCycle) {
                    // Undo: drop the last needs edge (the one we just added, if
                    // it wasn't a dedup no-op). Safe because apply appends at end.
                    if (self.needs.items.len > 0) {
                        const last = self.needs.items[self.needs.items.len - 1];
                        if (last.from.eql(ev.dep.from) and last.to.eql(ev.dep.to))
                            _ = self.needs.pop();
                    }
                }
                return e;
            };
        }
        try self.persistAppend(ev);
    }

    fn persistAppend(self: *Store, ev: Event) !void {
        var sub = try self.dir.createDirPathOpen(self.io, tracker_subdir, .{});
        defer sub.close(self.io);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        try codec.encode(&line, self.gpa, ev);
        try line.append(self.gpa, '\n');

        // Open (or create) the log and write at end-of-file. createFile with
        // truncate=false preserves existing content; we position the write at the
        // current length for an O(1) append.
        var f = try sub.createFile(self.io, log_name, .{ .read = true, .truncate = false });
        defer f.close(self.io);
        const end = try f.length(self.io);
        try f.writePositionalAll(self.io, line.items, end);
        try f.sync(self.io);
    }

    /// Atomic full-file write helper: write `data` to a temp file in the same
    /// dir, then rename over `name` (atomic on the same filesystem). Used by
    /// compaction (and any future snapshot rewrite).
    pub fn atomicWrite(self: *Store, sub: Io.Dir, name: []const u8, data: []const u8) !void {
        // Temp name in the SAME dir so the rename is a same-filesystem atomic op.
        var tmp_buf: [80]u8 = undefined;
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        const hex = std.fmt.bytesToHex(rnd, .lower);
        const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.tmp.{s}", .{ name, &hex }) catch unreachable;

        {
            var f = try sub.createFile(self.io, tmp_name, .{ .truncate = true });
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, data);
            try f.sync(self.io);
        }
        try sub.rename(tmp_name, sub, name, self.io);
    }

    /// Compaction result: summary counts for the CLI one-liner.
    pub const CompactResult = struct {
        /// Number of live (non-dropped) tasks written to the new snapshot.
        live_tasks: usize,
        /// Number of events that were in the log before it was truncated.
        log_events_before: usize,
    };

    /// Compact: write a fresh full-state snapshot then truncate the log.
    ///
    /// **Single-writer / orchestrator-only** (issue-tracker.md §Compaction).
    ///
    /// **Crash-safety ordering:**
    ///   1. Serialize state → temp file → rename over snapshot.jsonl  (atomic)
    ///   2. Empty string   → temp file → rename over log.jsonl        (atomic)
    ///
    /// If we crash between step 1 and step 2, the old log is still intact.
    /// Re-folding: new snapshot (current state minus dropped tasks) + old log
    /// (all events including the ones for dropped tasks) → every `apply` is
    /// idempotent (last-write-wins for scalars, dedup-guards for edges), so the
    /// fold converges to the pre-compaction state. Dropped tasks may transiently
    /// reappear; a second compact run cleans them. No data is ever lost.
    ///
    /// **History retention ruling** (resolves docs/design.md open
    /// fork "Compaction & history retention"):
    ///   - `dropped` tasks are EXCLUDED from the snapshot. They are abandoned work
    ///     with no future structural role. Git history preserves the raw log as
    ///     an audit trail if a recovery is ever needed. Dropping them here is the
    ///     GC step analogous to `externalization.md`'s adopt/condemn: condemn =
    ///     mark dropped, compact = collect.
    ///   - `done` tasks are KEPT in the snapshot. A completed task is still a live
    ///     structural node: other tasks may hold `needs` edges pointing at it, and
    ///     dropping it from the snapshot would silently un-block their dependents
    ///     on the next load. A done prereq is what makes a dependent eligible —
    ///     losing it corrupts the graph.
    ///   - Edges (`dep`, `in`) involving a dropped endpoint are also excluded.
    pub fn compact(self: *Store) !CompactResult {
        // Count log events before truncation.
        const log_events_before = try self.countLogEvents();

        var sub = try self.dir.createDirPathOpen(self.io, tracker_subdir, .{});
        defer sub.close(self.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        const live = try self.serializeState(&buf);

        // Step 1: new snapshot, durable before we touch the log.
        try self.atomicWrite(sub, snapshot_name, buf.items);

        // Step 2: truncate the log. A crash between here and step 1 leaves the
        // old log intact; crash-safe re-fold described in the doc above.
        try self.atomicWrite(sub, log_name, "");

        return .{ .live_tasks = live, .log_events_before = log_events_before };
    }

    /// Count non-empty lines in the log file (≈ events before compaction).
    /// Returns 0 if the log does not exist.
    fn countLogEvents(self: *Store) !usize {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer sub.close(self.io);
        const bytes = sub.readFileAlloc(self.io, log_name, self.gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer self.gpa.free(bytes);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
        }
        return n;
    }

    /// Emit current in-memory state as a minimal canonical event stream:
    ///   - one `add` per live task (not dropped, not archived), in ULID order
    ///   - `setState` for any non-open state (omitted for dropped/archived — they
    ///     are excluded entirely)
    ///   - `setPriority` if non-zero
    ///   - `docref` events per task
    ///   - `dep` edges sorted by (from, to) — skipped if either endpoint is gone
    ///   - `in`  edges sorted by (task, arc) — skipped if either endpoint is gone
    ///
    /// Both `dropped` (won't-do, retention ruling) and `archived` (completed +
    /// recorded in the changelog) are GC'd here — compaction is where a graduated
    /// task physically leaves the store.
    ///
    /// Tags within each `add` are **sorted** so the output is byte-identical for
    /// the same logical state (two compactions produce the same bytes — testable).
    ///
    /// Returns the count of live tasks written.
    fn serializeState(self: *Store, buf: *std.ArrayList(u8)) !usize {
        const all_ids = try self.sortedTaskIds(self.gpa);
        defer self.gpa.free(all_ids);

        // Build a set of GC'd (dropped OR archived) task keys so edge filtering is
        // O(1) and a graduated/abandoned task drops out of the snapshot.
        var gc_set = std.AutoHashMapUnmanaged(Key, void){};
        defer gc_set.deinit(self.gpa);
        for (all_ids) |id| {
            if (isGarbage(self.tasks.get(key(id)).?.state))
                try gc_set.put(self.gpa, key(id), {});
        }

        var live: usize = 0;
        for (all_ids) |id| {
            const t = self.tasks.get(key(id)).?;
            if (isGarbage(t.state)) continue; // dropped/archived: excluded

            // Sort tags for determinism before folding them into the `add`.
            const tag_slice = try self.gpa.alloc([]const u8, t.tags.items.len);
            defer self.gpa.free(tag_slice);
            for (t.tags.items, 0..) |tg, i| tag_slice[i] = tg;
            std.sort.pdq([]const u8, tag_slice, {}, lessThanStr);

            try self.emit(buf, .{ .add = .{
                .id = id, .title = t.title, .body = t.body, .tags = tag_slice,
            } });
            if (t.state != .open)
                try self.emit(buf, .{ .setState = .{ .id = id, .state = t.state } });
            if (t.priority != 0)
                try self.emit(buf, .{ .setPriority = .{ .id = id, .priority = t.priority } });
            for (t.docrefs.items) |dr|
                try self.emit(buf, .{ .docref = .{
                    .id = id, .doc_id = dr.doc_id, .section_id = dr.section_id,
                } });
            live += 1;
        }

        // `dep` edges: stable (from, to) order; skip dropped endpoints.
        const sorted_needs = try self.gpa.dupe(Needs, self.needs.items);
        defer self.gpa.free(sorted_needs);
        std.sort.pdq(Needs, sorted_needs, {}, needsLessThan);
        for (sorted_needs) |e| {
            if (gc_set.contains(key(e.from))) continue;
            if (gc_set.contains(key(e.to))) continue;
            try self.emit(buf, .{ .dep = .{ .from = e.from, .to = e.to } });
        }

        // `in` edges: stable (task, arc) order; skip dropped endpoints.
        const sorted_ins = try self.gpa.dupe(In, self.ins.items);
        defer self.gpa.free(sorted_ins);
        std.sort.pdq(In, sorted_ins, {}, inLessThan);
        for (sorted_ins) |e| {
            if (gc_set.contains(key(e.task))) continue;
            if (gc_set.contains(key(e.arc))) continue;
            try self.emit(buf, .{ .in = .{ .task = e.task, .arc = e.arc, .seq = e.seq } });
        }

        // `setDocPath` entries: sorted by doc_id for determinism.
        // Collect all keys into a slice, sort, then emit in order.
        const n_docs = self.doc_paths.count();
        if (n_docs > 0) {
            const doc_ids = try self.gpa.alloc([]const u8, n_docs);
            defer self.gpa.free(doc_ids);
            var it = self.doc_paths.keyIterator();
            var i: usize = 0;
            while (it.next()) |dk| : (i += 1) doc_ids[i] = dk.*;
            std.sort.pdq([]const u8, doc_ids, {}, lessThanStr);
            for (doc_ids) |doc_id| {
                const path = self.doc_paths.get(doc_id).?;
                try self.emit(buf, .{ .setDocPath = .{ .doc_id = doc_id, .path = path } });
            }
        }

        return live;
    }

    /// A state that compaction physically GCs from the snapshot: `dropped`
    /// (won't-do) or `archived` (completed + recorded in the changelog).
    fn isGarbage(s: State) bool {
        return s == .dropped or s == .archived;
    }

    fn lessThanStr(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }

    fn needsLessThan(_: void, lhs: Needs, rhs: Needs) bool {
        const cf = std.mem.order(u8, &lhs.from.text, &rhs.from.text);
        if (cf != .eq) return cf == .lt;
        return std.mem.lessThan(u8, &lhs.to.text, &rhs.to.text);
    }

    fn inLessThan(_: void, lhs: In, rhs: In) bool {
        const ct = std.mem.order(u8, &lhs.task.text, &rhs.task.text);
        if (ct != .eq) return ct == .lt;
        return std.mem.lessThan(u8, &lhs.arc.text, &rhs.arc.text);
    }

    fn emit(self: *Store, buf: *std.ArrayList(u8), ev: Event) !void {
        try codec.encode(buf, self.gpa, ev);
        try buf.append(self.gpa, '\n');
    }

    // ----------------------------------------------------------------- queries

    /// Look up a doc_id in the registry. Returns the repo-relative path if
    /// registered, or null if the doc_id has never been set. The returned slice
    /// is arena-owned and valid for the lifetime of the Store.
    pub fn docPath(self: *Store, doc_id: []const u8) ?[]const u8 {
        return self.doc_paths.get(doc_id);
    }

    /// All tasks that directly need `id` (the reverse of `dep` edges — tasks
    /// whose `from` points at `id`). Caller owns the returned slice.
    /// Sorted ascending by Ulid for deterministic output.
    pub fn reverseDeps(self: *Store, alloc: std.mem.Allocator, id: Ulid) ![]Ulid {
        var out: std.ArrayList(Ulid) = .empty;
        for (self.needs.items) |e| {
            if (e.to.eql(id)) try out.append(alloc, e.from);
        }
        const s = try out.toOwnedSlice(alloc);
        std.sort.pdq(Ulid, s, {}, Ulid.lessThan);
        return s;
    }

    /// A raw log entry for `trk log` (event history view).
    pub const LogEntry = struct {
        ts: i64,
        op: model.Op,
        /// The primary task id for this event (null for setDocPath which has no task id).
        task_id: ?Ulid,
        /// Human-readable summary of the event. gpa-owned; caller frees.
        summary: []const u8,
    };

    /// Read the raw event log (snapshot + log) in file order, returning a slice of
    /// LogEntry. Caller owns the slice and must free each `summary` plus the slice
    /// itself. Events are returned in file order (snapshot first, then log).
    pub fn readLogEntries(self: *Store, alloc: std.mem.Allocator) ![]LogEntry {
        var out: std.ArrayList(LogEntry) = .empty;
        try self.collectLogEntries(&out, alloc, snapshot_name);
        try self.collectLogEntries(&out, alloc, log_name);
        return out.toOwnedSlice(alloc);
    }

    fn collectLogEntries(self: *Store, out: *std.ArrayList(LogEntry), alloc: std.mem.Allocator, name: []const u8) !void {
        var sub = self.dir.openDir(self.io, tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer sub.close(self.io);

        const bytes = sub.readFileAlloc(self.io, name, alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer alloc.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const ev = codec.decode(alloc, trimmed) catch continue;
            defer freeEvent(alloc, ev);

            var ts: i64 = 0;
            var task_id: ?Ulid = null;
            const summary = switch (ev) {
                .add => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "add: {s}", .{x.title});
                },
                .setState => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "state -> {s}", .{x.state.toString()});
                },
                .dep => |x| blk: {
                    ts = x.ts;
                    task_id = x.from;
                    break :blk try std.fmt.allocPrint(alloc, "dep: {s} needs {s}", .{ x.from.slice(), x.to.slice() });
                },
                .undep => |x| blk: {
                    ts = x.ts;
                    task_id = x.from;
                    break :blk try std.fmt.allocPrint(alloc, "undep: {s} no longer needs {s}", .{ x.from.slice(), x.to.slice() });
                },
                .in => |x| blk: {
                    ts = x.ts;
                    task_id = x.task;
                    break :blk try alloc.dupe(u8, "in arc");
                },
                .setPriority => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "priority -> {d}", .{x.priority});
                },
                .tag => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "tag: +{s}", .{x.tag});
                },
                .untag => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "tag: -{s}", .{x.tag});
                },
                .setTitle => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "title -> {s}", .{x.title});
                },
                .setBody => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try alloc.dupe(u8, "body updated");
                },
                .docref => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "docref: {s}", .{x.doc_id});
                },
                .setDocPath => |x| blk: {
                    ts = x.ts;
                    task_id = null;
                    break :blk try std.fmt.allocPrint(alloc, "docpath: {s} -> {s}", .{ x.doc_id, x.path });
                },
            };
            try out.append(alloc, .{
                .ts = ts,
                .op = std.meta.activeTag(ev),
                .task_id = task_id,
                .summary = summary,
            });
        }
    }

    pub fn get(self: *Store, id: Ulid) ?Task {
        return self.tasks.get(key(id));
    }

    pub fn count(self: *Store) usize {
        return self.tasks.count();
    }

    /// Every task id, sorted ascending (ULID == chronological). Caller owns the
    /// slice. Used by the CLI for prefix resolution and `shortId` (it needs the
    /// full id set to find the shortest unambiguous prefix). A thin public
    /// wrapper over the internal `sortedTaskIds` — keeps the iteration order
    /// deterministic for the human projections.
    pub fn allIds(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        return self.sortedTaskIds(alloc);
    }

    fn sortedTaskIds(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var ids = try alloc.alloc(Ulid, self.tasks.count());
        var it = self.tasks.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) ids[i] = .{ .text = k.* };
        std.sort.pdq(Ulid, ids, {}, Ulid.lessThan);
        return ids;
    }

    /// All tasks in arc `arc`: direct `in arc` members, plus everything
    /// reachable from a member by following `needs` edges (a prereq of a member
    /// is in the arc). The arc root itself is included. Caller owns the slice.
    pub fn membersOf(self: *Store, alloc: std.mem.Allocator, arc: Ulid) ![]Ulid {
        var seen = std.AutoHashMapUnmanaged(Key, void){};
        defer seen.deinit(self.gpa);
        var frontier: std.ArrayList(Ulid) = .empty;
        defer frontier.deinit(self.gpa);

        // Seeds: the arc root + every direct `in arc` member.
        try self.pushUnseen(&seen, &frontier, arc);
        for (self.ins.items) |e| {
            if (e.arc.eql(arc)) try self.pushUnseen(&seen, &frontier, e.task);
        }

        // Closure over `needs`: from a member `m`, every `to` of `m needs to`
        // is also a member (the prereq belongs to the arc).
        var i: usize = 0;
        while (i < frontier.items.len) : (i += 1) {
            const m = frontier.items[i];
            for (self.needs.items) |e| {
                if (e.from.eql(m)) try self.pushUnseen(&seen, &frontier, e.to);
            }
        }

        const out = try alloc.alloc(Ulid, frontier.items.len);
        @memcpy(out, frontier.items);
        std.sort.pdq(Ulid, out, {}, Ulid.lessThan);
        return out;
    }

    fn pushUnseen(self: *Store, seen: *std.AutoHashMapUnmanaged(Key, void), frontier: *std.ArrayList(Ulid), id: Ulid) !void {
        const gop = try seen.getOrPut(self.gpa, key(id));
        if (!gop.found_existing) try frontier.append(self.gpa, id);
    }

    /// Every arc that `task` belongs to (direct `in` membership OR reachability:
    /// `task` is reachable-via-`needs` from a member of the arc). Caller owns slice.
    pub fn arcsOf(self: *Store, alloc: std.mem.Allocator, task: Ulid) ![]Ulid {
        // An arc is any id that appears as an `in.arc`. For each, test membership.
        var arc_seen = std.AutoHashMapUnmanaged(Key, void){};
        defer arc_seen.deinit(self.gpa);
        var arcs: std.ArrayList(Ulid) = .empty;
        defer arcs.deinit(self.gpa);
        for (self.ins.items) |e| {
            const gop = try arc_seen.getOrPut(self.gpa, key(e.arc));
            if (!gop.found_existing) try arcs.append(self.gpa, e.arc);
        }

        var out: std.ArrayList(Ulid) = .empty;
        for (arcs.items) |arc| {
            const members = try self.membersOf(self.gpa, arc);
            defer self.gpa.free(members);
            for (members) |m| {
                if (m.eql(task)) {
                    try out.append(self.gpa, arc);
                    break;
                }
            }
        }
        const slice = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(slice);
        const final = try alloc.alloc(Ulid, slice.len);
        @memcpy(final, slice);
        std.sort.pdq(Ulid, final, {}, Ulid.lessThan);
        return final;
    }

    // -------------------------------------------------------------- arc-as-prereq

    /// True if `id` is used as an arc — i.e. at least one task is `in id`.
    /// (A `needs` edge whose target is an arc means "needs the whole arc.")
    pub fn isArc(self: *Store, id: Ulid) bool {
        for (self.ins.items) |e| {
            if (e.arc.eql(id)) return true;
        }
        return false;
    }

    /// Arc completion: every DIRECT member (a task with `in id`) is done/dropped,
    /// EXCLUDING members tagged `parked` (optional/future stubs are not part of an
    /// arc's completion criteria — otherwise a gate would wait on them forever).
    /// Returns false for a non-arc / an arc with no non-parked members — callers
    /// gate on `isArc` first. Direct members only: a member can't be done while its
    /// own `needs` are open, so "all direct members satisfied" implies their prereqs.
    pub fn arcComplete(self: *Store, id: Ulid) bool {
        var any = false;
        for (self.ins.items) |e| {
            if (!e.arc.eql(id)) continue;
            const m = self.tasks.get(key(e.task)) orelse return false; // unknown member → not complete
            if (self.taskHasTag(m, "parked")) continue; // parked stubs don't gate
            any = true;
            if (!m.state.satisfiesPrereq()) return false;
        }
        return any;
    }

    /// (done, total) over an arc's DIRECT, non-parked members — for display.
    pub fn arcProgress(self: *Store, id: Ulid) struct { done: usize, total: usize } {
        var d: usize = 0;
        var n: usize = 0;
        for (self.ins.items) |e| {
            if (!e.arc.eql(id)) continue;
            const m = self.tasks.get(key(e.task)) orelse continue;
            if (self.taskHasTag(m, "parked")) continue;
            n += 1;
            if (m.state.satisfiesPrereq()) d += 1;
        }
        return .{ .done = d, .total = n };
    }

    fn taskHasTag(_: *Store, t: Task, tag: []const u8) bool {
        for (t.tags.items) |tg| {
            if (std.mem.eql(u8, tg, tag)) return true;
        }
        return false;
    }

    // ----------------------------------------------------------------- next

    /// The per-task sort key for `next` / a future list view.
    /// Ordering (issue-tracker.md `next` ruling):
    ///   1. best (smallest) arc-priority `seq` across all arcs the task is in
    ///      (a task in NO arc gets the sentinel max → orders after arc'd tasks).
    ///   2. personal priority (the global `priority` field; lower first).
    ///   3. id (ULID; stable, time-ascending tiebreak).
    pub const Ranked = struct {
        id: Ulid,
        best_arc_seq: i64,
        priority: i32,

        fn less(_: void, x: Ranked, y: Ranked) bool {
            if (x.best_arc_seq != y.best_arc_seq) return x.best_arc_seq < y.best_arc_seq;
            if (x.priority != y.priority) return x.priority < y.priority;
            return x.id.order(y.id) == .lt;
        }
    };

    /// The ready frontier: every `open` task whose every `needs`-target is
    /// satisfied (state `done` or `dropped`), ordered per `Ranked.less`. A task
    /// with no `needs` is trivially ready; a task in no arc still appears
    /// (sorted after arc'd tasks by the sentinel). Caller owns the slice.
    pub fn next(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(self.gpa);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr.*;
            if (!t.state.isEligible()) continue; // only `open` is eligible

            // Every prereq must be satisfied.
            var ready = true;
            for (self.needs.items) |e| {
                if (!e.from.eql(t.id)) continue;
                // A `needs` edge whose target is an arc means "needs the whole
                // arc": satisfied iff every direct member is done/dropped.
                if (self.isArc(e.to)) {
                    if (!self.arcComplete(e.to)) {
                        ready = false;
                        break;
                    }
                    continue;
                }
                const pre = self.tasks.get(key(e.to)) orelse {
                    // A placeholder prereq we never learned the state of: treat
                    // as not-satisfied (default state `open` blocks) — it's
                    // conservatively NOT ready. (Placeholders default to .open.)
                    ready = false;
                    break;
                };
                if (!pre.state.satisfiesPrereq()) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;

            // Best arc-priority across this task's arcs.
            const arcs = try self.arcsOf(self.gpa, t.id);
            defer self.gpa.free(arcs);
            var best: i64 = std.math.maxInt(i64); // sentinel: arc-less sorts last
            for (arcs) |arc| {
                for (self.ins.items) |e| {
                    if (e.task.eql(t.id) and e.arc.eql(arc)) {
                        if (e.seq < best) best = e.seq;
                    }
                }
            }
            try ranked.append(self.gpa, .{ .id = t.id, .best_arc_seq = best, .priority = t.priority });
        }

        std.sort.pdq(Ranked, ranked.items, {}, Ranked.less);
        const out = try alloc.alloc(Ulid, ranked.items.len);
        for (ranked.items, 0..) |r, i| out[i] = r.id;
        return out;
    }
};
