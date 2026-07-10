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
//!   {"op":"add","id":"<ulid>","title":"..","body":"..","tags":["a","b"],"ts":169..}
//!   {"op":"setState","id":"<ulid>","state":"open|done|blocked|dropped","ts":0}
//!   {"op":"dep","from":"<ulid>","to":"<ulid>","ts":0}
//!   {"op":"in","task":"<ulid>","arc":"<ulid>","seq":0,"ts":0}
//!   {"op":"setPriority","id":"<ulid>","priority":0,"ts":0}
//!   {"op":"tag","id":"<ulid>","tag":"...","ts":0}
//!   {"op":"docref","id":"<ulid>","doc_id":"...","section_id":"..."|null-omitted,"ts":0}
//!   {"op":"setDocPath","doc_id":"...","path":"docs/design/foo.md","ts":0}
//!   {"op":"setTitle","id":"<ulid>","title":"...","ts":0}
//!   {"op":"setBody","id":"<ulid>","body":"...","ts":0}
//!   {"op":"untag","id":"<ulid>","tag":"...","ts":0}
//!   {"op":"undep","from":"<ulid>","to":"<ulid>","ts":0}
//!
//! ts=0 is tolerated on decode (legacy lines / snapshot events).

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

// ----------------------------------------------------------------- encode

fn writeJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
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
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, a.ts);
        },
        .setState => |s| {
            try writeKey(buf, gpa, "id", &first);
            try writeJsonString(buf, gpa, s.id.slice());
            try writeKey(buf, gpa, "state", &first);
            try writeJsonString(buf, gpa, s.state.toString());
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
        .undep => |d| {
            try writeKey(buf, gpa, "from", &first);
            try writeJsonString(buf, gpa, d.from.slice());
            try writeKey(buf, gpa, "to", &first);
            try writeJsonString(buf, gpa, d.to.slice());
            try writeKey(buf, gpa, "ts", &first);
            try writeInt(buf, gpa, d.ts);
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

fn getUlid(obj: std.json.ObjectMap, key: []const u8) DecodeError!Ulid {
    const s = try getStr(obj, key);
    return ulid.parse(s) catch error.BadUlid;
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
            return .{ .add = .{
                .id = id,
                .title = title,
                .body = body,
                .tags = try tags.toOwnedSlice(gpa),
                .ts = getIntDefault(obj, "ts", 0),
            } };
        },
        .setState => {
            const id = try getUlid(obj, "id");
            const st = model.State.fromString(try getStr(obj, "state")) orelse return error.BadState;
            return .{ .setState = .{ .id = id, .state = st, .ts = getIntDefault(obj, "ts", 0) } };
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
        .undep => return .{ .undep = .{
            .from = try getUlid(obj, "from"),
            .to = try getUlid(obj, "to"),
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
