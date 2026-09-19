// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! MCP front-end tests: the JSON-RPC protocol, the tool list derived from
//! `Cli.verbs`, argument validation, tree selection against real git
//! worktrees, and tool calls landing in the named tree's store. Every repo here
//! is a tmpDir with its own `.git` — without one, repo discovery would climb
//! into the enclosing checkout.

const std = @import("std");
const testing = std.testing;
const tracker = @import("tracker");
const cli = @import("cli.zig");
const mcp = @import("mcp.zig");

const Value = std.json.Value;
const io = testing.io;
const gpa = testing.allocator;

/// A tmpDir git repository with an initialized store, and a server started in it.
const Repo = struct {
    tmp: testing.TmpDir,
    root: []u8,
    server: mcp.Server,

    fn init(opts: struct { real_git: bool = false, read_only: bool = false }) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (opts.real_git) {
            try runGit(tmp.dir, &.{ "git", "init", "-q" });
            try runGit(tmp.dir, &.{ "git", "config", "user.email", "trk-test@example.com" });
            try runGit(tmp.dir, &.{ "git", "config", "user.name", "trk test" });
        } else {
            try tmp.dir.createDirPath(io, ".git");
        }
        try tmp.dir.createDirPath(io, ".tracker");
        const z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(z);
        const root = try gpa.dupe(u8, z);
        errdefer gpa.free(root);
        return .{ .tmp = tmp, .root = root, .server = try mcp.Server.init(gpa, io, root, opts.read_only) };
    }

    fn deinit(self: *Repo) void {
        self.server.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// Send one message; return the parsed response (null for no response).
    fn send(self: *Repo, msg: []const u8) !?std.json.Parsed(Value) {
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(gpa);
        try self.server.handle(msg, &resp);
        if (resp.items.len == 0) return null;
        return try std.json.parseFromSlice(Value, gpa, resp.items, .{});
    }

    /// `tools/call` `name` with `args_json` (an object literal's inside).
    fn call(self: *Repo, name: []const u8, args_json: []const u8) !Call {
        const msg = try std.fmt.allocPrint(gpa,
            \\{{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{{"name":"{s}","arguments":{{{s}}}}}}}
        , .{ name, args_json });
        defer gpa.free(msg);
        const parsed = (try self.send(msg)).?;
        return .{ .parsed = parsed };
    }
};

const Call = struct {
    parsed: std.json.Parsed(Value),

    fn deinit(self: *Call) void {
        self.parsed.deinit();
    }
    fn result(self: *Call) std.json.ObjectMap {
        return self.parsed.value.object.get("result").?.object;
    }
    fn isError(self: *Call) bool {
        return self.result().get("isError").?.bool;
    }
    /// The first content block's text.
    fn text(self: *Call) []const u8 {
        return self.result().get("content").?.array.items[0].object.get("text").?.string;
    }
    /// Every content block's text, joined.
    fn allText(self: *Call, buf: *std.ArrayList(u8)) ![]const u8 {
        for (self.result().get("content").?.array.items) |c| try buf.appendSlice(gpa, c.object.get("text").?.string);
        return buf.items;
    }
};

