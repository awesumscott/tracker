// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! `trk mcp-serve` — trk as an MCP server: JSON-RPC 2.0, one message per line,
//! over stdio. An additional front end for agents; the CLI stays primary.
//!
//! Every tool is DERIVED from `Cli.verbs` (the table the CLI dispatches on) and
//! executes by building CLI argv from its typed arguments and handing it to
//! `Cli.dispatch` — the same code the CLI verb runs, never a reimplementation.
//! What that buys over a shell: no pipe to mask an exit, no shell to execute a
//! backtick in a body, named parameters where positionals could be swapped, and
//! a body edit that cannot be issued without its direction.
//!
//! TREE SELECTION. Claude Code starts one stdio server per session, and
//! subagents share it — so a lane working in a git worktree reaches a server
//! whose cwd is the main checkout. Every tool therefore takes a REQUIRED `tree`:
//! "main", or the path of one of this repository's linked worktrees. The store
//! is opened at exactly that tree's root (no walk-up, no fallback) and re-read
//! on every call. Worktree membership is checked from git's own on-disk
//! registration, both directions, with no git binary: `<tree>/.git` is a file
//! naming `<common-dir>/worktrees/<name>`, whose `gitdir` file names
//! `<tree>/.git` back. Anything else is refused.

const std = @import("std");
const Io = std.Io;
const tracker = @import("tracker");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Cli = cli.Cli;
const writeJsonString = tracker.json_codec.writeJsonString;

