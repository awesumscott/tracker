// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! JSON line codec for the event log.
//!
//! Write path: hand-rolled minimal JSON emit into an `ArrayList(u8)` — one
//! compact object per line, deterministic key order, no trailing newline (the
//! store adds it). Hand-rolling keeps us off the moving `std.json.Stringify`
//! Writer-interface surface (it churned across 0.x) and gives a stable on-disk
//! format we fully control.
//!
//! Read path: `std.json.parseFromSlice(std.json.Value, ...)` — the dynamic
//! Value tree is the stable part of std.json. We pull typed fields off it.
//!
//! Schema (one object per line). `op` is the discriminator:
//!   {"op":"add","id":"<ulid>","title":"..","body":"..","tags":["a","b"],"short":"..."|omitted,"ts":169..}
//!   {"op":"setState","id":"<ulid>","state":"open|done|blocked|dropped|archived|leased|submitted","ts":0}
//!     (state tokens are NOT the CLI names for every state — see `stateToWire`)
//!   {"op":"dep","from":"<ulid>","to":"<ulid>","ts":0}
//!   {"op":"in","task":"<ulid>","arc":"<ulid>","seq":0,"ts":0}
//!   {"op":"setPriority","id":"<ulid>","priority":0,"ts":0}
//! An `add` written by `compact` carries one extra key, `"wm"` (the task's
//! watermark — see `model.Event.add.wm`); the decoder ignores keys it does not
//! know, so an older binary reads such a snapshot unchanged.
//!   {"op":"tag","id":"<ulid>","tag":"...","ts":0}
//!   {"op":"docref","id":"<ulid>","doc_id":"...","section_id":"..."|null-omitted,"ts":0}
//!   {"op":"setDocPath","doc_id":"...","path":"docs/design/foo.md","ts":0}
//!   {"op":"setTitle","id":"<ulid>","title":"...","ts":0}
//!   {"op":"setBody","id":"<ulid>","body":"...","ts":0}
//!   {"op":"untag","id":"<ulid>","tag":"...","ts":0}
//!   {"op":"undep","from":"<ulid>","to":"<ulid>","ts":0}
//!   {"op":"unin","task":"<ulid>","arc":"<ulid>","ts":0}
//!   {"op":"undocref","id":"<ulid>","doc_id":"...","ts":0}
//!   {"op":"arcDeclare","id":"<ulid>","declared":true|false,"ts":0}
//!   {"op":"arcStanding","id":"<ulid>","standing":true|false,"ts":0}
//!   {"op":"setShort","id":"<ulid>","short":"...","ts":0}
//!   {"op":"release","id":"<ulid>","holder":"...","ts":0}
//! A `setState` to the lease (`"leased"`) carries `"holder":"..."`; no other
//! state writes the key, and decode ignores it on any other state.
//!
//! ts=0 is tolerated on decode (legacy lines / snapshot events). `add`'s
//! "short" is likewise optional-on-decode (absent -> null): every add event
//! written before short-id freezing existed omits it.
//!
//! Forward-compat contract for a FUTURE op (01KYT2QET, 2026-07-30): an
//! unrecognized `op` no longer hard-fails `Store.load` — it is skipped (and
//! warned about), because a single line carrying a new op must not brick
//! every not-yet-updated binary's reads. This is safe by default only because
//! every op that exists today is monotonic in the "safe to miss" direction
//! (see `Op` in model.zig / `peekUnknownOp` below); a future op whose effect
//! would NOT be safe for an old binary to silently miss must carry an
//! explicit `"breaking":true` field in its own encode() case, which routes an
//! old binary to a hard failure instead of a silent skip. Default (absent) is
//! `false` — every op below predates this contract and needs no change.

const std = @import("std");
const model = @import("model.zig");
const ulid = @import("ulid.zig");

const Event = model.Event;
const Ulid = model.Ulid;

pub const DecodeError = error{
    NotAnObject,
    MissingOp,
    UnknownOp,
    MissingField,
    BadFieldType,
    BadUlid,
    BadState,
} || std.mem.Allocator.Error;

