// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! The Store: in-memory task graph folded from an append-only JSONL event log,
//! plus the queries (`membersOf`, `arcsOf`, `isArc`, `arcless`, `next`) and the
//! write/atomic-write helpers.
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
    /// `add.arcless` — policy when `trk add` mints a task with neither `--in`
    /// nor `--arc`. `false` (default, `"warn"` or absent) prints a warning to
    /// stderr and proceeds; `true` (`"error"`) refuses the add outright. Warn
    /// is the default so a repo with no config behaves exactly as before.
    add_arcless_error: bool = false,
};

pub const Error = error{
    DependencyCycle,
} || std.mem.Allocator.Error;

/// A `needs` edge in memory.
pub const Needs = model.Needs;
/// An `in` membership edge in memory.
pub const In = model.In;

/// Endpoints of the back-edge that closes a self-wait cycle (see
/// `findSelfWaitCycles`). Just a (from, to) pair — reuses `Needs`'s shape
/// since a report is two ids, regardless of whether the closing edge was a
/// genuine `needs` edge or an `in` membership edge (always reported in its
/// needs-EQUIVALENT direction: arc -> task, i.e. "arc depends on task").
pub const SelfWaitPair = Needs;

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
    /// Tombstone set for `unin` ops: every (task,arc) pair for which a `unin`
    /// has been applied. Exact mirror of `dep_tombstones` for the `in` edge
    /// kind — an `in` for the same pair is a no-op if this set contains it, so
    /// the tombstone beats an `in` regardless of fold order.
    in_tombstones: std.AutoHashMapUnmanaged([ulid.len * 2]u8, void) = .empty,
    /// Doc-id registry: maps stable doc_id strings to repo-relative paths.
    /// Keys and values are arena-owned. Last-write-wins: a second setDocPath for
    /// the same doc_id replaces the path in the map (old key/value stay in the
    /// arena — cheap and correct since the arena only grows until deinit).
    doc_paths: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Explicitly declared arc roots (`trk arc <id>` / `trk add --arc`), folded
    /// from `arcDeclare` events. A member of this set is an arc even with zero
    /// `in` members — the structural fix for an empty goal that was previously
    /// inexpressible. See `isArc`.
    declared_arcs: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// Standing-arc markers (`trk arc <id> --standing`), folded from
    /// `arcStanding{standing:true}` events. A member is excluded from `next`'s
    /// ready frontier UNCONDITIONALLY, drained or not — see `isStanding` and
    /// `next`.
    standing_arcs: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// Parsed `.tracker/config.json` (defaults when the file is absent). Loaded
    /// by `load` alongside the event fold; best-effort (a malformed file yields
    /// defaults and sets `config_malformed` rather than failing the command).
    config: Config = .{},
    /// True iff a `config.json` was present but could not be parsed as the
    /// expected JSON object. main.zig surfaces a one-line stderr warning; the
    /// command still runs with default config.
    config_malformed: bool = false,
    /// EVERY self-wait cycle found in the loaded log — mediated by `in` (arc
    /// membership), NOT a plain `needs` cycle (those still hard-fail `load`
    /// via `checkAcyclic`). Empty = none found. Set by `load` from
    /// `findSelfWaitCycles`; main.zig surfaces each pair as a one-line
    /// stderr warning, same shape as `config_malformed` — the log still
    /// loads, because refusing would brick a repo the bug already reached
    /// (exactly the state a real repo was found in — see
    /// `findSelfWaitCycles`'s doc). Plural, not `?SelfWaitPair`, because a
    /// log can carry more than one independent stuck pair (e.g. two
    /// unrelated bad merges) — reporting only the first would leave every
    /// OTHER cycled task exactly as silently unreachable as the bug this
    /// mechanism exists to kill. gpa-owned; freed in `deinit`.
    self_wait_cycles: std.ArrayList(SelfWaitPair) = .empty,

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
        self.in_tombstones.deinit(self.gpa);
        self.doc_paths.deinit(self.gpa);
        self.declared_arcs.deinit(self.gpa);
        self.standing_arcs.deinit(self.gpa);
        self.self_wait_cycles.deinit(self.gpa);
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
                // Freeze the short id carried on this add (mint time, or a
                // compact's re-canonicalized add carrying the already-frozen
                // value forward). null means "never frozen" — display falls
                // back to the dynamic computation. See `Task.short`.
                t.short = if (x.short) |s| try self.a().dupe(u8, s) else null;
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
                // Tombstone check: if a `unin` for this edge exists (in any
                // fold-order position), the edge stays absent — tombstone beats
                // add (exact mirror of `dep`'s tombstone check above).
                if (self.in_tombstones.contains(edgeKey(x.task, x.arc))) return;
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
                // Empty path = tombstone (`trk doc unset`): remove the mapping so
                // docPath/list see it as never-registered. Same last-write-wins
                // fold as a set; serializeState simply never emits a removed
                // entry, so compaction GCs the tombstone for free.
                if (x.path.len == 0) {
                    _ = self.doc_paths.remove(x.doc_id);
                    return;
                }
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
                    if (std.mem.eql(u8, tg, x.tag)) {
                        idx = i;
                        break;
                    }
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
                    if (e.from.eql(x.from) and e.to.eql(x.to)) {
                        idx = i;
                        break;
                    }
                }
                if (idx) |i| _ = self.needs.orderedRemove(i);
            },
            .unin => |x| {
                // Exact mirror of `undep`, for the `in` edge kind: record the
                // tombstone (so a later `in` for the same pair, in union-merge
                // order, is blocked regardless of append order), then also
                // remove the edge if already present (handles the case where
                // the `in` precedes the `unin` in fold order).
                try self.in_tombstones.put(self.gpa, edgeKey(x.task, x.arc), {});
                var idx: ?usize = null;
                for (self.ins.items, 0..) |e, i| {
                    if (e.task.eql(x.task) and e.arc.eql(x.arc)) {
                        idx = i;
                        break;
                    }
                }
                if (idx) |i| _ = self.ins.orderedRemove(i);
            },
            .arcDeclare => |x| {
                // Out-of-order tolerance like dep/in: a declare for an id we
                // haven't `add`ed yet creates the placeholder.
                _ = try self.ensureNode(x.id);
                if (x.declared) {
                    try self.declared_arcs.put(self.gpa, key(x.id), {});
                } else {
                    _ = self.declared_arcs.remove(key(x.id));
                }
            },
            .arcStanding => |x| {
                // Out-of-order tolerance like arcDeclare/dep/in.
                _ = try self.ensureNode(x.id);
                if (x.standing) {
                    try self.standing_arcs.put(self.gpa, key(x.id), {});
                } else {
                    _ = self.standing_arcs.remove(key(x.id));
                }
            },
            .setShort => |x| {
                const t = try self.ensureNode(x.id);
                t.short = try self.a().dupe(u8, x.short);
            },
        }
    }

    /// Replay snapshot (if present) then the log, then verify the DAG invariant.
    /// A cycle anywhere in the folded `needs` set is a loud `error.DependencyCycle`
    /// — re-checked here (not only on append) because a merge could introduce a
    /// cycle neither side had.
    ///
    /// A self-wait cycle mediated by `in` (arc membership) — e.g. a task that
    /// `needs` its own arc — is a DIFFERENT case: `append` refuses to ever
    /// CREATE one going forward (`combinedReaches`, below), but a log that
    /// predates this check, or was hand-edited/badly merged, may already
    /// carry one. Refusing to load it would brick an already-affected repo,
    /// which is strictly worse than the bug (a real repo was found in
    /// exactly this state — see `docs/design.md` "Arc-as-prereq"). So this
    /// is a WARNING, not a load failure: EVERY such pair found is collected
    /// into `self_wait_cycles` and surfaced by main.zig; `load` still
    /// succeeds. Union-merge is exactly why this must run at load time and
    /// not only at append time: two parallel worktrees can each append an
    /// edge that is individually acyclic from that writer's own local view
    /// (one adds `t needs arc`, the other adds `t in arc`, neither sees the
    /// other's edge) — `append`'s incremental gate cannot catch a cycle
    /// that only exists in the UNION of two logs neither writer held
    /// locally; the full rescan here is the check that cannot be evaded by
    /// that race (see store_test.zig's union-merge self-wait test).
    pub fn load(self: *Store) !void {
        try self.replayFile(snapshot_name);
        try self.replayFile(log_name);
        try self.checkAcyclic();
        // Reset before recomputing: `load` is safe to call more than once on
        // a live Store (tests do), and the list must not accumulate stale
        // pairs from a prior fold.
        self.self_wait_cycles.clearRetainingCapacity();
        try self.findSelfWaitCycles(&self.self_wait_cycles);
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
        self.config.add_arcless_error = self.readAddArclessError(root);
    }

    /// Pull `add.arcless` (a string, `"warn"` or `"error"`) from the config
    /// root. Returns `false` (warn) for a missing section/key, a non-string
    /// value, or any string other than exactly `"error"` — so a typo degrades
    /// to the safe default rather than silently hard-erroring every add.
    fn readAddArclessError(_: *Store, root: std.json.ObjectMap) bool {
        const sv = root.get("add") orelse return false;
        const so = switch (sv) {
            .object => |o| o,
            else => return false,
        };
        const ov = so.get("arcless") orelse return false;
        const s = switch (ov) {
            .string => |str| str,
            else => return false,
        };
        return std.mem.eql(u8, s, "error");
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
                if (x.short) |s| gpa.free(s);
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
            .setShort => |x| gpa.free(x.short),
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

    /// True iff `target` is reachable from `start` via the COMBINED self-wait
    /// graph: `needs` edges (from -> to) union `in` membership edges
    /// reversed (arc -> task, since an arc structurally depends on
    /// completing every direct member before IT can be considered done —
    /// see `append`'s doc comment and design.md "Arc-as-prereq"). Pure
    /// query over whatever is currently applied; no allocation escapes.
    ///
    /// This is the incremental, single-edge gate `append` uses: adding a new
    /// directed edge X -> Y closes a cycle iff Y can already reach X, so the
    /// call site checks `combinedReaches(Y, X)` AFTER tentatively applying
    /// the edge — the edge itself points the wrong way to matter to this
    /// search (it goes OUT of X, this search is looking for a path INTO X),
    /// so including it in the graph already is harmless.
    fn combinedReaches(self: *Store, alloc: std.mem.Allocator, start: Ulid, target: Ulid) Error!bool {
        var seen = std.AutoHashMapUnmanaged(Key, void){};
        defer seen.deinit(alloc);
        var stack: std.ArrayList(Ulid) = .empty;
        defer stack.deinit(alloc);
        try stack.append(alloc, start);
        try seen.put(alloc, key(start), {});

        while (stack.pop()) |cur| {
            if (cur.eql(target)) return true;
            for (self.needs.items) |e| {
                if (!e.from.eql(cur)) continue;
                const gop = try seen.getOrPut(alloc, key(e.to));
                if (!gop.found_existing) try stack.append(alloc, e.to);
            }
            for (self.ins.items) |e| {
                if (!e.arc.eql(cur)) continue; // arc -> task, reversed
                const gop = try seen.getOrPut(alloc, key(e.task));
                if (!gop.found_existing) try stack.append(alloc, e.task);
            }
        }
        return false;
    }

    /// Full scan of the COMBINED self-wait graph (see `combinedReaches` for
    /// the edge-set definition) for EVERY cycle anywhere in it — appends the
    /// (from, to) endpoints of the back-edge that closes each one found to
    /// `out` (scan order, not necessarily insertion order; `out` is left
    /// empty, not cleared, on an acyclic graph). Pure query: never mutates
    /// self, never raises on a found cycle — the caller decides what a
    /// cycle means (`append` rejects via `combinedReaches`, `load` warns via
    /// this, once per pair).
    ///
    /// Reports ALL cycles, not just the first: a log can carry more than one
    /// independent self-wait pair (two unrelated bad merges, or debris from
    /// before this check existed), and stopping at the first would leave
    /// every OTHER cycled task exactly as silently unreachable from every
    /// view as the bug this whole mechanism exists to make visible.
    ///
    /// Unlike `combinedReaches` (a single-edge, incremental check), this is
    /// an unconditional full rescan — too expensive to run on every write,
    /// but exactly right for the ONE-TIME check right after `load`, where
    /// the log may hold structure no incremental gate ever validated (a
    /// hand-edited log, a log predating this check, or a union-merge of two
    /// worktree logs — see `load`'s doc comment for why append-time
    /// checking alone cannot catch the merge case).
    pub fn findSelfWaitCycles(self: *Store, out: *std.ArrayList(SelfWaitPair)) Error!void {
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
        for (self.ins.items) |e| {
            // Reversed: the arc depends on the member, exactly like a needs edge.
            const gop = try adj.getOrPut(self.gpa, key(e.arc));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, e.task);
        }

        var color = std.AutoHashMapUnmanaged(Key, Color){};
        defer color.deinit(self.gpa);
        var task_it = self.tasks.keyIterator();
        while (task_it.next()) |k| {
            if ((color.get(k.*) orelse .white) != .white) continue;
            try self.selfWaitDfs(k.*, &adj, &color, out);
        }
    }

    fn selfWaitDfs(
        self: *Store,
        start: Key,
        adj: *std.AutoHashMapUnmanaged(Key, std.ArrayList(Ulid)),
        color: *std.AutoHashMapUnmanaged(Key, Color),
        out: *std.ArrayList(SelfWaitPair),
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
                    // A back-edge closes a cycle: RECORD it and keep scanning
                    // (do not push/descend into an already-gray node — that
                    // would loop forever) so a second, independent cycle
                    // elsewhere in the graph is not left unreported.
                    .gray => try out.append(self.gpa, .{ .from = .{ .text = top.node }, .to = next_id }),
                    .black => {},
                }
            } else {
                try color.put(self.gpa, top.node, .black);
                _ = stack.pop();
            }
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
    /// applying it to in-memory state. For a `dep`/`in` event we re-verify the
    /// self-wait invariant and reject `error.DependencyCycle` *before*
    /// persisting, so the log never holds a write that closes a cycle.
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

        // Capture lengths so we can tell a genuinely NEW edge from a dedup
        // no-op (`dep`) or a seq-only update (`in`) — both append-only lists
        // grow iff `apply` actually added an entry (see `apply`'s dedup
        // guards). This matters: re-checking on a no-op/update is not just
        // wasted work, it risks popping the WRONG (unrelated) tail entry.
        const needs_before = self.needs.items.len;
        const ins_before = self.ins.items.len;
        try self.apply(ev);

        // A freshly-added `dep` or `in` edge can close a cycle in the
        // COMBINED self-wait graph: `needs` edges (from -> to) union `in`
        // membership edges reversed (arc -> task — an arc structurally
        // depends on completing every direct member before IT can be
        // considered done, exactly like a needs edge, just spelled the other
        // way round from the `in(task, arc)` event; see design.md
        // "Arc-as-prereq"). The single most common shape: a task that
        // `needs` its own arc (directly or transitively) can never become
        // ready, because the arc can never drain while that same task is
        // still open — each waits on the other forever.
        //
        // Checked INCREMENTALLY against just the new edge: every prior
        // structural change went through this same gate, so the combined
        // graph was self-wait-free immediately before this one edge lands,
        // which means any cycle in the new graph must run through it —
        // scanning from its far endpoint back to its near endpoint
        // (`combinedReaches`) is therefore equivalent to, and far cheaper
        // than, a full rescan. It also stays scoped to THIS edit even in a
        // repo that already carries a pre-existing (legacy, load-time-warned
        // — see `load`) cycle elsewhere: an unrelated future `dep`/`in` is
        // never blocked by debt it doesn't touch, because the search starts
        // at this edge's own endpoints, not at the whole graph.
        switch (ev) {
            .dep => |x| {
                if (self.needs.items.len > needs_before and try self.combinedReaches(self.gpa, x.to, x.from)) {
                    _ = self.needs.pop();
                    return error.DependencyCycle;
                }
            },
            .in => |x| {
                if (self.ins.items.len > ins_before and try self.combinedReaches(self.gpa, x.task, x.arc)) {
                    _ = self.ins.pop();
                    return error.DependencyCycle;
                }
            },
            else => {},
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
    ///   - `arcDeclare{declared:true}` if the task is in `declared_arcs`
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

            // .short is carried through VERBATIM — this is the fix for the
            // instability bug: a compact must never let a task's frozen short
            // silently regress to a shorter/different dynamically-computed
            // value just because the live id set shrank.
            try self.emit(buf, .{ .add = .{
                .id = id,
                .title = t.title,
                .body = t.body,
                .tags = tag_slice,
                .short = t.short,
            } });
            if (t.state != .open)
                try self.emit(buf, .{ .setState = .{ .id = id, .state = t.state } });
            if (t.priority != 0)
                try self.emit(buf, .{ .setPriority = .{ .id = id, .priority = t.priority } });
            for (t.docrefs.items) |dr|
                try self.emit(buf, .{ .docref = .{
                    .id = id,
                    .doc_id = dr.doc_id,
                    .section_id = dr.section_id,
                } });
            if (self.declared_arcs.contains(key(id)))
                try self.emit(buf, .{ .arcDeclare = .{ .id = id, .declared = true } });
            if (self.standing_arcs.contains(key(id)))
                try self.emit(buf, .{ .arcStanding = .{ .id = id, .standing = true } });
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
                .unin => |x| blk: {
                    ts = x.ts;
                    task_id = x.task;
                    break :blk try std.fmt.allocPrint(alloc, "unin: {s} no longer in {s}", .{ x.task.slice(), x.arc.slice() });
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
                .arcDeclare => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "arc: {s}", .{if (x.declared) "declared" else "undeclared"});
                },
                .arcStanding => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "arc: {s}", .{if (x.standing) "marked standing" else "unmarked standing"});
                },
                .setShort => |x| blk: {
                    ts = x.ts;
                    task_id = x.id;
                    break :blk try std.fmt.allocPrint(alloc, "short frozen: {s}", .{x.short});
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

    /// True if `id` is an arc: EXPLICITLY DECLARED (`trk arc <id>` / `trk add
    /// --arc`, an `arcDeclare{declared:true}` event — `declared_arcs`), OR at
    /// least one task is `in id`. A `needs` edge whose target is an arc means
    /// "needs the whole arc."
    ///
    /// This is the single, unified arc-ness check — it replaces three
    /// previously non-agreeing notions: this direct-`in`-edge test, `in`+
    /// reachability (`membersOf`/`arcsOf`, a strictly WIDER set used for
    /// listing/rendering — do not conflate the two), and a cosmetic `arc:`
    /// slug tag that a render-polish commit introduced to keep an empty arc
    /// (no `in` members yet, so invisible to the two structural checks) out of
    /// the "Arc-less" section. Declaring makes an empty arc structurally
    /// expressible, so the tag is no longer needed as a definition — but it is
    /// still HONORED here, read-only, for backward compatibility with any
    /// already-tagged arc: DEPRECATED, do not write new `arc:` tags; `trk
    /// migrate-arcs` converts every tagged task to a real `arcDeclare` and
    /// strips the tag.
    pub fn isArc(self: *Store, id: Ulid) bool {
        if (self.declared_arcs.contains(key(id))) return true;
        for (self.ins.items) |e| {
            if (e.arc.eql(id)) return true;
        }
        if (self.tasks.get(key(id))) |t| {
            for (t.tags.items) |tg| {
                if (std.mem.startsWith(u8, tg, "arc:")) return true;
            }
        }
        return false;
    }

    /// True iff `id` is marked a STANDING arc (`trk arc <id> --standing`): a
    /// goal container that names a perpetual category rather than a
    /// completable goal. Consulted only where it matters — `next` excludes a
    /// standing arc from the ready frontier unconditionally, drained or not,
    /// so it never surfaces as a false "this looks finished, close it?"
    /// prompt. Meaningless (but harmless) on a task for which `isArc` is
    /// false; `trk arc <id> --standing` always declares the arc in the same
    /// act, so that combination should not arise via the CLI.
    pub fn isStanding(self: *Store, id: Ulid) bool {
        return self.standing_arcs.contains(key(id));
    }

    /// Every declared-or-inferred arc root id: appears as an `in.arc`, is in
    /// `declared_arcs`, or (back-compat) carries an `arc:` tag — i.e. every id
    /// for which `isArc` is true. Caller owns the slice. Shared by `arcless`
    /// and the CLI's arc-section collector so both use the identical set.
    pub fn arcRoots(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var out: std.ArrayList(Ulid) = .empty;
        var it = self.tasks.keyIterator();
        while (it.next()) |k| {
            const id: Ulid = .{ .text = k.* };
            if (self.isArc(id)) try out.append(alloc, id);
        }
        const s = try out.toOwnedSlice(alloc);
        std.sort.pdq(Ulid, s, {}, Ulid.lessThan);
        return s;
    }

    /// Every task belonging to NO arc: not itself an arc root, not a direct
    /// `in` member of one, and not `needs`-reachable from a member of one —
    /// the complement of the union of `membersOf(arc)` over every arc root.
    /// The completeness counterpart to `membersOf`: the terminating condition
    /// for "sort everything into arcs" (`trk list --no-arc`), and what
    /// `render`'s generated header counts as drift. Caller owns the slice.
    pub fn arcless(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        const roots = try self.arcRoots(self.gpa);
        defer self.gpa.free(roots);

        var in_some = std.AutoHashMapUnmanaged(Key, void){};
        defer in_some.deinit(self.gpa);
        for (roots) |arc| {
            const members = try self.membersOf(self.gpa, arc);
            defer self.gpa.free(members);
            for (members) |m| try in_some.put(self.gpa, key(m), {});
        }

        var out: std.ArrayList(Ulid) = .empty;
        var it = self.tasks.keyIterator();
        while (it.next()) |k| {
            if (!in_some.contains(k.*)) try out.append(self.gpa, .{ .text = k.* });
        }
        const s = try out.toOwnedSlice(self.gpa);
        defer self.gpa.free(s);
        const final = try alloc.alloc(Ulid, s.len);
        @memcpy(final, s);
        std.sort.pdq(Ulid, final, {}, Ulid.lessThan);
        return final;
    }

    /// Drained: no DIRECT member (a task with `in id`), excluding members tagged
    /// `parked` (optional/future stubs), is unsatisfied. Vacuously TRUE for an
    /// arc with no non-parked members — nothing actionable is pending, so the
    /// root should surface for its close-out rather than black-hole.
    ///
    /// Drained is the OBSERVED fact and is never stored (it flaps by design: a
    /// newly filed member un-drains the arc). The root's own `done` is the
    /// completion JUDGMENT: `needs` gates wait on the root's state like any
    /// other prereq; `next` uses drained only to decide when to OFFER the root
    /// (the close-out prompt). See design.md's drained-vs-complete ruling.
    /// Direct members only: a member can't be done while its own `needs` are
    /// open, so "all direct members satisfied" implies their prereqs.
    pub fn arcDrained(self: *Store, id: Ulid) bool {
        for (self.ins.items) |e| {
            if (!e.arc.eql(id)) continue;
            const m = self.tasks.get(key(e.task)) orelse return false; // unknown member → not drained
            if (self.taskHasTag(m, "parked")) continue; // parked stubs don't gate
            if (!m.state.satisfiesPrereq()) return false;
        }
        return true;
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
    /// (sorted after arc'd tasks by the sentinel). An arc ROOT is a container —
    /// its work is its members' — so it is additionally held back until the arc
    /// is drained, then surfaces exactly once as the close-out prompt. A `needs`
    /// edge targeting a root gates on the root's own state (the completion
    /// judgment), NOT on drainage — the root is an ordinary prereq here.
    /// Caller owns the slice.
    pub fn next(self: *Store, alloc: std.mem.Allocator) ![]Ulid {
        var ranked: std.ArrayList(Ranked) = .empty;
        defer ranked.deinit(self.gpa);

        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr.*;
            if (!t.state.isEligible()) continue; // only `open` is eligible

            if (self.isArc(t.id)) {
                // A standing arc (a perpetual category, not a completable goal)
                // NEVER surfaces here, drained or not — offering it as the
                // close-out prompt would assert a completion that never
                // happens (see `isStanding`).
                if (self.isStanding(t.id)) continue;
                // An undrained arc root is never handed out (do the members first).
                if (!self.arcDrained(t.id)) continue;
            }

            // Every prereq must be satisfied.
            var ready = true;
            for (self.needs.items) |e| {
                if (!e.from.eql(t.id)) continue;
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