fn runGit(dir: std.Io.Dir, argv: []const []const u8) !void {
    const r = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.GitCommandFailed;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Load the store rooted at `dir` and return how many tasks it holds.
fn taskCount(dir: std.Io.Dir) !usize {
    var s = tracker.Store.open(gpa, io, dir);
    defer s.deinit();
    try s.load();
    return s.tasks.count();
}

// ------------------------------------------------------------------ protocol

test "initialize: echoes a known protocol version, answers an unknown one with the newest" {
    var r = try Repo.init(.{});
    defer r.deinit();
    {
        var p = (try r.send(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
        )).?;
        defer p.deinit();
        const res = p.value.object.get("result").?.object;
        try testing.expectEqualStrings("2024-11-05", res.get("protocolVersion").?.string);
        try testing.expect(res.get("capabilities").?.object.get("tools") != null);
        try testing.expectEqualStrings("trk", res.get("serverInfo").?.object.get("name").?.string);
        try testing.expectEqual(@as(i64, 1), p.value.object.get("id").?.integer);
    }
    {
        var p = (try r.send(
            \\{"jsonrpc":"2.0","id":"s-1","method":"initialize","params":{"protocolVersion":"1999-01-01"}}
        )).?;
        defer p.deinit();
        try testing.expectEqualStrings(mcp.protocol_versions[0], p.value.object.get("result").?.object.get("protocolVersion").?.string);
        try testing.expectEqualStrings("s-1", p.value.object.get("id").?.string);
    }
}

test "protocol: notifications get no answer; bad input gets JSON-RPC errors" {
    var r = try Repo.init(.{});
    defer r.deinit();
    try testing.expect((try r.send(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) == null);
    try testing.expect((try r.send(
        \\{"jsonrpc":"2.0","method":"no/such"}
    )) == null);

    const cases = [_]struct { msg: []const u8, code: i64 }{
        .{ .msg = "not json", .code = -32700 },
        .{ .msg = "[1,2]", .code = -32600 },
        .{ .msg = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"no/such\"}", .code = -32601 },
        .{ .msg = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"frobnicate\"}}", .code = -32602 },
        .{ .msg = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"init\",\"arguments\":{}}}", .code = -32602 },
    };
    for (cases) |c| {
        var p = (try r.send(c.msg)).?;
        defer p.deinit();
        try testing.expectEqual(c.code, p.value.object.get("error").?.object.get("code").?.integer);
    }

    var p = (try r.send(
        \\{"jsonrpc":"2.0","id":6,"method":"ping"}
    )).?;
    defer p.deinit();
    try testing.expect(p.value.object.get("result").?.object.count() == 0);
}

test "serve: one answer line per request, notifications skipped, final line needs no newline" {
    var r = try Repo.init(.{});
    defer r.deinit();
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    ;
    var in = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try r.server.serve(&in, &out.writer);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    var ids: [2]i64 = undefined;
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const p = try std.json.parseFromSlice(Value, gpa, line, .{});
        defer p.deinit();
        ids[n] = p.value.object.get("id").?.integer;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 1), ids[0]);
    try testing.expectEqual(@as(i64, 2), ids[1]);
}

// ------------------------------------------------------------------ tool list

test "tools/list: one tool per exposed verb, all requiring tree, readOnlyHint from the verb" {
    var r = try Repo.init(.{});
    defer r.deinit();
    var p = (try r.send(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    )).?;
    defer p.deinit();
    const tools = p.value.object.get("result").?.object.get("tools").?.array.items;

    var expected: usize = 0;
    for (cli.Cli.verbs) |v| expected += v.tools.len;
    try testing.expectEqual(expected, tools.len);

    for (tools) |t| {
        const name = t.object.get("name").?.string;
        // `migrate-decisions` joins the CLI-only set for the same reasons as its
        // siblings: a one-shot migration an orchestrator runs once, whose second
        // pass is a report a human reads and acts on.
        for ([_][]const u8{ "init", "migrate-arcs", "migrate-shorts", "migrate-decisions", "mcp-serve" }) |cli_only|
            try testing.expect(!std.mem.eql(u8, name, cli_only));
        const schema = t.object.get("inputSchema").?.object;
        try testing.expect(schema.get("properties").?.object.get("tree") != null);
        try testing.expectEqualStrings("tree", schema.get("required").?.array.items[0].string);
        try testing.expect(!schema.get("additionalProperties").?.bool);
        const ro = t.object.get("annotations").?.object.get("readOnlyHint").?.bool;
        const want_ro = for ([_][]const u8{ "next", "list", "tree", "show", "log", "stale", "tombstones", "doc_list", "doc_resolve" }) |rn| {
            if (std.mem.eql(u8, rn, name)) break true;
        } else false;
        try testing.expectEqual(want_ro, ro);
    }
}

test "tool specs stay in lockstep with the verbs they call" {
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    for (cli.Cli.verbs) |v| {
        for (v.tools) |t| {
            try testing.expect(!(try names.getOrPut(t.name)).found_existing);
            var seen_optional_positional = false;
            for (t.params) |prm| {
                try testing.expect(!std.mem.eql(u8, prm.name, "tree"));
                // A renamed or removed flag must not leave a stale tool behind.
                if (prm.flag) |f| {
                    if (!contains(v.text, f)) {
                        std.debug.print("tool {s}: flag {s} not in `trk {s} --help`\n", .{ t.name, f, v.name });
                        return error.FlagMissingFromHelp;
                    }
                } else if (prm.kind != .body_edit) {
                    // Positionals fill in order, so a required one may not follow an optional one.
                    if (prm.required) try testing.expect(!seen_optional_positional) else seen_optional_positional = true;
                    try testing.expect(prm.kind == .string or prm.kind == .choice);
                }
                if (prm.kind == .integer or prm.kind == .boolean or prm.kind == .string_list)
                    try testing.expect(prm.flag != null);
                for (prm.choices) |ch| try testing.expect(tracker.State.fromString(ch) != null);
            }
        }
    }
}

// ------------------------------------------------------------------ tool calls