// ----------------------------------------------------------------- state tokens

/// The on-disk token for a state. Identical to the CLI name except for the
/// lease: `State.claimed` is written `leased`, because the token `claimed` was
/// already spent — every line a pre-rename binary wrote with it means
/// `submitted`, and a long-lived branch can union-merge more of those in at any
/// time. A token that has never meant anything else keeps both readable forever.
pub fn stateToWire(st: model.State) []const u8 {
    return switch (st) {
        .claimed => "leased",
        else => st.toString(),
    };
}

/// Inverse of `stateToWire`, plus the legacy alias: `claimed` decodes as
/// `submitted`, never as the lease. An older binary meets `leased`/`submitted`
/// as `BadState` and refuses to load — loud, never a silent misread.
pub fn stateFromWire(tok: []const u8) ?model.State {
    if (std.mem.eql(u8, tok, "leased")) return .claimed;
    if (std.mem.eql(u8, tok, "claimed")) return .submitted;
    if (std.mem.eql(u8, tok, "submitted")) return .submitted;
    const st = model.State.fromString(tok) orelse return null;
    return switch (st) {
        .claimed, .submitted => unreachable, // both handled above
        else => st,
    };
}

// ----------------------------------------------------------------- encode

pub fn writeJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var tmp: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(gpa, hex);
            },
            else => try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
}

fn writeKey(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8, first: *bool) !void {
    if (!first.*) try buf.append(gpa, ',');
    first.* = false;
    try writeJsonString(buf, gpa, key);
    try buf.append(gpa, ':');
}

fn writeInt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64) !void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    try buf.appendSlice(gpa, s);
}

fn writeBool(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(gpa, if (v) "true" else "false");
}