/// Newest first; the first is what we answer a client that asks for anything
/// else. Nothing trk uses differs between them.
pub const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const tree_param_desc =
    "Which checkout's store: \"main\" (the main checkout of the repository the server was started in) " ++
    "or the path of one of its linked git worktrees. Required — a write lands in exactly this tree.";

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    /// The "main" tree: the main checkout's root, or the start dir outside git.
    /// Null for a bare repository (no main checkout exists).
    main_root: ?[]const u8,
    /// The repository's common git dir (real path), or null outside git.
    common_dir: ?[]const u8,
    read_only: bool,

    /// Locate the repository enclosing `start` (an absolute path).
    pub fn init(gpa: Allocator, io: Io, start: []const u8, read_only: bool) !Server {
        var self: Server = .{ .gpa = gpa, .io = io, .main_root = null, .common_dir = null, .read_only = read_only };
        errdefer self.deinit();

        var dir: []const u8 = start;
        while (true) {
            const dotgit = try std.fs.path.join(gpa, &.{ dir, ".git" });
            defer gpa.free(dotgit);
            if (Io.Dir.cwd().statFile(io, dotgit, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .directory) {
                    self.common_dir = try realPath(gpa, io, dotgit);
                    self.main_root = try gpa.dupe(u8, dir);
                    return self;
                }
                const gitdir = try readGitdirFile(gpa, io, dotgit, dir);
                defer gpa.free(gitdir);
                const commondir_file = try std.fs.path.join(gpa, &.{ gitdir, "commondir" });
                defer gpa.free(commondir_file);
                const rel = readTrimmed(gpa, io, commondir_file) catch |e| switch (e) {
                    // No `commondir`: not a linked worktree (a submodule's
                    // `.git` file) — this dir is its own main checkout.
                    error.FileNotFound => {
                        self.common_dir = try gpa.dupe(u8, gitdir);
                        self.main_root = try gpa.dupe(u8, dir);
                        return self;
                    },
                    else => return e,
                };
                defer gpa.free(rel);
                const common = try std.fs.path.resolve(gpa, &.{ gitdir, rel });
                defer gpa.free(common);
                self.common_dir = try realPath(gpa, io, common);
                if (std.mem.eql(u8, std.fs.path.basename(self.common_dir.?), ".git"))
                    self.main_root = try gpa.dupe(u8, std.fs.path.dirname(self.common_dir.?).?);
                return self;
            } else |_| {}
            dir = std.fs.path.dirname(dir) orelse break;
        }
        // Not in a git repository: the start dir is "main", and no other tree exists.
        self.main_root = try gpa.dupe(u8, start);
        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.main_root) |p| self.gpa.free(p);
        if (self.common_dir) |p| self.gpa.free(p);
        self.* = undefined;
    }

    /// Read messages until end of input, answering each request on its own line.
    pub fn serve(self: *Server, in: *Io.Reader, out: *Io.Writer) !void {
        var line: Io.Writer.Allocating = .init(self.gpa);
        defer line.deinit();
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.gpa);
        while (true) {
            line.clearRetainingCapacity();
            _ = try in.streamDelimiterEnding(&line.writer, '\n');
            const at_eof = in.bufferedLen() == 0;
            if (!at_eof) in.toss(1); // the delimiter
            const msg = std.mem.trim(u8, line.written(), " \t\r");
            if (msg.len != 0) {
                resp.clearRetainingCapacity();
                try self.handle(msg, &resp);
                if (resp.items.len != 0) {
                    try out.writeAll(resp.items);
                    try out.writeAll("\n");
                    try out.flush();
                }
            }
            if (at_eof) {
                // `streamDelimiterEnding` leaves the buffer empty only at end of
                // stream; confirm there is truly nothing more coming.
                _ = in.peekByte() catch return;
            }
        }
    }

    /// Answer one JSON-RPC message into `resp` (left empty for a notification).
    pub fn handle(self: *Server, msg: []const u8, resp: *std.ArrayList(u8)) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = std.json.parseFromSliceLeaky(Value, arena, msg, .{}) catch
            return self.rpcError(resp, null, -32700, "Parse error");
        const obj = switch (parsed) {
            .object => |o| o,
            else => return self.rpcError(resp, null, -32600, "Invalid Request: expected one JSON object"),
        };
        const id = obj.get("id");
        const method = switch (obj.get("method") orelse Value.null) {
            .string => |s| s,
            else => {
                if (id == null) return;
                return self.rpcError(resp, id, -32600, "Invalid Request: no method");
            },
        };
        const req_id = id orelse return; // a notification: never answered

        const params: ?std.json.ObjectMap = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => null,
        } else null;

        if (std.mem.eql(u8, method, "initialize")) {
            var version: []const u8 = protocol_versions[0];
            if (params) |p| if (p.get("protocolVersion")) |v| if (v == .string) {
                for (protocol_versions) |known| {
                    if (std.mem.eql(u8, known, v.string)) version = known;
                }
            };
            try self.resultOpen(resp, req_id);
            try resp.appendSlice(self.gpa, "{\"protocolVersion\":");
            try writeJsonString(resp, self.gpa, version);
            try resp.appendSlice(self.gpa, ",\"capabilities\":{\"tools\":{\"listChanged\":false}}," ++
                "\"serverInfo\":{\"name\":\"trk\",\"version\":\"0\"}}}");
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.resultOpen(resp, req_id);
            try resp.appendSlice(self.gpa, "{}}");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try self.resultOpen(resp, req_id);
            try self.writeToolList(resp);
            try resp.appendSlice(self.gpa, "}");
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const p = params orelse return self.rpcError(resp, req_id, -32602, "tools/call needs params");
            const name = switch (p.get("name") orelse Value.null) {
                .string => |s| s,
                else => return self.rpcError(resp, req_id, -32602, "tools/call needs a string name"),
            };
            const found = findTool(name) orelse {
                const m = try std.fmt.allocPrint(arena, "Unknown tool: {s}", .{name});
                return self.rpcError(resp, req_id, -32602, m);
            };
            const args: ?std.json.ObjectMap = switch (p.get("arguments") orelse Value.null) {
                .object => |o| o,
                .null => null,
                else => return self.rpcError(resp, req_id, -32602, "tools/call arguments must be an object"),
            };
            try self.resultOpen(resp, req_id);
            try self.callTool(arena, found.verb, found.tool, args, resp);
            try resp.appendSlice(self.gpa, "}");
        } else {
            const m = try std.fmt.allocPrint(arena, "Method not found: {s}", .{method});
            return self.rpcError(resp, req_id, -32601, m);
        }
    }

    fn resultOpen(self: *Server, resp: *std.ArrayList(u8), id: Value) !void {
        try resp.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(resp, id);
        try resp.appendSlice(self.gpa, ",\"result\":");
    }

    fn rpcError(self: *Server, resp: *std.ArrayList(u8), id: ?Value, code: i32, message: []const u8) !void {
        try resp.appendSlice(self.gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(resp, id orelse .null);
        try resp.print(self.gpa, ",\"error\":{{\"code\":{d},\"message\":", .{code});
        try writeJsonString(resp, self.gpa, message);
        try resp.appendSlice(self.gpa, "}}");
    }

    fn writeId(self: *Server, resp: *std.ArrayList(u8), id: Value) !void {
        switch (id) {
            .integer => |n| try resp.print(self.gpa, "{d}", .{n}),
            .string => |s| try writeJsonString(resp, self.gpa, s),
            .number_string => |s| try resp.appendSlice(self.gpa, s),
            else => try resp.appendSlice(self.gpa, "null"),
        }
    }

    // ------------------------------------------------------------- tools/list

    fn writeToolList(self: *Server, resp: *std.ArrayList(u8)) !void {
        const gpa = self.gpa;
        try resp.appendSlice(gpa, "{\"tools\":[");
        var first = true;
        for (&Cli.verbs) |*v| {
            for (v.tools) |t| {
                if (!first) try resp.append(gpa, ',');
                first = false;
                try resp.appendSlice(gpa, "{\"name\":");
                try writeJsonString(resp, gpa, t.name);
                try resp.appendSlice(gpa, ",\"description\":");
                try writeJsonString(resp, gpa, v.text);
                try resp.appendSlice(gpa, ",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"tree\":{\"type\":\"string\",\"description\":");
                try writeJsonString(resp, gpa, tree_param_desc);
                try resp.append(gpa, '}');
                for (t.params) |prm| {
                    try resp.append(gpa, ',');
                    try writeJsonString(resp, gpa, prm.name);
                    try resp.append(gpa, ':');
                    try writeParamSchema(gpa, resp, prm);
                }
                try resp.appendSlice(gpa, "},\"required\":[\"tree\"");
                for (t.params) |prm| {
                    if (!prm.required) continue;
                    try resp.append(gpa, ',');
                    try writeJsonString(resp, gpa, prm.name);
                }
                try resp.print(gpa, "],\"additionalProperties\":false}},\"annotations\":{{\"readOnlyHint\":{}}}}}", .{
                    !Cli.isMutating(v, t.argv),
                });
            }
        }
        try resp.appendSlice(gpa, "]}");
    }

    // ------------------------------------------------------------- tools/call

    const ToolError = error{ OutOfMemory, WriteFailed };

    /// Validate `args`, build argv, open the tree's store and dispatch. A tool
    /// failure of any kind is a result with `isError: true` carrying the
    /// message, so the caller sees why — never a protocol error.
    fn callTool(
        self: *Server,
        arena: Allocator,
        verb: *const cli.Cli.Verb,
        tool: *const cli.Tool,
        args: ?std.json.ObjectMap,
        resp: *std.ArrayList(u8),
    ) !void {
        var msg: std.ArrayList(u8) = .empty; // tool-level refusal text, if any
        const argv = self.buildArgv(arena, verb, tool, args, &msg) catch |e| switch (e) {
            error.Refused => return self.toolResult(resp, "", msg.items, true),
            else => |x| return x,
        };
        const tree = switch ((if (args) |a| a.get("tree") else null) orelse Value.null) {
            .string => |s| s,
            else => return self.toolResult(resp, "", "trk: `tree` is required: \"main\" or a linked worktree path\n", true),
        };
        const root = self.resolveTree(arena, tree, &msg) catch |e| switch (e) {
            error.Refused => return self.toolResult(resp, "", msg.items, true),
            else => |x| return x,
        };

        var dir = Io.Dir.cwd().openDir(self.io, root, .{}) catch {
            const m = try std.fmt.allocPrint(arena, "trk: cannot open tree {s}\n", .{root});
            return self.toolResult(resp, "", m, true);
        };
        defer dir.close(self.io);
        dir.access(self.io, tracker.store.tracker_subdir, .{}) catch {
            const m = try std.fmt.allocPrint(arena, "trk: no {s}/ at {s} — this tree has no store (create one with `trk init` from the CLI)\n", .{ tracker.store.tracker_subdir, root });
            return self.toolResult(resp, "", m, true);
        };

        var store = tracker.Store.open(self.gpa, self.io, dir);
        defer store.deinit();
        store.load() catch |e| {
            const m = try std.fmt.allocPrint(arena, "trk: failed to load store at {s}: {s}\n", .{ root, @errorName(e) });
            return self.toolResult(resp, "", m, true);
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var warn: std.ArrayList(u8) = .empty;
        defer warn.deinit(self.gpa);
        try cli.appendLoadWarnings(self.gpa, &store, &warn);

        var c = Cli{
            .gpa = self.gpa,
            .io = self.io,
            .store = &store,
            .dir = dir,
            .out = &out,
            .warn = &warn,
            .read_only = self.read_only,
            .body_dash_reads_stdin = false,
        };
        defer c.prereq_scratch.deinit(self.gpa);

        var failed = false;
        c.dispatch(argv) catch |e| {
            failed = true;
            // A CliError already put its message in `out`; anything else did not.
            if (out.items.len == 0) try out.print(self.gpa, "trk: error: {s}\n", .{@errorName(e)});
        };
        return self.toolResult(resp, out.items, warn.items, failed);
    }

    /// `{"content":[{text: out}, {text: warnings}?],"isError":bool}`. A result
    /// with nothing to say still carries one (empty) text block.
    fn toolResult(self: *Server, resp: *std.ArrayList(u8), out: []const u8, extra: []const u8, is_error: bool) !void {
        const gpa = self.gpa;
        try resp.appendSlice(gpa, "{\"content\":[");
        var n: usize = 0;
        if (out.len != 0 or extra.len == 0) {
            try resp.appendSlice(gpa, "{\"type\":\"text\",\"text\":");
            try writeJsonString(resp, gpa, out);
            try resp.append(gpa, '}');
            n += 1;
        }
        if (extra.len != 0) {
            if (n != 0) try resp.append(gpa, ',');
            try resp.appendSlice(gpa, "{\"type\":\"text\",\"text\":");
            try writeJsonString(resp, gpa, extra);
            try resp.append(gpa, '}');
        }
        try resp.print(gpa, "],\"isError\":{}}}", .{is_error});
    }

    fn refuse(arena: Allocator, msg: *std.ArrayList(u8), comptime fmt: []const u8, a: anytype) error{ Refused, OutOfMemory } {
        msg.print(arena, "trk: " ++ fmt ++ "\n", a) catch return error.OutOfMemory;
        return error.Refused;
    }

    /// `[verb] ++ tool.argv ++ positionals ++ flags`, from typed arguments.
    fn buildArgv(
        self: *Server,
        arena: Allocator,
        verb: *const cli.Cli.Verb,
        tool: *const cli.Tool,
        args: ?std.json.ObjectMap,
        msg: *std.ArrayList(u8),
    ) error{ Refused, OutOfMemory }![]const []const u8 {
        _ = self;
        var positionals: std.ArrayList([]const u8) = .empty;
        var flags: std.ArrayList([]const u8) = .empty;

        if (args) |a| {
            var it = a.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "tree")) continue;
                if (findParam(tool, kv.key_ptr.*) == null)
                    return refuse(arena, msg, "{s}: unknown argument '{s}'", .{ tool.name, kv.key_ptr.* });
            }
        }

        for (tool.params) |prm| {
            const val = (if (args) |a| a.get(prm.name) else null) orelse Value.null;
            if (val == .null) {
                if (prm.required) return refuse(arena, msg, "{s}: missing required argument '{s}'", .{ tool.name, prm.name });
                continue;
            }
            switch (prm.kind) {
                .string, .choice => {
                    const sv = switch (val) {
                        .string => |s| s,
                        else => return refuse(arena, msg, "{s}: '{s}' must be a string", .{ tool.name, prm.name }),
                    };
                    if (prm.kind == .choice) {
                        for (prm.choices) |ch| {
                            if (std.mem.eql(u8, ch, sv)) break;
                        } else return refuse(arena, msg, "{s}: '{s}' is not one of the allowed values for '{s}'", .{ tool.name, sv, prm.name });
                    }
                    if (prm.flag) |f| {
                        try flags.appendSlice(arena, &.{ f, sv });
                    } else {
                        // The verb parsers read a leading `-` as a flag.
                        if (sv.len != 0 and sv[0] == '-')
                            return refuse(arena, msg, "{s}: '{s}' may not begin with '-' (the value would be parsed as a flag)", .{ tool.name, prm.name });
                        try positionals.append(arena, sv);
                    }
                },
                .integer => {
                    const n = switch (val) {
                        .integer => |n| n,
                        else => return refuse(arena, msg, "{s}: '{s}' must be an integer", .{ tool.name, prm.name }),
                    };
                    try flags.appendSlice(arena, &.{ prm.flag.?, try std.fmt.allocPrint(arena, "{d}", .{n}) });
                },
                .boolean => {
                    const b = switch (val) {
                        .bool => |b| b,
                        else => return refuse(arena, msg, "{s}: '{s}' must be a boolean", .{ tool.name, prm.name }),
                    };
                    if (b) try flags.append(arena, prm.flag.?);
                },
                .string_list => {
                    const items = switch (val) {
                        .array => |arr| arr.items,
                        else => return refuse(arena, msg, "{s}: '{s}' must be an array of strings", .{ tool.name, prm.name }),
                    };
                    for (items) |item| switch (item) {
                        .string => |s| try flags.appendSlice(arena, &.{ prm.flag.?, s }),
                        else => return refuse(arena, msg, "{s}: '{s}' must be an array of strings", .{ tool.name, prm.name }),
                    };
                },
                .body_edit => {
                    const o = switch (val) {
                        .object => |o| o,
                        else => return refuse(arena, msg, "{s}: '{s}' must be an object {{direction, text}}", .{ tool.name, prm.name }),
                    };
                    var bit = o.iterator();
                    while (bit.next()) |kv| {
                        const k = kv.key_ptr.*;
                        if (!std.mem.eql(u8, k, "direction") and !std.mem.eql(u8, k, "text"))
                            return refuse(arena, msg, "{s}: '{s}' has unknown field '{s}'", .{ tool.name, prm.name, k });
                    }
                    const dir = switch (o.get("direction") orelse Value.null) {
                        .string => |s| s,
                        else => return refuse(arena, msg, "{s}: '{s}.direction' is required: \"append\" or \"replace\"", .{ tool.name, prm.name }),
                    };
                    const text = switch (o.get("text") orelse Value.null) {
                        .string => |s| s,
                        else => return refuse(arena, msg, "{s}: '{s}.text' is required (a string)", .{ tool.name, prm.name }),
                    };
                    const flag: []const u8 = if (std.mem.eql(u8, dir, "append"))
                        "--append-body"
                    else if (std.mem.eql(u8, dir, "replace"))
                        "--replace-body"
                    else
                        return refuse(arena, msg, "{s}: '{s}.direction' must be \"append\" or \"replace\"", .{ tool.name, prm.name });
                    try flags.appendSlice(arena, &.{ flag, text });
                },
            }
        }

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, verb.name);
        try argv.appendSlice(arena, tool.argv);
        try argv.appendSlice(arena, positionals.items);
        try argv.appendSlice(arena, flags.items);
        return argv.items;
    }

    /// The absolute root of `tree`, or `error.Refused` with the reason in `msg`.
    pub fn resolveTree(self: *Server, arena: Allocator, tree: []const u8, msg: *std.ArrayList(u8)) error{ Refused, OutOfMemory }![]const u8 {
        const io = self.io;
        if (std.mem.eql(u8, tree, "main")) {
            return self.main_root orelse refuse(arena, msg, "this repository is bare — there is no \"main\" tree", .{});
        }
        const common = self.common_dir orelse
            return refuse(arena, msg, "tree '{s}' refused: the server is not in a git repository, so \"main\" is the only tree", .{tree});

        const base = self.main_root orelse common;
        const joined = try std.fs.path.resolve(arena, &.{ base, tree });
        const p = realPath(arena, io, joined) catch
            return refuse(arena, msg, "tree '{s}' refused: no such directory", .{tree});
        if (self.main_root) |m| if (std.mem.eql(u8, p, m)) return m;

        const not_worktree = "tree '{s}' refused: not \"main\" and not a linked worktree of this repository ({s})";
        const dotgit = try std.fs.path.join(arena, &.{ p, ".git" });
        const st = Io.Dir.cwd().statFile(io, dotgit, .{ .follow_symlinks = false }) catch
            return refuse(arena, msg, not_worktree, .{ tree, "it has no .git" });
        if (st.kind != .file)
            return refuse(arena, msg, not_worktree, .{ tree, "its .git is a directory — a separate repository" });
        const gitdir = readGitdirFile(arena, io, dotgit, p) catch
            return refuse(arena, msg, not_worktree, .{ tree, "its .git file names no gitdir" });
        const gitdir_real = realPath(arena, io, gitdir) catch
            return refuse(arena, msg, not_worktree, .{ tree, "its gitdir does not exist" });
        const worktrees = try std.fs.path.join(arena, &.{ common, "worktrees" });
        if (!std.mem.eql(u8, std.fs.path.dirname(gitdir_real) orelse "", worktrees))
            return refuse(arena, msg, not_worktree, .{ tree, "its gitdir belongs to a different repository" });

        // The registration must point back at this very tree.
        const back_file = try std.fs.path.join(arena, &.{ gitdir_real, "gitdir" });
        const back = readTrimmed(arena, io, back_file) catch
            return refuse(arena, msg, not_worktree, .{ tree, "the repository has no registration for it" });
        const back_abs = try std.fs.path.resolve(arena, &.{ gitdir_real, back });
        const back_real = realPath(arena, io, back_abs) catch
            return refuse(arena, msg, not_worktree, .{ tree, "the repository's registration points at a missing path" });
        const dotgit_real = realPath(arena, io, dotgit) catch
            return refuse(arena, msg, not_worktree, .{ tree, "its .git could not be resolved" });
        if (!std.mem.eql(u8, back_real, dotgit_real))
            return refuse(arena, msg, not_worktree, .{ tree, "the repository registers that worktree at a different path" });
        return p;
    }
};