test "tools/call: add, lease, show and next run the CLI verbs against the main tree" {
    var r = try Repo.init(.{});
    defer r.deinit();

    var add = try r.call("add",
        \\"tree":"main","title":"shell `whoami` $(id) stays text","body":"--help is data here","arc":true
    );
    defer add.deinit();
    try testing.expect(!add.isError());
    const id = std.mem.trimEnd(u8, add.text(), "\n");
    try testing.expectEqual(@as(usize, 26), id.len);
    const id_json = try std.fmt.allocPrint(gpa, "\"tree\":\"main\",\"id\":\"{s}\"", .{id});
    defer gpa.free(id_json);

    {
        // The old habit: no holder. Refused, naming `submitted`.
        const a = try std.fmt.allocPrint(gpa, "{s},\"state\":\"claimed\"", .{id_json});
        defer gpa.free(a);
        var c = try r.call("state", a);
        defer c.deinit();
        try testing.expect(c.isError());
        try testing.expect(contains(c.text(), "submitted"));
    }
    {
        const a = try std.fmt.allocPrint(gpa, "{s},\"state\":\"claimed\",\"holder\":\"lane-1\"", .{id_json});
        defer gpa.free(a);
        var c = try r.call("state", a);
        defer c.deinit();
        try testing.expect(!c.isError());
    }
    {
        var c = try r.call("show", id_json);
        defer c.deinit();
        try testing.expect(!c.isError());
        const shown = try std.json.parseFromSlice(Value, gpa, c.text(), .{});
        defer shown.deinit();
        const o = shown.value.object;
        try testing.expectEqualStrings("shell `whoami` $(id) stays text", o.get("title").?.string);
        try testing.expectEqualStrings("--help is data here", o.get("body").?.string);
        try testing.expectEqualStrings("claimed", o.get("state").?.string);
        try testing.expectEqualStrings("lane-1", o.get("holder").?.string);
    }
    {
        var c = try r.call("next",
            \\"tree":"main"
        );
        defer c.deinit();
        const ready = try std.json.parseFromSlice(Value, gpa, c.text(), .{});
        defer ready.deinit();
        try testing.expectEqual(@as(usize, 0), ready.value.array.items.len); // leased
    }
    {
        var c = try r.call("log", id_json);
        defer c.deinit();
        const events = try std.json.parseFromSlice(Value, gpa, c.text(), .{});
        defer events.deinit();
        try testing.expect(events.value.array.items.len >= 2);
    }
}

test "tools/call: arguments are validated before anything runs" {
    var r = try Repo.init(.{});
    defer r.deinit();
    const cases = [_]struct { tool: []const u8, args: []const u8, says: []const u8 }{
        .{ .tool = "list", .args = "", .says = "`tree` is required" },
        .{ .tool = "add", .args = "\"tree\":\"main\"", .says = "missing required argument 'title'" },
        .{ .tool = "add", .args = "\"tree\":\"main\",\"title\":\"t\",\"tags\":[\"x\"]", .says = "unknown argument 'tags'" },
        .{ .tool = "add", .args = "\"tree\":\"main\",\"title\":\"t\",\"priority\":\"5\"", .says = "'priority' must be an integer" },
        .{ .tool = "add", .args = "\"tree\":\"main\",\"title\":\"-v\"", .says = "may not begin with '-'" },
        .{ .tool = "add", .args = "\"tree\":\"main\",\"title\":\"t\",\"tag\":\"x\"", .says = "must be an array of strings" },
        .{ .tool = "state", .args = "\"tree\":\"main\",\"id\":\"x\",\"state\":\"archived\"", .says = "not one of the allowed values" },
        .{ .tool = "edit", .args = "\"tree\":\"main\",\"id\":\"x\",\"body\":{\"text\":\"t\"}", .says = "'body.direction' is required" },
        .{ .tool = "edit", .args = "\"tree\":\"main\",\"id\":\"x\",\"body\":{\"direction\":\"prepend\",\"text\":\"t\"}", .says = "must be \"append\" or \"replace\"" },
    };
    for (cases) |cs| {
        var c = try r.call(cs.tool, cs.args);
        defer c.deinit();
        try testing.expect(c.isError());
        if (!contains(c.text(), cs.says)) {
            std.debug.print("{s} {s}: got {s}\n", .{ cs.tool, cs.args, c.text() });
            return error.WrongMessage;
        }
    }
    try testing.expectEqual(@as(usize, 0), try taskCount(r.tmp.dir));
}