/// Encode an event as a single JSON object (no newline) appended to `buf`.
pub fn encode(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, ev: Event) !void {
    var first = true;
    try buf.append(gpa, '{');
    try writeKey(buf, gpa, "op", &first);
    try writeJsonString(buf, gpa, @tagName(ev));
    switch (ev) {
        .add => |a| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, a.id.slice());
            try writeKey(buf, gpa, "title", &first);
            try writeJsonString(buf, gpa, a.title);
            try writeKey(buf, gpa, "body", &first);
            try writeJsonString(buf, gpa, a.body);
            try writeKey(buf, gpa, "tags", &first);
            try buf.append(gpa, '[');
            for (a.tags, 0..) |t, i| {
                if (i != 0) try buf.append(gpa, ',');
                try writeJsonString(buf, gpa, t);
            }
            try buf.append(gpa, ']');
            if (a.short) |s| {
                try writeKey(buf, gpa, "short", &first);
                try writeJsonString(buf, gpa, s);
            }
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, a.ts);
            // Only when set (snapshot lines), so every line the APPEND path
            // writes stays byte-identical to what it wrote before this existed.
            if (a.wm != 0) {
                try writeKey(buf, gpa, "wm", &first);
                try writeInt(buf, gpa, a.wm);
            }
        },
        .setState => |s| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, s.id.slice());
            try writeKey(buf, gpa, "state", &first);
            try writeJsonString(buf, gpa, stateToWire(s.state));
            if (s.state == .claimed) {
                if (s.holder) |h| {
                    try writeKey(buf, gpa, "holder", &first);
                    try writeJsonString(buf, gpa, h);
                }
            }
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, s.ts);
        },
        .dep => |d| {
            try writeKey(buf, gpa, "from", &first);
            try writeJsonString(buf, gpa, d.from.slice());
            try writeKey(buf, gpa, "to", &first);
            try writeJsonString(buf, gpa, d.to.slice());
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
        },
        .in => |n| {
            try writeKey(buf, gpa, "task", &first);
            try writeJsonString(buf, gpa, n.task.slice());
            try writeKey(buf, gpa, "arc", &first);
            try writeJsonString(buf, gpa, n.arc.slice());
            try writeKey(buf, gpa, "seq", &first);
            try writeInt(buf, gpa, n.seq);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, n.ts);
        },
        .setPriority => |p| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, p.id.slice());
            try writeKey(buf, gpa, "priority", &first);
            try writeInt(buf, gpa, p.priority);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, p.ts);
        },
        .tag => |t| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, t.id.slice());
            try writeKey(buf, gpa, "tag", &first);
            try writeJsonString(buf, gpa, t.tag);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, t.ts);
        },
        .docref => |r| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, r.id.slice());
            try writeKey(buf, gpa, "doc_id", &first);
            try writeJsonString(buf, gpa, r.doc_id);
            if (r.section_id) |sid| {
                try writeKey(buf, gpa, "section_id", &first);
                try writeJsonString(buf, gpa, sid);
            }
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, r.ts);
        },
        .setDocPath => |p| {
            try writeKey(buf, gpa, "doc_id", &first);
            try writeJsonString(buf, gpa, p.doc_id);
            try writeKey(buf, gpa, "path", &first);
            try writeJsonString(buf, gpa, p.path);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, p.ts);
        },
        .setTitle => |t| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, t.id.slice());
            try writeKey(buf, gpa, "title", &first);
            try writeJsonString(buf, gpa, t.title);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, t.ts);
        },
        .setBody => |b| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, b.id.slice());
            try writeKey(buf, gpa, "body", &first);
            try writeJsonString(buf, gpa, b.body);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, b.ts);
        },
        .untag => |t| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, t.id.slice());
            try writeKey(buf, gpa, "tag", &first);
            try writeJsonString(buf, gpa, t.tag);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, t.ts);
        },
        .undocref => |r| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, r.id.slice());
            try writeKey(buf, gpa, "doc_id", &first);
            try writeJsonString(buf, gpa, r.doc_id);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, r.ts);
        },
        .undep => |d| {
            try writeKey(buf, gpa, "from", &first);
            try writeJsonString(buf, gpa, d.from.slice());
            try writeKey(buf, gpa, "to", &first);
            try writeJsonString(buf, gpa, d.to.slice());
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
        },
        .unin => |d| {
            try writeKey(buf, gpa, "task", &first);
            try writeJsonString(buf, gpa, d.task.slice());
            try writeKey(buf, gpa, "arc", &first);
            try writeJsonString(buf, gpa, d.arc.slice());
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
        },
        .arcDeclare => |d| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, d.id.slice());
            try writeKey(buf, gpa, "declared", &first);
            try writeBool(buf, gpa, d.declared);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
        },
        .arcStanding => |d| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, d.id.slice());
            try writeKey(buf, gpa, "standing", &first);
            try writeBool(buf, gpa, d.standing);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
        },
        .setShort => |s| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, s.id.slice());
            try writeKey(buf, gpa, "short", &first);
            try writeJsonString(buf, gpa, s.short);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, s.ts);
        },
        .release => |r| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, r.id.slice());
            try writeKey(buf, gpa, "holder", &first);
            try writeJsonString(buf, gpa, r.holder);
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, r.ts);
        },
    }
    try buf.append(gpa, '}');
}

// ----------------------------------------------------------------- decode

fn getStr(obj: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |s| s,
        else => error.BadFieldType,
    };
}

fn getStrDefault(obj: std.json.ObjectMap, key: []const u8, def: []const u8) []const u8 {
    const v = obj.get(key) orelse return def;
    return switch (v) {
        .string => |s| s,
        else => def,
    };
}

fn getIntDefault(obj: std.json.ObjectMap, key: []const u8, def: i64) i64 {
    const v = obj.get(key) orelse return def;
    return switch (v) {
        .integer => |i| i,
        else => def,
    };
}

fn getBoolDefault(obj: std.json.ObjectMap, key: []const u8, def: bool) bool {
    const v = obj.get(key) orelse return def;
    return switch (v) {
        .bool => |b| b,
        else => def,
    };
}

fn getUlid(obj: std.json.ObjectMap, key: []const u8) DecodeError!Ulid {
    const s = try getStr(obj, key);
    return ulid.parse(s) catch error.BadUlid;
}