fn findParam(tool: *const cli.Tool, name: []const u8) ?*const cli.Param {
    for (tool.params) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub const FoundTool = struct { verb: *const Cli.Verb, tool: *const cli.Tool };

pub fn findTool(name: []const u8) ?FoundTool {
    for (&Cli.verbs) |*v| {
        for (v.tools) |*t| {
            if (std.mem.eql(u8, t.name, name)) return .{ .verb = v, .tool = t };
        }
    }
    return null;
}

fn writeParamSchema(gpa: Allocator, resp: *std.ArrayList(u8), prm: cli.Param) !void {
    switch (prm.kind) {
        .string => try resp.appendSlice(gpa, "{\"type\":\"string\""),
        .integer => try resp.appendSlice(gpa, "{\"type\":\"integer\""),
        .boolean => try resp.appendSlice(gpa, "{\"type\":\"boolean\""),
        .string_list => try resp.appendSlice(gpa, "{\"type\":\"array\",\"items\":{\"type\":\"string\"}"),
        .choice => {
            try resp.appendSlice(gpa, "{\"type\":\"string\",\"enum\":[");
            for (prm.choices, 0..) |ch, i| {
                if (i != 0) try resp.append(gpa, ',');
                try writeJsonString(resp, gpa, ch);
            }
            try resp.append(gpa, ']');
        },
        .body_edit => try resp.appendSlice(gpa, "{\"type\":\"object\",\"properties\":{" ++
            "\"direction\":{\"type\":\"string\",\"enum\":[\"append\",\"replace\"]}," ++
            "\"text\":{\"type\":\"string\"}},\"required\":[\"direction\",\"text\"],\"additionalProperties\":false"),
    }
    try resp.appendSlice(gpa, ",\"description\":");
    try writeJsonString(resp, gpa, prm.desc);
    try resp.append(gpa, '}');
}

/// `gitdir: <path>` from a `.git` file, resolved against `base`. Caller frees.
fn readGitdirFile(gpa: Allocator, io: Io, path: []const u8, base: []const u8) ![]u8 {
    const content = try readTrimmed(gpa, io, path);
    defer gpa.free(content);
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, content, prefix)) return error.NotAGitdirFile;
    const rel = std.mem.trim(u8, content[prefix.len..], " \t");
    return std.fs.path.resolve(gpa, &.{ base, rel });
}

fn readTrimmed(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    return gpa.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

fn realPath(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const z = try Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa);
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}