test "tools/call: an appended body keeps a body that lives only in the snapshot" {
    var r = try Repo.init(.{});
    defer r.deinit();
    var add = try r.call("add",
        \\"tree":"main","title":"t","body":"first paragraph","arc":true
    );
    defer add.deinit();
    const id = std.mem.trimEnd(u8, add.text(), "\n");
    const id_json = try std.fmt.allocPrint(gpa, "\"tree\":\"main\",\"id\":\"{s}\"", .{id});
    defer gpa.free(id_json);

    var compact = try r.call("compact",
        \\"tree":"main"
    );
    defer compact.deinit();
    try testing.expect(!compact.isError());

    const a = try std.fmt.allocPrint(gpa, "{s},\"body\":{{\"direction\":\"append\",\"text\":\"-\"}}", .{id_json});
    defer gpa.free(a);
    var edit = try r.call("edit", a);
    defer edit.deinit();
    try testing.expect(!edit.isError());

    var show = try r.call("show", id_json);
    defer show.deinit();
    const shown = try std.json.parseFromSlice(Value, gpa, show.text(), .{});
    defer shown.deinit();
    // The snapshot body survives, and "-" is text — never a stdin read.
    try testing.expectEqualStrings("first paragraph\n\n-", shown.value.object.get("body").?.string);
}

test "tools/call: TRK_READONLY refuses writing tools and still serves reads" {
    var r = try Repo.init(.{ .read_only = true });
    defer r.deinit();
    var add = try r.call("add",
        \\"tree":"main","title":"t"
    );
    defer add.deinit();
    try testing.expect(add.isError());
    try testing.expect(contains(add.text(), "TRK_READONLY"));
    var list = try r.call("list",
        \\"tree":"main"
    );
    defer list.deinit();
    try testing.expect(!list.isError());
    try testing.expectEqual(@as(usize, 0), try taskCount(r.tmp.dir));
}

// ------------------------------------------------------------------ trees

test "tree: a linked worktree's writes land in its own store; anything else is refused" {
    var r = try Repo.init(.{ .real_git = true });
    defer r.deinit();
    try r.tmp.dir.writeFile(io, .{ .sub_path = "README", .data = "x" });
    try runGit(r.tmp.dir, &.{ "git", "add", "README" });
    try runGit(r.tmp.dir, &.{ "git", "commit", "-q", "-m", "base" });
    try runGit(r.tmp.dir, &.{ "git", "worktree", "add", "-q", "wt/lane-1" });
    try r.tmp.dir.createDirPath(io, "wt/lane-1/.tracker");
    try r.tmp.dir.createDirPath(io, "wt/lane-2");
    try runGit(r.tmp.dir, &.{ "git", "worktree", "add", "-q", "wt/no-store" });

    const wt_abs = try std.fs.path.join(gpa, &.{ r.root, "wt", "lane-1" });
    defer gpa.free(wt_abs);

    // Absolute and main-relative spellings both name the worktree.
    for ([_][]const u8{ wt_abs, "wt/lane-1" }) |tree| {
        const a = try std.fmt.allocPrint(gpa, "\"tree\":\"{s}\",\"title\":\"lane work\",\"arc\":true", .{tree});
        defer gpa.free(a);
        var c = try r.call("add", a);
        defer c.deinit();
        try testing.expect(!c.isError());
    }
    var wt_dir = try r.tmp.dir.openDir(io, "wt/lane-1", .{});
    defer wt_dir.close(io);
    try testing.expectEqual(@as(usize, 2), try taskCount(wt_dir));
    try testing.expectEqual(@as(usize, 0), try taskCount(r.tmp.dir)); // main untouched

    // A separate repository, a plain directory, a missing path, and a forged
    // `.git` file claiming this repo's registration all refused.
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try runGit(other.dir, &.{ "git", "init", "-q" });
    const other_abs = try other.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(other_abs);

    try r.tmp.dir.createDirPath(io, "wt/forged/.tracker");
    const forged_gitdir = try std.fmt.allocPrint(gpa, "gitdir: {s}/.git/worktrees/lane-1\n", .{r.root});
    defer gpa.free(forged_gitdir);
    try r.tmp.dir.writeFile(io, .{ .sub_path = "wt/forged/.git", .data = forged_gitdir });

    const refusals = [_]struct { tree: []const u8, says: []const u8 }{
        .{ .tree = other_abs, .says = "separate repository" },
        .{ .tree = "wt/lane-2", .says = "it has no .git" },
        .{ .tree = "wt/nope", .says = "no such directory" },
        .{ .tree = "wt/forged", .says = "registers that worktree at a different path" },
        .{ .tree = "wt/no-store", .says = "has no store" },
    };
    for (refusals) |ref| {
        const a = try std.fmt.allocPrint(gpa, "\"tree\":\"{s}\"", .{ref.tree});
        defer gpa.free(a);
        var c = try r.call("list", a);
        defer c.deinit();
        try testing.expect(c.isError());
        if (!contains(c.text(), ref.says)) {
            std.debug.print("tree {s}: got {s}\n", .{ ref.tree, c.text() });
            return error.WrongMessage;
        }
    }
}