/// Info about a line whose `op` is not in the CURRENT binary's `Op` enum —
/// i.e. `decode` on it returned `error.UnknownOp`. Consulted ONLY on that
/// path (01KYT2QET, 2026-07-30): a single log line carrying a new op used to
/// hard-fail `Store.load` for every older binary — reads included, not just
/// writes — which is what made `trk unin` unusable on any not-yet-updated
/// checkout for hours the day it shipped. `Store.load` now SKIPS (and warns
/// about) an unrecognized op by default rather than failing the whole load.
pub const UnknownOpInfo = struct {
    /// The raw `op` string, gpa-owned (caller frees).
    op: []const u8,
    /// True iff the line explicitly opts OUT of the skip-and-warn default via
    /// a `"breaking":true` envelope field. This is the escape hatch for the
    /// hazard skip-and-warn cannot safely be blind to: skipping is safe ONLY
    /// while every op is monotonic in the direction "an old binary that
    /// never applies this op sees a MORE-connected / MORE-blocked graph than
    /// truth, never a more-satisfied one" (true of `undep`/`unin` today — an
    /// old binary that misses one just keeps an edge that should be gone,
    /// which can only under-eligible, never falsely mark something ready or
    /// done). Nothing enforces that direction for an op that doesn't exist
    /// yet. So the decision is pushed to whoever adds the NEW op, explicitly,
    /// at write time — not inferred by the reader, which cannot know a future
    /// op's semantics: if its effect would be unsafe for an old binary to
    /// silently miss (e.g. it revokes a satisfaction, or deletes a task
    /// outright rather than just an edge), the writer marks it
    /// `"breaking":true` and an old binary refuses to load past it instead of
    /// silently trusting stale, falsely-permissive state. Absent (or
    /// `false`) — the default for every op that exists today — means safe to
    /// skip.
    breaking: bool,
};

/// Peek at a line already known to carry an unrecognized `op` (i.e. `decode`
/// on it returned `error.UnknownOp`) and extract just the `op` string plus
/// the `"breaking"` envelope flag, without needing to know the unrecognized
/// op's own field shape. Re-parses the line — cheap, since this only runs on
/// the rare unknown-op fallback path, never per-line on the hot path. Returns
/// `null` only if the line somehow no longer parses as a JSON object with a
/// string `op` (shouldn't happen for a line `decode` already got as far as
/// `UnknownOp` on, but handled defensively rather than asserted).
pub fn peekUnknownOp(gpa: std.mem.Allocator, line: []const u8) !?UnknownOpInfo {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const op_str = getStr(obj, "op") catch return null;
    return .{
        .op = try gpa.dupe(u8, op_str),
        .breaking = getBoolDefault(obj, "breaking", false),
    };
}

/// Parse one JSON line into an Event. Strings in the returned Event are dup'd
/// into `gpa` (so they outlive the parse arena — the store owns the dup'd mem).
/// ts=0 (missing field) is tolerated for all variants (legacy / snapshot lines).
pub fn decode(gpa: std.mem.Allocator, line: []const u8) DecodeError!Event {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
        return error.NotAnObject;
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const op_str = getStr(obj, "op") catch return error.MissingOp;
    const op = std.meta.stringToEnum(model.Op, op_str) orelse return error.UnknownOp;

    switch (op) {
        .add => {
            const id = try getUlid(obj, "id");
            const title = try gpa.dupe(u8, getStrDefault(obj, "title", ""));
            const body = try gpa.dupe(u8, getStrDefault(obj, "body", ""));
            var tags: std.ArrayList([]const u8) = .empty;
            if (obj.get("tags")) |tv| switch (tv) {
                .array => |arr| {
                    for (arr.items) |item| switch (item) {
                        .string => |s| try tags.append(gpa, try gpa.dupe(u8, s)),
                        else => {},
                    };
                },
                else => {},
            };
            const short: ?[]const u8 = blk: {
                if (obj.get("short")) |sv| switch (sv) {
                    .string => |s| break :blk try gpa.dupe(u8, s),
                    else => {},
                };
                break :blk null;
            };
            return .{ .add = .{
                .id = id,
                .title = title,
                .body = body,
                .tags = try tags.toOwnedSlice(gpa),
                .short = short,
                .ts = getIntDefault(obj, "ts", 0),
                .wm = getIntDefault(obj, "wm", 0),
            } };
        },
        .setState => {
            const id = try getUlid(obj, "id");
            const st = stateFromWire(try getStr(obj, "state")) orelse return error.BadState;
            const holder: ?[]const u8 = blk: {
                if (st != .claimed) break :blk null;
                if (obj.get("holder")) |hv| switch (hv) {
                    .string => |h| break :blk try gpa.dupe(u8, h),
                    else => {},
                };
                break :blk null;
            };
            return .{ .setState = .{ .id = id, .state = st, .holder = holder, .ts = getIntDefault(obj, "ts", 0) } };
        },
        .dep => return .{ .dep = .{
            .from = try getUlid(obj, "from"),
            .to = try getUlid(obj, "to"),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .in => return .{ .in = .{
            .task = try getUlid(obj, "task"),
            .arc = try getUlid(obj, "arc"),
            .seq = @intCast(getIntDefault(obj, "seq", 0)),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .setPriority => return .{ .setPriority = .{
            .id = try getUlid(obj, "id"),
            .priority = @intCast(getIntDefault(obj, "priority", 0)),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .tag => return .{ .tag = .{
            .id = try getUlid(obj, "id"),
            .tag = try gpa.dupe(u8, try getStr(obj, "tag")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .docref => {
            const id = try getUlid(obj, "id");
            const doc_id = try gpa.dupe(u8, try getStr(obj, "doc_id"));
            const sid: ?[]const u8 = blk: {
                if (obj.get("section_id")) |sv| switch (sv) {
                    .string => |s| break :blk try gpa.dupe(u8, s),
                    else => {},
                };
                break :blk null;
            };
            return .{ .docref = .{ .id = id, .doc_id = doc_id, .section_id = sid, .ts = getIntDefault(obj, "ts", 0) } };
        },
        .setDocPath => return .{ .setDocPath = .{
            .doc_id = try gpa.dupe(u8, try getStr(obj, "doc_id")),
            .path = try gpa.dupe(u8, try getStr(obj, "path")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .setTitle => return .{ .setTitle = .{
            .id = try getUlid(obj, "id"),
            .title = try gpa.dupe(u8, try getStr(obj, "title")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .setBody => return .{ .setBody = .{
            .id = try getUlid(obj, "id"),
            .body = try gpa.dupe(u8, try getStr(obj, "body")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .untag => return .{ .untag = .{
            .id = try getUlid(obj, "id"),
            .tag = try gpa.dupe(u8, try getStr(obj, "tag")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .undocref => return .{ .undocref = .{
            .id = try getUlid(obj, "id"),
            .doc_id = try gpa.dupe(u8, try getStr(obj, "doc_id")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .undep => return .{ .undep = .{
            .from = try getUlid(obj, "from"),
            .to = try getUlid(obj, "to"),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .unin => return .{ .unin = .{
            .task = try getUlid(obj, "task"),
            .arc = try getUlid(obj, "arc"),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .arcDeclare => return .{ .arcDeclare = .{
            .id = try getUlid(obj, "id"),
            .declared = getBoolDefault(obj, "declared", false),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .arcStanding => return .{ .arcStanding = .{
            .id = try getUlid(obj, "id"),
            .standing = getBoolDefault(obj, "standing", false),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .setShort => return .{ .setShort = .{
            .id = try getUlid(obj, "id"),
            .short = try gpa.dupe(u8, try getStr(obj, "short")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
        .release => return .{ .release = .{
            .id = try getUlid(obj, "id"),
            .holder = try gpa.dupe(u8, try getStr(obj, "holder")),
            .ts = getIntDefault(obj, "ts", 0),
        } },
    }
}

// ----- tests -----

const testing = std.testing;

test "encode/decode round-trip add" {
    const gpa = testing.allocator;
    const id = try ulid.parse(&ulid.mintAt(testing.io, 100).text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const tags = [_][]const u8{ "wm", "metal" };
    try encode(&buf, gpa, .{ .add = .{ .id = id, .title = "T", .body = "b\"q\"", .tags = &tags, .ts = 100 } });

    const ev = try decode(gpa, buf.items);
    defer {
        gpa.free(ev.add.title);
        gpa.free(ev.add.body);
        for (ev.add.tags) |t| gpa.free(t);
        gpa.free(ev.add.tags);
    }
    try testing.expect(ev.add.id.eql(id));
    try testing.expectEqualStrings("T", ev.add.title);
    try testing.expectEqualStrings("b\"q\"", ev.add.body); // quote escaping survived
    try testing.expectEqual(@as(usize, 2), ev.add.tags.len);
}

test "encode/decode add: short is omitted when null, round-trips when set" {
    const gpa = testing.allocator;
    const id = try ulid.parse(&ulid.mintAt(testing.io, 100).text);

    // null short -> the key is absent from the line entirely.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try encode(&buf, gpa, .{ .add = .{ .id = id, .title = "T", .ts = 100 } });
        try testing.expect(std.mem.indexOf(u8, buf.items, "\"short\"") == null);

        const ev = try decode(gpa, buf.items);
        defer {
            gpa.free(ev.add.title);
            gpa.free(ev.add.body);
            gpa.free(ev.add.tags);
        }
        try testing.expect(ev.add.short == null);
    }

    // A set short survives the round-trip byte-for-byte.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try encode(&buf, gpa, .{ .add = .{ .id = id, .title = "T", .short = "01ARZ3NDE", .ts = 100 } });

        const ev = try decode(gpa, buf.items);
        defer {
            gpa.free(ev.add.title);
            gpa.free(ev.add.body);
            gpa.free(ev.add.tags);
            gpa.free(ev.add.short.?);
        }
        try testing.expectEqualStrings("01ARZ3NDE", ev.add.short.?);
    }
}

test "encode/decode round-trip setShort" {
    const gpa = testing.allocator;
    const id = try ulid.parse(&ulid.mintAt(testing.io, 100).text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(&buf, gpa, .{ .setShort = .{ .id = id, .short = "01ARZ3NDE", .ts = 100 } });

    const ev = try decode(gpa, buf.items);
    defer gpa.free(ev.setShort.short);
    try testing.expect(ev.setShort.id.eql(id));
    try testing.expectEqualStrings("01ARZ3NDE", ev.setShort.short);
}

test "encode/decode round-trip arcStanding" {
    const gpa = testing.allocator;
    const id = try ulid.parse(&ulid.mintAt(testing.io, 100).text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(&buf, gpa, .{ .arcStanding = .{ .id = id, .standing = true, .ts = 100 } });

    const ev = try decode(gpa, buf.items);
    try testing.expect(ev.arcStanding.id.eql(id));
    try testing.expect(ev.arcStanding.standing);
    try testing.expectEqual(@as(i64, 100), ev.arcStanding.ts);
}

test "encode/decode round-trip unin" {
    const gpa = testing.allocator;
    const task = try ulid.parse(&ulid.mintAt(testing.io, 100).text);
    const arc = try ulid.parse(&ulid.mintAt(testing.io, 200).text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encode(&buf, gpa, .{ .unin = .{ .task = task, .arc = arc, .ts = 150 } });

    const ev = try decode(gpa, buf.items);
    try testing.expect(ev.unin.task.eql(task));
    try testing.expect(ev.unin.arc.eql(arc));
    try testing.expectEqual(@as(i64, 150), ev.unin.ts);
}

test "decode rejects junk and unknown op" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotAnObject, decode(gpa, "not json"));
    try testing.expectError(error.UnknownOp, decode(gpa, "{\"op\":\"frobnicate\"}"));
    try testing.expectError(error.MissingOp, decode(gpa, "{\"id\":\"x\"}"));
}

test "encode/decode ts=0 legacy tolerance" {
    // A JSON line without a ts field (legacy format) must decode to ts=0.
    const gpa = testing.allocator;
    const line = "{\"op\":\"setState\",\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"state\":\"done\"}";
    const ev = try decode(gpa, line);
    try testing.expectEqual(@as(i64, 0), ev.setState.ts);
}

test "state wire tokens: legacy `claimed` decodes as submitted; the lease round-trips as `leased`" {
    const gpa = testing.allocator;
    const legacy = "{\"op\":\"setState\",\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"state\":\"claimed\",\"ts\":5}";
    try testing.expectEqual(model.State.submitted, (try decode(gpa, legacy)).setState.state);

    const id = try ulid.parse("01ARZ3NDEKTSV4RRFFQ69G5FAV");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for ([_]model.State{ .open, .done, .blocked, .dropped, .archived, .claimed, .submitted }) |st| {
        buf.clearRetainingCapacity();
        try encode(&buf, gpa, .{ .setState = .{ .id = id, .state = st, .holder = "lane-3", .ts = 1 } });
        // No state is ever WRITTEN as the spent token.
        try testing.expect(std.mem.indexOf(u8, buf.items, "\"claimed\"") == null);
        // Only the lease carries its holder.
        try testing.expectEqual(st == .claimed, std.mem.indexOf(u8, buf.items, "\"holder\":\"lane-3\"") != null);
        const ev = try decode(gpa, buf.items);
        try testing.expectEqual(st, ev.setState.state);
        if (ev.setState.holder) |h| {
            defer gpa.free(h);
            try testing.expectEqualStrings("lane-3", h);
        } else try testing.expect(st != .claimed);
    }
    buf.clearRetainingCapacity();
    try encode(&buf, gpa, .{ .setState = .{ .id = id, .state = .claimed, .ts = 1 } });
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"state\":\"leased\"") != null);

    buf.clearRetainingCapacity();
    try encode(&buf, gpa, .{ .release = .{ .id = id, .holder = "lane-3", .ts = 9 } });
    const rel = try decode(gpa, buf.items);
    defer gpa.free(rel.release.holder);
    try testing.expectEqualStrings("lane-3", rel.release.holder);
    try testing.expectEqual(@as(i64, 9), rel.release.ts);
    try testing.expectError(error.BadState, decode(gpa, "{\"op\":\"setState\",\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"state\":\"taken\"}"));
}

test "peekUnknownOp: extracts the op name and defaults breaking to false when absent" {
    const gpa = testing.allocator;
    const info = (try peekUnknownOp(gpa, "{\"op\":\"frobnicate\",\"id\":\"x\"}")).?;
    defer gpa.free(info.op);
    try testing.expectEqualStrings("frobnicate", info.op);
    try testing.expect(!info.breaking);
}

test "peekUnknownOp: honors an explicit \"breaking\":true envelope flag" {
    const gpa = testing.allocator;
    const info = (try peekUnknownOp(gpa, "{\"op\":\"purgeTask\",\"id\":\"x\",\"breaking\":true}")).?;
    defer gpa.free(info.op);
    try testing.expectEqualStrings("purgeTask", info.op);
    try testing.expect(info.breaking);
}

test "peekUnknownOp: an explicit \"breaking\":false is indistinguishable from absent" {
    const gpa = testing.allocator;
    const info = (try peekUnknownOp(gpa, "{\"op\":\"frobnicate\",\"breaking\":false}")).?;
    defer gpa.free(info.op);
    try testing.expect(!info.breaking);
}

test "peekUnknownOp: returns null on a line that isn't even a JSON object with a string op" {
    const gpa = testing.allocator;
    try testing.expect(try peekUnknownOp(gpa, "not json") == null);
    try testing.expect(try peekUnknownOp(gpa, "{\"id\":\"x\"}") == null); // no op field at all
}