test "tree: a server started inside a linked worktree still resolves \"main\" to the main checkout" {
    var r = try Repo.init(.{ .real_git = true });
    defer r.deinit();
    try r.tmp.dir.writeFile(io, .{ .sub_path = "README", .data = "x" });
    try runGit(r.tmp.dir, &.{ "git", "add", "README" });
    try runGit(r.tmp.dir, &.{ "git", "commit", "-q", "-m", "base" });
    try runGit(r.tmp.dir, &.{ "git", "worktree", "add", "-q", "wt/lane-1" });

    const wt_abs = try std.fs.path.join(gpa, &.{ r.root, "wt", "lane-1" });
    defer gpa.free(wt_abs);
    var s = try mcp.Server.init(gpa, io, wt_abs, false);
    defer s.deinit();
    try testing.expectEqualStrings(r.root, s.main_root.?);
}

// The CLI's `add` takes its title from the first BARE token so a misspelled
// leading flag gets blamed instead of the title (01M1FMMFZ). That scan is safe
// to make unconditional only because MCP refuses a dash-leading positional at
// the boundary, where the message can say what actually happened — a typed
// `title` is data, and "unknown flag" would be a lie about it. This arm is what
// keeps the two halves of that argument from drifting apart.
test "tools/call: a dash-leading title is refused at the boundary, never reparsed as a flag (01M1FMMFZ)" {
    var r = try Repo.init(.{});
    defer r.deinit();

    var add = try r.call("add",
        \\"tree":"main","title":"--tags=a,b is a title here","arc":true
    );
    defer add.deinit();
    try testing.expect(add.isError());
    try testing.expect(contains(add.text(), "may not begin with '-'"));
    try testing.expect(!contains(add.text(), "unknown flag"));

    // And an ordinary title is unaffected by the scan.
    var ok = try r.call("add",
        \\"tree":"main","title":"an ordinary title","arc":true
    );
    defer ok.deinit();
    try testing.expect(!ok.isError());
}

// The decisions mechanism over MCP (01M2VFX27). `decision` is exposed;
// `migrate-decisions` deliberately is NOT — it is a one-shot migration an
// orchestrator runs once from the CLI, and its whole second pass is a report a
// human reads.
test "tools/call: decision raises a node, next withholds the work it blocks, list --decision finds it" {
    var r = try Repo.init(.{});
    defer r.deinit();

    var work = try r.call("add",
        \\"tree":"main","title":"the display fix","arc":true
    );
    defer work.deinit();
    const wid = std.mem.trimEnd(u8, work.text(), "\n");

    const args = try std.fmt.allocPrint(gpa,
        \\"tree":"main","question":"does TODO.md want the annotation?","from":"{s}","blocks":["{s}"]
    , .{ wid, wid });
    defer gpa.free(args);
    var d = try r.call("decision", args);
    defer d.deinit();
    try testing.expect(!d.isError());
    const did = std.mem.trimEnd(u8, d.text(), "\n");
    try testing.expectEqual(@as(usize, 26), did.len);

    // The frontier is empty: the question is not work, and the work waits on it.
    var nx = try r.call("next", "\"tree\":\"main\"");
    defer nx.deinit();
    try testing.expect(!nx.isError());
    try testing.expectEqualStrings("[]", std.mem.trim(u8, nx.text(), " \n"));

    // ...and the machine-readable way to find out why, which `next --json`
    // deliberately does not carry (an array has nowhere to put a tail).
    var ls = try r.call("list", "\"tree\":\"main\",\"decision\":true,\"state\":\"open\"");
    defer ls.deinit();
    try testing.expect(!ls.isError());
    try testing.expect(contains(ls.text(), "does TODO.md want the annotation?"));

    // Ruling it releases the work, in one call.
    const rule_args = try std.fmt.allocPrint(gpa,
        \\"tree":"main","id":"{s}","text":"RULED: list --arc only"
    , .{did});
    defer gpa.free(rule_args);
    var ruled = try r.call("rule", rule_args);
    defer ruled.deinit();
    try testing.expect(!ruled.isError());

    var nx2 = try r.call("next", "\"tree\":\"main\"");
    defer nx2.deinit();
    try testing.expect(contains(nx2.text(), "the display fix"));
    try testing.expect(!contains(nx2.text(), "does TODO.md want"));
}
