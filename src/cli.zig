// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! `trk` CLI core — argument parsing, prefix resolution, the `next`/`list`
//! output formatting, and the two human projections (`render` markdown +
//! `tree` ASCII hierarchy). Wires the verbs onto the Wave-1 `Store` API; no
//! store *semantics* live here (writes go through `Store.append`).
//!
//! Design notes:
//!   - Output is written into a caller-owned `*std.ArrayList(u8)` (the `out`
//!     field), never directly to a TTY. main.zig flushes it to stdout; tests
//!     assert against it. This keeps the CLI writer-parameterized and
//!     cross-compile-clean (no POSIX TTY assumptions).
//!   - User errors surface as `CliError` + a clean message appended to `out`
//!     (main maps that to a non-zero exit). No Zig stack traces on bad input.
//!   - ID ergonomics: every id argument accepts a unique ULID *prefix*
//!     (git-short-hash style). All human output uses short ids, but a short
//!     id is NOT always dynamically computed: a task minted after short-id
//!     freezing landed (or migrated via `trk migrate-shorts`) carries a
//!     PERSISTED `short` that `shortId` returns verbatim, stable forever —
//!     it never changes on add, archive, or compact. A task with no
//!     persisted short falls back to the legacy behavior: the shortest
//!     CURRENTLY-unambiguous prefix (min `min_short`), which moves as the
//!     live id set moves. See design.md "short-id stability".

const std = @import("std");
const tracker = @import("tracker");
const ulid = tracker.ulid;

const Store = tracker.Store;
const Ulid = tracker.Ulid;
const State = tracker.State;
const Task = tracker.Task;
const model = tracker.model;
const codec = tracker.json_codec;
const Io = std.Io;

/// Minimum length of a DYNAMICALLY-computed short id — the legacy/back-compat
/// path for a task with no persisted `short` (git uses 7; ULIDs are denser,
/// but a short floor keeps them recognizable). This value governs ONLY the
/// fallback computation; it is intentionally left at its historical value —
/// existing un-migrated ids are never retroactively re-lengthened.
pub const min_short = 6;

/// Floor for a NEWLY MINTED task's short id (`Cli.mintShortId`), frozen
/// forever into `Task.short` at mint time. Higher than the legacy
/// `min_short` floor: 9 matches the dominant historical id length in
/// practice, so a fresh mint less often needs extending past the floor —
/// and because a frozen short is never recomputed, a longer floor pays off
/// once instead of on every future collision check.
pub const min_short_mint = 9;

/// User-facing errors. Each is reported as a clean one-line message; the caller
/// (main) maps any `CliError` to a non-zero exit code. `error.DependencyCycle`
/// from the store is folded in here too.
pub const CliError = error{
    UsageError,
    UnknownCommand,
    MissingArgument,
    UnknownFlag,
    BadId,
    AmbiguousId,
    NoSuchId,
    BadState,
    BadNumber,
    DependencyCycle,
    /// A mutating verb was rejected because `read_only` is set (mirrors the
    /// `TRK_READONLY` env var main.zig checks).
    ReadOnly,
    /// `trk add` landed a task in no arc (neither `--in` nor `--arc`) while
    /// `.tracker/config.json`'s `add.arcless` is `"error"`.
    NoArc,
    /// `trk in <task> <arc>` (or `trk add --in <arc>`) named an `<arc>` that
    /// is not a declared arc — see `Store.isArc`/`Store.append`'s doc
    /// comments for why this is no longer inferred from the edge itself.
    UndeclaredArc,
    /// `trk state <id> claimed` on a task that is not `open` (see
    /// `State.claimRefusal`); a hint naming the likely intent is already in `out`.
    ClaimRequiresOpen,
    /// `trk state <id> claimed` without `--holder`; the hint names `submitted`.
    HolderRequired,
    /// `trk release <id> --holder <h>` where someone other than `<h>` holds it.
    LeaseHolderMismatch,
    /// `trk stale` could not run or was refused by `git log` (not a git repo,
    /// `git` missing from PATH, non-zero exit). A clean message is already
    /// appended to `out` before this is returned.
    GitLogFailed,
    /// `trk show <id>` resolved the id in the TOMBSTONE index rather than the
    /// live store: the task existed and `compact` physically GC'd it
    /// (01M2M2K1J). NOT a failure to find the id — the opposite: the record is
    /// already printed to `out`. It is a distinct error, and main.zig maps it to
    /// its own exit code 2, because the three answers `show` can give are three
    /// different facts and a caller that branches on the exit status must be
    /// able to tell them apart: 0 = live, 2 = compacted, 1 = no such id. Folding
    /// this into 0 would tell `dangling-tracker-id-lint.sh` a graduated id is
    /// live; folding it into 1 would put it back where it started.
    CompactedId,
    /// `trk tombstones --verify` found at least one id in `.tracker/log.jsonl`'s
    /// full git history that is neither live nor entombed — the tombstone
    /// index is INCOMPLETE. The offending ids are already listed in `out`
    /// before this is returned; main.zig exits 1 (a plain failure — there is
    /// no dedicated exit code for this the way `CompactedId` gets one, because
    /// nothing resolves an id through this path the way `show` does).
    TombstoneIndexIncomplete,
};

/// The store's write path surfaces a broad fs error set (append/atomicWrite).
/// We union it in rather than re-listing it so it stays correct if the store's
/// I/O surface changes.
const StoreWriteError = @typeInfo(@typeInfo(@TypeOf(Store.append)).@"fn".return_type.?).error_union.error_set;
const StoreCompactError = @typeInfo(@typeInfo(@TypeOf(Store.compact)).@"fn".return_type.?).error_union.error_set;

pub const Error = CliError || std.mem.Allocator.Error || error{WriteFailed} ||
    StoreWriteError || StoreCompactError || std.Io.Dir.WriteFileError;

/// Append one warning line per thing `Store.load` tolerated but a human should
/// see — a malformed config, each self-wait cycle, ghost, withheld stale event
/// and unknown op. Shared by the CLI (flushed to stderr) and the MCP server
/// (returned with the tool result), so neither can report less than the other.
pub fn appendLoadWarnings(gpa: std.mem.Allocator, store: *const Store, w: *std.ArrayList(u8)) !void {
    // Best-effort config is non-fatal: warn but proceed on a malformed file.
    if (store.config_malformed)
        try w.print(gpa, "trk: warning: {s}/{s} is malformed — using default config\n", .{ tracker.store.tracker_subdir, tracker.store.config_name });
    // Every self-wait cycle already baked into the log (mediated by `in` arc
    // membership — see Store.load's doc comment) is likewise non-fatal: warn
    // on EACH one but keep going, since refusing to load would brick the
    // repo. Looping (not just the first) matters: a log can carry more than
    // one independent stuck pair, and reporting only one would leave every
    // other cycled task exactly as silently invisible as the bug this
    // warning exists to kill.
    for (store.self_wait_cycles.items) |p|
        try w.print(
            gpa,
            "trk: warning: {s} and {s} form a self-wait cycle across needs + arc-membership edges — " ++
                "neither can ever complete while depending on the other; fix with `trk undep` or by " ++
                "re-parenting the membership (`trk in`)\n",
            .{ &p.from.text, &p.to.text },
        );
    // Every log line whose `op` this binary doesn't recognize is likewise
    // non-fatal: warn on EACH one but keep going (see Store.load's doc
    // comment / skipped_unknown_ops — a single new-op line must not brick
    // reads on a not-yet-updated binary). Looping, not just the first, for
    // the same reason as the self-wait loop above.
    // Every ghost task (an id the fold materialized with no `add` behind it) is
    // likewise non-fatal at load: warn on EACH one and keep going, so the data
    // that IS there stays readable. Looping, not just the first, for the same
    // reason as the loops above. This fires on EVERY command, which is why
    // `compact` needs no refusal of its own — it GCs the ghost and spools its
    // lines to .tracker/quarantine.jsonl, reporting what it took out.
    for (store.ghost_tasks.items) |id|
        try w.print(
            gpa,
            "trk: warning: {s} has no `add` event anywhere in the fold — its title/tags/arcs " ++
                "are missing, not empty (a union-merge that outlived a compact). It is not a real " ++
                "task; `trk compact` will GC it and quarantine its log lines\n",
            .{&id.text},
        );
    // Every task whose late-merged events were withheld as provably stale. Not
    // fatal, and never a silent drop: the events are still in the log, so a
    // change that really was wanted can be re-applied deliberately.
    for (store.superseded.items) |sd|
        try w.print(
            gpa,
            "trk: warning: {s}: {d} log event(s) predate the snapshot's value for this task and were " ++
                "NOT applied (a pre-compact event union-merged back in). The snapshot's newer state " ++
                "stands; re-apply deliberately if the change is real\n",
            .{ &sd.id.text, sd.events },
        );
    for (store.skipped_unknown_ops.items) |s|
        try w.print(
            gpa,
            "trk: warning: skipped a log line with unrecognized op \"{s}\" — this binary may be older " ++
                "than the log; install the latest `trk` to see its effect\n",
            .{s.op},
        );
}

/// One MCP tool parameter, and how it becomes CLI argv (`mcp.zig` builds the
/// argv and hands it to `Cli.dispatch` — the same code path the CLI verb runs).
pub const Param = struct {
    name: []const u8,
    kind: Kind,
    /// `null` = positional, filled in declaration order. Otherwise the flag the
    /// value is passed with (repeated per element for `string_list`; present
    /// or absent for `boolean`).
    flag: ?[]const u8 = null,
    required: bool = false,
    /// The allowed values of a `choice`.
    choices: []const []const u8 = &.{},
    desc: []const u8,

    pub const Kind = enum {
        string,
        integer,
        boolean,
        string_list,
        choice,
        /// `{direction: "append"|"replace", text}` -> `--append-body <text>` /
        /// `--replace-body <text>`. An object with both fields required, so a
        /// body edit cannot be issued without naming its direction.
        body_edit,
    };
};

/// One MCP tool: a verb (plus fixed leading args — a subcommand, or `--json`
/// for the structured read output) and its parameters. Whether it writes is not
/// declared here; it derives from the verb (`Cli.isMutating`).
pub const Tool = struct {
    name: []const u8,
    argv: []const []const u8 = &.{},
    params: []const Param = &.{},
};

pub const Cli = struct {
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    /// Where `dir`-relative `--out` paths are written. Borrowed.
    dir: Io.Dir,
    /// Accumulated stdout-bound output. Caller owns it.
    out: *std.ArrayList(u8),
    /// Accumulated stderr-bound output (currently: the `trk add` arc-less
    /// warning). Kept separate from `out` because `out` is scriptable
    /// (`ID=$(trk add "x")`) and must never carry a warning line. main.zig
    /// flushes this to real stderr; tests assert against it directly. Caller
    /// owns it.
    warn: *std.ArrayList(u8),
    /// When true, every mutating verb (see `isMutating` below) refuses
    /// with `error.ReadOnly` before dispatch; read verbs are unaffected.
    /// main.zig sets this from the `TRK_READONLY` env var; tests can set it
    /// directly on a `Cli` built over a `Fixture`.
    read_only: bool = false,
    /// The source `--body -` reads from. `null` = no stdin was wired, and
    /// `--body -` then REFUSES rather than storing a literal "-" (which is what
    /// it silently did before 01M0EM10X — an agent lost a multi-paragraph body
    /// to it and only noticed by re-reading). main.zig wires real stdin; tests
    /// wire a temp file, so the same read path is exercised either way.
    stdin: ?Io.File = null,
    /// When false, a body value of `-` is the literal text "-", never a stdin
    /// read. The MCP front end clears it: its body arrives as a typed string.
    body_dash_reads_stdin: bool = true,
    /// Scratch for `directPrereqs` — must be drained/copied before the next
    /// call. tree recursion copies into a local dupe before recursing, so reuse
    /// is safe. Owned by the Cli; the caller (main/tests) deinits it.
    prereq_scratch: std.ArrayList(Ulid) = .empty,

    fn print(self: *Cli, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, fmt, args);
    }

    fn write(self: *Cli, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    /// Resolve a body-flag value: a literal `-` means "read the whole of stdin",
    /// the conventional meaning everywhere else. Returns gpa-owned bytes the
    /// caller must free (the store re-dups into its arena on append), or the
    /// argument itself borrowed unchanged — `owned` says which. `flag` is the
    /// spelling the caller used (`--body` on `add`, `--replace-body` /
    /// `--append-body` on `edit`) so every diagnostic below names the flag that
    /// was actually typed.
    ///
    /// Exactly ONE trailing newline is trimmed, because `trk show <id> --body`
    /// adds one when the body lacks it: `trk show <id> --body | trk edit <id>
    /// --replace-body -` is then byte-stable, and stable on every later round trip.
    fn bodyArg(self: *Cli, flag: []const u8, arg: []const u8) Error!struct { text: []const u8, owned: bool } {
        if (!self.body_dash_reads_stdin or !std.mem.eql(u8, arg, "-")) return .{ .text = arg, .owned = false };
        const f = self.stdin orelse {
            try self.print("trk: {s} -: no stdin to read (pipe one in, e.g. " ++
                "`trk show <id> --body | trk edit <id> --replace-body -`)\n", .{flag});
            return error.UsageError;
        };
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = f.readStreaming(self.io, &.{&chunk}) catch |e| switch (e) {
                error.EndOfStream => break,
                else => {
                    try self.print("trk: {s} -: could not read stdin\n", .{flag});
                    return error.UsageError;
                },
            };
            if (n == 0) break;
            try buf.appendSlice(self.gpa, chunk[0..n]);
        }
        // Nothing on stdin is refused, not applied. Clearing a body is a real
        // operation, but `--replace-body ""` already says so explicitly; an EMPTY
        // read here is far more often a pipe that never ran (a failed upstream
        // command, a forgotten redirect), and applying it would wipe the body
        // exactly the way this flag's old literal-"-" behavior did.
        if (buf.items.len == 0) {
            // No explicit deinit — the `errdefer` above frees `buf` on this
            // return path (doing both is a double free).
            try self.print("trk: {s} -: stdin was empty — refusing to write an empty body " ++
                "(use `{s} \"\"` if that is what you meant)\n", .{ flag, flag });
            return error.UsageError;
        }
        // One trailing newline (CRLF-aware), not all of them: a body may
        // legitimately end in blank lines, and `$(...)` already eats those —
        // this path exists precisely to stop being lossy about body bytes.
        if (buf.items.len != 0 and buf.items[buf.items.len - 1] == '\n') {
            buf.items.len -= 1;
            if (buf.items.len != 0 and buf.items[buf.items.len - 1] == '\r') buf.items.len -= 1;
        }
        return .{ .text = try buf.toOwnedSlice(self.gpa), .owned = true };
    }

    /// Append `s` as a JSON string literal (quotes + minimal escaping). Used by
    /// the `--json` output of `list`/`next` so titles/tags with quotes, newlines,
    /// or control chars stay valid JSON.
    fn writeJsonString(self: *Cli, s: []const u8) !void {
        try self.write("\"");
        for (s) |ch| switch (ch) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => if (ch < 0x20)
                try self.print("\\u{x:0>4}", .{ch})
            else
                try self.out.append(self.gpa, ch),
        };
        try self.write("\"");
    }

    /// One task as a JSON object: id (full), short, title, state, priority,
    /// [seq when an arc context is given], tags. Relations stay in `trk show`.
    fn appendTaskJson(self: *Cli, id: Ulid, arc_id: ?Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        try self.print("{{\"id\":\"{s}\",\"short\":\"{s}\",\"title\":", .{ &id.text, sid });
        try self.writeJsonString(t.title);
        try self.print(",\"state\":\"{s}\",\"priority\":{d}", .{ t.state.toString(), t.priority });
        if (t.holder) |h| {
            try self.write(",\"holder\":");
            try self.writeJsonString(h);
            try self.print(",\"lease_ts\":{d}", .{t.lease_ts});
        }
        if (self.seqFor(id, arc_id)) |s| try self.print(",\"seq\":{d}", .{s});
        try self.write(",\"tags\":[");
        for (t.tags.items, 0..) |tg, i| {
            if (i != 0) try self.write(",");
            try self.writeJsonString(tg);
        }
        try self.write("]}");
    }

    // ----------------------------------------------------------- dispatch

    /// Run one CLI invocation. `args` is argv WITHOUT the program name (so
    /// `args[0]` is the subcommand). The store must already be loaded.
    pub fn run(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) return self.usage();
        const cmd = args[0];
        const rest = args[1..];

        // Help routing, BEFORE dispatch. `trk help [<verb>]`, `trk -h`/`--help`,
        // and `trk <verb> --help`/`-h` all explain rather than execute. This also
        // guards the classic agent trap: without it `trk add --help` parses
        // `--help` as the <title> and mints a task literally called "--help".
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            if (rest.len > 0) return self.helpFor(rest[0]);
            return self.usage();
        }
        if (argsWantHelp(rest)) return self.helpFor(cmd);

        return self.dispatch(args);
    }

    /// Execute `args` (`args[0]` = the verb) with NO help routing: the read-only
    /// gate, then the verb's handler from `verbs`. `run` is this plus help
    /// routing; the MCP front end (`mcp.zig`) calls this directly, because its
    /// argv is built from typed parameters — a body or title that happens to be
    /// the literal text `--help` is data there, never a help request.
    pub fn dispatch(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) return self.usage();
        const cmd = args[0];
        const rest = args[1..];
        const v = findVerb(cmd) orelse {
            try self.print("trk: unknown command '{s}'\n", .{cmd});
            return error.UnknownCommand;
        };
        if (self.read_only and isMutating(v, rest)) {
            try self.print("trk: refusing to run '{s}' — TRK_READONLY is set (mutations are disabled)\n", .{cmd});
            return error.ReadOnly;
        }
        return v.run(self, rest);
    }

    /// True iff `--help` or `-h` appears as a standalone token in `rest`. A flag
    /// *value* of literally "--help" (e.g. `--body --help`) would also trip this,
    /// but "--help" is never a real title/body/tag in practice, so treating it as
    /// a help request everywhere is the right trade for agent ergonomics.
    fn argsWantHelp(rest: []const []const u8) bool {
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
        }
        return false;
    }

    /// Does running verb `v` with `rest` write persisted state? `Verb.mutates`,
    /// or — for a verb whose subcommands differ (`doc set`/`doc unset` vs `doc
    /// list`/`doc resolve`) — whether `rest[0]` is one of its writing
    /// subcommands. `read_only` (`TRK_READONLY`) gates exactly this.
    pub fn isMutating(v: *const Verb, rest: []const []const u8) bool {
        if (v.mutates) return true;
        if (rest.len == 0) return false;
        for (v.mutating_subcommands) |sub| {
            if (std.mem.eql(u8, rest[0], sub)) return true;
        }
        return false;
    }

    pub fn findVerb(name: []const u8) ?*const Verb {
        for (&verbs) |*v| {
            if (std.mem.eql(u8, v.name, name)) return v;
        }
        return null;
    }

    pub const Verb = struct {
        name: []const u8,
        run: *const fn (*Cli, []const []const u8) Error!void,
        /// Writes persisted state: an appended log event, a scaffolded
        /// `.tracker/` (`init`), a rewritten snapshot (`compact`), or an
        /// out-file (`render`, `archive`). See `isMutating`.
        mutates: bool = false,
        /// For a verb that is otherwise read-only: the subcommands that write.
        mutating_subcommands: []const []const u8 = &.{},
        /// The MCP tools this verb is exposed as (`mcp.zig`). Empty = CLI-only,
        /// which must be a deliberate, commented choice.
        tools: []const Tool,
        /// Full synopsis + purpose + key flags + an example — `trk <verb>
        /// --help`, and the MCP tool description.
        text: []const u8,
    };

    /// THE verb table: dispatch, `--help`, the read-only gate and the MCP tool
    /// list all derive from it, so none of them can drift from the others.
    pub const verbs = [_]Verb{
        .{ .name = "init", .run = &cmdInit, .mutates = true, .tools = &cli_only_tools, .text =
        \\trk init [--out <path>] [--force] [--no-gitattributes] [--no-gitignore]
        \\  Scaffold a fresh tracker: .tracker/ + an empty log, a config.json
        \\  (render.out defaults to docs/TODO.md; set it with --out), a
        \\  .tracker/.gitattributes, a .tracker/.gitignore, and a starter TODO.md.
        \\  Idempotent + non-destructive: never overwrites an existing TODO.md,
        \\  .gitattributes, or .gitignore; --force rewrites config.json only.
        \\  The .gitattributes union-merges log.jsonl (parallel-worktree appends
        \\  combine) and pins snapshot.jsonl + quarantine.jsonl to the text driver
        \\  (a raced compact must surface as a conflict). It goes INSIDE .tracker/
        \\  on purpose: git resolves attributes per directory and the nearest file
        \\  wins, so a later root-level `*.jsonl` glob cannot capture the baselines.
        \\  --no-gitattributes skips it (a repo managing attributes centrally).
        \\  The .gitignore ignores compact's backup/ runs (a bounded but nonzero
        \\  pre-rewrite copy on every compact, see `trk compact --help`) and a
        \\  crash-orphaned atomic-write temp file, for the same INSIDE-.tracker/
        \\  reason as the attributes file. --no-gitignore skips it likewise.
        \\  e.g.  trk init            trk init --out TODO.md
        },
        .{ .name = "add", .run = &cmdAdd, .mutates = true, .tools = &add_tools, .text =
        \\trk add "<title>" [--body <s>] [--tag <t> ...] [--doc <doc_id[#section]> ...]
        \\       [--in <arc> [--seq <n>]] [--arc] [--needs <id> ...] [--priority <n>] [-v]
        \\  Create a task. Prints ONLY the new full ULID (scriptable: ID=$(trk add "x"));
        \\  -v/--verbose prints the friendly "added <short> (<full>)" instead. --needs
        \\  wires prerequisite edges, --in adds it to an EXISTING, ALREADY-DECLARED arc as
        \\  a member (refused with UndeclaredArc otherwise — declare it first with `trk
        \\  arc`), --arc declares THIS new task itself an arc root (even with zero members
        \\  yet, and needs no prior declaration), --doc
        \\  attaches a design pointer (register the id first with `trk doc set`).
        \\  --priority: int, LOWER SORTS FIRST, and unset ranks 100 — so --priority 10
        \\  raises a task above untouched ones and --priority 500 sinks it below them.
        \\  `--priority 0` means unset (back to the default rank), not "strongest".
        \\  `--body -` reads the body from STDIN (one trailing newline trimmed).
        \\  Neither --in nor --arc given -> a stderr warning (never
        \\  stdout); escalate to a hard error via .tracker/config.json's add.arcless.
        \\  A `--tag arc:<slug>` is a DEPRECATED way to mark an arc (still honored, but
        \\  warns) — use --arc instead.
        \\  e.g.  trk add "Add dark mode" --tag ui --in 01KVX4K0 --needs 01KWZJFRR
        \\        trk add "Ship v2" --arc
        },
        .{ .name = "dep", .run = &cmdDep, .mutates = true, .tools = &dep_tools, .text =
        \\trk dep <needer> --needs <prereq> [--needs <prereq> ...]
        \\  Make <needer> require prerequisite <prereq> (a `needs` edge). ONE positional,
        \\  the prereq(s) flagged: two bare positionals of the same type could be swapped
        \\  by accident, and the swap produced a VALID edge pointing the wrong way — wrong
        \\  DAG, wrong ready frontier, no error. The bare `trk dep A B` form is now a hard
        \\  usage error naming the fix. Rejected if it would close a cycle; undo with
        \\  `trk undep <needer> --needs <prereq>`.
        \\  `dep`/`in` are NOT interchangeable: `dep` only adds DAG ordering (and, as a
        \\  side effect, reachability-membership if the prereq belongs to an arc) — it
        \\  never by itself makes anything an arc. See `trk in --help`.
        \\  ALSO rejected if <needer> is a (direct or transitive) member of <prereq>'s
        \\  arc: an arc can't finish while an open member waits on it, so a member
        \\  needing its own arc is a permanent self-wait, not an ordinary cycle. A
        \\  prereq in a DIFFERENT arc — or the whole of a different arc — is unaffected.
        \\  e.g.  trk dep 01KX6H4V --needs 01KX6H48   (init needs config)
        },
        .{ .name = "undep", .run = &cmdUndep, .mutates = true, .tools = &undep_tools, .text =
        \\trk undep <needer> --needs <prereq> [--needs <prereq> ...]
        \\  Remove the <needer> needs <prereq> edge (tombstoned; a no-op if absent).
        \\  Exact argument shape as `trk dep`, so undoing an edge is the same sentence
        \\  with one verb changed. The bare two-positional form is a hard usage error.
        \\  e.g.  trk undep 01KX6H4V --needs 01KX6H48
        },
        .{ .name = "in", .run = &cmdIn, .mutates = true, .tools = &in_tools, .text =
        \\trk in <task> <arc> [--seq <n>]
        \\  Add <task> to arc <arc> as a DIRECT member, optionally ordered by --seq.
        \\  <arc> MUST already be a declared arc (`trk arc <arc>` / `trk add --arc`) —
        \\  `in` no longer mints one on the fly. Rejected with `UndeclaredArc` if it
        \\  isn't; declare it first, then retry.
        \\  ARGUMENT ORDER: <task> FIRST, <arc> SECOND — the opposite of how you'd say
        \\  "arc needs task" via `trk dep <arc> <task>`. Reversing it (`trk in <arc>
        \\  <task>`) either fails outright (if <task> was never declared an arc — the
        \\  common case, and the whole point of the declared-arc requirement above) or,
        \\  if BOTH ids happen to already be declared arcs, silently makes <arc> a
        \\  member of <task> instead, exactly backwards. If unsure, verify after with
        \\  `trk tree <arc>` (the new task should appear nested under it) or
        \\  `trk show <task>` (its `arcs:` list should include <arc>).
        \\  A backwards call between two already-declared arcs is fixed with
        \\  `trk unin <task> <arc>` — same argument order as this command, NOT swapped
        \\  (see `trk unin --help`).
        \\  `in` and `dep` are NOT interchangeable: `in` is the membership-authoring
        \\  primitive (requires <arc> already declared, per above); `dep` only adds a
        \\  `needs` prerequisite edge, and merely auto-JOINS an existing arc via
        \\  reachability when the prereq's dependent is already a member.
        \\  Rejected if <task> already (directly or transitively) NEEDS <arc>: the
        \\  membership would close the same self-wait loop `dep` guards against, just
        \\  from the other direction — see `trk dep --help`. Also rejected if <task>
        \\  and <arc> are the same id (a task cannot be a member of itself).
        \\  e.g.  trk arc 01KVX4K0               (declare 01KVX4K0 an arc, once)
        \\        trk in 01KX6H4V 01KVX4K0       (add 01KX6H4V to arc 01KVX4K0)
        },
        .{ .name = "unin", .run = &cmdUnin, .mutates = true, .tools = &unin_tools, .text =
        \\trk unin <task> <arc>
        \\  Remove the <task> in <arc> membership edge (tombstoned; a no-op if
        \\  absent). Exact mirror of `undep`, for the `in` edge kind. Same argument
        \\  order as `trk in` (task first, arc second) — do NOT swap.
        \\  To undo a swapped-argument `trk in` mistake, replay the SAME two ids in
        \\  the SAME (wrong) order you originally typed, just with `unin` swapped
        \\  in for `in` — e.g. if `trk in A B` was meant to be `trk in B A`, the fix
        \\  is `trk unin A B` (not `trk unin B A`), because the edge that actually
        \\  got written has A in the task slot and B in the arc slot.
        \\  e.g.  trk unin 01KX6H4V 01KVX4K0
        },
        .{ .name = "arc", .run = &cmdArc, .mutates = true, .tools = &arc_tools, .text =
        \\trk arc <id> [--undo] [--standing [--undo]]
        \\  Declare <id> an arc root (an `arcDeclare` event), independent of whether any
        \\  task is `in` it — the fix for an arc with genuinely zero members yet (a real
        \\  goal with no work filed), which a direct-`in`/reachability check alone cannot
        \\  express. `--undo` retracts the declaration (a no-op if <id> is still an arc
        \\  via an `in` member) and also clears any standing mark. `trk add --arc`
        \\  declares a brand-new task in one step.
        \\  --standing marks <id> a STANDING arc: a perpetual category (housekeeping,
        \\  the debug/observability substrate) rather than a completable goal — it
        \\  never surfaces in `trk next`, drained or not, but still accepts new `in`
        \\  members. Declares the arc in the same act. `--standing --undo` clears
        \\  JUST the standing mark, leaving the arc declaration intact.
        \\  e.g.  trk arc 01KX6H4V           trk arc 01KX6H4V --undo
        \\        trk arc 01KVKHBZQ --standing           trk arc 01KVKHBZQ --standing --undo
        },
        .{ .name = "migrate-arcs", .run = &cmdMigrateArcs, .mutates = true, .tools = &cli_only_tools, .text =
        \\trk migrate-arcs
        \\  One-time (but idempotent/re-runnable) migration, two passes: (1) for every
        \\  task carrying a legacy `arc:<slug>` tag, emit an `arcDeclare{declared:true}`
        \\  and strip the tag; (2) for every id that is an arc ONLY because some task
        \\  carries a direct `in` edge naming it (never explicitly declared), emit an
        \\  `arcDeclare{declared:true}` for it too. Prints what it changed, one line per
        \\  migrated task, plus a summary count. A second run finds nothing — safe to
        \\  re-run blind.
        },
        .{ .name = "migrate-shorts", .run = &cmdMigrateShorts, .mutates = true, .tools = &cli_only_tools, .text =
        \\trk migrate-shorts [--min <n>]
        \\  One-time (but idempotent/re-runnable) migration: for every task with no
        \\  FROZEN short id yet, freeze it at its CURRENT dynamically-computed short
        \\  (a `setShort` event) so it never again changes on add/archive/compact.
        \\  A second run finds nothing (every task now has a frozen short) — safe to
        \\  re-run blind. LIMITATION: if a prior `compact` already shortened/changed an
        \\  id's displayed prefix, that PRE-compact value is not recorded anywhere and
        \\  cannot be recovered — this freezes whatever prefix is CURRENT right now,
        \\  which is the only recoverable baseline. Going forward, frozen ids are stable.
        \\
        \\  --min <n>  REPAIR mode: freeze/re-freeze every task at max(its current
        \\  short length, n), collision-checked. Without --min, an already-frozen
        \\  short is NEVER touched; --min is the one exception that DELIBERATELY
        \\  LENGTHENS an already-frozen short shorter than n — this CHANGES an id a
        \\  prior run already froze (e.g. every id you'd already written down at 8
        \\  or 6 chars becomes longer). Run it once, on purpose, not routinely.
        \\  e.g.  trk migrate-shorts --min 9
        },
        .{ .name = "state", .run = &cmdState, .mutates = true, .tools = &state_tools, .text =
        \\trk state <id> <open|claimed|submitted|done|blocked|dropped> [--holder <who>]
        \\  Set a task's state. Lifecycle: open -> claimed -> submitted -> done, with
        \\  `trk release` (claimed -> open) as the release.
        \\  `claimed` is the LEASE — "this task is taken": it leaves `trk next` so
        \\  nobody else is handed it. It REQUIRES --holder <who> (a lane or worktree
        \\  name — whatever `trk release --holder` will later name). Only an OPEN
        \\  task can be claimed; claiming a task someone already holds is refused.
        \\  `submitted` is COMPLETION PENDING VERIFICATION ("this commit completes the
        \\  task"), safe for a compile-only builder to write in the same commit as
        \\  the implementing change. It stays in TODO.md (marker `[s]`), does NOT
        \\  satisfy a dependent's prereq, and does NOT appear in `trk next`. The
        \\  orchestrator's post-gate reconcile promotes it to `done` or demotes it
        \\  to `open`; `trk list --state submitted` is that queue. (Before the lease
        \\  existed this state was spelled `claimed` — to report completion, write
        \\  `submitted`.)
        \\  `done` drops it from TODO.md and queues it for `trk archive` — it asserts
        \\  the work PASSED ITS GATE; `dropped` = won't-do (also leaves TODO.md);
        \\  `blocked` is a manual hold. Ids accept any unique prefix.
        \\  e.g.  trk state 01KX6H48 claimed --holder lane-3
        \\        trk state 01KX6H48 submitted
        },
        .{ .name = "release", .run = &cmdRelease, .mutates = true, .tools = &release_tools, .text =
        \\trk release <id> [--holder <who>]
        \\trk release --holder <who>
        \\  Release a lease (claimed -> open), putting the task back in `trk next`.
        \\  With an id: releases that task's lease; adding --holder asserts who holds
        \\  it and refuses if someone else does. With only --holder: releases every
        \\  task that holder has claimed — the teardown for a lane that finished or
        \\  died. A task that is not claimed is reported and left alone.
        \\  The written release names the holder and applies ONLY while that holder
        \\  still holds the task, so a lane's `submitted` that merges in after the
        \\  release still wins, and a stale release never undoes someone else's newer
        \\  lease. (`trk state <id> open` is the unconditional override.)
        \\  e.g.  trk release --holder lane-3        trk release 01KX6H48
        },
        .{ .name = "next", .run = &cmdNext, .tools = &next_tools, .text =
        \\trk next [--arc <id>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> | --word <term> ...]
        \\  The ready frontier: open tasks whose prereqs are ALL met. An arc root is
        \\  a container: it is held back until its non-parked members are finished,
        \\  then surfaces once as the close-out prompt (`trk state <root> done` marks
        \\  the goal complete and unblocks anything that needs the arc) — UNLESS the
        \\  arc is marked --standing (`trk arc`), in which case it never surfaces.
        \\  Bare <term>s (or --word <term>; repeatable, ANDed) are a case-insensitive
        \\  substring search over title+body+tags. --not-tag <t> (repeatable, ANDed
        \\  exclusion) drops any task carrying that tag — the autonomous-eligible
        \\  bucket (no blocker tag) is one bare command:
        \\    trk next --not-tag metal --not-tag scott-testing --not-tag scott-decision
        \\  --json emits a machine-readable array.
        \\  e.g.  trk next           trk next prism windowed
        },
        .{ .name = "list", .run = &cmdList, .tools = &list_tools, .text =
        \\trk list [--arc <id> | --no-arc] [--state <s>] [--tag <t>] [--not-tag <t> ...]
        \\         [--limit <n>] [--json] [<term> | --word <term> ...]
        \\  Every task (not just the ready frontier), filterable by arc/state/tag and
        \\  the same bare-term search as `next`. --not-tag (repeatable, ANDed
        \\  exclusion) drops any task carrying that tag. --no-arc lists every task in
        \\  NO arc (by the unified isArc/membership model, including needs-
        \\  reachability) — the completeness query for "sort everything into arcs";
        \\  mutually exclusive with --arc. --json for machine-readable output.
        \\  e.g.  trk list --state open net           trk list --no-arc
        \\        trk list --state submitted           (the awaiting-verification queue)
        \\        trk list --state claimed             (tasks currently leased)
        },
        .{ .name = "render", .run = &cmdRender, .mutates = true, .tools = &render_tools, .text =
        \\trk render [--out <path>]
        \\  Write the TODO.md markdown projection. Destination precedence:
        \\  explicit --out > config render.out > stdout. Overwrites the target (it is
        \\  a generated projection with a do-not-edit header) — never hand-edit it.
        \\  A task shared by several arcs is listed in full (tags, docs, body) only
        \\  the first time; later listings link back to that anchor. A body that is
        \\  multi-line (or longer than one summary line) is folded into a
        \\  <details> disclosure — collapsed to its first line in any HTML view,
        \\  unchanged in the raw bytes. The header reports an arc-less drift count
        \\  every regeneration (`trk list --no-arc` for the list).
        },
        .{ .name = "tree", .run = &cmdTree, .tools = &tree_tools, .text =
        \\trk tree <arc-or-task> [--json]
        \\  Print the ASCII prereq hierarchy rooted at an arc or task (prereqs nested
        \\  under their dependents; a shared prereq prints once, then "(seen)").
        \\  --json: nested {id,short,title,state,children}; a repeat carries "seen":true.
        \\  GRADUATED MEMBERS ARE REPORTED, NOT OMITTED: `compact` deletes an `in` edge
        \\  along with its collected member, so an arc that was fully built and
        \\  compacted would otherwise render as a bare one-line tree — identical to one
        \\  that was never sliced. Any member found in the tombstone index is listed
        \\  under a `compacted members (N)` heading (root "compacted_members" in --json,
        \\  always present, possibly empty). An arc with no graduated members still
        \\  renders with no such block.
        \\  A COMPACTED root gets `show`'s answer, not "no task matches": the record
        \\  plus its graduated members, exit 2 (live 0 / compacted 2 / absent 1).
        },
        .{ .name = "compact", .run = &cmdCompact, .mutates = true, .tools = &compact_tools, .text =
        \\trk compact
        \\  Rewrite the snapshot + truncate the log, physically GC'ing archived/dropped
        \\  tasks. Orchestrator-only (rewrites the whole snapshot — the merge flashpoint).
        \\  A GHOST id (one the log carries events for but no `add` anywhere) is GC'd
        \\  too, and its log lines are moved to .tracker/quarantine.jsonl first — it is
        \\  not a task, and writing it out would promote a nameless husk into a real
        \\  one. Reported by id, never silent. Warns (stderr) if .tracker/.gitattributes
        \\  is missing a pin — this is the verb that creates the two files that must
        \\  never be union-merged. Before rewriting, copies the pre-compact
        \\  snapshot/log into .tracker/backup/<epoch>/ and evicts down to
        \\  config's compact.backup_retain (default 10) — ignored by
        \\  .tracker/.gitignore so it never becomes an untracked stray. Never
        \\  compact while fan-out worktrees are in flight.
        },
        .{ .name = "archive", .run = &cmdArchive, .mutates = true, .tools = &archive_tools, .text =
        \\trk archive [<term> | --word <term> ...] [--arc <id>] [--tag <t>] [--out <path>]
        \\            [--dry-run] [--allow-buried-decisions] [--allow-buried-decisions-for <id>:<n>:<digest>]...
        \\  Graduate DONE tasks to changelog bullets (--out > config archive.out >
        \\  stdout), then flip each to `archived` so it leaves every view (structural
        \\  dedup — re-running finds nothing). A file target is APPENDED to under a
        \\  `## YYYY-MM-DD` run heading, never truncated. --dry-run previews on
        \\  stdout without flipping (and never touches the file).
        \\  DECISION GUARD: a task body routinely holds more than the work — an open
        \\  fork, a "your call", a FIX NOTE. The work can be finished while the DECISION
        \\  is unresolved, and `archived` is hidden from every view, so archiving buries
        \\  it. archive REFUSES if any closing body carries a marker, listing task id +
        \\  matched line (labeled marker-shaped or prose-shaped — reporting only, it
        \\  does not change what's fatal); split those out as their own tasks, then
        \\  archive. It refuses rather than warning because a warning in a bulk run
        \\  scrolls past and the burial is permanent. --dry-run reports the hits without
        \\  refusing (nothing is buried by a preview).
        \\  Two overrides, different blast radius: --allow-buried-decisions-for
        \\  <id>:<n>:<digest> (repeat the FLAG to name more than one — a bare id-shaped
        \\  token after it is a hard error, not a second value) exempts ONLY that task's
        \\  hits, and ONLY while it still carries EXACTLY those <n> lines, unchanged.
        \\  Naming <n>:<digest> is an assertion about the hit set you READ: a marker
        \\  line added, removed, or swapped in that task afterwards stops it matching
        \\  and the exemption stops applying — it does not silently ride along, and a
        \\  count-preserving swap does not sneak past. You never compute the value
        \\  yourself: the guard's own report prints the ready-to-paste
        \\  <id>:<n>:<digest> under each task's hits. This is how one task whose body
        \\  legitimately discusses the
        \\  guard's own marker vocabulary (e.g. a task ABOUT this very check) can be
        \\  exempted without forcing you to wave through every other hit in the same
        \\  run, and without that exemption quietly covering a LATER decision appended
        \\  to the same task. --allow-buried-decisions (bare) overrides the WHOLE run —
        \\  use it only once you have looked at every hit, since a false positive on
        \\  one task otherwise pressures you into bypassing the guard for a real one
        \\  hiding in the same batch.
        \\  Markers default to: scott-decision, OPEN QUESTION, FIX NOTE, your call, TODO
        \\  (matched case-insensitively). Override with .tracker/config.json ->
        \\  archive.decision_markers, a JSON array of strings; [] disables the check.
        },
        .{ .name = "doc", .run = &cmdDoc, .mutating_subcommands = &.{ "set", "unset" }, .tools = &doc_tools, .text =
        \\trk doc set <doc_id> <path>   register/update a doc_id -> repo-relative path
        \\trk doc unset <doc_id>        unregister a doc_id (idempotent; refs fall back
        \\                              to the raw doc_id until it is re-set)
        \\trk doc list                  print all registered doc_id -> path mappings
        \\trk doc resolve <doc_id>      print the path for a doc_id
        \\  The registry backs the --doc/--add-doc design pointers on add/edit.
        },
        .{ .name = "show", .run = &cmdShow, .tools = &show_tools, .text =
        \\trk show <id> [--body | --json]
        \\  Full detail for one task: body, state, priority, tags, prereqs,
        \\  dependents, arc memberships, and doc pointers. Ids accept any unique prefix.
        \\  --json emits the same facts as one object.
        \\  --body prints ONLY the raw body bytes (no header, no indent) — the safe
        \\  read half of an edit round-trip — pipe it back with `--replace-body -`:
        \\  trk show <id> --body | trk edit <id> --replace-body -
        \\  (`trk edit <id> --body "$(trk show <id> --body)"` also works, but the
        \\  shell eats ALL trailing newlines and the arg is length-capped)
        },
        .{ .name = "edit", .run = &cmdEdit, .mutates = true, .tools = &edit_tools, .text =
        \\trk edit <id> [--title <s>] [--replace-body <s|->] [--append-body <s|->]
        \\        [--add-tag <t> ...] [--rm-tag <t> ...]
        \\        [--add-doc <doc_id[#section]> ...] [--rm-doc <doc_id> ...] [--priority <n>]
        \\  Modify an existing task in place.
        \\  BODY EDITS NAME THEIR DIRECTION — there is no `--body`, and passing it is a
        \\  hard error, not a warning:
        \\    --replace-body <s>  overwrite the whole body. Warns if the new bytes are
        \\                        IDENTICAL to the current ones (the write "succeeded"
        \\                        while adding nothing — a real and repeated failure).
        \\    --append-body <s>   add to the body, keeping what is there, separated by a
        \\                        blank line. Reads the current body through trk's own
        \\                        log+snapshot fold — the half an external
        \\                        read-modify-write CANNOT do correctly, because a body
        \\                        last written before the newest `compact` lives only in
        \\                        snapshot.jsonl and a log-only helper sees it as empty.
        \\  Either takes `-` to read from STDIN (exactly one trailing newline trimmed, so
        \\  `trk show <id> --body | trk edit <id> --replace-body -` is byte-stable; without
        \\  a pipe, or on empty stdin, it refuses rather than blanking the body).
        \\  --rm-doc removes a doc-ref by doc id — the inverse of --add-doc, and the fix
        \\  for a typo'd ref. A `#section` suffix is accepted and ignored: one --rm-doc
        \\  clears every ref to that doc. No-op (and says so) if the ref is absent.
        \\  --priority: int, LOWER SORTS FIRST, and unset ranks 100 — `--priority 10`
        \\  raises, `--priority 500` sinks, `--priority 0` restores the default rank.
        \\  `--add-tag arc:<slug>` is a DEPRECATED way to mark an arc (still honored,
        \\  but warns) — use `trk arc <id>` instead.
        \\  e.g.  trk edit 01KX6H --replace-body "revised plan" --add-tag tooling
        \\        trk edit 01KX6H --append-body "2026-08-23: reproduced on main."
        \\        trk edit 01KX6H --rm-doc none
        },
        .{ .name = "log", .run = &cmdLog, .tools = &log_tools, .text =
        \\trk log [<id>] [--limit <n>] [--json]
        \\  Event history, most-recent-last: the whole log, or one task's events.
        \\  --json: an array of {ts,op,task_id,summary}.
        },
        .{ .name = "stale", .run = &cmdStale, .tools = &stale_tools, .text =
        \\trk stale
        \\  Cross-reference: which OPEN tasks have their id cited in a LANDED commit
        \\  message (this branch's `git log --oneline` ancestry — deliberately NOT
        \\  `--all`, which would count unmerged worktree-branch commits as landed)
        \\  but were never closed? Matches by exact token (full id or displayed short
        \\  id), not raw substring. Leased (`claimed`) tasks are included: a landed
        \\  citation on a task still held means its lane merged without submitting.
        \\  `submitted` tasks are excluded (already in the awaiting-verification
        \\  queue — see `trk state --help`). Runs `git` against the store root (the
        \\  repo housing `.tracker/`, which may differ from where `trk` itself lives).
        \\  e.g.  trk stale
        },
        .{ .name = "tombstones", .run = &cmdTombstones, .mutating_subcommands = &.{"--rebuild"}, .tools = &tombstones_tools, .text =
        \\trk tombstones [--rebuild | --verify] [--json]
        \\  The index of tasks `trk compact` physically GC'd (.tracker/tombstones.jsonl).
        \\  Compaction is the only thing that destroys an id: the task, its title and
        \\  its edges leave every file under .tracker/, and without this index
        \\  `trk show <that id>` answers "no task matches" — byte-identical to the
        \\  answer for an id that NEVER existed. Those are opposite facts, and the
        \\  wrong one invites someone to "fix" a citation that was correct.
        \\  With the index, `trk show` resolves a compacted id and says COMPACTED,
        \\  exiting 2 (0 = live, 2 = compacted, 1 = no such id).
        \\  No flags: list every tombstone (id, short, why it left, title).
        \\  --rebuild: RECOVER tombstones for ids compacted BEFORE this index existed,
        \\  by replaying .tracker/log.jsonl's full git history (`git log --all -p`) and
        \\  entombing every id it ever carried that is neither live nor already
        \\  recorded — every id ANY event names (an edge's both endpoints included),
        \\  not just the ones that happen to carry a title. That is the method
        \\  scripts/dangling-tracker-id-lint.sh uses to tell historical from
        \\  dangling — run ONCE and persisted, instead of per query: measured on a
        \\  10,574-commit repo it is ~31s and ~162MB of diff, which is fine for a
        \\  one-shot migration and is exactly why `show` cannot do it live.
        \\  Idempotent (an id already entombed is skipped); it never touches the
        \\  log, the snapshot, or any live task. Recovered rows are marked
        \\  src=git-history and carry no collection time.
        \\  --verify: the STANDING CHECK — same git-history walk as --rebuild, but
        \\  asserts (never repairs) that every id it finds is either live or already
        \\  entombed. Exits nonzero and lists the gap if not — the check
        \\  `--rebuild`'s own "N recorded" count cannot give you, because a count is
        \\  coverage of what it found, not proof it found everything. Read-only,
        \\  same cost as --rebuild; not for routine/per-commit use.
        \\  e.g.  trk tombstones           trk tombstones --rebuild
        \\        trk tombstones --verify
        },
        .{ .name = "mcp-serve", .run = &cmdMcpServe, .tools = &cli_only_tools, .text =
        \\trk mcp-serve
        \\  Serve trk as an MCP server: JSON-RPC 2.0, one message per line, on
        \\  stdin/stdout. Every verb above except init, migrate-arcs, migrate-shorts
        \\  and mcp-serve is a tool of the same name (`doc` is doc_set, doc_unset,
        \\  doc_list, doc_resolve) with typed parameters, running the same code as
        \\  the CLI verb. show/list/next/tree/log return JSON.
        \\  Every tool takes a REQUIRED `tree`: "main" (the main checkout of the repo
        \\  the server was started in) or the path of one of that repo's linked git
        \\  worktrees. Anything else is refused. The store is re-read on every call.
        \\  TRK_READONLY in the server's environment refuses every writing tool.
        \\  Register it for Claude Code in .mcp.json:
        \\    {"mcpServers": {"trk": {"command": "trk", "args": ["mcp-serve"]}}}
        },
    };

    // ----------------------------------------------------------- MCP tool specs
    //
    // Parameters mirror each verb's parser; every `flag` must appear in that
    // verb's help text (asserted), so a renamed flag cannot leave a stale tool.
    // Positional string values beginning with `-` are refused by mcp.zig — the
    // verb parsers would read them as flags.

    /// CLI-only verbs: `init` scaffolds a store (the server serves an existing
    /// one), `migrate-arcs`/`migrate-shorts` are one-time deliberate repairs
    /// (`--min` rewrites frozen ids), and `mcp-serve` is the server itself.
    const cli_only_tools = [_]Tool{};

    const p_id = Param{ .name = "id", .kind = .string, .required = true, .desc = "Task id (any unique prefix)." };

    const add_tools = [_]Tool{.{ .name = "add", .params = &.{
        .{ .name = "title", .kind = .string, .required = true, .desc = "Task title." },
        .{ .name = "body", .kind = .string, .flag = "--body", .desc = "Task body." },
        .{ .name = "tag", .kind = .string_list, .flag = "--tag", .desc = "Tags." },
        .{ .name = "doc", .kind = .string_list, .flag = "--doc", .desc = "Doc refs, doc_id or doc_id#section." },
        .{ .name = "in", .kind = .string, .flag = "--in", .desc = "Add to this already-declared arc." },
        .{ .name = "seq", .kind = .integer, .flag = "--seq", .desc = "Arc sequence (with `in`)." },
        .{ .name = "arc", .kind = .boolean, .flag = "--arc", .desc = "Declare the new task an arc root." },
        .{ .name = "needs", .kind = .string_list, .flag = "--needs", .desc = "Prerequisite task ids." },
        .{ .name = "priority", .kind = .integer, .flag = "--priority", .desc = "Lower sorts first; 0 = unset." },
    } }};

    const dep_params = [_]Param{
        .{ .name = "needer", .kind = .string, .required = true, .desc = "The task that needs the prerequisite(s)." },
        .{ .name = "needs", .kind = .string_list, .flag = "--needs", .required = true, .desc = "Prerequisite task ids." },
    };
    const dep_tools = [_]Tool{.{ .name = "dep", .params = &dep_params }};
    const undep_tools = [_]Tool{.{ .name = "undep", .params = &dep_params }};

    const membership_params = [_]Param{
        .{ .name = "task", .kind = .string, .required = true, .desc = "The member task." },
        .{ .name = "arc", .kind = .string, .required = true, .desc = "The (declared) arc." },
    };
    const in_tools = [_]Tool{.{ .name = "in", .params = &(membership_params ++ [_]Param{
        .{ .name = "seq", .kind = .integer, .flag = "--seq", .desc = "Order within the arc; lower first." },
    }) }};
    const unin_tools = [_]Tool{.{ .name = "unin", .params = &membership_params }};

    const arc_tools = [_]Tool{.{ .name = "arc", .params = &.{
        p_id,
        .{ .name = "undo", .kind = .boolean, .flag = "--undo", .desc = "Retract (with `standing`: just the standing mark)." },
        .{ .name = "standing", .kind = .boolean, .flag = "--standing", .desc = "Mark a perpetual-category arc." },
    } }};

    const state_tools = [_]Tool{.{ .name = "state", .params = &.{
        p_id,
        .{
            .name = "state",
            .kind = .choice,
            .required = true,
            .choices = &.{ "open", "claimed", "submitted", "done", "blocked", "dropped" },
            .desc = "claimed = the lease (needs holder); submitted = completion pending verification.",
        },
        .{ .name = "holder", .kind = .string, .flag = "--holder", .desc = "Lease holder; required for claimed, refused otherwise." },
    } }};

    const release_tools = [_]Tool{.{ .name = "release", .params = &.{
        .{ .name = "id", .kind = .string, .desc = "Release this task's lease." },
        .{ .name = "holder", .kind = .string, .flag = "--holder", .desc = "Alone: release every lease this holder has. With id: assert the holder." },
    } }};

    const p_arc_filter = Param{ .name = "arc", .kind = .string, .flag = "--arc", .desc = "Only this arc's members." };
    const p_not_tag = Param{ .name = "not_tag", .kind = .string_list, .flag = "--not-tag", .desc = "Exclude tasks carrying any of these tags." };
    const p_limit = Param{ .name = "limit", .kind = .integer, .flag = "--limit", .desc = "At most this many." };
    const p_term = Param{ .name = "term", .kind = .string_list, .flag = "--word", .desc = "Case-insensitive substrings over title+body+tags, ANDed." };

    const next_tools = [_]Tool{.{ .name = "next", .argv = &.{"--json"}, .params = &.{ p_arc_filter, p_not_tag, p_limit, p_term } }};

    const list_tools = [_]Tool{.{ .name = "list", .argv = &.{"--json"}, .params = &.{
        p_arc_filter,
        .{ .name = "no_arc", .kind = .boolean, .flag = "--no-arc", .desc = "Only tasks in no arc." },
        .{
            .name = "state",
            .kind = .choice,
            .flag = "--state",
            .choices = &.{ "open", "claimed", "submitted", "done", "blocked", "dropped", "archived" },
            .desc = "Only tasks in this state.",
        },
        .{ .name = "tag", .kind = .string, .flag = "--tag", .desc = "Only tasks carrying this tag." },
        p_not_tag,
        p_limit,
        p_term,
    } }};

    const p_out = Param{ .name = "out", .kind = .string, .flag = "--out", .desc = "Output path, relative to the store root." };
    const render_tools = [_]Tool{.{ .name = "render", .params = &.{p_out} }};
    const tree_tools = [_]Tool{.{ .name = "tree", .argv = &.{"--json"}, .params = &.{p_id} }};
    const compact_tools = [_]Tool{.{ .name = "compact" }};

    const archive_tools = [_]Tool{.{ .name = "archive", .params = &.{
        p_term,
        .{ .name = "arc", .kind = .string, .flag = "--arc", .desc = "Only this arc's done members." },
        .{ .name = "tag", .kind = .string, .flag = "--tag", .desc = "Only done tasks carrying this tag." },
        p_out,
        .{ .name = "dry_run", .kind = .boolean, .flag = "--dry-run", .desc = "Preview without archiving." },
        .{ .name = "allow_buried_decisions", .kind = .boolean, .flag = "--allow-buried-decisions", .desc = "Override the decision guard for the whole run." },
        .{ .name = "allow_buried_decisions_for", .kind = .string_list, .flag = "--allow-buried-decisions-for", .desc = "<id>:<n>:<digest> exemptions, as printed by the guard." },
    } }};

    const p_doc_id = Param{ .name = "doc_id", .kind = .string, .required = true, .desc = "The doc id." };
    const doc_tools = [_]Tool{
        .{ .name = "doc_set", .argv = &.{"set"}, .params = &.{
            p_doc_id,
            .{ .name = "path", .kind = .string, .required = true, .desc = "Repo-relative path." },
        } },
        .{ .name = "doc_unset", .argv = &.{"unset"}, .params = &.{p_doc_id} },
        .{ .name = "doc_list", .argv = &.{"list"} },
        .{ .name = "doc_resolve", .argv = &.{"resolve"}, .params = &.{p_doc_id} },
    };

    const show_tools = [_]Tool{.{ .name = "show", .argv = &.{"--json"}, .params = &.{p_id} }};

    const edit_tools = [_]Tool{.{ .name = "edit", .params = &.{
        p_id,
        .{ .name = "title", .kind = .string, .flag = "--title", .desc = "New title." },
        .{ .name = "body", .kind = .body_edit, .desc = "Body edit; `direction` is required: append keeps the body, replace overwrites it." },
        .{ .name = "add_tag", .kind = .string_list, .flag = "--add-tag", .desc = "Tags to add." },
        .{ .name = "rm_tag", .kind = .string_list, .flag = "--rm-tag", .desc = "Tags to remove." },
        .{ .name = "add_doc", .kind = .string_list, .flag = "--add-doc", .desc = "Doc refs to add." },
        .{ .name = "rm_doc", .kind = .string_list, .flag = "--rm-doc", .desc = "Doc ids whose refs to remove." },
        .{ .name = "priority", .kind = .integer, .flag = "--priority", .desc = "Lower sorts first; 0 = unset." },
    } }};

    const log_tools = [_]Tool{.{ .name = "log", .argv = &.{"--json"}, .params = &.{
        .{ .name = "id", .kind = .string, .desc = "Only this task's events." },
        p_limit,
    } }};

    const stale_tools = [_]Tool{.{ .name = "stale" }};

    // READ-ONLY over MCP, deliberately: neither `--rebuild` nor `--verify` is
    // exposed. `--rebuild` is a one-shot migration that shells out to `git log
    // --all -p` (~31s, ~162MB on a real repo) and writes the index — an
    // orchestrator runs it once from the CLI; exposing it here would also make
    // `readOnlyHint` a lie, since that hint is derived from `argv` alone and
    // could not see a `rebuild: true` argument coming. `--verify` IS read-only
    // (never writes), but shares `--rebuild`'s full-history-walk cost — an MCP
    // caller has no reason to expect an ~80s tool call, so it stays a CLI-only,
    // orchestrator-invoked check for the same reason `--rebuild` is.
    const tombstones_tools = [_]Tool{.{ .name = "tombstones", .argv = &.{"--json"} }};

    /// Print one verb's help (from `verbs`), or fall back to the full usage
    /// overview for an unknown/absent verb (so `trk help nonsense` still helps).
    fn helpFor(self: *Cli, cmd: []const u8) !void {
        for (verbs) |v| {
            if (std.mem.eql(u8, v.name, cmd)) {
                try self.write(v.text);
                try self.write("\n");
                return;
            }
        }
        return self.usage();
    }

    fn usage(self: *Cli) !void {
        try self.write(
            \\trk — an in-repo issue tracker
            \\
            \\Usage:
            \\  trk init [--out <path>] [--force] [--no-gitattributes] [--no-gitignore]   scaffold
            \\      .tracker/ + config.json + .tracker/.gitattributes + .tracker/.gitignore + a starter
            \\      TODO.md. Idempotent and non-destructive: never overwrites an existing TODO.md,
            \\      .gitattributes, or .gitignore (or config.json without --force).
            \\      --out sets config's render.out (default docs/TODO.md).
            \\  trk add "<title>" [--body <s>] [--tag <t> ...] [--doc <doc_id[#section]> ...] [--in <arc> [--seq <n>]] [--arc]
            \\                    [--needs <id> ...] [--priority <n>] [-v]   (prints the new ULID; -v = friendly)
            \\      Neither --in nor --arc -> warns to stderr (escalate via config's add.arcless).
            \\  trk dep <needer> --needs <prereq> [--needs <prereq> ...]
            \\      mark <needer> as needing prerequisite <prereq>. ONE positional, prereqs
            \\      flagged — two bare positionals could be swapped, and the swap wired a
            \\      valid edge backwards with no error. `trk dep A B` is now a usage error.
            \\  trk undep <needer> --needs <prereq> [--needs <prereq> ...]
            \\      remove the edge (tombstone; no-op if absent). Same shape as `dep`.
            \\  trk in <task> <arc> [--seq <n>]   add task to an arc, task FIRST (NOT the same order as
            \\      `dep`'s arc-needs-task phrasing — see `trk in --help`)
            \\  trk unin <task> <arc>         remove the <task> in <arc> edge (tombstone; no-op if absent;
            \\      same arg order as `trk in` — fixes a swapped-argument `in` mistake)
            \\  trk arc <id> [--undo] [--standing [--undo]]   declare/retract <id> as an arc root
            \\      --standing marks a perpetual-category arc (never surfaces in `next`,
            \\      drained or not, but still accepts new members); `--standing --undo`
            \\      clears just the mark.
            \\  trk migrate-arcs             backfill real declarations for legacy `arc:` tags AND in-edge-only arcs; idempotent
            \\  trk migrate-shorts [--min <n>]   freeze every task's CURRENT short id so it never changes again
            \\      --min <n> is a one-time REPAIR: also lengthens an already-frozen short below n
            \\  trk state <id> <open|claimed|submitted|done|blocked|dropped> [--holder <who>]
            \\      `claimed` = the lease ("this task is taken"; hides it from `next`; needs --holder).
            \\      `submitted` = a builder's self-report ("this commit completes it, pending
            \\      verification") — safe for a compile-only agent, unlike `done`.
            \\  trk release <id> [--holder <who>] | --holder <who>   release a lease (claimed -> open)
            \\  trk next [--arc <id>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> ...]   the ready frontier
            \\  trk list [--arc <id> | --no-arc] [--state <s>] [--tag <t>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> ...]
            \\      <term> (bare or --word <term>, repeatable) ANDs a case-insensitive
            \\      substring search over title+body+tags. --not-tag (repeatable, ANDed
            \\      exclusion) drops any task carrying that tag. --no-arc lists every task in
            \\      no arc. --json emits a machine-readable array
            \\      (id/short/title/state/priority/seq?/tags).
            \\  trk render [--out <path>]    the TODO.md markdown projection (--out > config render.out > stdout)
            \\      Header reports an arc-less drift count every regeneration.
            \\  trk tree <arc-or-task>       the ASCII prereq hierarchy
            \\  trk archive [<term> ...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]
            \\              [--allow-buried-decisions] [--allow-buried-decisions-for <id>:<n>:<digest>]...
            \\      Graduate DONE tasks to the changelog: emit them as markdown bullets
            \\      (appended to --out/config target under a dated heading, else stdout),
            \\      then flip each to `archived` so it leaves every view (structural
            \\      dedup). --dry-run previews on stdout without archiving.
            \\      REFUSES if a closing body carries a decision marker (scott-decision,
            \\      OPEN QUESTION, FIX NOTE, your call, TODO — configurable via config's
            \\      archive.decision_markers): `archived` is hidden from every view, so an
            \\      unresolved fork in a finished task's body would be buried with it.
            \\      --allow-buried-decisions-for <id>:<n>:<digest> exempts just that task's hits, and
            \\      only while it still carries exactly those <n> lines unchanged — the guard's report
            \\      prints the value to paste (repeat the flag for more than one);
            \\      --allow-buried-decisions overrides the WHOLE run; --dry-run reports without refusing.
            \\  trk compact [--force]        rewrite snapshot + truncate log (drops archived/dropped)
            \\  trk doc set <doc_id> <path>  register/update a doc_id -> repo-relative path
            \\  trk doc list                 print all registered doc_id -> path mappings
            \\  trk doc resolve <doc_id>     print the path for a doc_id
            \\  trk show <id> [--body | --json]   full task detail
            \\  trk edit <id> [--title <s>] [--replace-body <s|->] [--append-body <s|->]
            \\                [--add-tag <t> ...] [--rm-tag <t> ...]
            \\                [--add-doc <doc_id[#section]> ...] [--rm-doc <doc_id> ...] [--priority <n>]
            \\      A body edit must NAME its direction; there is no `--body` (hard error).
            \\      --append-body reads the current body through trk's own log+snapshot fold,
            \\      which an external read-modify-write cannot do correctly.
            \\  trk log [<id>] [--limit <n>] event history (most-recent-last)
            \\  trk stale                    open or claimed tasks cited in a landed commit but never closed
            \\  trk mcp-serve                serve the verbs as MCP tools over stdio (see `trk mcp-serve --help`)
            \\
            \\Ids accept any unique prefix (git-short-hash style). A task minted after
            \\short-id freezing (or migrated via `trk migrate-shorts`) always displays
            \\the SAME short id — it never changes on add/archive/compact. A task with
            \\no frozen short falls back to a dynamically-computed prefix that can
            \\change as the id set changes; `trk migrate-shorts` freezes it in place.
            \\Per-verb help: `trk <verb> --help`  (or  `trk help <verb>`).
            \\
            \\.tracker/ is found by walking up from cwd (git-style), bounded at a linked
            \\worktree's root (never escapes into an enclosing repo's tracker).
            \\TRK_READONLY=1 in the environment refuses every mutating verb.
            \\
        );
    }

    // ----------------------------------------------------------- id resolution

    /// Resolve a (possibly short) id string to a full task id. Accepts:
    ///   - a full 26-char ULID (parsed/canonicalized), OR
    ///   - a unique case-insensitive prefix of an existing task's id.
    /// Errors cleanly (with candidate list) on ambiguity / no-match / bad chars.
    pub fn resolve(self: *Cli, s: []const u8) Error!Ulid {
        // Full ULID: parse + verify it exists (a full id that isn't a task is a
        // NoSuchId, not a parse success that later faults).
        if (s.len == ulid.len) {
            const u = ulid.parse(s) catch {
                try self.print("trk: '{s}' is not a valid id\n", .{s});
                return error.BadId;
            };
            if (self.store.get(u) == null) {
                try self.print("trk: no task with id {s}\n", .{s});
                return error.NoSuchId;
            }
            return u;
        }
        if (s.len == 0) {
            try self.write("trk: empty id\n");
            return error.BadId;
        }

        // Prefix match (case-insensitive, against the canonical upper-case text).
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var match: ?Ulid = null;
        var n_matches: usize = 0;
        for (ids) |id| {
            if (prefixMatches(s, &id.text)) {
                n_matches += 1;
                if (match == null) match = id;
            }
        }
        if (n_matches == 0) {
            try self.print("trk: no task matches prefix '{s}'\n", .{s});
            return error.NoSuchId;
        }
        if (n_matches > 1) {
            try self.print("trk: prefix '{s}' is ambiguous ({d} matches):\n", .{ s, n_matches });
            for (ids) |id| {
                if (prefixMatches(s, &id.text)) {
                    const t = self.store.get(id).?;
                    var sb: [ulid.len]u8 = undefined;
                    try self.print("  {s}  {s}\n", .{ try self.shortId(id, &sb), t.title });
                }
            }
            return error.AmbiguousId;
        }
        return match.?;
    }

    /// Case-insensitive "does `pfx` prefix the canonical id text". Crockford ids
    /// are upper-case canonical; we upper the user input per char to compare.
    fn prefixMatches(pfx: []const u8, id_text: []const u8) bool {
        if (pfx.len > id_text.len) return false;
        for (pfx, id_text[0..pfx.len]) |p, c| {
            if (std.ascii.toUpper(p) != c) return false;
        }
        return true;
    }

    /// Shared prefix-search: the shortest prefix of `id.text` (>= `floor`,
    /// capped at the full ULID) that collides with at most `max_collisions`
    /// other entries in `ids`. Two call shapes:
    ///   - DISPLAY (`id` is already a member of `ids`): `max_collisions = 1`
    ///     tolerates the id matching itself.
    ///   - MINT (`id` is NOT yet in `ids` — not yet inserted into the store):
    ///     `max_collisions = 0`, so any match is a real collision to extend past.
    /// Written into the caller-provided `buf`; returns a slice of `buf`. No heap
    /// allocation. Lookup is O(N·len) over the id set — fine for an in-repo backlog.
    fn shortestPrefix(id: Ulid, ids: []const Ulid, floor: usize, max_collisions: usize, buf: *[ulid.len]u8) []const u8 {
        var n: usize = floor;
        while (n < ulid.len) : (n += 1) {
            var collisions: usize = 0;
            for (ids) |other| {
                if (std.mem.eql(u8, id.text[0..n], other.text[0..n])) collisions += 1;
            }
            if (collisions <= max_collisions) break;
        }
        @memcpy(buf[0..n], id.text[0..n]);
        return buf[0..n];
    }

    /// The short id to DISPLAY for `id`. If a short was frozen for this task
    /// (at mint time via `mintShortId`, or later via `trk migrate-shorts`),
    /// returns it verbatim — stable forever, independent of the live id set.
    /// Otherwise falls back to the legacy dynamically-computed prefix (>=
    /// `min_short`), which is UNSTABLE: it moves as the id set moves (an add,
    /// an archive, a compact can all change it). Written into the
    /// caller-provided `buf`; returns a slice of `buf`. No heap allocation
    /// needed by the caller (two short ids in one line want two buffers).
    pub fn shortId(self: *Cli, id: Ulid, buf: *[ulid.len]u8) ![]const u8 {
        if (self.store.get(id)) |t| {
            if (t.short) |s| {
                @memcpy(buf[0..s.len], s);
                return buf[0..s.len];
            }
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        return shortestPrefix(id, ids, min_short, 1, buf);
    }

    /// The short id to FREEZE for a newly-minted `id` that is NOT YET in the
    /// store (called before `store.append(.add)`). The shortest prefix (>=
    /// `min_short_mint`) that does not collide with any EXISTING task's id —
    /// collision handling is one-sided: only the new id's candidate is ever
    /// extended; an already-frozen short is never touched. The caller embeds
    /// the result in the `add` event's `short` field so it persists forever.
    pub fn mintShortId(self: *Cli, id: Ulid, buf: *[ulid.len]u8) ![]const u8 {
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        return shortestPrefix(id, ids, min_short_mint, 0, buf);
    }

    // ----------------------------------------------------------- small parse helpers

    fn parseI32(self: *Cli, s: []const u8) Error!i32 {
        return std.fmt.parseInt(i32, s, 10) catch {
            try self.print("trk: '{s}' is not a number\n", .{s});
            return error.BadNumber;
        };
    }

    fn parseUsize(self: *Cli, s: []const u8) Error!usize {
        return std.fmt.parseInt(usize, s, 10) catch {
            try self.print("trk: '{s}' is not a non-negative number\n", .{s});
            return error.BadNumber;
        };
    }

    /// Read the next arg as a flag value or report a clean missing-arg error.
    fn flagVal(self: *Cli, args: []const []const u8, i: *usize, flag: []const u8) Error![]const u8 {
        if (i.* + 1 >= args.len) {
            try self.print("trk: {s} needs a value\n", .{flag});
            return error.MissingArgument;
        }
        i.* += 1;
        return args[i.*];
    }

    /// True iff `path` (relative to `self.dir`) exists.
    fn fileExists(self: *Cli, path: []const u8) bool {
        self.dir.access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Write `data` to `path` under `self.dir`, best-effort creating the parent
    /// directory chain first (`writeFile` alone does no `mkdir -p`, so a config
    /// render.out like `docs/TODO.md` in a fresh checkout would else fail). The
    /// mkdir is best-effort — if it fails, the `writeFile` surfaces the real error.
    fn writeOutFile(self: *Cli, path: []const u8, data: []const u8) Error!void {
        if (std.fs.path.dirname(path)) |d| {
            if (d.len > 0) {
                if (self.dir.createDirPathOpen(self.io, d, .{})) |pd| {
                    var pdv = pd;
                    pdv.close(self.io);
                } else |_| {}
            }
        }
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = data, .flags = .{} });
    }

    /// Append `data` at the end of `path` under `self.dir` (created if absent,
    /// parent chain best-effort like `writeOutFile`), preceded by a blank-line
    /// separator when the file already has content. For accumulating targets
    /// (the changelog): `render` regenerates its whole projection so it
    /// truncates; `archive` emits increments, so truncating would destroy the
    /// prior records.
    fn appendOutFile(self: *Cli, path: []const u8, data: []const u8) Error!void {
        if (std.fs.path.dirname(path)) |d| {
            if (d.len > 0) {
                if (self.dir.createDirPathOpen(self.io, d, .{})) |pd| {
                    var pdv = pd;
                    pdv.close(self.io);
                } else |_| {}
            }
        }
        var f = try self.dir.createFile(self.io, path, .{ .read = true, .truncate = false });
        defer f.close(self.io);
        var end = try f.length(self.io);
        if (end > 0) {
            try f.writePositionalAll(self.io, "\n", end);
            end += 1;
        }
        try f.writePositionalAll(self.io, data, end);
    }

    // ----------------------------------------------------------- init

    /// `trk init [--out <path>] [--force] [--no-gitattributes] [--no-gitignore]`
    /// — scaffold a fresh project's tracker.
    /// Artifacts, each created only if absent (idempotent, non-destructive):
    ///   1. `.tracker/` + an empty `log.jsonl` (today made lazily on first write;
    ///      init makes it explicit so `trk next` works immediately),
    ///   2. `.tracker/config.json` with a default `render.out` (rewritten only
    ///      under `--force`),
    ///   3. `.tracker/.gitattributes` — the merge semantics the whole model rests
    ///      on (see `store.gitattributes_text`), skippable with
    ///      `--no-gitattributes` for a repo that manages attributes centrally,
    ///   4. `.tracker/.gitignore` — ignores `compact`'s pre-rewrite `backup/`
    ///      runs (see `store.gitignore_text`) so they never become a permanent
    ///      untracked stray in `git status`, skippable with `--no-gitignore`
    ///      for a repo that manages ignores centrally,
    ///   5. a starter `TODO.md` at the render path — a valid empty projection.
    /// The TODO.md is NEVER overwritten (unlike `trk render`, which regenerates
    /// its projection by design): if one exists init leaves it and reports it, so
    /// init can't clobber a live projection or a user's file.
    fn cmdInit(self: *Cli, args: []const []const u8) Error!void {
        var out_arg: ?[]const u8 = null;
        var force = false;
        var write_attrs = true;
        var write_ignore = true;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_arg = try self.flagVal(args, &i, "--out");
            } else if (std.mem.eql(u8, args[i], "--force")) {
                force = true;
            } else if (std.mem.eql(u8, args[i], "--no-gitattributes")) {
                write_attrs = false;
            } else if (std.mem.eql(u8, args[i], "--no-gitignore")) {
                write_ignore = false;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        const sd = tracker.store.tracker_subdir;
        const default_out = "docs/TODO.md";

        // 1. .tracker/ + an empty log.jsonl (createDirPathOpen is mkdir -p; idempotent).
        var sub = self.dir.createDirPathOpen(self.io, sd, .{}) catch {
            try self.print("trk: init: cannot create {s}/\n", .{sd});
            return error.WriteFailed;
        };
        defer sub.close(self.io);
        const log_existed = blk: {
            sub.access(self.io, tracker.store.log_name, .{}) catch break :blk false;
            break :blk true;
        };
        if (!log_existed) {
            var lf = sub.createFile(self.io, tracker.store.log_name, .{ .truncate = false }) catch {
                try self.print("trk: init: cannot create {s}/{s}\n", .{ sd, tracker.store.log_name });
                return error.WriteFailed;
            };
            lf.close(self.io);
            try self.print("created {s}/{s}\n", .{ sd, tracker.store.log_name });
        } else {
            try self.print("{s}/{s} already exists\n", .{ sd, tracker.store.log_name });
        }

        // 2. config.json — write if absent (or --force). An existing config's
        //    render.out wins over --out for the seed step below (don't fight a
        //    path the project already chose).
        const cfg = tracker.store.config_name;
        const cfg_existed = self.dirHas(sub, cfg);
        var render_out: []const u8 = out_arg orelse default_out;
        if (cfg_existed and !force) {
            if (self.store.config.render_out) |ro| render_out = ro;
            try self.print("{s}/{s} already exists (use --force to rewrite)\n", .{ sd, cfg });
        } else {
            var cbuf: std.ArrayList(u8) = .empty;
            defer cbuf.deinit(self.gpa);
            try cbuf.print(self.gpa,
                \\{{
                \\  "render": {{ "out": "{s}" }},
                \\  "archive": {{ "out": null }}
                \\}}
                \\
            , .{render_out});
            sub.writeFile(self.io, .{ .sub_path = cfg, .data = cbuf.items, .flags = .{} }) catch {
                try self.print("trk: init: cannot write {s}/{s}\n", .{ sd, cfg });
                return error.WriteFailed;
            };
            try self.print("{s} {s}/{s} (render.out = {s})\n", .{
                if (cfg_existed) "rewrote" else "created",
                sd,
                cfg,
                render_out,
            });
        }

        // 3. .tracker/.gitattributes — never overwritten (a project may have
        //    tuned it), and never written at the repo ROOT: git resolves
        //    attributes per directory and the nearest file wins, so keeping the
        //    pins here makes them immune to a later root-level `*.jsonl` glob
        //    instead of dependent on a "keep these lines last" convention.
        if (write_attrs) {
            const ga = tracker.store.gitattributes_name;
            if (self.dirHas(sub, ga)) {
                try self.print("{s}/{s} already exists — left untouched\n", .{ sd, ga });
            } else {
                sub.writeFile(self.io, .{
                    .sub_path = ga,
                    .data = tracker.store.gitattributes_text,
                    .flags = .{},
                }) catch {
                    try self.print("trk: init: cannot write {s}/{s}\n", .{ sd, ga });
                    return error.WriteFailed;
                };
                try self.print("created {s}/{s} (log union-merges; the baselines conflict on purpose)\n", .{ sd, ga });
            }
        }

        // 4. .tracker/.gitignore — never overwritten, and never written at the
        //    repo ROOT for the same reason .gitattributes isn't: git resolves
        //    ignores per directory, so a pattern here can't be missed by a repo
        //    whose root .gitignore never learned about compact's backup dir.
        if (write_ignore) {
            const gi = tracker.store.gitignore_name;
            if (self.dirHas(sub, gi)) {
                try self.print("{s}/{s} already exists — left untouched\n", .{ sd, gi });
            } else {
                sub.writeFile(self.io, .{
                    .sub_path = gi,
                    .data = tracker.store.gitignore_text,
                    .flags = .{},
                }) catch {
                    try self.print("trk: init: cannot write {s}/{s}\n", .{ sd, gi });
                    return error.WriteFailed;
                };
                try self.print("created {s}/{s} (ignores compact's backup/ runs)\n", .{ sd, gi });
            }
        }

        // 5. Seed a starter TODO.md at render_out — ONLY if none exists.
        if (self.fileExists(render_out)) {
            try self.print("{s} already exists — left untouched (init never overwrites it)\n", .{render_out});
        } else {
            var md: std.ArrayList(u8) = .empty;
            defer md.deinit(self.gpa);
            try self.renderMarkdown(&md);
            try self.writeOutFile(render_out, md.items);
            try self.print("seeded {s} (starter projection)\n", .{render_out});
        }
    }

    /// True iff `name` exists directly inside the already-open dir `d`.
    fn dirHas(self: *Cli, d: Io.Dir, name: []const u8) bool {
        d.access(self.io, name, .{}) catch return false;
        return true;
    }

    // ----------------------------------------------------------- add

    fn cmdAdd(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: add needs a \"<title>\"\n");
            return error.MissingArgument;
        }
        const title = args[0];
        var body: []const u8 = "";
        // Set when `--body -` read stdin into a fresh allocation (see bodyArg).
        var body_owned = false;
        defer if (body_owned) self.gpa.free(body);
        var priority: ?i32 = null;
        var in_arc: ?[]const u8 = null;
        var declare_arc = false;
        var seq: i32 = 0;
        var verbose = false;
        var tags: std.ArrayList([]const u8) = .empty;
        defer tags.deinit(self.gpa);
        var needs: std.ArrayList([]const u8) = .empty;
        defer needs.deinit(self.gpa);
        var docs: std.ArrayList([]const u8) = .empty;
        defer docs.deinit(self.gpa);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--body")) {
                const b = try self.bodyArg("--body", try self.flagVal(args, &i, "--body"));
                body = b.text;
                body_owned = b.owned;
            } else if (std.mem.eql(u8, arg, "--tag")) {
                try tags.append(self.gpa, try self.flagVal(args, &i, "--tag"));
            } else if (std.mem.eql(u8, arg, "--needs")) {
                try needs.append(self.gpa, try self.flagVal(args, &i, "--needs"));
            } else if (std.mem.eql(u8, arg, "--doc")) {
                try docs.append(self.gpa, try self.flagVal(args, &i, "--doc"));
            } else if (std.mem.eql(u8, arg, "--in")) {
                in_arc = try self.flagVal(args, &i, "--in");
            } else if (std.mem.eql(u8, arg, "--arc")) {
                declare_arc = true;
            } else if (std.mem.eql(u8, arg, "--seq")) {
                seq = try self.parseI32(try self.flagVal(args, &i, "--seq"));
            } else if (std.mem.eql(u8, arg, "--priority")) {
                priority = try self.parseI32(try self.flagVal(args, &i, "--priority"));
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            }
        }

        // Resolve referenced ids BEFORE minting, so a bad --in/--needs fails
        // without leaving a half-built task in the log.
        const arc_id: ?Ulid = if (in_arc) |a| try self.resolve(a) else null;
        // `--in` must name an already-declared arc, checked here (not left to
        // the `.in` append below) so the failure happens BEFORE minting —
        // same "no half-built task in the log" reasoning as --needs.
        if (arc_id) |a| {
            if (!self.store.isArc(a)) {
                var ab: [ulid.len]u8 = undefined;
                const as = try self.shortId(a, &ab);
                try self.print(
                    "trk: refusing: {s} is not a declared arc — declare it first with `trk arc {s}` (or `trk add --arc`), then retry\n",
                    .{ as, as },
                );
                return error.UndeclaredArc;
            }
        }
        var need_ids = try self.gpa.alloc(Ulid, needs.items.len);
        defer self.gpa.free(need_ids);
        for (needs.items, 0..) |n, idx| need_ids[idx] = try self.resolve(n);

        // Neither --in nor --arc: the task lands in no arc. Decided BEFORE
        // minting so the hard-error path (config add.arcless = "error") never
        // leaves a half-built task in the log.
        const has_arc = arc_id != null or declare_arc;
        if (!has_arc and self.store.config.add_arcless_error) {
            try self.write(
                "trk: refusing: this task would land in no arc (neither --in nor --arc given) — " ++
                    "pass one, or set add.arcless to \"warn\" in .tracker/config.json to downgrade this to a warning\n",
            );
            return error.NoArc;
        }

        const id = ulid.mint(self.io);
        // Freeze the short id NOW, before `id` exists in the store, so the
        // collision check is against the pre-add id set (mintShortId's
        // contract) — then carry it in the add event so it's persisted
        // forever (Task.short), never recomputed.
        var short_buf: [ulid.len]u8 = undefined;
        const short = try self.mintShortId(id, &short_buf);
        const tag_slice = tags.items;
        try self.store.append(.{ .add = .{ .id = id, .title = title, .body = body, .tags = tag_slice, .short = short } });
        if (priority) |p| try self.store.append(.{ .setPriority = .{ .id = id, .priority = p } });
        if (arc_id) |a| try self.store.append(.{ .in = .{ .task = id, .arc = a, .seq = seq } });
        if (declare_arc) try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
        for (need_ids) |to| try self.store.append(.{ .dep = .{ .from = id, .to = to } });
        for (docs.items) |d| {
            const ref = splitDocRef(d);
            try self.store.append(.{ .docref = .{ .id = id, .doc_id = ref.doc_id, .section_id = ref.section_id } });
        }

        // Arc-less warning goes to the SEPARATE `warn` buffer (stderr), never
        // `out` (stdout) — `out` is exactly the scriptable ULID and nothing else.
        if (!has_arc) {
            var sb: [ulid.len]u8 = undefined;
            try self.warn.print(self.gpa, "trk: warning: {s} \"{s}\" is in no arc (pass --in <arc> or --arc)\n", .{ try self.shortId(id, &sb), title });
        }
        for (tag_slice) |tg| try self.warnDeprecatedArcTag(id, tg);

        // Quiet by default: print ONLY the full ULID so `ID=$(trk add ...)` is
        // scriptable with no parsing. `-v`/`--verbose` gives the friendly form.
        if (verbose) {
            var sb: [ulid.len]u8 = undefined;
            try self.print("added {s}  ({s})\n", .{ try self.shortId(id, &sb), &id.text });
        } else {
            try self.print("{s}\n", .{&id.text});
        }
    }

    // ----------------------------------------------------------- dep

    /// `trk dep <id> --needs <id> [--needs <id> ...]`
    ///
    /// ONE positional, the rest flagged. The asymmetry IS the guard: two bare
    /// positionals of the same type can be swapped by accident, and the swap
    /// produces a VALID edge pointing the wrong way — wrong DAG, wrong ready
    /// frontier, no error (task 01M0QKHWQ). You cannot swap two things when
    /// only one of them is spellable positionally.
    fn cmdDep(self: *Cli, args: []const []const u8) Error!void {
        const p = try self.parseNeedsArgs("dep", args);
        defer self.gpa.free(p.prereqs);
        const from = p.needer;
        for (p.prereqs) |to| try self.depOne(from, to);
    }

    /// The direction-explicit argument shape shared by `dep` and `undep`:
    /// `<needer> --needs <prereq> [--needs <prereq> ...]`. Repeats are allowed
    /// for the same reason `trk add --needs` allows them — wiring several
    /// prerequisites is one thought, not N commands.
    fn parseNeedsArgs(
        self: *Cli,
        verb: []const u8,
        args: []const []const u8,
    ) Error!struct { needer: Ulid, prereqs: []Ulid } {
        if (args.len == 0) {
            try self.print("trk: usage: trk {s} <id> --needs <id>\n", .{verb});
            return error.MissingArgument;
        }
        var prereqs: std.ArrayList(Ulid) = .empty;
        errdefer prereqs.deinit(self.gpa);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--needs")) {
                try prereqs.append(self.gpa, try self.resolve(try self.flagVal(args, &i, "--needs")));
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            } else {
                // The legacy `trk <verb> A B` form. Hard-errored, not accepted:
                // tolerating it would keep the exact footgun this shape exists
                // to close, and the fix is one word long.
                try self.print(
                    "trk: `trk {s} {s} {s}` — the two-positional form was REMOVED because the argument " ++
                        "order silently inverted the edge.\n       Name the direction: trk {s} {s} --needs {s}\n",
                    .{ verb, args[0], arg, verb, args[0], arg },
                );
                return error.UsageError;
            }
        }
        if (prereqs.items.len == 0) {
            try self.print("trk: {s} needs a --needs <id> (trk {s} {s} --needs <id>)\n", .{ verb, verb, args[0] });
            return error.MissingArgument;
        }
        return .{ .needer = try self.resolve(args[0]), .prereqs = try prereqs.toOwnedSlice(self.gpa) };
    }

    fn depOne(self: *Cli, from: Ulid, to: Ulid) Error!void {
        var fb: [ulid.len]u8 = undefined;
        var tb: [ulid.len]u8 = undefined;
        self.store.append(.{ .dep = .{ .from = from, .to = to } }) catch |e| {
            if (e == error.DependencyCycle) {
                const fs = try self.shortId(from, &fb);
                const ts = try self.shortId(to, &tb);
                // Covers both shapes the store now rejects: a plain needs
                // cycle (A->B->...->A) and a self-wait mediated by arc
                // membership (e.g. `to` is an arc `from` is itself a
                // member of) — "ts already depends on fs" is literally true
                // either way, so one message serves both without needing to
                // know which relation closed the loop.
                try self.print(
                    "trk: refusing: {s} needs {s} would close a cycle — {s} already (directly or transitively) depends on {s}, so {s} would wait on itself forever\n",
                    .{ fs, ts, ts, fs, fs },
                );
                return error.DependencyCycle;
            }
            return e;
        };
        try self.print("{s} now needs {s}\n", .{ try self.shortId(from, &fb), try self.shortId(to, &tb) });
    }

    // ----------------------------------------------------------- undep

    /// `trk undep <id> --needs <id>` — same argument shape as `dep`, so undoing
    /// an edge is the same sentence with one verb changed.
    fn cmdUndep(self: *Cli, args: []const []const u8) Error!void {
        const p = try self.parseNeedsArgs("undep", args);
        defer self.gpa.free(p.prereqs);
        var fb: [ulid.len]u8 = undefined;
        var tb: [ulid.len]u8 = undefined;
        for (p.prereqs) |to| {
            try self.store.append(.{ .undep = .{ .from = p.needer, .to = to } });
            try self.print("{s} no longer needs {s}\n", .{ try self.shortId(p.needer, &fb), try self.shortId(to, &tb) });
        }
    }

    // ----------------------------------------------------------- in

    fn cmdIn(self: *Cli, args: []const []const u8) Error!void {
        if (args.len < 2) {
            try self.write("trk: usage: trk in <task> <arc> [--seq <n>]\n");
            return error.UsageError;
        }
        const task = try self.resolve(args[0]);
        const arc = try self.resolve(args[1]);
        var seq: i32 = 0;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--seq")) {
                seq = try self.parseI32(try self.flagVal(args, &i, "--seq"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }
        // A task cannot be a member of itself. Caught explicitly (rather than
        // left to the generic cycle-detector, which WOULD also reject it, but
        // with a confusing "X already needs X" message) so the diagnosis is
        // immediate and unambiguous.
        if (task.eql(arc)) {
            var tb: [ulid.len]u8 = undefined;
            const ts = try self.shortId(task, &tb);
            try self.print("trk: refusing: {s} cannot be a member of itself\n", .{ts});
            return error.DependencyCycle;
        }
        self.store.append(.{ .in = .{ .task = task, .arc = arc, .seq = seq } }) catch |e| {
            if (e == error.DependencyCycle) {
                var tb: [ulid.len]u8 = undefined;
                var ab: [ulid.len]u8 = undefined;
                const ts = try self.shortId(task, &tb);
                const as = try self.shortId(arc, &ab);
                // The mirror of cmdDep's rejection: this membership would
                // close the SAME combined self-wait graph from the other
                // side — `task` already (directly or transitively) needs
                // `arc`, so making it a member too means `arc` can never
                // drain (it's waiting on a member that's waiting on it).
                // The single most common real-world cause of THIS specific
                // rejection is a swapped argument order (`trk in <arc>
                // <task>` instead of `<task> <arc>`) landing on top of an
                // edge the swap already created — so the hint is worth the
                // line even though it isn't always the cause.
                try self.print(
                    "trk: refusing: {s} in {s} would close a cycle — {s} already (directly or transitively) needs {s}, so {s} would wait on itself forever (it can never finish while depending on a member that's waiting on it)\n" ++
                        "trk: hint: if this looks backwards, double check argument order — it's `trk in <task> <arc>`, not <arc> <task>. `trk unin {s} {s}` removes a wrongly-directed edge.\n",
                    .{ ts, as, ts, as, as, ts, as },
                );
                return error.DependencyCycle;
            }
            if (e == error.UndeclaredArc) {
                var tb: [ulid.len]u8 = undefined;
                var ab: [ulid.len]u8 = undefined;
                const ts = try self.shortId(task, &tb);
                const as = try self.shortId(arc, &ab);
                // `arc` has never been declared (`trk arc`/`trk add --arc`)
                // — `in` no longer mints one on the fly (01KYTFRD7). The
                // single most common real-world cause is the SAME
                // argument-order slip cmdDep/the cycle branch above warn
                // about: `trk in <arc> <task>` instead of `<task> <arc>`,
                // where the intended arc ends up in the TASK position and
                // the intended task — never declared — ends up where an arc
                // is required.
                try self.print(
                    "trk: refusing: {s} is not a declared arc — declare it first with `trk arc {s}` (or `trk add --arc`), then retry `trk in {s} {s}`\n" ++
                        "trk: hint: if this looks backwards, double check argument order — it's `trk in <task> <arc>`, not <arc> <task>.\n",
                    .{ as, as, ts, as },
                );
                return error.UndeclaredArc;
            }
            return e;
        };
        var tb: [ulid.len]u8 = undefined;
        var ab: [ulid.len]u8 = undefined;
        try self.print("{s} in arc {s} (seq {d})\n", .{ try self.shortId(task, &tb), try self.shortId(arc, &ab), seq });
    }

    // ----------------------------------------------------------- unin

    fn cmdUnin(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk unin <task> <arc>\n");
            return error.UsageError;
        }
        const task = try self.resolve(args[0]);
        const arc = try self.resolve(args[1]);
        try self.store.append(.{ .unin = .{ .task = task, .arc = arc } });
        var tb: [ulid.len]u8 = undefined;
        var ab: [ulid.len]u8 = undefined;
        try self.print("{s} no longer in {s}\n", .{ try self.shortId(task, &tb), try self.shortId(arc, &ab) });
    }

    // ----------------------------------------------------------- arc

    /// If `tg` is the DEPRECATED `arc:<slug>` marker, nudge to stderr steering
    /// new usage at `trk arc`/`trk add --arc` instead — the whole point of
    /// unifying arc-ness is that nothing should keep silently writing the old,
    /// cosmetic marker. `Store.isArc` still HONORS an already-written tag
    /// read-only (back-compat: an un-migrated repo's arcs keep working); this
    /// is the write-path guard that stops NEW ones from accumulating. Never
    /// blocks the write (a warning, not an error) — the tag is still valid
    /// input, just steered away from.
    fn warnDeprecatedArcTag(self: *Cli, id: Ulid, tg: []const u8) Error!void {
        if (!std.mem.startsWith(u8, tg, "arc:")) return;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        try self.warn.print(
            self.gpa,
            "trk: warning: {s}: tag \"{s}\" is the DEPRECATED arc marker — use `trk arc {s}` (or `trk add --arc`) instead; `trk migrate-arcs` converts existing ones\n",
            .{ sid, tg, sid },
        );
    }

    /// `trk arc <id> [--undo] [--standing [--undo]]` — declare (or, with
    /// --undo, retract) <id> as an arc root independent of `in` membership;
    /// `--standing` additionally marks it a STANDING arc (a perpetual
    /// category, never a `next` close-out candidate — see `Store.isStanding`).
    /// See `Store.isArc`.
    fn cmdArc(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: usage: trk arc <id> [--undo] [--standing [--undo]]\n");
            return error.UsageError;
        }
        const id = try self.resolve(args[0]);
        var undo = false;
        var standing = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--undo")) {
                undo = true;
            } else if (std.mem.eql(u8, args[i], "--standing")) {
                standing = true;
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }
        var sb: [ulid.len]u8 = undefined;

        if (standing and undo) {
            // Clear JUST the standing mark; leave the arc declaration intact.
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = false } });
            try self.print("{s} standing mark retracted (still an arc)\n", .{try self.shortId(id, &sb)});
            return;
        }
        if (standing) {
            // Standing implies arc-ness: declare in the same act (idempotent
            // last-write-wins if already declared).
            try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = true } });
            try self.print("{s} declared an arc and marked standing\n", .{try self.shortId(id, &sb)});
            return;
        }

        try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = !undo } });
        if (undo) {
            // Retracting the arc declaration also clears any orphaned standing
            // mark — a task that is no longer (declared) an arc has no
            // business staying "standing" (no-op if it never was one).
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = false } });
            try self.print("{s} arc declaration retracted\n", .{try self.shortId(id, &sb)});
        } else {
            try self.print("{s} declared an arc\n", .{try self.shortId(id, &sb)});
        }
    }

    // ----------------------------------------------------------- migrate-arcs

    /// `trk migrate-arcs` — one-time-but-idempotent backfill onto real
    /// `arcDeclare` events, in two independent passes:
    ///
    ///   1. Every legacy `arc:<slug>` tag → `arcDeclare` + strip the tag
    ///      (pre-existing).
    ///   2. Every id that is an arc ONLY because some task carries a direct
    ///      `in` edge naming it (01KYTFRD7, 2026-07-30 — added the same day
    ///      `Store.isArc`'s in-edge inference was deleted). This pass is what
    ///      makes deleting that inference SAFE rather than merely bypassed:
    ///      it backfills a real declaration for every arc that existed
    ///      because of it, so `isArc`'s answer for every arc that existed
    ///      BEFORE this landed is unchanged after — only a brand-new,
    ///      never-declared `in` target is affected going forward (and that
    ///      is now refused at `append`, not silently minted).
    ///
    /// Safe to re-run: pass 1 finds nothing once tags are stripped, pass 2
    /// finds nothing once every in-edge target carries a declaration — both
    /// are structural idempotency, not a separate "already migrated" check.
    fn cmdMigrateArcs(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: migrate-arcs takes no arguments\n");
            return error.UsageError;
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var migrated: usize = 0;

        // Pass 1: legacy `arc:` tags.
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (!hasArcTag(t)) continue;
            var arc_tags: std.ArrayList([]const u8) = .empty;
            defer arc_tags.deinit(self.gpa);
            for (t.tags.items) |tg| {
                if (std.mem.startsWith(u8, tg, "arc:")) try arc_tags.append(self.gpa, try self.gpa.dupe(u8, tg));
            }
            defer for (arc_tags.items) |tg| self.gpa.free(tg);
            if (arc_tags.items.len == 0) continue;

            try self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } });
            for (arc_tags.items) |tg| try self.store.append(.{ .untag = .{ .id = id, .tag = tg } });

            var sb: [ulid.len]u8 = undefined;
            try self.print("migrated {s}  {s}  (declared; stripped {d} arc: tag(s))\n", .{
                try self.shortId(id, &sb), t.title, arc_tags.items.len,
            });
            migrated += 1;
        }

        // Pass 2: every UNIQUE `in.arc` id not already declared (by config,
        // by pass 1 above, or from before this migration ever ran). Iterates
        // `self.store.ins` directly — the same field the CLI already reaches
        // into elsewhere (render/tree) — rather than adding a new Store
        // query for a one-time migration pass.
        var seen: std.AutoHashMapUnmanaged([ulid.len]u8, void) = .empty;
        defer seen.deinit(self.gpa);
        for (self.store.ins.items) |e| {
            const gop = try seen.getOrPut(self.gpa, e.arc.text);
            if (gop.found_existing) continue;
            if (self.store.declared_arcs.contains(e.arc.text)) continue;

            try self.store.append(.{ .arcDeclare = .{ .id = e.arc, .declared = true } });

            var sb: [ulid.len]u8 = undefined;
            const title = if (self.store.get(e.arc)) |t| t.title else "";
            try self.print("migrated {s}  {s}  (declared; was in-edge-inferred only)\n", .{
                try self.shortId(e.arc, &sb), title,
            });
            migrated += 1;
        }

        if (migrated == 0) {
            try self.write("migrate-arcs: nothing to migrate\n");
        } else {
            try self.print("migrate-arcs: {d} task(s) migrated\n", .{migrated});
        }
    }

    // ----------------------------------------------------------- migrate-shorts

    /// `trk migrate-shorts [--min <n>]` — one-time-but-idempotent: freeze
    /// every task with no persisted `short` yet at its CURRENT dynamically-
    /// computed short id (a `setShort` event), so it never again moves on a
    /// future add/archive/compact. Safe to re-run: a task already frozen (and
    /// already >= `--min`, if given) is skipped, so a settled repo finds
    /// nothing.
    ///
    /// LIMITATION (stated here and in the help text): a freshly-frozen value
    /// is whatever `shortId` computes RIGHT NOW. If an earlier `compact`
    /// already shortened/changed a task's displayed prefix, that pre-compact
    /// value was never recorded anywhere and cannot be recovered — the
    /// current computed value is the only recoverable baseline.
    ///
    /// `--min <n>` is the one-time REPAIR path: every task (frozen or not) is
    /// frozen at `max(its current short length, n)`, collision-checked like
    /// any mint. Without `--min`, an already-frozen short is NEVER touched
    /// (today's default, unchanged); `--min` is the one exception that
    /// deliberately LENGTHENS an already-frozen short when it's shorter than
    /// `n` — this changes an id a prior run already froze, so it is gated
    /// behind the explicit flag and meant to be run once, on purpose (e.g. to
    /// bring a repo's ids up to a length that matches what's already been
    /// written down elsewhere).
    fn cmdMigrateShorts(self: *Cli, args: []const []const u8) Error!void {
        var min_len: ?usize = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--min")) {
                min_len = try self.parseUsize(try self.flagVal(args, &i, "--min"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        var frozen: usize = 0;
        var lengthened: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            var sb: [ulid.len]u8 = undefined;

            if (t.short) |s| {
                const min_l = min_len orelse continue; // no --min: never re-touch a frozen short
                if (s.len >= min_l) continue; // already long enough
                // Repair: lengthen this already-frozen short to >= min_l
                // (still collision-checked — it may need to extend further).
                const longer = shortestPrefix(id, ids, min_l, 1, &sb);
                try self.store.append(.{ .setShort = .{ .id = id, .short = longer } });
                try self.print("lengthened {s} -> {s}  {s}\n", .{ s, longer, t.title });
                lengthened += 1;
                continue;
            }

            // Never frozen: freeze at max(the natural unambiguous floor, --min).
            const floor = @max(min_short, min_len orelse min_short);
            const short = shortestPrefix(id, ids, floor, 1, &sb);
            try self.store.append(.{ .setShort = .{ .id = id, .short = short } });
            try self.print("froze {s}  {s}\n", .{ short, t.title });
            frozen += 1;
        }

        if (frozen == 0 and lengthened == 0) {
            try self.write("migrate-shorts: nothing to migrate (every task already has a frozen short" ++
                " long enough)\n");
        } else {
            try self.print(
                "migrate-shorts: froze {d} new task(s), lengthened {d} existing short(s) — note this " ++
                    "is a best-effort baseline: any id already changed by an earlier `compact` cannot be " ++
                    "recovered to a prior value; going forward these ids are stable.\n",
                .{ frozen, lengthened },
            );
        }
    }

    /// `mcp-serve` never reaches dispatch from the real binary: main.zig starts
    /// the server before any store is loaded. This only answers a direct call.
    fn cmdMcpServe(self: *Cli, args: []const []const u8) Error!void {
        _ = args;
        try self.write("trk: mcp-serve is started by the trk binary itself (`trk mcp-serve`), not from within a command\n");
        return error.UsageError;
    }

    // ----------------------------------------------------------- state

    fn cmdState(self: *Cli, args: []const []const u8) Error!void {
        var pos: [2][]const u8 = undefined;
        var npos: usize = 0;
        var holder: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--holder")) {
                holder = try self.flagVal(args, &i, "--holder");
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                if (npos == pos.len) {
                    npos += 1;
                    break;
                }
                pos[npos] = args[i];
                npos += 1;
            }
        }
        if (npos != 2) {
            try self.write("trk: usage: trk state <id> <open|claimed|submitted|done|blocked|dropped> [--holder <who>]\n");
            return error.UsageError;
        }
        const id = try self.resolve(pos[0]);
        const st = State.fromString(pos[1]) orelse {
            try self.print("trk: '{s}' is not a state (open|claimed|submitted|done|blocked|dropped)\n", .{pos[1]});
            return error.BadState;
        };
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        if (holder != null and st != .claimed) {
            try self.write("trk: --holder only applies to `claimed` (the lease)\n");
            return error.UsageError;
        }
        if (st == .claimed and (holder == null or holder.?.len == 0)) {
            try self.print(
                "trk: `claimed` is the lease and needs --holder <who> (trk state {s} claimed --holder <lane>). " ++
                    "If you meant \"this commit completes it\", that is `trk state {s} submitted`.\n",
                .{ sid, sid },
            );
            return error.HolderRequired;
        }
        self.store.append(.{ .setState = .{ .id = id, .state = st, .holder = holder } }) catch |e| {
            if (e != error.ClaimRequiresOpen) return e;
            const from = self.store.get(id).?.state;
            // Every refusal names `submitted`: writing `claimed` to mean
            // completion was the standing habit before the lease existed.
            switch (State.claimRefusal(from).?) {
                .already_claimed => try self.print(
                    "trk: {s} is already claimed by {s}. If you meant \"this commit completes it\", " ++
                        "that is now `trk state {s} submitted`.\n",
                    .{ sid, self.store.get(id).?.holder orelse "(unknown holder)", sid },
                ),
                .already_submitted => try self.print(
                    "trk: {s} is already submitted (awaiting verification); `claimed` is now the lease, " ++
                        "not completion. Nothing to do if you meant completion.\n",
                    .{sid},
                ),
                .finished, .blocked => try self.print(
                    "trk: {s} is {s}; only an open task can be claimed (the lease). If you meant " ++
                        "\"this commit completes it\", that is `trk state {s} submitted`.\n",
                    .{ sid, from.toString(), sid },
                ),
            }
            return error.ClaimRequiresOpen;
        };
        if (holder) |h|
            try self.print("{s} -> {s} (held by {s})\n", .{ sid, st.toString(), h })
        else
            try self.print("{s} -> {s}\n", .{ sid, st.toString() });
    }

    // ----------------------------------------------------------- release

    /// `trk release <id> [--holder <h>]` / `trk release --holder <h>`. Every
    /// release event names the holder it releases (the task's CURRENT holder
    /// for the by-id form), because the fold applies it only while that holder
    /// still holds the task — see `Op.release`.
    fn cmdRelease(self: *Cli, args: []const []const u8) Error!void {
        var id_arg: ?[]const u8 = null;
        var holder: ?[]const u8 = null;
        var extra_positional = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--holder")) {
                holder = try self.flagVal(args, &i, "--holder");
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else if (id_arg == null) {
                id_arg = args[i];
            } else {
                extra_positional = true;
            }
        }
        if (extra_positional or (id_arg == null and (holder == null or holder.?.len == 0))) {
            try self.write("trk: usage: trk release <id> [--holder <who>] | trk release --holder <who>\n");
            return error.UsageError;
        }

        if (id_arg) |a| {
            const id = try self.resolve(a);
            const t = self.store.get(id).?;
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            if (t.state != .claimed or t.holder == null) {
                try self.print("release: {s} is {s}, not claimed — nothing to release\n", .{ sid, t.state.toString() });
                return;
            }
            const current = t.holder.?;
            if (holder) |h| if (!std.mem.eql(u8, h, current)) {
                try self.print("trk: {s} is held by {s}, not {s} — not releasing\n", .{ sid, current, h });
                return error.LeaseHolderMismatch;
            };
            try self.store.append(.{ .release = .{ .id = id, .holder = current } });
            try self.print("{s} -> open (released from {s})\n", .{ sid, current });
            return;
        }

        const h = holder.?;
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        var released: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.state != .claimed) continue;
            const cur = t.holder orelse continue;
            if (!std.mem.eql(u8, cur, h)) continue;
            try self.store.append(.{ .release = .{ .id = id, .holder = h } });
            var sb: [ulid.len]u8 = undefined;
            try self.print("{s} -> open (released from {s})  {s}\n", .{ try self.shortId(id, &sb), h, t.title });
            released += 1;
        }
        if (released == 0) try self.print("release: nothing claimed by {s}\n", .{h});
    }

    // ----------------------------------------------------------- compact

    /// `trk compact` — rewrite the snapshot from current in-memory state and
    /// truncate the log. Prints a one-line summary on success, plus a named
    /// report of any ghost ids it GC'd (see `Store.compact`): those are the one
    /// thing here a human may want to act on, so they are never folded into the
    /// count alone.
    fn cmdCompact(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: usage: trk compact\n");
            return error.UsageError;
        }
        const result = self.store.compact() catch |e| {
            if (e == error.CompactVerifyFailed) {
                try self.print(
                    "trk: compact REFUSED — round-trip self-verify found {d} diverged id(s) after the " ++
                        "rewrite. The pre-compact snapshot.jsonl/log.jsonl were RESTORED byte-for-byte; " ++
                        "nothing was lost:\n",
                    .{self.store.diverged_on_verify.items.len},
                );
                for (self.store.diverged_on_verify.items) |id|
                    try self.print("    {s}\n", .{&id.text});
                try self.write(
                    "  This should never happen — it means compact's own rewrite (or the reload that\n" ++
                        "  checks it) produced a different result for a live task than the state it started\n" ++
                        "  from. Inspect each id above (`trk show <id>` / `trk log <id>`) before re-running\n" ++
                        "  compact; a copy of the pre-compact files also lives under .tracker/backup/.\n",
                );
            }
            return e;
        };
        // `compact` re-scans `ghost_tasks` itself, so the list read below is the
        // set it actually GC'd, not a stale load-time one.
        try self.warnUnpinnedAttrs();
        try self.print(
            "compacted: {d} events -> {d} live tasks, log truncated\n",
            .{ result.log_events_before, result.live_tasks },
        );
        if (result.tombstoned != 0)
            try self.print(
                "  {d} GC'd task(s) entombed in .tracker/{s} — their ids still RESOLVE:\n" ++
                    "  `trk show <id>` reports each COMPACTED (exit 2), never \"no such task\".\n",
                .{ result.tombstoned, tracker.store.tombstones_name },
            );
        if (result.ghosts != 0) {
            try self.print(
                "  {d} ghost id(s) GC'd (no `add` event anywhere in the fold — not tasks, the\n" ++
                    "  residue of events about ids that no longer exist). {d} log line(s) moved to\n" ++
                    "  .tracker/{s}, nothing destroyed:\n",
                .{ result.ghosts, result.quarantined_lines, tracker.store.quarantine_name },
            );
            for (self.store.ghost_tasks.items) |id|
                try self.print("    {s}\n", .{&id.text});
            try self.write(
                "  If a snapshot was clobbered and these were real tasks, restore\n" ++
                    "  .tracker/snapshot.jsonl from git and append the quarantine file back onto\n" ++
                    "  .tracker/log.jsonl — the ids still match.\n",
            );
        }
    }

    /// Warn (to stderr, never stdout) when `.tracker/.gitattributes` is absent or
    /// missing one of its pins. Called from `compact` because that is the verb
    /// which CREATES `snapshot.jsonl`/`quarantine.jsonl` — the exact moment two
    /// files that must never be union-merged come into existence.
    ///
    /// The claim is deliberately narrow. This path never shells out to git (two
    /// verbs do — `stale` and `tombstones --rebuild` — but not this one), so it
    /// cannot ask what attributes are actually in EFFECT (a parent
    /// `.gitattributes`, `.git/info/attributes` and `core.attributesFile` all
    /// feed that, and reimplementing git's resolution would be worse than not
    /// checking). What it can check is its OWN file, so a missing one says
    /// "absent, and here is what it would do" rather than "your repo is wrong" —
    /// a repo that pins these at the root is correct too, just not visibly so
    /// from here.
    fn warnUnpinnedAttrs(self: *Cli) Error!void {
        const sd = tracker.store.tracker_subdir;
        const ga = tracker.store.gitattributes_name;
        var sub = self.dir.openDir(self.io, sd, .{}) catch return;
        defer sub.close(self.io);

        const bytes = sub.readFileAlloc(self.io, ga, self.gpa, .unlimited) catch {
            try self.warn.print(
                self.gpa,
                "trk: warning: {s}/{s} is absent. {s} and {s} are whole-file baselines that " ++
                    "must NOT be union-merged (a raced compact has to surface as a conflict), and " ++
                    "{s} must be. If this repo pins them elsewhere, ignore this; otherwise run " ++
                    "`trk init` to write it.\n",
                .{ sd, ga, tracker.store.snapshot_name, tracker.store.quarantine_name, tracker.store.log_name },
            );
            return;
        };
        defer self.gpa.free(bytes);

        // Each pin as its own line, leading/trailing whitespace ignored. Matching
        // whole lines rather than substrings so a mention inside a COMMENT (this
        // file is heavily commented, and the comments name every pattern) can't
        // pass the check.
        const pins = [_][]const u8{
            tracker.store.log_name ++ " merge=union",
            tracker.store.snapshot_name ++ " merge=text",
            tracker.store.quarantine_name ++ " merge=text",
            tracker.store.tombstones_name ++ " merge=union",
        };
        for (pins) |pin| {
            var found = false;
            var it = std.mem.splitScalar(u8, bytes, '\n');
            while (it.next()) |line| {
                if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), pin)) {
                    found = true;
                    break;
                }
            }
            if (!found) try self.warn.print(
                self.gpa,
                "trk: warning: {s}/{s} has no `{s}` line — re-add it or delete the file and " ++
                    "re-run `trk init`.\n",
                .{ sd, ga, pin },
            );
        }
    }

    // ----------------------------------------------------------- archive

    /// `trk archive [<term>...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]`
    /// — graduate completed work to the changelog. Selects `done` tasks (narrowed
    /// by the same term/arc/tag filters as `list`), emits them as changelog-ready
    /// markdown bullets, then flips each to `archived` so it leaves every working
    /// view — the recorded item can never be re-emitted (structural dedup). A file
    /// target (`--out` or config) is APPENDED to, under a `## YYYY-MM-DD` run
    /// heading. `--dry-run` previews the queue on stdout without archiving — it
    /// never touches the file (an appended preview would duplicate on the real run).
    fn cmdArchive(self: *Cli, args: []const []const u8) Error!void {
        var out_path: ?[]const u8 = null;
        var dry_run = false;
        var allow_buried = false;
        var allow_for_raw: std.ArrayList([]const u8) = .empty;
        defer allow_for_raw.deinit(self.gpa);
        var arc_filter: ?[]const u8 = null;
        var tag_filter: ?[]const u8 = null;
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_path = try self.flagVal(args, &i, "--out");
            } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, args[i], "--allow-buried-decisions")) {
                allow_buried = true;
            } else if (std.mem.eql(u8, args[i], "--allow-buried-decisions-for")) {
                try allow_for_raw.append(self.gpa, try self.flagVal(args, &i, "--allow-buried-decisions-for"));
            } else if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--tag")) {
                tag_filter = try self.flagVal(args, &i, "--tag");
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                // A bare id-shaped token here can ONLY be a mistake (finding 7,
                // 01M12ZG5ER): the synopsis renders `--allow-buried-decisions-for
                // <id> ...` as if a second bare id extended the SAME flag, but the
                // parser takes exactly one value per flag and silently folds any
                // further bare token into the title/body/tag search filter
                // instead — exempting only the first id and quietly narrowing the
                // archive set to (almost always) zero matches, with no error at
                // all. A search term that happens to be id-shaped is not a real
                // use case worth keeping alive at that cost.
                if (looksIdShaped(args[i])) {
                    try self.print(
                        "trk: '{s}' looks like a task id, not a search word. If you meant to " ++
                            "exempt another task from the decision guard, repeat the flag: " ++
                            "--allow-buried-decisions-for {s}:<n>:<digest> (a bare `trk archive` " ++
                            "prints the exact value for each task it refuses on)\n",
                        .{ args[i], args[i] },
                    );
                    return error.UsageError;
                }
                try words.append(self.gpa, args[i]);
            }
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| members = try self.store.membersOf(self.gpa, a);

        // Collect matching DONE tasks in deterministic id order.
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        var matched: std.ArrayList(Ulid) = .empty;
        defer matched.deinit(self.gpa);
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.state != .done) continue;
            if (members) |m| if (!containsId(m, id)) continue;
            if (tag_filter) |tf| if (!hasTag(t, tf)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            try matched.append(self.gpa, id);
        }

        if (matched.items.len == 0) {
            try self.write("(no done tasks to archive)\n");
            return;
        }

        // Per-task escape (01M12ZG5ER, tightened by finding 4 and again by
        // 01M13JXWN): each --allow-buried-decisions-for value is
        // `<id>:<n>:<digest>`, exempting ONLY the named task's hits, and ONLY
        // while that task still carries EXACTLY those `n` lines, unchanged —
        // see AllowFor/hitDigest/reportBuriedDecisions for why the assertion is
        // the hit set's identity and not merely its size. An id never contains
        // a colon, so the FIRST colon ends it and the remainder is `<n>:<hex>`.
        // Resolved same as --arc: a bad id is a hard error, not a silent no-op.
        var allow_for: std.ArrayList(AllowFor) = .empty;
        defer allow_for.deinit(self.gpa);
        for (allow_for_raw.items) |raw| {
            const bad_value = "trk: --allow-buried-decisions-for needs '<id>:<n>:<digest>' " ++
                "(the task's expected hit count and hit-set digest, printed by the guard's own " ++
                "report), got '{s}'\n";
            const sep = std.mem.indexOfScalar(u8, raw, ':') orelse {
                try self.print(bad_value, .{raw});
                return error.UsageError;
            };
            const rest = raw[sep + 1 ..];
            const sep2 = std.mem.indexOfScalar(u8, rest, ':') orelse {
                try self.print(bad_value, .{raw});
                return error.UsageError;
            };
            const id = try self.resolve(raw[0..sep]);
            const n = try self.parseUsize(rest[0..sep2]);
            const digest = std.fmt.parseInt(u32, rest[sep2 + 1 ..], 16) catch {
                try self.print(bad_value, .{raw});
                return error.UsageError;
            };
            try allow_for.append(self.gpa, .{ .id = id, .count = n, .digest = digest });
        }

        // Decision guard. `archive` is the LAST actor that can see these bodies:
        // one line later every matched task is `archived`, which is hidden from
        // every view. It is also the only actor that sees the whole done queue at
        // that moment. So the check belongs here and nowhere else.
        const guard_mode: BuriedMode = if (dry_run) .preview else if (allow_buried) .override else .refuse;
        if (try self.reportBuriedDecisions(matched.items, guard_mode, allow_for.items)) {
            return error.UsageError;
        }

        // Build the changelog-bullet draft, GROUPED BY DESTINATION (01M2F8GBQ):
        // an explicit --out sends every task to one file, same as always;
        // otherwise each task's own tags are checked against `archive.routes`,
        // so a task whose gate/home differs from the rest of the batch (e.g. a
        // prism-library task next to an ordinary Enix-adoption one in the same
        // done queue) lands in ITS OWN changelog, in this SAME run — no manual
        // per-tag split, no ritual to remember. A repo with no `archive.routes`
        // configured always resolves to exactly one group (`archive_out`, or
        // stdout), which is byte-for-byte the prior single-destination
        // behavior. Groups are emitted in first-matched order, which is
        // deterministic because `matched` already is.
        const Group = struct {
            out: ?[]const u8,
            ids: std.ArrayList(Ulid) = .empty,
            draft: std.ArrayList(u8) = .empty,
        };
        var groups: std.ArrayList(Group) = .empty;
        defer {
            for (groups.items) |*g| {
                g.ids.deinit(self.gpa);
                g.draft.deinit(self.gpa);
            }
            groups.deinit(self.gpa);
        }
        for (matched.items) |id| {
            const t = self.store.get(id).?;
            const dest = try self.resolveDestination(out_path, t);
            var idx: ?usize = null;
            for (groups.items, 0..) |g, gidx| {
                if (optStrEql(g.out, dest)) {
                    idx = gidx;
                    break;
                }
            }
            const gi = idx orelse blk: {
                try groups.append(self.gpa, .{ .out = dest });
                break :blk groups.items.len - 1;
            };
            try groups.items[gi].ids.append(self.gpa, id);
            try self.appendArchiveBullet(&groups.items[gi].draft, id);
        }

        // Emit every group's draft BEFORE flipping state so the records are
        // out even if a state write fails partway. A real run APPENDS each
        // group to ITS file target under a dated run heading (a changelog
        // accumulates — truncating here once destroyed one); --dry-run
        // previews on stdout and never touches any file. When routing split
        // the batch into more than one destination, each stdout preview group
        // is labeled with its path so a dry run reads as more than one
        // undifferentiated list — with exactly one group (the common, no
        // `archive.routes` case) the preview is unlabeled, unchanged from
        // before this feature existed.
        var ts_buf: [32]u8 = undefined;
        const ms = Io.Timestamp.now(self.io, .real).toMilliseconds();
        const heading_date = fmtTs(ms, &ts_buf)[0..10];
        for (groups.items) |g| {
            if (dry_run) {
                if (groups.items.len > 1) {
                    try self.print("-- {s} --\n", .{g.out orelse "(stdout)"});
                }
                try self.write(g.draft.items);
            } else if (g.out) |p| {
                var chunk: std.ArrayList(u8) = .empty;
                defer chunk.deinit(self.gpa);
                try chunk.print(self.gpa, "## {s}\n\n", .{heading_date});
                try chunk.appendSlice(self.gpa, g.draft.items);
                try self.appendOutFile(p, chunk.items);
            } else {
                try self.write(g.draft.items);
            }
        }

        // Flip to archived (unless previewing). Recoverable until `trk compact`.
        if (!dry_run) {
            for (matched.items) |id|
                try self.store.append(.{ .setState = .{ .id = id, .state = .archived } });
        }

        // A summary per destination that actually received a file append (so
        // a stdout-only draft stays a clean paste, same as before this
        // feature existed).
        for (groups.items) |g| {
            const p = g.out orelse continue;
            if (dry_run) {
                try self.print("(dry run) {d} done task(s) would be archived; a real run appends to {s}\n", .{ g.ids.items.len, p });
            } else {
                try self.print("archived {d} task(s); appended -> {s}\n", .{ g.ids.items.len, p });
            }
        }
    }

    /// Resolve where task `t`'s changelog bullet belongs (01M2F8GBQ). An
    /// explicit `--out` overrides every configured route — the operator asked
    /// for one file, full stop, the same precedence `render`'s `--out`
    /// already uses. Otherwise each `archive.routes` entry names a tag and a
    /// destination; a task carrying that tag routes there. At most one
    /// configured route may match a given task: two matching is an authoring
    /// conflict in `.tracker/config.json` (which tag wins is not a runtime
    /// pick trk should make silently), so it is a hard error naming the task
    /// and both routes rather than a silent first-match. A task matching no
    /// route falls back to `archive_out` (or stdout), exactly as before
    /// `archive.routes` existed.
    fn resolveDestination(self: *Cli, out_path: ?[]const u8, t: Task) Error!?[]const u8 {
        if (out_path) |p| return p;
        var matched: ?[]const u8 = null;
        var matched_tag: ?[]const u8 = null;
        for (self.store.config.archive_routes) |route| {
            if (!hasTag(t, route.tag)) continue;
            if (matched) |_| {
                try self.print(
                    "trk: '{s}' matches two configured archive routes ('{s}' -> {s} and " ++
                        "'{s}' -> {s}) -- archive.routes in .tracker/config.json must route each " ++
                        "task to exactly one destination\n",
                    .{ t.title, matched_tag.?, matched.?, route.tag, route.out },
                );
                return error.UsageError;
            }
            matched = route.out;
            matched_tag = route.tag;
        }
        return matched orelse self.store.config.archive_out;
    }

    /// What the archive run intends to do about a decision-marker hit. Only the
    /// wording changes here; the caller enforces `.refuse`.
    const BuriedMode = enum {
        /// A real run with no override: hits are fatal.
        refuse,
        /// `--dry-run` — nothing is buried by a preview, so hits are information.
        preview,
        /// `--allow-buried-decisions` — the operator saw them and chose to proceed.
        override,
    };

    /// One `--allow-buried-decisions-for <id>:<n>:<digest>` value: exempt `id`,
    /// but only while it carries EXACTLY `n` marker hits AND those hits are
    /// still the SAME LINES the operator looked at, identified by `digest`
    /// (`hitDigest` over the matched lines). See `reportBuriedDecisions`.
    const AllowFor = struct { id: Ulid, count: usize, digest: u32 };

    /// Content identity of a task's decision-marker hit set: FNV-1a/32 over the
    /// matched lines in body order, each terminated by a newline. Rendered as 8
    /// lowercase hex characters in the `--allow-buried-decisions-for` value.
    ///
    /// This is the invariant the per-task escape actually needs, and a COUNT is
    /// not it (01M13JXWN). A cardinality assertion answers "did the number of
    /// hits change?", but what the operator asserted by naming an exemption is
    /// "I read THESE lines and none of them is a live fork" — and a
    /// count-preserving edit (delete one prose-shaped mention of `TODO`, append
    /// a real `OPEN QUESTION: ship the count or the digest?`) leaves the count
    /// at 15 while replacing the very thing that was reviewed. The exemption
    /// then still applies and the genuine fork is archived out of sight: the
    /// same scroll-past-and-bury failure the guard exists to prevent, one level
    /// further down. Counting more finely (marker-shaped vs prose-shaped
    /// sub-counts) only moves the seam — a marker-shaped line swapped for
    /// another marker-shaped line defeats that too. Identity is the honest
    /// check, so identity is what is asserted.
    ///
    /// The count is kept ALONGSIDE the digest even though the digest subsumes
    /// it: they cannot disagree in a dangerous direction (both must match), and
    /// `15 -> 16` is a diagnosis a human can read where a hash mismatch is only
    /// a verdict.
    ///
    /// Reordering the hit lines without changing any of them changes the digest
    /// and drops the exemption. That is a false positive, and the intended
    /// direction of the trade: a spurious refusal costs one re-look, a missed
    /// change is a permanent burial.
    pub fn hitDigest(lines: []const []const u8) u32 {
        var h = std.hash.Fnv1a_32.init();
        for (lines) |l| {
            h.update(l);
            h.update("\n");
        }
        return h.final();
    }

    /// Scan each closing body for decision markers and report every hit as
    /// `<short-id>  [<marker>] (<shape>)  <line>`. Returns true iff the run
    /// should be BLOCKED (the caller's cue to return `error.UsageError`) —
    /// never merely "anything matched", since `exempt` can make a hit non-fatal.
    ///
    /// `exempt` is the `<id>:<n>:<digest>` list from
    /// `--allow-buried-decisions-for` (01M12ZG5ER, tightened by finding 4 on
    /// 2026-08-27 and again by 01M13JXWN on 2026-08-31): a hit on one of
    /// these ids is still REPORTED (transparency — the operator should see
    /// what they exempted) and is non-fatal ONLY while that task's ACTUAL hit
    /// count still equals the declared `n` AND its actual hit CONTENT still
    /// hashes to the declared `digest`. This is the per-task escape that
    /// removes the all-or-nothing pressure `--allow-buried-decisions`
    /// (whole-run override, `mode == .override`) creates: one task whose body
    /// legitimately discusses the guard's own marker vocabulary (a meta-task
    /// like 01M12D4EV) should not force the operator to wave through every
    /// OTHER hit in the same done queue, which is exactly how a genuine buried
    /// fork gets missed later.
    ///
    /// The exemption value is an ASSERTION, not a label (the `enixedit` `count`
    /// convention): a bare per-task exemption with no assertion would exempt
    /// EVERY marker line the task ever grows, including one appended AFTER the
    /// operator looked and exempted it — the exact scroll-past failure the
    /// guard exists to prevent, one level down, because the operator can no
    /// longer distinguish "the 15 lines I already saw" from "the 16th, added
    /// since". Naming the hit set forces a re-look: any change to it — a hit
    /// added, removed, OR swapped for a different one at the same cardinality —
    /// makes the declaration stop matching, and the exemption stops applying to
    /// that task; every one of its hits reverts to fatal under `.refuse`,
    /// printed with a mismatch note rather than the exempted tag. What is
    /// asserted is the hit set's IDENTITY (`hitDigest`), not merely its size;
    /// see `hitDigest` for why a count alone was not enough.
    ///
    /// The declaration is discoverable, never hand-counted: every non-exempt
    /// task in the report prints the exact ready-to-paste
    /// `<short-id>:<n>:<digest>` for its current hits.
    ///
    /// This is deliberately NOT solved by sharpening the content heuristic
    /// (`isFilenamePosition`'s filename/path shape check): the meta body's
    /// markers sit in a comma list glued to no path syntax, so no reliable
    /// syntactic signal distinguishes it from a genuine marker written with a
    /// slightly different shape (an em dash instead of a colon, say) — and a
    /// false negative there is a silent, permanent burial, while a false
    /// positive is only an annoyance. That asymmetry is why the hit-set
    /// assertion — not a smarter heuristic — is the fix; the heuristic still
    /// contributes a REPORTING-only refinement (see `isMarkerShaped`) that
    /// labels each hit `marker-shaped` (colon-glued to content, the genuine
    /// shape) vs `prose-shaped` (the meta-discussion shape), which does not
    /// change fatality but makes a newly-added 16th hit stand out among 15
    /// already-seen prose-shaped ones.
    ///
    /// A real run REFUSES rather than warning, on the same reasoning that ruled
    /// hard-removal over deprecation for `--body`: a warning inside a bulk
    /// archive run scrolls past in an agent's tool output, and the thing it
    /// failed to stop is a permanent burial.
    fn reportBuriedDecisions(self: *Cli, ids: []const Ulid, mode: BuriedMode, exempt: []const AllowFor) Error!bool {
        const markers = self.store.config.decision_markers orelse
            tracker.store.default_decision_markers;
        if (markers.len == 0) return false; // explicitly disabled via config

        // The full live id set, for `lineCitesLiveTask` -- a citation can name
        // ANY task, not just one in this run's `ids` (which is the DONE subset
        // about to archive). Fetched once per archive run, not per line.
        const all_ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(all_ids);

        const Hit = struct { marker: []const u8, line: []const u8 };

        var hits: usize = 0;
        var fatal: usize = 0; // hits NOT covered by mode/exempt -- these block a refuse run
        var mismatched_tasks: usize = 0; // exempted ids whose declared count no longer matches
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.body.len == 0) continue;

            // Collect this task's hits FIRST, so the count assertion is judged
            // against its real, current total -- not the count the operator
            // declared, which may now be stale.
            var task_hits: std.ArrayList(Hit) = .empty;
            defer task_hits.deinit(self.gpa);
            var lines = std.mem.splitScalar(u8, t.body, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                for (markers) |m| {
                    if (m.len == 0 or !containsMarker(line, m)) continue;
                    // 01M29VWW9: a marker glued to a LIVE task id names the
                    // fork's actual carrier -- "follow-ons filed: 01M296E8F
                    // (scott-decision)" is a citation, not a burial, because
                    // archiving THIS task cannot lose a fork that lives at
                    // that other id. Silent: not a hit, no report, no
                    // exemption needed. A marker with no id, or one naming an
                    // archived/nonexistent/self id, falls through unchanged.
                    if (self.lineCitesLiveTask(line, id, all_ids)) break;
                    try task_hits.append(self.gpa, .{ .marker = m, .line = line });
                    break; // one report per line, whichever marker hit first
                }
            }
            if (task_hits.items.len == 0) continue;

            // Content identity of THIS task's current hit set, judged against
            // the declaration. Built from the same `task_hits` the fatality
            // loop below iterates, so the digest can never describe a
            // different set of lines than the one being reported.
            var hit_lines: std.ArrayList([]const u8) = .empty;
            defer hit_lines.deinit(self.gpa);
            for (task_hits.items) |h| try hit_lines.append(self.gpa, h.line);
            const actual_digest = hitDigest(hit_lines.items);

            var declared: ?AllowFor = null;
            for (exempt) |e| {
                if (e.id.eql(id)) {
                    declared = e;
                    break;
                }
            }
            const count_matches = declared != null and declared.?.count == task_hits.items.len;
            const digest_matches = declared != null and declared.?.digest == actual_digest;
            // .override (--allow-buried-decisions, bare) already waves through
            // the whole run, so every id is exempt under it; per-task exemption
            // only has teeth under .refuse/.preview, and only while BOTH the
            // count and the hit-set digest still match what was declared.
            const is_exempt = mode == .override or (count_matches and digest_matches);
            const named_but_stale = declared != null and !(count_matches and digest_matches);
            // The count-preserving swap (01M13JXWN) is the case a pure count
            // assertion missed, so it says so by name rather than reporting a
            // generic mismatch the operator would read as "I miscounted".
            const swapped_at_same_count = named_but_stale and count_matches;
            if (named_but_stale) mismatched_tasks += 1;

            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            for (task_hits.items) |h| {
                if (hits == 0) {
                    try self.warn.print(self.gpa, "trk: {s}: task bodies about to be archived carry DECISION markers. " ++
                        "`archived` is hidden from every view, so these lines are graduated out of sight " ++
                        "with the work:\n", .{if (mode == .refuse) "refusing" else "note"});
                }
                hits += 1;
                if (!is_exempt) fatal += 1;
                const shape = if (isMarkerShaped(h.line, h.marker)) "marker-shaped" else "prose-shaped";
                const tag = if (is_exempt and mode != .override)
                    "  (exempted: --allow-buried-decisions-for)"
                else if (swapped_at_same_count)
                    "  (--allow-buried-decisions-for: same hit COUNT, different hit CONTENT -- a line was swapped since that digest was named; exemption does NOT apply)"
                else if (named_but_stale)
                    "  (--allow-buried-decisions-for count no longer matches -- exemption does NOT apply)"
                else
                    "";
                try self.warn.print(self.gpa, "  {s}  [{s}] ({s})  {s}{s}\n", .{ sid, h.marker, shape, h.line, tag });
            }
            // Make the declaration discoverable: the operator must never have
            // to hand-count lines or hand-hash them. Printed for every task
            // whose hits are not already covered, in both .refuse and .preview
            // (under .override nothing is being asserted, so it is noise).
            if (!is_exempt and mode != .override) {
                try self.warn.print(
                    self.gpa,
                    "      -> after reading the {d} line(s) above, exempt this task with: " ++
                        "--allow-buried-decisions-for {s}:{d}:{x:0>8}\n",
                    .{ task_hits.items.len, sid, task_hits.items.len, actual_digest },
                );
            }
        }
        if (hits == 0) return false;
        if (mismatched_tasks > 0) {
            try self.warn.print(self.gpa, "  {d} task(s) named via --allow-buried-decisions-for no longer carry the declared " ++
                "hit set -- a marker line was added, removed, or SWAPPED since that " ++
                "<n>:<digest> was named, so the exemption does not apply; re-read the lines and " ++
                "re-declare with the value printed above.\n", .{mismatched_tasks});
        }
        if (mode == .preview) {
            if (fatal == 0) {
                try self.warn.print(self.gpa, "  ({d} line(s), all exempted via --allow-buried-decisions-for -- a real run " ++
                    "would archive anyway)\n", .{hits});
            } else if (fatal < hits) {
                try self.warn.print(self.gpa, "  ({d} line(s), {d} exempted via --allow-buried-decisions-for; a real run would " ++
                    "still refuse the remaining {d})\n", .{ hits, hits - fatal, fatal });
            } else {
                try self.warn.print(self.gpa, "  ({d} line(s); a real run without --allow-buried-decisions would refuse)\n", .{hits});
            }
        } else if (mode == .override) {
            try self.warn.print(self.gpa, "  ({d} line(s); archiving anyway per --allow-buried-decisions — these are now hidden " ++
                "from every view)\n", .{hits});
        } else if (fatal == 0) {
            try self.warn.print(self.gpa, "  ({d} line(s), all exempted via --allow-buried-decisions-for — archiving anyway)\n", .{hits});
        } else {
            try self.warn.print(self.gpa, "  Split each decision out as its own task first (`trk add ...`), then archive.\n" ++
                "  To archive just the exempted task(s) anyway: trk archive --allow-buried-decisions-for <id>:<n>:<digest> (each printed above)\n" ++
                "  To archive everything anyway: trk archive --allow-buried-decisions\n" ++
                "  To change what counts: .tracker/config.json -> archive.decision_markers (a JSON array; [] disables)\n", .{});
        }
        return mode == .refuse and fatal > 0;
    }

    /// True if the occurrence at `haystack[start..end]` sits where a filename
    /// or path component would, rather than where a marker word would.
    /// Measured 2026-08-27 (task 01M12D4EV): the `TODO` marker fires on the
    /// literal string `docs/TODO.md`, which every task discussing the render
    /// projection contains in prose — 6 of 9 marker hits in one sweep, 0 of
    /// them a real buried decision. A pure alphanumeric word-boundary check
    /// does NOT fix this: `/` and `.` are already non-alphanumeric, so `TODO`
    /// inside `docs/TODO.md` already sits on a "word boundary" by that
    /// definition and would still match. What actually distinguishes the two
    /// is path/filename SHAPE, not word-ness:
    ///   - preceded by `/`      -- a path component (`docs/TODO.md`, `path/TODO`)
    ///   - followed by `.<letter>` -- a file extension (`TODO.md`, `TODO.zig`)
    /// A marker used AS a marker is prose: it is never glued to a path
    /// separator, and when it precedes a `.` that `.` ends a sentence, so the
    /// next character is whitespace or the end of the line -- never another
    /// letter, which is what an extension looks like. So this filter can only
    /// ever SUPPRESS a match at a path/filename-shaped position; it adds no
    /// path through which a genuine marker written as prose goes unseen.
    fn isFilenamePosition(haystack: []const u8, start: usize, end: usize) bool {
        if (start > 0 and haystack[start - 1] == '/') return true;
        if (end < haystack.len and haystack[end] == '.' and
            end + 1 < haystack.len and std.ascii.isAlphabetic(haystack[end + 1])) return true;
        return false;
    }

    /// End index (exclusive) of the first occurrence of `needle` in `haystack`
    /// (ASCII case-insensitive) that `isFilenamePosition` does NOT identify as
    /// a path/filename component, or `null` if there is none. Shared by
    /// `containsMarker` (fatality) and `isMarkerShaped` (reporting shape) so
    /// both judge the SAME occurrence. A line can contain the needle more than
    /// once (e.g. both a path mention and a real marker use), so a
    /// filename-shaped occurrence does not short-circuit the scan — it keeps
    /// looking for one that isn't.
    fn markerMatchEnd(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len > haystack.len) return null;
        var i: usize = 0;
        outer: while (i + needle.len <= haystack.len) : (i += 1) {
            for (needle, 0..) |c, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
            }
            if (!isFilenamePosition(haystack, i, i + needle.len)) return i + needle.len;
        }
        return null;
    }

    /// ASCII case-insensitive substring search for a decision marker, skipping
    /// any occurrence that `isFilenamePosition` identifies as a path/filename
    /// component rather than a marker word. The marker set mixes cases
    /// (`TODO`, `your call`), and a body written by a human or an agent will
    /// not match the configured casing reliably — matching case-sensitively
    /// would make the guard depend on shouting.
    fn containsMarker(haystack: []const u8, needle: []const u8) bool {
        return markerMatchEnd(haystack, needle) != null;
    }

    /// REPORTING-only classification (does not affect fatality — see
    /// `reportBuriedDecisions`'s doc comment for why the count assertion, not
    /// this heuristic, is what the guard's correctness rests on): a genuine
    /// marker use is glued to its content by a colon (`OPEN QUESTION: which
    /// cadence…`); a marker WORD merely discussed in running prose (a comma
    /// list, a sentence describing the guard itself, e.g. 01M12D4EV's "a
    /// scott-decision, OPEN QUESTION, FIX NOTE, your call, or TODO marker.")
    /// is not. This label exists to make a genuinely new hit stand out among a
    /// batch of already-seen prose-shaped noise — directly mitigating finding
    /// 4's failure shape — not to suppress or promote anything.
    fn isMarkerShaped(line: []const u8, marker: []const u8) bool {
        const end = markerMatchEnd(line, marker) orelse return false;
        var j = end;
        while (j < line.len and line[j] == ' ') : (j += 1) {}
        if (j >= line.len or line[j] != ':') return false;
        j += 1;
        while (j < line.len and line[j] == ' ') : (j += 1) {}
        return j < line.len;
    }

    /// Heuristic (finding 7, 01M12ZG5ER's flag surface): does `s` plausibly
    /// look like a ULID or a frozen/dynamic short-id (Crockford base32,
    /// case-insensitive, no I/L/O/U, length in a short-id's plausible range)?
    /// Used only to refuse a bare positional in `archive`'s arg list that would
    /// otherwise silently fall through to the title/body/tag search filter —
    /// the one place this fires for real is a second id typed after
    /// `--allow-buried-decisions-for` without repeating the flag, which
    /// otherwise exempts only the first id and narrows the archive set to a
    /// search term that (almost always) matches nothing, with no error at all.
    ///
    /// The Crockford-alphabet test ALONE is far too loose to hang a hard error
    /// on (01M13JXWS): the alphabet's only exclusions are I/L/O/U, so ordinary
    /// English words of 9+ letters routinely satisfy it — `statement`,
    /// `namespace`, `webserver`, `watermark`, `regressed`, `parameters`,
    /// `assessment`, `management` were all rejected, which made `trk archive
    /// statement` a hard failure on archive's ONLY search surface. The leading
    /// character settles it structurally rather than by degree: a trk id is a
    /// ULID or a prefix of one, and a ULID's first character encodes the top 5
    /// bits of a 48-bit millisecond timestamp — `0` for every id mintable
    /// before roughly the year 3084 — so a real id ALWAYS starts with a digit
    /// and no English word ever does.
    ///
    /// With that gate in place the hard error stays the right response, and
    /// deliberately so: a digit-leading Crockford token of 9+ characters in
    /// archive's positional slot is a misplaced or mistyped id essentially
    /// every time. Demoting it to "just treat an unresolvable one as a search
    /// term" was considered and rejected — a TYPO'd id is the likeliest
    /// remaining case, and that rule would turn it back into a silent
    /// zero-match archive run, which is the exact failure the error closed.
    fn looksIdShaped(s: []const u8) bool {
        if (s.len < min_short_mint or s.len > ulid.len) return false;
        if (!std.ascii.isDigit(s[0])) return false;
        for (s) |c| {
            const u = std.ascii.toUpper(c);
            const is_digit = u >= '0' and u <= '9';
            const is_letter = u >= 'A' and u <= 'Z' and u != 'I' and u != 'L' and u != 'O' and u != 'U';
            if (!is_digit and !is_letter) return false;
        }
        return true;
    }

    /// True if `line` names a LIVE task id, other than `self_id` -- the
    /// discriminator `reportBuriedDecisions` uses to tell a CITATION of a fork
    /// carried elsewhere from a genuine unresolved one (01M29VWW9, measured
    /// 2026-09-11: 19 of 20 audited marker hits were exactly this shape --
    /// "follow-ons filed: 01M296E8F (scott-decision)", "RISK 4 ... file a live
    /// scott-decision if it's genuinely still open"). Scans `line` for
    /// Crockford-shaped id tokens (split on non-alphanumerics) using the same
    /// range/alphabet test `looksIdShaped` uses for archive's own positional
    /// arg, then resolves each one the way `resolve` does -- case-insensitive
    /// prefix against `all_ids` -- but SILENTLY: no output, no error. A token
    /// that does not resolve, or resolves ambiguously (more than one task
    /// shares the prefix), is not a citation; it just doesn't count, and the
    /// line falls through to the ordinary fatal-hit path. So does a token that
    /// resolves to `self_id` (citing your own id is not evidence the fork
    /// lives elsewhere) or to a task whose state is `.archived` (already
    /// hidden from every view -- exactly the state a real burial produces, so
    /// it cannot be trusted as a live carrier).
    fn lineCitesLiveTask(self: *Cli, line: []const u8, self_id: Ulid, all_ids: []const Ulid) bool {
        var i: usize = 0;
        while (i < line.len) {
            if (!std.ascii.isAlphanumeric(line[i])) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < line.len and std.ascii.isAlphanumeric(line[j])) : (j += 1) {}
            const tok = line[i..j];
            defer i = j;
            if (!looksIdShaped(tok)) continue;
            var match: ?Ulid = null;
            var n_matches: usize = 0;
            for (all_ids) |cand| {
                if (prefixMatches(tok, &cand.text)) {
                    n_matches += 1;
                    if (match == null) match = cand;
                }
            }
            if (n_matches != 1) continue;
            const m = match.?;
            if (m.eql(self_id)) continue;
            const ct = self.store.get(m) orelse continue;
            if (ct.state == .archived) continue;
            return true;
        }
        return false;
    }

    /// One changelog-draft bullet for a graduated task: `- <title> #tags
    /// (doc#sec) (<short-id>)`. No checkbox — it is completed; the short id is
    /// kept for traceability back to the tracker/log.
    fn appendArchiveBullet(self: *Cli, buf: *std.ArrayList(u8), id: Ulid) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        try buf.print(gpa, "- {s}", .{t.title});
        for (t.tags.items) |tg| try buf.print(gpa, " #{s}", .{tg});
        for (t.docrefs.items) |dr| {
            const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
            if (dr.section_id) |sec| {
                try buf.print(gpa, " ({s}#{s})", .{ display, sec });
            } else {
                try buf.print(gpa, " ({s})", .{display});
            }
        }
        var sb: [ulid.len]u8 = undefined;
        try buf.print(gpa, " ({s})\n", .{try self.shortId(id, &sb)});
    }

    // ----------------------------------------------------------- doc

    /// `trk doc <set|list|resolve> ...` — doc-id registry commands.
    fn cmdDoc(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: doc needs a subcommand: set, unset, list, resolve\n");
            return error.UsageError;
        }
        const sub = args[0];
        const rest = args[1..];
        if (std.mem.eql(u8, sub, "set")) return self.cmdDocSet(rest);
        if (std.mem.eql(u8, sub, "unset")) return self.cmdDocUnset(rest);
        if (std.mem.eql(u8, sub, "list")) return self.cmdDocList(rest);
        if (std.mem.eql(u8, sub, "resolve")) return self.cmdDocResolve(rest);
        try self.print("trk: doc: unknown subcommand '{s}' (set|unset|list|resolve)\n", .{sub});
        return error.UnknownCommand;
    }

    /// `trk doc set <doc_id> <path>` — register/update a doc_id → path.
    fn cmdDocSet(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 2) {
            try self.write("trk: usage: trk doc set <doc_id> <path>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        const path = args[1];
        try self.store.append(.{ .setDocPath = .{ .doc_id = doc_id, .path = path } });
        try self.print("doc {s} -> {s}\n", .{ doc_id, path });
    }

    /// `trk doc unset <doc_id>` — unregister a doc_id. Emits the empty-path
    /// tombstone the fold removes the mapping on. Idempotent: unsetting an
    /// unregistered id is a no-op append, like `untag`/`undep`.
    fn cmdDocUnset(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 1) {
            try self.write("trk: usage: trk doc unset <doc_id>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        try self.store.append(.{ .setDocPath = .{ .doc_id = doc_id, .path = "" } });
        try self.print("doc {s} unregistered\n", .{doc_id});
    }

    /// `trk doc list` — print all doc_id -> path entries, sorted by doc_id.
    fn cmdDocList(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: doc list takes no arguments\n");
            return error.UsageError;
        }
        const n = self.store.doc_paths.count();
        if (n == 0) {
            try self.write("(no doc paths registered)\n");
            return;
        }
        // Collect keys and sort for deterministic output.
        const doc_ids = try self.gpa.alloc([]const u8, n);
        defer self.gpa.free(doc_ids);
        var it = self.store.doc_paths.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) doc_ids[i] = k.*;
        std.sort.pdq([]const u8, doc_ids, {}, lessThanStrCli);
        for (doc_ids) |doc_id| {
            const path = self.store.doc_paths.get(doc_id).?;
            try self.print("{s}  ->  {s}\n", .{ doc_id, path });
        }
    }

    /// `trk doc resolve <doc_id>` — print the path, non-zero exit if unregistered.
    fn cmdDocResolve(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 1) {
            try self.write("trk: usage: trk doc resolve <doc_id>\n");
            return error.UsageError;
        }
        const doc_id = args[0];
        if (self.store.docPath(doc_id)) |path| {
            try self.print("{s}\n", .{path});
        } else {
            try self.print("trk: doc '{s}' is not registered\n", .{doc_id});
            return error.NoSuchId;
        }
    }

    // ----------------------------------------------------------- next

    fn cmdNext(self: *Cli, args: []const []const u8) Error!void {
        var arc_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var json = false;
        // Search terms: repeated `--word` AND bare positionals, ANDed — so
        // `trk next prism` is "the ready frontier, prism only".
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        // `--not-tag <t>` (repeatable, ANDed exclusion): drop any task carrying
        // ANY of these tags. The backfilled negative blocker-tag vocabulary
        // (`metal`/`scott-testing`/`scott-decision`) makes the autonomous-
        // eligible bucket one bare command:
        //   trk next --not-tag metal --not-tag scott-testing --not-tag scott-decision
        var not_tags: std.ArrayList([]const u8) = .empty;
        defer not_tags.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.eql(u8, args[i], "--not-tag")) {
                try not_tags.append(self.gpa, try self.flagVal(args, &i, "--not-tag"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                try words.append(self.gpa, args[i]);
            }
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;

        const ready = try self.store.next(self.gpa);
        defer self.gpa.free(ready);

        // If filtering by arc, precompute its member set once.
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| members = try self.store.membersOf(self.gpa, a);

        if (json) try self.write("[");
        var shown: usize = 0;
        for (ready) |id| {
            if (members) |m| {
                if (!containsId(m, id)) continue;
            }
            const t = self.store.get(id).?;
            if (hasAnyTag(t, not_tags.items)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            if (limit) |lim| {
                if (shown >= lim) break;
            }
            if (json) {
                if (shown != 0) try self.write(",");
                try self.appendTaskJson(id, arc_id);
            } else {
                try self.printTaskLine(id, arc_id);
            }
            shown += 1;
        }
        if (json) {
            try self.write("]\n");
        } else if (shown == 0) {
            try self.write("(nothing ready)\n");
        }
    }

    /// `<short-id>  [<arc-seq>/<prio>]  <title>` — `next`/`list` one-liner.
    /// `arc_id` (if given) selects which arc's seq to show; otherwise the best.
    /// EITHER column prints `-` when unset: no `in` edge for the seq, stored
    /// `0` for the priority. A literal `0` there used to read as a real rank
    /// while ordering treated it as unset, so the two disagreed on screen.
    fn printTaskLine(self: *Cli, id: Ulid, arc_id: ?Ulid) !void {
        const t = self.store.get(id).?;
        const seq = self.seqFor(id, arc_id);
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        var seq_buf: [16]u8 = undefined;
        var pri_buf: [16]u8 = undefined;
        const seq_txt = if (seq) |s| try std.fmt.bufPrint(&seq_buf, "{d}", .{s}) else "-";
        const pri_txt = if (t.priority != 0)
            try std.fmt.bufPrint(&pri_buf, "{d}", .{t.priority})
        else
            "-";
        try self.print("{s}  [{s}/{s}]  {s}\n", .{ sid, seq_txt, pri_txt, t.title });
    }

    /// The arc-seq to display for a task: if `arc_id` is given, that arc's seq;
    /// else the best (lowest) seq across all arcs the task carries an `in` for.
    fn seqFor(self: *Cli, id: Ulid, arc_id: ?Ulid) ?i32 {
        var best: ?i32 = null;
        for (self.store.ins.items) |e| {
            if (!e.task.eql(id)) continue;
            if (arc_id) |a| {
                if (!e.arc.eql(a)) continue;
                return e.seq;
            }
            if (best == null or e.seq < best.?) best = e.seq;
        }
        return best;
    }

    // ----------------------------------------------------------- list

    fn cmdList(self: *Cli, args: []const []const u8) Error!void {
        var arc_filter: ?[]const u8 = null;
        var no_arc = false;
        var state_filter: ?State = null;
        var tag_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var json = false;
        // Search terms: each repeated `--word` AND each bare positional. ANDed.
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        // `--not-tag <t>` (repeatable, ANDed exclusion) — see `cmdNext`'s copy
        // of this doc for the motivating case (the autonomous-eligible bucket).
        var not_tags: std.ArrayList([]const u8) = .empty;
        defer not_tags.deinit(self.gpa);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--no-arc")) {
                no_arc = true;
            } else if (std.mem.eql(u8, args[i], "--state")) {
                const sv = try self.flagVal(args, &i, "--state");
                state_filter = State.fromString(sv) orelse {
                    try self.print("trk: '{s}' is not a state\n", .{sv});
                    return error.BadState;
                };
            } else if (std.mem.eql(u8, args[i], "--tag")) {
                tag_filter = try self.flagVal(args, &i, "--tag");
            } else if (std.mem.eql(u8, args[i], "--not-tag")) {
                try not_tags.append(self.gpa, try self.flagVal(args, &i, "--not-tag"));
            } else if (std.mem.eql(u8, args[i], "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            } else {
                // Bare positional = a search term (shorthand for `--word`).
                try words.append(self.gpa, args[i]);
            }
        }
        if (arc_filter != null and no_arc) {
            try self.write("trk: --arc and --no-arc are mutually exclusive\n");
            return error.UsageError;
        }
        const arc_id: ?Ulid = if (arc_filter) |a| try self.resolve(a) else null;
        var members: ?[]Ulid = null;
        defer if (members) |m| self.gpa.free(m);
        if (arc_id) |a| {
            members = try self.store.membersOf(self.gpa, a);
        } else if (no_arc) {
            members = try self.store.arcless(self.gpa);
        }

        // Deterministic: iterate sorted ids (in-memory query over the fold).
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        if (json) try self.write("[");
        var shown: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (state_filter) |sf| {
                if (t.state != sf) continue;
            } else if (t.state == .archived) {
                // Archived = retired to the changelog; hidden unless asked for
                // explicitly (`--state archived`) so the live list stays clean.
                continue;
            }
            if (members) |m| if (!containsId(m, id)) continue;
            if (tag_filter) |tf| if (!hasTag(t, tf)) continue;
            if (hasAnyTag(t, not_tags.items)) continue;
            if (!allWordsMatch(t, words.items)) continue;
            if (limit) |lim| if (shown >= lim) break;
            if (json) {
                if (shown != 0) try self.write(",");
                try self.appendTaskJson(id, arc_id);
            } else {
                try self.printListLine(id);
            }
            shown += 1;
        }
        if (json) {
            try self.write("]\n");
        } else if (shown == 0) {
            try self.write("(no matching tasks)\n");
        }
    }

    /// list one-liner: `<state-marker> <short-id>  <title>  #tags`.
    fn printListLine(self: *Cli, id: Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        try self.print("{s} {s}  {s}", .{ stateMarker(t.state), try self.shortId(id, &sb), t.title });
        for (t.tags.items) |tg| try self.print("  #{s}", .{tg});
        if (t.holder) |h| {
            var tb: [32]u8 = undefined;
            try self.print("  (held by {s} since {s})", .{ h, fmtTs(t.lease_ts, &tb) });
        }
        try self.write("\n");
    }

    // ----------------------------------------------------------- render (markdown)

    fn cmdRender(self: *Cli, args: []const []const u8) Error!void {
        var out_path: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--out")) {
                out_path = try self.flagVal(args, &i, "--out");
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{args[i]});
                return error.UnknownFlag;
            }
        }

        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(self.gpa);
        try self.renderMarkdown(&md);

        // Precedence: explicit --out > config render.out > stdout.
        const effective = out_path orelse self.store.config.render_out;
        if (effective) |p| {
            try self.writeOutFile(p, md.items);
            try self.print("wrote {d} bytes to {s}\n", .{ md.items.len, p });
        } else {
            try self.write(md.items);
        }
    }

    /// Build the TODO.md-style markdown projection into `buf`. Deterministic:
    /// arcs ordered by their root task's (priority, id); tasks within an arc in
    /// `next`/seq order (then id); a trailing "Arc-less" section. Writer-
    /// parameterized (a buffer) so it's testable without disk.
    pub fn renderMarkdown(self: *Cli, buf: *std.ArrayList(u8)) Error!void {
        const gpa = self.gpa;
        try buf.print(gpa,
            \\# TODO — remaining work
            \\
            \\> Generated by `trk render` from the in-repo issue tracker (`.tracker/`). Do not edit by hand —
            \\> mutate via `trk add`/`dep`/`in`/`edit`/`state` and regenerate.
            \\
            \\
        , .{});

        // Arc-less drift: surfaced every regeneration so it can't go unnoticed
        // for weeks (`trk list --no-arc` for the list itself).
        try buf.print(gpa, "> Arc-less drift: {d} remaining task(s) belong to no arc (`trk list --no-arc`).\n\n", .{
            try self.arclessRemainingCount(),
        });

        // Collect arcs = every id `isArc` is true for (declared, `in`-target, or
        // back-compat `arc:` tag). Sort by (root prio, id).
        const arcs = try self.collectArcs();
        defer gpa.free(arcs);

        // Track which tasks have been printed under some arc, to build Arc-less.
        var printed = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer printed.deinit(gpa);

        // Pre-count how many arc sections will list each task: a task shared by
        // several arcs is listed in full exactly once (anchored), and every
        // later listing links back to it instead of repeating the body. Arc
        // order is deterministic, so "first" is stable across renders.
        var listing_count = std.AutoHashMapUnmanaged([ulid.len]u8, u32){};
        defer listing_count.deinit(gpa);
        for (arcs) |arc| {
            const members = try self.store.membersOf(gpa, arc);
            defer gpa.free(members);
            for (members) |id| {
                if (!isRemaining(self.store.get(id).?.state)) continue;
                if (self.store.isArc(id)) continue;
                const gop = try listing_count.getOrPut(gpa, id.text);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }

        for (arcs) |arc| {
            const arc_t = self.store.get(arc).?;
            try buf.print(gpa, "## {s}", .{arc_t.title});
            var asb: [ulid.len]u8 = undefined;
            const arc_short = try self.shortId(arc, &asb);
            try buf.print(gpa, "  ({s})\n", .{arc_short});
            // The arc's OWN body — the goal's rationale, and the prose most
            // worth reading in the section it heads. It was dropped entirely
            // until 2026-08-26: an arc renders as a heading rather than a
            // bullet, so it never reached `renderTaskBullet`, the only place
            // that had ever printed a body. No list-item indent, since a `##`
            // section's prose is document-level.
            try self.renderBody(buf, arc_t.body, "");
            try buf.print(gpa, "\n", .{});

            // Members ordered by (seq-in-this-arc, id) — direct `in` members
            // carry an explicit seq, a reachability-only member (a shared
            // prereq) sorts after them. Deterministic; see orderMembers.
            const members = try self.store.membersOf(gpa, arc);
            defer gpa.free(members);
            const ordered = try self.orderMembers(arc, members);
            defer gpa.free(ordered);

            // An arc with no renderable member left is a real, recurring shape
            // (2026-08-27, 01M0ZC286): work finished but the arc root never
            // closed, or a goal whose slices were never filed. Rendering a bare
            // `## title (id)` with nothing under it reads as "here is live work"
            // when there is none — so track whether anything actually printed
            // and, if not, say so explicitly instead of leaving a heading that
            // looks like an omission.
            var has_bullet = false;
            for (ordered) |id| {
                // TODO = only not-yet-built work: show open/blocked, never the
                // finished/abandoned states (done graduates to the CHANGELOG via
                // `trk archive`; dropped is won't-do; archived is already recorded).
                if (!isRemaining(self.store.get(id).?.state)) continue;
                // An arc is always represented by its own section header, never a
                // bullet — skip any arc root here (its own section, or another arc
                // that reaches it via a `needs` edge). Mark printed so it doesn't
                // fall into the Arc-less section.
                if (self.store.isArc(id)) {
                    try printed.put(gpa, id.text, {});
                    continue;
                }
                const listing: Listing = if (printed.contains(id.text))
                    .repeat
                else if ((listing_count.get(id.text) orelse 1) > 1)
                    .anchored
                else
                    .plain;
                try self.renderTaskBullet(buf, id, arc, listing);
                try printed.put(gpa, id.text, {});
                has_bullet = true;
            }
            if (!has_bullet) {
                try buf.print(gpa, "*(no open members under this arc)*\n", .{});
            }
            try buf.print(gpa, "\n", .{});
        }

        // Arc-less: every task printed by no arc section.
        const ids = try self.store.allIds(gpa);
        defer gpa.free(ids);
        var any_arcless = false;
        for (ids) |id| {
            if (printed.contains(id.text)) continue;
            if (!isRemaining(self.store.get(id).?.state)) continue;
            // An arc (declared, `in`-target, or back-compat `arc:` tag — the
            // unified `isArc`) is always represented by its own section above,
            // even with zero members — never list it as a stray Arc-less bullet.
            // (Belt-and-suspenders: `printed` already covers this for every
            // remaining-state arc root reachable from `collectArcs`, since it is
            // always its own first member; this check is the explicit backstop.)
            if (self.store.isArc(id)) continue;
            if (!any_arcless) {
                try buf.print(gpa, "## Arc-less\n\n", .{});
                any_arcless = true;
            }
            try self.renderTaskBullet(buf, id, null, .plain);
        }
        if (any_arcless) try buf.print(gpa, "\n", .{});
    }

    /// How a task appears in a render section. A task reachable from several
    /// arcs is listed everywhere it belongs, but its full detail (tags,
    /// doc-refs, body) appears exactly once: the first listing carries an HTML
    /// anchor (the full ULID — the only stable fragment target a markdown list
    /// item can have), and every repeat renders its short id as a link back.
    const Listing = enum { plain, anchored, repeat };

    /// One markdown bullet: `- [marker] <short-id> <title> #tags (doc#sec)`,
    /// followed by the body (if any) as a 2-space-indented block. The blank
    /// line before the block is load-bearing: without it, markdown lazy-
    /// continuation fuses the body's first line into the title paragraph.
    fn renderTaskBullet(self: *Cli, buf: *std.ArrayList(u8), id: Ulid, arc: ?Ulid, listing: Listing) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        const checkbox = stateCheckbox(t.state);
        const seq = self.seqFor(id, arc);
        switch (listing) {
            .plain => try buf.print(gpa, "- {s} `{s}`", .{ checkbox, sid }),
            .anchored => try buf.print(gpa, "- {s} <a id=\"{s}\"></a>`{s}`", .{ checkbox, &id.text, sid }),
            .repeat => {
                // Link back to the anchored first listing; keep the title (and
                // this arc's seq) for scanability, skip the repeated detail.
                try buf.print(gpa, "- {s} [`{s}`](#{s})", .{ checkbox, sid, &id.text });
                // seq 0 is the default (no explicit ordering) — omit it rather
                // than render the ABSENCE of ordering as noise. A genuine
                // non-zero seq uses "(seq N)", never bare "[N]": in markdown a
                // bare `[N]` is reference-link syntax with no definition, so it
                // rendered as an empty/broken anchor.
                if (seq) |s| if (s != 0) try buf.print(gpa, " (seq {d})", .{s});
                try buf.print(gpa, " {s}\n", .{t.title});
                return;
            },
        }
        if (seq) |s| if (s != 0) try buf.print(gpa, " (seq {d})", .{s});
        try buf.print(gpa, " {s}", .{t.title});
        for (t.tags.items) |tg| try buf.print(gpa, " #{s}", .{tg});
        for (t.docrefs.items) |dr| {
            // Resolve doc_id through the registry: use the path when registered,
            // fall back to the raw doc_id (so unregistered ids still render, no crash).
            const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
            if (dr.section_id) |sec| {
                try buf.print(gpa, " ({s}#{s})", .{ display, sec });
            } else {
                try buf.print(gpa, " ({s})", .{display});
            }
        }
        try buf.print(gpa, "\n", .{});

        try self.renderBody(buf, t.body, "  ");
    }

    /// Render a task-or-arc BODY beneath its heading/bullet. `indent` is the
    /// list-item continuation prefix ("  " under a bullet, "" under a `##`
    /// section heading, where the body is document-level prose and indenting it
    /// two spaces would be meaningless at best and a code block at worst).
    ///
    /// Factored out of `renderTaskBullet` (2026-08-26) because an ARC ROOT never
    /// went through that function at all: an arc renders as a `## title (id)`
    /// section and its own body was simply dropped. Measured at the time: 37 of
    /// 304 open tasks with a substantive body had that body appear NOWHERE in
    /// the projection, and the sampled ones were all arc roots — which are
    /// exactly the tasks whose body states a goal's rationale, so the omission
    /// hit the highest-value prose in the file.
    fn renderBody(self: *Cli, buf: *std.ArrayList(u8), body_raw: []const u8, indent: []const u8) Error!void {
        const gpa = self.gpa;
        const body = std.mem.trimEnd(u8, body_raw, "\n");
        if (body.len == 0) return;
        try buf.print(gpa, "\n", .{});
        // A body long enough to hide is wrapped in a `<details>` disclosure so
        // the projection reads as an outline of TITLES on GitHub (and any
        // HTML-rendering viewer), with the prose one click away. The raw bytes
        // are unchanged for the plain-text/agent reader — `cat TODO.md` still
        // shows every body in full, which is why the body is NOT dropped or
        // elided, only folded. A short single-line body is left inline: a
        // disclosure whose summary IS the whole body hides nothing.
        const collapse = !fitsInlineBody(body);
        if (collapse) {
            // On one line: `<details>` opens an HTML block that ends at the next
            // blank line, and the blank line after it is what puts the body back
            // into MARKDOWN parsing rather than raw HTML.
            try buf.print(gpa, "{s}<details><summary>", .{indent});
            try self.writeBodySummary(buf, body);
            try buf.print(gpa, "</summary>\n\n", .{});
        }
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) {
                try buf.print(gpa, "\n", .{});
            } else {
                try buf.print(gpa, "{s}", .{indent});
                // Neutralize a line-leading construct that would hijack the
                // DOCUMENT's own heading structure. Bodies are informally
                // markdown by convention and that stays true for everything
                // else — a leading `-` bullet list still renders as a list;
                // only heading-shaped lines are escaped. Leading whitespace is
                // skipped before testing: CommonMark allows up to 3 leading
                // spaces on an ATX heading, and inside a list item several MORE
                // still parse as a heading rather than an indented code block.
                const lead = leadingWhitespaceLen(line);
                const rest = line[lead..];
                if (isHeadingHazard(rest)) {
                    try buf.print(gpa, "{s}\\{s}\n", .{ line[0..lead], rest });
                } else {
                    try buf.print(gpa, "{s}\n", .{line});
                }
            }
        }
        // Blank line before the close: `</details>` must start its own HTML
        // block, and it keeps the caller's indent so a bullet's disclosure stays
        // INSIDE the list item instead of terminating it.
        if (collapse) try buf.print(gpa, "\n{s}</details>\n", .{indent});
        try buf.print(gpa, "\n", .{});
    }

    /// Byte cap on the `<summary>` teaser. Long enough to carry a real sentence
    /// fragment, short enough that a collapsed task stays one line at a normal
    /// width.
    const summary_max = 72;

    /// True if a body should be printed inline rather than folded into a
    /// `<details>`: one line, and short enough that the teaser would have been
    /// the whole of it anyway.
    fn fitsInlineBody(body: []const u8) bool {
        return std.mem.indexOfScalar(u8, body, '\n') == null and body.len <= summary_max;
    }

    /// The collapsed teaser: the body's first non-blank line, capped at
    /// `summary_max` bytes (backed off to a UTF-8 boundary, with an ellipsis
    /// when it was cut). `&` and `<` are entity-escaped — inside `<summary>`
    /// the text is HTML, not markdown, so an unescaped `<` in a body (a type
    /// parameter, a `<id>` placeholder, a stray tag) would be swallowed as
    /// markup and silently eat the rest of the teaser.
    fn writeBodySummary(self: *Cli, buf: *std.ArrayList(u8), body: []const u8) Error!void {
        const gpa = self.gpa;
        var first: []const u8 = "";
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) {
                first = trimmed;
                break;
            }
        }
        // A body of nothing but blank lines has no teaser to show; the bullet
        // still gets a disclosure, so give it a label rather than an empty one.
        if (first.len == 0) {
            try buf.print(gpa, "body", .{});
            return;
        }

        var cut = first.len;
        const truncated = cut > summary_max;
        if (truncated) {
            cut = summary_max;
            // Never split a code point: back off over continuation bytes.
            while (cut > 0 and (first[cut] & 0xC0) == 0x80) cut -= 1;
            // Prefer a word boundary when one is close, so the teaser doesn't
            // end mid-word; fall back to the hard cut.
            const floor = summary_max * 3 / 4;
            if (std.mem.lastIndexOfScalar(u8, first[0..cut], ' ')) |sp| {
                if (sp >= floor) cut = sp;
            }
        }
        for (first[0..cut]) |ch| switch (ch) {
            '&' => try buf.print(gpa, "&amp;", .{}),
            '<' => try buf.print(gpa, "&lt;", .{}),
            else => try buf.append(gpa, ch),
        };
        if (truncated) try buf.print(gpa, "…", .{});
    }

    /// Index of the first non-space/tab byte in `line` (== `line.len` if the
    /// line is all whitespace). Used to find where a hazard character sits so
    /// the escaping backslash can be inserted AT that point, not at column 0.
    fn leadingWhitespaceLen(line: []const u8) usize {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        return i;
    }

    /// True if `rest` (a line with leading whitespace already stripped) would
    /// be parsed as markdown heading structure, outranking the render's own
    /// `#`/`##` hierarchy: an ATX heading (`#`...`######` at line-start), or a
    /// setext underline (a line consisting of ONLY `=` or ONLY `-`
    /// characters, CommonMark also permits trailing whitespace on that line)
    /// — which, following a non-blank line, retroactively turns THAT line
    /// into an H1/H2. A setext-shaped line is flagged unconditionally (not
    /// only when a preceding line is known) since escaping it is harmless
    /// either way. List markers (`- item`, which always carry a space +
    /// content after the dash) and inline formatting are deliberately left
    /// alone.
    fn isHeadingHazard(rest: []const u8) bool {
        if (rest.len == 0) return false;
        if (rest[0] == '#') return true;
        const setext = std.mem.trimEnd(u8, rest, " \t");
        return setext.len != 0 and (isAllChar(setext, '=') or isAllChar(setext, '-'));
    }

    fn isAllChar(s: []const u8, c: u8) bool {
        for (s) |ch| {
            if (ch != c) return false;
        }
        return true;
    }

    // ----------------------------------------------------------- tree (ASCII)

    fn cmdTree(self: *Cli, args: []const []const u8) Error!void {
        var id_arg: ?[]const u8 = null;
        var json = false;
        var extra_positional = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (id_arg == null) {
                id_arg = a;
            } else {
                extra_positional = true;
            }
        }
        if (extra_positional) id_arg = null;
        const want = id_arg orelse {
            try self.write("trk: usage: trk tree <arc-or-task-id> [--json]\n");
            return error.UsageError;
        };
        // Same three-way verdict `show` gives (01M2M2K1J): live 0, COMPACTED 2,
        // absent 1. `tree` answering "no task matches" for an arc that was
        // built and graduated is the SAME misreading this task is about,
        // pointing at the root instead of at its members — so it gets the same
        // answer, and the arc's graduated members are listed under it.
        const mark = self.out.items.len;
        const root = self.resolve(want) catch |e| {
            if (e != error.NoSuchId) return e;
            switch (self.store.lookupTombstone(want)) {
                .none => return e,
                .ambiguous => |n| {
                    self.out.shrinkRetainingCapacity(mark);
                    try self.print("trk: prefix '{s}' matches no live task and {d} compacted ones:\n", .{ want, n });
                    for (self.store.tombstones.items) |*tb| {
                        if (!tombstoneCited(want, tb)) continue;
                        try self.print("  {s}  {s}\n", .{ tb.short orelse &tb.id.text, tb.title });
                    }
                    return error.AmbiguousId;
                },
                .one => |tb| {
                    self.out.shrinkRetainingCapacity(mark);
                    if (json) {
                        try self.tombstoneJsonOpen(tb);
                        try self.compactedMembersJson(tb.id);
                        try self.write("}\n");
                    } else {
                        try self.tombstoneRecord(tb);
                        try self.compactedMemberBlock(self.out, tb.id);
                        try self.tombstoneFooter(tb);
                    }
                    return error.CompactedId;
                },
            }
        };
        if (json) {
            var visited = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
            defer visited.deinit(self.gpa);
            try self.treeJson(root, true, &visited);
            try self.write("\n");
            return;
        }
        try self.renderTree(self.out, root);
    }

    /// ASCII prereq hierarchy rooted at `root`. If `root` is an arc (has direct
    /// `in` members), the arc's members nest under it as branches; each task's
    /// `needs`-prereqs nest recursively beneath it. DAG-safe via a visited set:
    /// a node reached a second time prints `(↑ seen)` instead of re-expanding,
    /// so a diamond/shared-prereq never loops. Writer-parameterized.
    pub fn renderTree(self: *Cli, buf: *std.ArrayList(u8), root: Ulid) Error!void {
        const gpa = self.gpa;
        var visited = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer visited.deinit(gpa);

        // Root line (no connector).
        const rt = self.store.get(root).?;
        var rsb: [ulid.len]u8 = undefined;
        const rsid = try self.shortId(root, &rsb);
        try buf.print(gpa, "{s} {s} {s}\n", .{ stateMarker(rt.state), rsid, rt.title });
        try visited.put(gpa, root.text, {});

        // Children = arc members (direct `in root`) ++ direct prereqs of root.
        // Members come first (the arc-as-root view), then prereqs.
        var children: std.ArrayList(Ulid) = .empty;
        defer children.deinit(gpa);
        var seen_child = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
        defer seen_child.deinit(gpa);
        for (self.store.ins.items) |e| {
            if (e.arc.eql(root)) {
                const gop = try seen_child.getOrPut(gpa, e.task.text);
                if (!gop.found_existing) try children.append(gpa, e.task);
            }
        }
        for (self.directPrereqs(root)) |p| {
            const gop = try seen_child.getOrPut(gpa, p.text);
            if (!gop.found_existing) try children.append(gpa, p);
        }
        // Deterministic sibling order.
        sortByArcSeqThenId(self, root, children.items);

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(gpa);
        for (children.items, 0..) |child, idx| {
            const last = idx == children.items.len - 1;
            try self.treeNode(buf, &prefix, child, last, &visited);
        }

        try self.compactedMemberBlock(buf, root);
    }

    /// The graduated half of an arc's membership: every member `trk compact`
    /// collected, recovered from the tombstone index (01M29P5T7).
    ///
    /// Emitted UNCONDITIONALLY when there is anything to emit, with no flag to
    /// turn it on. A `--archived` flag would leave the silence exactly where it
    /// hurt: the reader who was misled did not know to ask, because the empty
    /// tree gave him no reason to. Absence is only fixed by making it speak.
    ///
    /// Shaped so a graduated member CANNOT be skimmed as a live one, which is
    /// the same rule `showTombstone` follows: no `[x]`-style state marker, no
    /// box-drawing connector, every row prefixed `compacted:`, under a heading.
    /// And when the arc has no graduated members this writes NOTHING — a
    /// genuinely unsliced arc must still render as genuinely empty, or the fix
    /// has only moved the ambiguity.
    fn compactedMemberBlock(self: *Cli, buf: *std.ArrayList(u8), arc: Ulid) Error!void {
        const gpa = self.gpa;
        const members = try self.store.compactedMembers(gpa, arc);
        defer gpa.free(members);
        if (members.len == 0) return;

        try buf.print(gpa, "\ncompacted members ({d}) — built, closed, and GC'd out of the live store:\n", .{members.len});
        for (members) |tb| {
            try buf.print(gpa, "  compacted: {s}  was {s}  {s}\n", .{
                tb.short orelse &tb.id.text,
                tb.reason,
                if (tb.title.len != 0) tb.title else "(title not recorded)",
            });
        }
        try buf.print(gpa, "  These are NOT missing members: an arc whose live tree is empty has NOT been shown\n" ++
            "  to be unsliced. `trk show <id>` for any of them; the full record is in git history.\n", .{});
    }

    /// `compactedMemberBlock`'s machine half: `,"compacted_members":[...]`,
    /// always emitted at the root (empty array included) so a consumer branches
    /// on the array's LENGTH and not on whether the key exists. Named
    /// `compacted_members`, not `compacted`, because a tombstone root already
    /// carries `"compacted": true` in the same object.
    fn compactedMembersJson(self: *Cli, arc: Ulid) Error!void {
        const gpa = self.gpa;
        const members = try self.store.compactedMembers(gpa, arc);
        defer gpa.free(members);
        try self.write(",\"compacted_members\":[");
        for (members, 0..) |tb, i| {
            if (i != 0) try self.write(",");
            try self.write("{\"compacted\":true,\"id\":\"");
            try self.write(&tb.id.text);
            try self.write("\",\"short\":");
            if (tb.short) |s| try self.writeJsonString(s) else try self.write("null");
            try self.write(",\"title\":");
            try self.writeJsonString(tb.title);
            try self.write(",\"was\":");
            try self.writeJsonString(tb.reason);
            try self.print(",\"collected_ts\":{d}}}", .{tb.ts});
        }
        try self.write("]");
    }

    /// `trk tree --json`: nested `{id,short,title,state,children}` with the same
    /// child order as the text view (root: arc members then prereqs, by arc
    /// seq; below: prereqs by id). A node reached again carries `"seen":true`
    /// and no children, exactly where the text view prints `(↑ seen)`.
    fn treeJson(
        self: *Cli,
        id: Ulid,
        is_root: bool,
        visited: *std.AutoHashMapUnmanaged([ulid.len]u8, void),
    ) Error!void {
        const gpa = self.gpa;
        try self.taskRefOpen(id);
        if (visited.contains(id.text)) {
            try self.write(",\"seen\":true}");
            return;
        }
        try visited.put(gpa, id.text, {});

        var children: std.ArrayList(Ulid) = .empty;
        defer children.deinit(gpa);
        if (is_root) {
            var seen_child = std.AutoHashMapUnmanaged([ulid.len]u8, void){};
            defer seen_child.deinit(gpa);
            for (self.store.ins.items) |e| {
                if (e.arc.eql(id)) {
                    const gop = try seen_child.getOrPut(gpa, e.task.text);
                    if (!gop.found_existing) try children.append(gpa, e.task);
                }
            }
            for (self.directPrereqs(id)) |p| {
                const gop = try seen_child.getOrPut(gpa, p.text);
                if (!gop.found_existing) try children.append(gpa, p);
            }
            sortByArcSeqThenId(self, id, children.items);
        } else {
            try children.appendSlice(gpa, self.directPrereqs(id));
            std.sort.pdq(Ulid, children.items, {}, Ulid.lessThan);
        }

        try self.write(",\"children\":[");
        for (children.items, 0..) |c, i| {
            if (i != 0) try self.write(",");
            try self.treeJson(c, false, visited);
        }
        try self.write("]");
        // Root only: `children` at a non-root node is a prereq list, and a
        // graduated arc member is not a prereq of anything here.
        if (is_root) try self.compactedMembersJson(id);
        try self.write("}");
    }

    fn treeNode(
        self: *Cli,
        buf: *std.ArrayList(u8),
        prefix: *std.ArrayList(u8),
        id: Ulid,
        last: bool,
        visited: *std.AutoHashMapUnmanaged([ulid.len]u8, void),
    ) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        const connector = if (last) "└─ " else "├─ ";

        const already = visited.contains(id.text);
        try buf.print(gpa, "{s}{s}{s} {s} {s}", .{ prefix.items, connector, stateMarker(t.state), sid, t.title });
        if (already) {
            try buf.print(gpa, " (\u{2191} seen)\n", .{}); // ↑ seen — do not re-expand
            return;
        }
        try buf.print(gpa, "\n", .{});
        try visited.put(gpa, id.text, {});

        // Recurse into this task's direct prereqs.
        const prereqs = self.directPrereqs(id);
        if (prereqs.len == 0) return;

        // Extend the prefix: a vertical bar if this node has a following sibling,
        // else blank.
        const added: []const u8 = if (last) "   " else "\u{2502}  "; // "│  "
        const old_len = prefix.items.len;
        try prefix.appendSlice(gpa, added);
        defer prefix.shrinkRetainingCapacity(old_len);

        // Stable order of prereqs.
        const kids = try gpa.dupe(Ulid, prereqs);
        defer gpa.free(kids);
        std.sort.pdq(Ulid, kids, {}, Ulid.lessThan);
        for (kids, 0..) |k, idx| {
            const klast = idx == kids.len - 1;
            try self.treeNode(buf, prefix, k, klast, visited);
        }
    }

    /// `directPrereqs(id)` — the `to` of every `id needs to` edge. Returns a
    /// slice into a freshly-allocated array (caller-owned via the arena trick:
    /// we allocate on gpa but the caller in tree uses it transiently). To keep
    /// lifetimes simple we allocate + the caller dupes when recursing; here we
    /// return a gpa-owned slice the caller frees. Re-implemented as a helper
    /// returning a slice the caller must free is awkward across recursion, so we
    /// instead scan inline. NOTE: small graphs, O(E) per call is fine.
    fn directPrereqs(self: *Cli, id: Ulid) []const Ulid {
        // We can't return a stack array; reuse a scratch list owned by the Cli.
        self.prereq_scratch.clearRetainingCapacity();
        for (self.store.needs.items) |e| {
            if (e.from.eql(id)) self.prereq_scratch.append(self.gpa, e.to) catch return &.{};
        }
        return self.prereq_scratch.items;
    }

    // ----------------------------------------------------------- arc helpers

    /// Count of remaining (open/blocked) tasks in NO arc — the render header's
    /// drift number. Wraps `Store.arcless`, filtered to `isRemaining` (a
    /// done/dropped/archived arc-less task isn't "not yet sorted" drift, it's
    /// just finished).
    fn arclessRemainingCount(self: *Cli) Error!usize {
        const ids = try self.store.arcless(self.gpa);
        defer self.gpa.free(ids);
        var n: usize = 0;
        for (ids) |id| {
            if (isRemaining(self.store.get(id).?.state)) n += 1;
        }
        return n;
    }

    /// Every arc (every id `isArc` is true for — declared, an `in.arc` target,
    /// or a back-compat `arc:` tag), sorted by (effective root priority, id). This is
    /// what earns a task its own "## <title>" render section, INCLUDING a
    /// declared-but-zero-member arc (it renders as a header with no bullets).
    fn collectArcs(self: *Cli) Error![]Ulid {
        const gpa = self.gpa;
        const out = try self.store.arcRoots(gpa);
        const Ctx = struct {
            cli: *Cli,
            fn less(c: @This(), x: Ulid, y: Ulid) bool {
                const tx = c.cli.store.get(x).?;
                const ty = c.cli.store.get(y).?;
                const px = model.effectivePriority(tx.priority);
                const py = model.effectivePriority(ty.priority);
                if (px != py) return px < py;
                return x.order(y) == .lt;
            }
        };
        std.sort.pdq(Ulid, out, Ctx{ .cli = self }, Ctx.less);
        return out;
    }

    /// Order an arc's members by (seq-in-this-arc, id). Direct members carry an
    /// explicit seq; reachability-only members (a shared prereq) get the
    /// sentinel max so they sort after the explicitly-ordered ones.
    fn orderMembers(self: *Cli, arc: Ulid, members: []const Ulid) Error![]Ulid {
        const gpa = self.gpa;
        const out = try gpa.dupe(Ulid, members);
        const Ctx = struct {
            cli: *Cli,
            arc: Ulid,
            fn seqOf(c: @This(), id: Ulid) i64 {
                for (c.cli.store.ins.items) |e| {
                    if (e.task.eql(id) and e.arc.eql(c.arc)) return e.seq;
                }
                return std.math.maxInt(i64);
            }
            fn less(c: @This(), x: Ulid, y: Ulid) bool {
                const sx = c.seqOf(x);
                const sy = c.seqOf(y);
                if (sx != sy) return sx < sy;
                return x.order(y) == .lt;
            }
        };
        std.sort.pdq(Ulid, out, Ctx{ .cli = self, .arc = arc }, Ctx.less);
        return out;
    }

    // ----------------------------------------------------------- show

    /// Does citation `s` name tombstone `tb` — by full id, by frozen short id,
    /// or by a prefix of either? The predicate `Store.lookupTombstone` counts
    /// with; re-exposed here so the ambiguity listing prints exactly the rows
    /// that were counted (a listing computed by a DIFFERENT rule than the count
    /// is how "N matches" ends up printing a different number of lines).
    fn tombstoneCited(s: []const u8, tb: *const tracker.store.Tombstone) bool {
        return Store.citationMatches(s, &tb.id.text) or
            (tb.short != null and Store.citationMatches(s, tb.short.?));
    }

    /// The human view for an id that resolved in the TOMBSTONE index rather
    /// than the live store (01M2M2K1J).
    ///
    /// Deliberately NOT shaped like the live view. The whole defect this closes
    /// is two different facts rendering identically, so the fix must not create
    /// a third: every line here is prefixed `compacted:` or sits under a banner
    /// that says COMPACTED in the first three words, and there is no `state:
    /// open`-shaped line anyone could skim as live. A reader who sees this
    /// output and a reader who sees a live task cannot mistake one for the
    /// other even at a glance.
    ///
    /// Split into `tombstoneRecord` + `tombstoneFooter` so `tree` can slot its
    /// graduated-member listing BETWEEN them (01M29P5T7), rather than after a
    /// paragraph that reads like the end of the output. The halves are never
    /// printed alone — a footer with no record, or a record with no footer,
    /// would be a third way for this to read wrong.
    fn showTombstone(self: *Cli, tb: *const tracker.store.Tombstone) Error!void {
        try self.tombstoneRecord(tb);
        try self.tombstoneFooter(tb);
    }

    fn tombstoneRecord(self: *Cli, tb: *const tracker.store.Tombstone) Error!void {
        try self.print("COMPACTED — {s} existed and is no longer in the live store.\n\n", .{&tb.id.text});
        try self.print("id:        {s}\n", .{&tb.id.text});
        if (tb.short) |s| try self.print("short:     {s}\n", .{s});
        try self.print("title:     {s}\n", .{if (tb.title.len != 0) tb.title else "(not recorded)"});
        try self.print("was:       {s}\n", .{tb.reason});
        if (tb.arcs.len != 0) {
            try self.write("arcs:      ");
            for (tb.arcs, 0..) |arc, i| {
                if (i != 0) try self.write(" ");
                try self.print("{s}", .{&arc.text});
            }
            try self.write("\n");
        }
        if (tb.ts != 0) {
            var buf: [32]u8 = undefined;
            try self.print("collected: {s} UTC\n", .{fmtTs(tb.ts, &buf)});
        }
        try self.print("record:    {s}\n", .{tb.src});
    }

    fn tombstoneFooter(self: *Cli, tb: *const tracker.store.Tombstone) Error!void {
        try self.print(
            "\nThis is NOT a dangling citation: the id was real, the work closed, and `trk compact`\n" ++
                "physically GC'd the task out of .tracker/. Do not \"fix\" a reference to it. The full\n" ++
                "record — body, events, edges — is still in git history and in .tracker/backup/:\n" ++
                "  git log --all -p -- .tracker/{s} | grep {s}\n",
            .{ tracker.store.log_name, &tb.id.text },
        );
    }

    /// `--json` for a tombstone. Carries `"compacted": true` — a field the live
    /// view never emits — so a machine reader branches on a key rather than on
    /// the absence of one.
    fn showTombstoneJson(self: *Cli, tb: *const tracker.store.Tombstone) Error!void {
        try self.tombstoneJsonOpen(tb);
        try self.write("}\n");
    }

    /// `showTombstoneJson` without its closing brace + newline, so `tree --json`
    /// can add `"compacted_members"` to the same object (01M29P5T7).
    fn tombstoneJsonOpen(self: *Cli, tb: *const tracker.store.Tombstone) Error!void {
        try self.write("{\"compacted\":true,\"id\":\"");
        try self.write(&tb.id.text);
        try self.write("\",\"short\":");
        if (tb.short) |s| try self.writeJsonString(s) else try self.write("null");
        try self.write(",\"title\":");
        try self.writeJsonString(tb.title);
        try self.write(",\"was\":");
        try self.writeJsonString(tb.reason);
        try self.write(",\"arcs\":[");
        for (tb.arcs, 0..) |arc, i| {
            if (i != 0) try self.write(",");
            try self.print("\"{s}\"", .{&arc.text});
        }
        try self.write("],\"src\":");
        try self.writeJsonString(tb.src);
        try self.print(",\"collected_ts\":{d}", .{tb.ts});
    }

    /// `trk show <id>` — full task detail view.
    fn cmdShow(self: *Cli, args: []const []const u8) Error!void {
        var id_arg: ?[]const u8 = null;
        var raw_body = false;
        var json = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--body")) {
                raw_body = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (id_arg == null) {
                id_arg = a;
            } else {
                try self.write("trk: usage: trk show <id> [--body | --json]\n");
                return error.UsageError;
            }
        }
        const want = id_arg orelse {
            try self.write("trk: usage: trk show <id> [--body | --json]\n");
            return error.UsageError;
        };
        if (raw_body and json) {
            try self.write("trk: usage: trk show <id> [--body | --json]\n");
            return error.UsageError;
        }
        // A live miss is not yet a verdict: the id may have been COMPACTED
        // (01M2M2K1J). `resolve` has already appended its "no task matches"
        // line, so rewind `out` to the mark before printing the tombstone —
        // "no task matches" immediately followed by the task's record is the
        // confusing half of both answers rather than either one.
        const mark = self.out.items.len;
        const id = self.resolve(want) catch |e| {
            if (e != error.NoSuchId) return e;
            switch (self.store.lookupTombstone(want)) {
                .none => return e,
                .ambiguous => |n| {
                    self.out.shrinkRetainingCapacity(mark);
                    try self.print("trk: prefix '{s}' matches no live task and {d} compacted ones:\n", .{ want, n });
                    for (self.store.tombstones.items) |*tb| {
                        if (!tombstoneCited(want, tb)) continue;
                        try self.print("  {s}  {s}\n", .{ tb.short orelse &tb.id.text, tb.title });
                    }
                    return error.AmbiguousId;
                },
                .one => |tb| {
                    self.out.shrinkRetainingCapacity(mark);
                    if (raw_body) {
                        // `--body` is the READ HALF OF A PIPE (`trk show X
                        // --body | trk edit Y --replace-body -`). A tombstone
                        // has no body, and printing its record on stdout here
                        // would hand that pipe plausible-looking body bytes. So
                        // stdout stays EMPTY — which `--replace-body -` refuses
                        // outright — and the explanation goes to stderr.
                        try self.warn.print(
                            self.gpa,
                            "trk: {s} is COMPACTED — it existed and `trk compact` GC'd it out of the live " ++
                                "store, so there is no body to read. `trk show {s}` prints what the tombstone " ++
                                "index kept.\n",
                            .{ &tb.id.text, tb.short orelse &tb.id.text },
                        );
                        return error.CompactedId;
                    }
                    if (json) try self.showTombstoneJson(tb) else try self.showTombstone(tb);
                    return error.CompactedId;
                },
            }
        };
        const t = self.store.get(id).?;
        if (json) return self.showJson(id);

        if (raw_body) {
            // Verbatim body bytes, nothing else — the read half of a safe edit
            // round-trip: trk edit <id> --body "$(trk show <id> --body)".
            try self.write(t.body);
            if (t.body.len != 0 and t.body[t.body.len - 1] != '\n') try self.write("\n");
            return;
        }

        try self.print("id:       {s}\n", .{&id.text});
        try self.print("title:    {s}\n", .{t.title});
        try self.print("state:    {s}\n", .{t.state.toString()});
        if (t.holder) |h| {
            var tb: [32]u8 = undefined;
            try self.print("holder:   {s} (since {s} UTC)\n", .{ h, fmtTs(t.lease_ts, &tb) });
        }
        if (t.priority != 0)
            try self.print("priority: {d}\n", .{t.priority})
        else
            try self.print("priority: unset (ranks {d})\n", .{model.default_priority});

        // Tags
        try self.write("tags:     ");
        if (t.tags.items.len == 0) {
            try self.write("(none)\n");
        } else {
            for (t.tags.items, 0..) |tg, i| {
                if (i != 0) try self.write(" ");
                try self.print("#{s}", .{tg});
            }
            try self.write("\n");
        }

        // Body
        try self.write("body:\n");
        if (t.body.len == 0) {
            try self.write("  (empty)\n");
        } else {
            // Indent each line by 2 spaces.
            var it = std.mem.splitScalar(u8, t.body, '\n');
            while (it.next()) |line| try self.print("  {s}\n", .{line});
        }

        // Prereqs (tasks this task needs)
        try self.write("\nprereqs (needs):\n");
        {
            var found = false;
            for (self.store.needs.items) |e| {
                if (!e.from.eql(id)) continue;
                found = true;
                const pre = self.store.get(e.to).?;
                var sb: [ulid.len]u8 = undefined;
                if (self.store.isArc(e.to)) {
                    // The gate is the ROOT's state (the completion judgment);
                    // drain progress is shown as context, not as the gate.
                    const p = self.store.arcProgress(e.to);
                    try self.print("  {s} {s}  arc: {s}  ({d}/{d} done", .{
                        stateMarker(pre.state), try self.shortId(e.to, &sb), pre.title, p.done, p.total,
                    });
                    // `arcProgress` counts LIVE members only — it walks `ins`,
                    // and compaction deleted the edges along with the members
                    // (01M29P5T7). So a fully-built, fully-graduated arc reads
                    // `(0/0 done)`, which is what an unsliced one reads too.
                    // Appended only when non-zero: the common line must not
                    // grow a `+0` on every arc.
                    const gone = try self.store.compactedMembers(self.gpa, e.to);
                    defer self.gpa.free(gone);
                    if (gone.len != 0) try self.print(", +{d} compacted", .{gone.len});
                    try self.write(")\n");
                } else {
                    try self.print("  {s} {s}  {s}\n", .{
                        stateMarker(pre.state), try self.shortId(e.to, &sb), pre.title,
                    });
                }
            }
            if (!found) try self.write("  (none)\n");
        }

        // Dependents (tasks that need this one)
        try self.write("\ndependents (needs this):\n");
        {
            const rdeps = try self.store.reverseDeps(self.gpa, id);
            defer self.gpa.free(rdeps);
            if (rdeps.len == 0) {
                try self.write("  (none)\n");
            } else {
                for (rdeps) |dep_id| {
                    const dep_t = self.store.get(dep_id).?;
                    var sb: [ulid.len]u8 = undefined;
                    try self.print("  {s} {s}  {s}\n", .{
                        stateMarker(dep_t.state), try self.shortId(dep_id, &sb), dep_t.title,
                    });
                }
            }
        }

        // Arcs
        try self.write("\narcs:\n");
        {
            const arcs = try self.store.arcsOf(self.gpa, id);
            defer self.gpa.free(arcs);
            if (arcs.len == 0) {
                try self.write("  (none)\n");
            } else {
                for (arcs) |arc_id| {
                    const arc_t = self.store.get(arc_id).?;
                    var sb: [ulid.len]u8 = undefined;
                    const seq = self.seqFor(id, arc_id);
                    if (seq) |s| {
                        try self.print("  {s}  {s}  seq={d}\n", .{
                            try self.shortId(arc_id, &sb), arc_t.title, s,
                        });
                    } else {
                        try self.print("  {s}  {s}\n", .{
                            try self.shortId(arc_id, &sb), arc_t.title,
                        });
                    }
                }
            }
        }

        // Doc-refs
        try self.write("\ndoc-refs:\n");
        if (t.docrefs.items.len == 0) {
            try self.write("  (none)\n");
        } else {
            for (t.docrefs.items) |dr| {
                const display = self.store.docPath(dr.doc_id) orelse dr.doc_id;
                if (dr.section_id) |sec| {
                    try self.print("  {s}#{s}\n", .{ display, sec });
                } else {
                    try self.print("  {s}\n", .{display});
                }
            }
        }
    }

    /// `trk show <id> --json`: the same facts as the text view, as one object.
    fn showJson(self: *Cli, id: Ulid) Error!void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        try self.print("{{\"id\":\"{s}\",\"short\":\"{s}\",\"title\":", .{ &id.text, try self.shortId(id, &sb) });
        try self.writeJsonString(t.title);
        try self.print(",\"state\":\"{s}\",\"priority\":{d}", .{ t.state.toString(), t.priority });
        if (t.holder) |h| {
            try self.write(",\"holder\":");
            try self.writeJsonString(h);
            try self.print(",\"lease_ts\":{d}", .{t.lease_ts});
        }
        try self.write(",\"tags\":[");
        for (t.tags.items, 0..) |tg, i| {
            if (i != 0) try self.write(",");
            try self.writeJsonString(tg);
        }
        try self.write("],\"body\":");
        try self.writeJsonString(t.body);

        try self.write(",\"prereqs\":[");
        {
            var n: usize = 0;
            for (self.store.needs.items) |e| {
                if (!e.from.eql(id)) continue;
                if (n != 0) try self.write(",");
                n += 1;
                try self.taskRefOpen(e.to);
                if (self.store.isArc(e.to)) {
                    const p = self.store.arcProgress(e.to);
                    const gone = try self.store.compactedMembers(self.gpa, e.to);
                    defer self.gpa.free(gone);
                    // Always emitted, unlike the text view's conditional suffix:
                    // a machine reader wants a stable schema, a human wants a
                    // line that stays quiet when there is nothing to say.
                    try self.print(",\"arc_progress\":{{\"done\":{d},\"total\":{d},\"compacted\":{d}}}", .{ p.done, p.total, gone.len });
                }
                try self.write("}");
            }
        }
        try self.write("],\"dependents\":[");
        {
            const rdeps = try self.store.reverseDeps(self.gpa, id);
            defer self.gpa.free(rdeps);
            for (rdeps, 0..) |d, i| {
                if (i != 0) try self.write(",");
                try self.taskRefJson(d);
            }
        }
        try self.write("],\"arcs\":[");
        {
            const arcs = try self.store.arcsOf(self.gpa, id);
            defer self.gpa.free(arcs);
            for (arcs, 0..) |a, i| {
                if (i != 0) try self.write(",");
                try self.taskRefOpen(a);
                if (self.seqFor(id, a)) |seq| try self.print(",\"seq\":{d}", .{seq});
                try self.write("}");
            }
        }
        try self.write("],\"docrefs\":[");
        for (t.docrefs.items, 0..) |dr, i| {
            if (i != 0) try self.write(",");
            try self.write("{\"doc_id\":");
            try self.writeJsonString(dr.doc_id);
            if (dr.section_id) |sec| {
                try self.write(",\"section_id\":");
                try self.writeJsonString(sec);
            }
            if (self.store.docPath(dr.doc_id)) |path| {
                try self.write(",\"path\":");
                try self.writeJsonString(path);
            }
            try self.write("}");
        }
        try self.write("]}\n");
    }

    /// `{"id","short","title","state"}` for a task another object points at.
    fn taskRefJson(self: *Cli, id: Ulid) !void {
        try self.taskRefOpen(id);
        try self.write("}");
    }

    /// `taskRefJson` without its closing brace, for a caller adding fields.
    fn taskRefOpen(self: *Cli, id: Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        try self.print("{{\"id\":\"{s}\",\"short\":\"{s}\",\"title\":", .{ &id.text, try self.shortId(id, &sb) });
        try self.writeJsonString(t.title);
        try self.print(",\"state\":\"{s}\"", .{t.state.toString()});
    }

    // ----------------------------------------------------------- edit

    /// `trk edit <id> [--title <s>] [--replace-body <s>|--append-body <s>]
    /// [--add-tag <t>] [--rm-tag <t>] [--add-doc <d>] [--rm-doc <d>] [--priority <n>]`
    ///
    /// There is deliberately NO `--body`. A body edit has two directions and
    /// the tool's other paired mutations (`--add-tag`/`--rm-tag`,
    /// `--add-doc`/`--rm-doc`, `dep`/`undep`) all REFUSE a default, so the
    /// caller names the direction. `--body` was the one flag that implied one,
    /// and it implied the DESTRUCTIVE one — it is removed rather than
    /// deprecated, because an honored-with-a-warning replace still destroys the
    /// body while the warning scrolls past in an agent's tool output (task
    /// 01M0QJ8K4, six measured body losses).
    fn cmdEdit(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: usage: trk edit <id> [--title <s>] [--replace-body <s>|--append-body <s>]\n" ++
                "            [--add-tag <t> ...] [--rm-tag <t> ...] [--add-doc <d> ...] [--rm-doc <d> ...] [--priority <n>]\n");
            return error.MissingArgument;
        }
        const id = try self.resolve(args[0]);

        var new_title: ?[]const u8 = null;
        var body_text: ?[]const u8 = null;
        var body_append = false;
        var body_flag: []const u8 = "";
        var priority: ?i32 = null;
        // Set when the body flag's `-` read stdin into a fresh allocation (see bodyArg).
        var body_owned = false;
        defer if (body_owned) self.gpa.free(body_text.?);
        var add_tags: std.ArrayList([]const u8) = .empty;
        defer add_tags.deinit(self.gpa);
        var rm_tags: std.ArrayList([]const u8) = .empty;
        defer rm_tags.deinit(self.gpa);
        var add_docs: std.ArrayList([]const u8) = .empty;
        defer add_docs.deinit(self.gpa);
        var rm_docs: std.ArrayList([]const u8) = .empty;
        defer rm_docs.deinit(self.gpa);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--title")) {
                new_title = try self.flagVal(args, &i, "--title");
            } else if (std.mem.eql(u8, arg, "--body")) {
                // Removed, not deprecated: a hard parser error naming both
                // replacements is the only migration that repairs a call site
                // instead of annotating it.
                try self.write("trk: --body was REMOVED — a body edit must name its direction:\n" ++
                    "       --replace-body <s|->   overwrite the whole body (what --body used to do)\n" ++
                    "       --append-body  <s|->   add to it, keeping what is there\n");
                return error.UnknownFlag;
            } else if (std.mem.eql(u8, arg, "--replace-body") or std.mem.eql(u8, arg, "--append-body")) {
                if (body_text != null) {
                    try self.print("trk: {s} and {s}: pick one direction per edit\n", .{ body_flag, arg });
                    return error.UsageError;
                }
                body_flag = arg;
                body_append = std.mem.eql(u8, arg, "--append-body");
                const b = try self.bodyArg(arg, try self.flagVal(args, &i, arg));
                body_text = b.text;
                body_owned = b.owned;
            } else if (std.mem.eql(u8, arg, "--add-doc")) {
                try add_docs.append(self.gpa, try self.flagVal(args, &i, "--add-doc"));
            } else if (std.mem.eql(u8, arg, "--rm-doc")) {
                try rm_docs.append(self.gpa, try self.flagVal(args, &i, "--rm-doc"));
            } else if (std.mem.eql(u8, arg, "--add-tag")) {
                try add_tags.append(self.gpa, try self.flagVal(args, &i, "--add-tag"));
            } else if (std.mem.eql(u8, arg, "--rm-tag")) {
                try rm_tags.append(self.gpa, try self.flagVal(args, &i, "--rm-tag"));
            } else if (std.mem.eql(u8, arg, "--priority")) {
                priority = try self.parseI32(try self.flagVal(args, &i, "--priority"));
            } else {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            }
        }

        // At least one flag required.
        if (new_title == null and body_text == null and priority == null and
            add_tags.items.len == 0 and rm_tags.items.len == 0 and
            add_docs.items.len == 0 and rm_docs.items.len == 0)
        {
            try self.write("trk: edit needs at least one flag (--title / --replace-body / --append-body / " ++
                "--add-tag / --rm-tag / --add-doc / --rm-doc / --priority)\n");
            return error.UsageError;
        }

        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);

        if (new_title) |nt| {
            try self.store.append(.{ .setTitle = .{ .id = id, .title = nt } });
            try self.print("{s}: title -> {s}\n", .{ sid, nt });
        }
        if (body_text) |nb| try self.applyBodyEdit(id, sid, nb, body_append);
        for (add_tags.items) |tg| {
            try self.store.append(.{ .tag = .{ .id = id, .tag = tg } });
            try self.print("{s}: +#{s}\n", .{ sid, tg });
            try self.warnDeprecatedArcTag(id, tg);
        }
        for (rm_tags.items) |tg| {
            try self.store.append(.{ .untag = .{ .id = id, .tag = tg } });
            try self.print("{s}: -#{s}\n", .{ sid, tg });
        }
        if (priority) |p| {
            try self.store.append(.{ .setPriority = .{ .id = id, .priority = p } });
            try self.print("{s}: priority -> {d}\n", .{ sid, p });
        }
        for (add_docs.items) |d| {
            const ref = splitDocRef(d);
            try self.store.append(.{ .docref = .{ .id = id, .doc_id = ref.doc_id, .section_id = ref.section_id } });
            try self.print("{s}: +doc {s}\n", .{ sid, d });
        }
        for (rm_docs.items) |d| {
            // A `#section` suffix is accepted and IGNORED, so the flag round-trips
            // whatever `--add-doc` was given: one undocref clears every section
            // ref to that doc (see model.Op.undocref). Reported by doc id so the
            // output never claims a narrower removal than happened.
            const ref = splitDocRef(d);
            const had = self.taskHasDocRef(id, ref.doc_id);
            try self.store.append(.{ .undocref = .{ .id = id, .doc_id = ref.doc_id } });
            if (had) {
                try self.print("{s}: -doc {s}\n", .{ sid, ref.doc_id });
            } else {
                // Idempotent like --rm-tag, but say so: a silent success on a
                // typo'd doc id reads as "removed" when nothing was.
                try self.print("{s}: -doc {s} (no such ref; no-op)\n", .{ sid, ref.doc_id });
            }
        }
    }

    /// True iff `id` currently carries any docref to `doc_id` (section or not).
    fn taskHasDocRef(self: *Cli, id: Ulid, doc_id: []const u8) bool {
        const t = self.store.get(id) orelse return false;
        for (t.docrefs.items) |dr| {
            if (std.mem.eql(u8, dr.doc_id, doc_id)) return true;
        }
        return false;
    }

    /// Write a body edit, replace or append. The APPEND half is the reason this
    /// lives in trk at all: the current body is the fold of `snapshot.jsonl` and
    /// every `setBody` in `log.jsonl`, so a body last written before the most
    /// recent `compact` lives ONLY in the snapshot. An external read-modify-write
    /// helper that scans just the log sees an empty body and truncates the task
    /// (task 01M0QJ8K4 — measured, twice in one session). Only the tool can read
    /// its own state correctly.
    fn applyBodyEdit(self: *Cli, id: Ulid, sid: []const u8, text: []const u8, append: bool) Error!void {
        const current = if (self.store.get(id)) |t| t.body else "";

        if (!append) {
            // Byte-identical REPLACE warning, deliberately scoped to this
            // direction only. The 2026-08-21 case was a hand-built "append"
            // that overwrote with the same bytes: the write succeeded, added
            // nothing, and the silence let the task be re-worked twice. An
            // append that happens to be a no-op is a different, far less
            // interesting event, so warning there would be noise.
            if (std.mem.eql(u8, current, text)) {
                try self.warn.print(
                    self.gpa,
                    "trk: warning: {s}: --replace-body wrote a BYTE-IDENTICAL body — nothing changed. " ++
                        "If you meant to add to it, use --append-body.\n",
                    .{sid},
                );
            }
            try self.store.append(.{ .setBody = .{ .id = id, .body = text } });
            try self.print("{s}: body replaced ({d} bytes)\n", .{ sid, text.len });
            return;
        }

        // Append: blank line between the old body and the new text, so an
        // accumulated diagnosis trail stays readable as distinct entries. No
        // separator when there is nothing to separate from.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        if (current.len > 0) {
            try buf.appendSlice(self.gpa, current);
            // Exactly one blank line, whatever trailing newlines the body has.
            var end = buf.items.len;
            while (end > 0 and buf.items[end - 1] == '\n') end -= 1;
            buf.shrinkRetainingCapacity(end);
            try buf.appendSlice(self.gpa, "\n\n");
        }
        try buf.appendSlice(self.gpa, text);
        try self.store.append(.{ .setBody = .{ .id = id, .body = buf.items } });
        try self.print("{s}: body appended (+{d} bytes, now {d})\n", .{ sid, text.len, buf.items.len });
    }

    // ----------------------------------------------------------- log

    /// `trk log [<id>] [--limit <n>]` — event history, newest-last.
    fn cmdLog(self: *Cli, args: []const []const u8) Error!void {
        var id_filter: ?[]const u8 = null;
        var limit: ?usize = null;
        var json = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--limit")) {
                limit = try self.parseUsize(try self.flagVal(args, &i, "--limit"));
            } else if (std.mem.eql(u8, arg, "--json")) {
                json = true;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                try self.print("trk: unknown flag '{s}'\n", .{arg});
                return error.UnknownFlag;
            } else {
                // Positional: the id filter.
                if (id_filter != null) {
                    try self.write("trk: log takes at most one <id> positional argument\n");
                    return error.UsageError;
                }
                id_filter = arg;
            }
        }

        // Resolve the id filter if given (will error cleanly on NoSuchId).
        const filter_id: ?Ulid = if (id_filter) |s| try self.resolve(s) else null;

        const entries = try self.store.readLogEntries(self.gpa);
        defer {
            for (entries) |e| self.gpa.free(e.summary);
            self.gpa.free(entries);
        }

        // Filter by task id.
        var filtered: std.ArrayList(tracker.Store.LogEntry) = .empty;
        defer filtered.deinit(self.gpa);
        for (entries) |e| {
            if (filter_id) |fid| {
                const matches = e.task_id != null and e.task_id.?.eql(fid);
                if (!matches) continue;
            }
            try filtered.append(self.gpa, e);
        }

        // Apply limit (take last N = most-recent-last view with tail truncation).
        var start: usize = 0;
        if (limit) |lim| {
            if (filtered.items.len > lim) start = filtered.items.len - lim;
        }
        const to_print = filtered.items[start..];

        if (json) {
            try self.write("[");
            for (to_print, 0..) |e, n| {
                if (n != 0) try self.write(",");
                try self.print("{{\"ts\":{d},\"op\":\"{s}\",\"task_id\":", .{ e.ts, @tagName(e.op) });
                if (e.task_id) |tid| try self.print("\"{s}\"", .{&tid.text}) else try self.write("null");
                try self.write(",\"summary\":");
                try self.writeJsonString(e.summary);
                try self.write("}");
            }
            try self.write("]\n");
            return;
        }

        if (to_print.len == 0) {
            try self.write("(no events)\n");
            return;
        }

        for (to_print) |e| {
            var ts_buf: [32]u8 = undefined;
            const ts_str = fmtTs(e.ts, &ts_buf);
            try self.print("{s}  {s}  {s}\n", .{ ts_str, @tagName(e.op), e.summary });
        }
    }

    // ----------------------------------------------------------- stale

    /// `trk stale` — cross-reference: which currently-`open` tasks have their
    /// id cited in a LANDED commit message, but were never closed? The
    /// evidence for the dominant rot found in the 2026-07-30 reconciliation:
    /// not "the work landed under a different id" (a minority case) but
    /// simply that the implementing commit NAMED the id and nobody ran `trk
    /// state done` — the evidence was sitting in `git log` the whole time.
    ///
    /// Scans `git log --oneline` on the CURRENT branch's ancestry, DELIBERATELY
    /// not `--all`: `--all` walks every ref, including a parallel fan-out's
    /// unmerged worktree branches, and a hit there is not proof the work is at
    /// HEAD (a commit can cite an id from a branch nobody has merged) — see
    /// the `git log --all --grep` false-positive finding. `--stale` wants only
    /// LANDED evidence. Runs `git` with cwd set to the store root (the repo
    /// that houses `.tracker/`, which may differ from where `trk` itself
    /// lives — `main.zig`'s `discover.findRoot` already resolved `self.dir`
    /// to exactly that repo).
    ///
    /// Matches by exact TOKEN (a maximal run of ASCII alphanumerics), not raw
    /// substring: the log text is scanned once, and each token is looked up
    /// against an index of every open task's full id AND its displayed short
    /// id. Token (not substring) matching means a short id can never
    /// accidentally match as part of some longer, unrelated token.
    ///
    /// `submitted` tasks are deliberately EXCLUDED from the report: a
    /// submission already IS the self-reported "this commit completes it"
    /// signal this verb exists to surface for a task that never got one —
    /// flagging it again would just be noise on an item that is already in
    /// the awaiting-verification queue (`trk list --state submitted`). See
    /// `State.submitted`.
    ///
    /// Leased (`claimed`) tasks are INCLUDED. A lane's commits reach this
    /// branch's ancestry only when the lane merges, and its `submitted` line
    /// merges with them — so a landed citation on a task still leased means
    /// the lane merged without submitting, or wrote the pre-rename `claimed`
    /// to mean completion. Either way the task is stranded out of both `next`
    /// and the verification queue, which is exactly this report's rot.
    fn cmdStale(self: *Cli, args: []const []const u8) Error!void {
        if (args.len != 0) {
            try self.write("trk: usage: trk stale\n");
            return error.UsageError;
        }

        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "log", "--oneline" },
            .cwd = .{ .dir = self.dir },
        }) catch |e| {
            try self.print(
                "trk: stale: failed to run 'git log': {s} (is the store root a git repo, and is git on PATH?)\n",
                .{@errorName(e)},
            );
            return error.GitLogFailed;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const exited_ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!exited_ok) {
            try self.print("trk: stale: 'git log' failed: {s}\n", .{std.mem.trimEnd(u8, result.stderr, " \t\r\n")});
            return error.GitLogFailed;
        }

        // Citation index: every OPEN task's full id + its currently-displayed
        // short id -> the task id. gpa-owned keys (both `id.slice()` and
        // `shortId`'s buffer are transient).
        var index = std.StringHashMapUnmanaged(Ulid){};
        defer {
            var it = index.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            index.deinit(self.gpa);
        }
        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.state != .open and t.state != .claimed) continue; // submitted/done/blocked/dropped/archived: not this report's concern
            try index.put(self.gpa, try self.gpa.dupe(u8, id.slice()), id);
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            if (!std.mem.eql(u8, sid, id.slice())) {
                try index.put(self.gpa, try self.gpa.dupe(u8, sid), id);
            }
        }

        // Tokenize the whole log text once; on each match keep the FIRST hit
        // per task (git log is newest-first, so that's the most recent citation).
        var hits = std.AutoHashMapUnmanaged([ulid.len]u8, []const u8){};
        defer hits.deinit(self.gpa);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var tok_start: ?usize = null;
            var ci: usize = 0;
            while (ci <= line.len) : (ci += 1) {
                const is_alnum = ci < line.len and std.ascii.isAlphanumeric(line[ci]);
                if (is_alnum) {
                    if (tok_start == null) tok_start = ci;
                } else if (tok_start) |s| {
                    if (index.get(line[s..ci])) |task_id| {
                        const gop = try hits.getOrPut(self.gpa, task_id.text);
                        if (!gop.found_existing) gop.value_ptr.* = line;
                    }
                    tok_start = null;
                }
            }
        }

        if (hits.count() == 0) {
            try self.write("trk: stale: nothing — no open or claimed task is cited in a landed commit\n");
            return;
        }

        // Deterministic report order.
        const stale_ids = try self.gpa.alloc(Ulid, hits.count());
        defer self.gpa.free(stale_ids);
        {
            var it = hits.keyIterator();
            var idx: usize = 0;
            while (it.next()) |k| : (idx += 1) stale_ids[idx] = .{ .text = k.* };
        }
        std.sort.pdq(Ulid, stale_ids, {}, Ulid.lessThan);

        try self.print("trk: stale: {d} open or claimed task(s) cited in a landed commit but never closed:\n", .{stale_ids.len});
        for (stale_ids) |id| {
            const t = self.store.get(id).?;
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            const line = hits.get(id.text).?;
            try self.print("{s} {s}  {s}\n    cited in: {s}\n", .{ stateMarker(t.state), sid, t.title, line });
        }
    }

    // ----------------------------------------------------------- tombstones

    /// `trk tombstones [--rebuild | --verify] [--json]` — read, back-fill, and
    /// verify the completeness of the index of ids `compact` physically GC'd
    /// (01M2M2K1J). See `store.tombstones_name`.
    fn cmdTombstones(self: *Cli, args: []const []const u8) Error!void {
        var rebuild = false;
        var json = false;
        var verify = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--rebuild")) {
                rebuild = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, a, "--verify")) {
                verify = true;
            } else {
                try self.write("trk: usage: trk tombstones [--rebuild | --verify] [--json]\n");
                return error.UsageError;
            }
        }
        if (verify) {
            if (rebuild or json) {
                try self.write("trk: usage: trk tombstones --verify takes no other flags\n");
                return error.UsageError;
            }
            return self.verifyTombstoneIndex();
        }
        if (rebuild) try self.rebuildTombstones();

        if (json) {
            try self.write("[");
            for (self.store.tombstones.items, 0..) |*tb, i| {
                if (i != 0) try self.write(",");
                try self.showTombstoneJson(tb);
            }
            try self.write("]\n");
            return;
        }
        if (self.store.tombstones.items.len == 0) {
            // The hint is suppressed right after a rebuild: telling someone to
            // run the command they just ran reads as a failure, when in fact it
            // is the clean answer — nothing in this store was ever compacted
            // away. (Observed on trk's own tracker, 2026-09-16.)
            if (rebuild) {
                try self.write("trk: tombstones: none — nothing in this store's history was ever compacted away.\n");
            } else {
                try self.print(
                    "trk: tombstones: none recorded in .tracker/{s}. If this repo has ever run " ++
                        "`trk compact`, its already-compacted ids are recoverable — run " ++
                        "`trk tombstones --rebuild`.\n",
                    .{tracker.store.tombstones_name},
                );
            }
            return;
        }
        try self.print("trk: {d} compacted task(s) on record:\n", .{self.store.tombstones.items.len});
        for (self.store.tombstones.items) |*tb| {
            var buf: [32]u8 = undefined;
            try self.print("  {s}  {s:<9}  {s}\n      {s}  ({s})\n", .{
                tb.short orelse &tb.id.text,
                tb.reason,
                tb.title,
                &tb.id.text,
                if (tb.ts != 0) fmtTs(tb.ts, &buf) else tb.src,
            });
        }
    }

    /// id -> the best record recovered so far from a log-history replay.
    /// `title`/`reason` each carry the ts of the event they came from, so a
    /// later `setTitle`/`setState` wins regardless of the order the history
    /// walk hands them over. An id can (and for a "ghost" — see
    /// `scanLogHistoryForIds` — routinely does) end up with an entry whose
    /// `title`/`reason` never move off their zero-value defaults: it was
    /// referenced (an edge, a `setBody`, a `tag`, ...) but never NAMED by any
    /// committed event.
    const RebuildRec = struct {
        short: ?[]const u8 = null,
        title: []const u8 = "",
        title_ts: i64 = -1,
        reason: []const u8 = "unknown",
        reason_ts: i64 = -1,
    };

    /// Replay `.tracker/log.jsonl`'s FULL git history (`git log --all -p`) —
    /// the only surviving record of an id compacted before the tombstone index
    /// existed — and return one `RebuildRec` per distinct id ANY event in that
    /// history OWNS. Shared by `rebuildTombstones` (which entombs the result)
    /// and `verifyTombstoneIndex` (which only checks it against what is
    /// already live/entombed): one scan, one notion of "every id history ever
    /// carried", so the two can never drift into disagreeing about what that
    /// set is.
    ///
    /// WHY GIT AND NOT THE STORE: there is nothing else left. `compact` excludes
    /// the task from the snapshot and truncates the log, so no file under
    /// `.tracker/` mentions the id afterwards. `.tracker/backup/` holds only the
    /// last `compact.backup_retain` runs and is gitignored. Git history is where
    /// `scripts/dangling-tracker-id-lint.sh` recovers it, and this is that same
    /// scan — run ONCE and persisted, rather than once per question.
    ///
    /// `--all`, unlike `cmdStale`'s deliberately-ancestry-only scan: this asks
    /// "did this id EVER exist", and an id minted on a branch nobody merged
    /// still existed. A false LIVE would be dangerous; a false EXISTED is not —
    /// the record says plainly that it is gone.
    ///
    /// MEMBERSHIP is decided by `model.eventTaskIds` — the same "who does this
    /// event name" rule `compact`'s ghost detector (`!t.has_add`) relies on:
    /// one id for a scalar op, two for an edge (`dep`/`undep`/`in`/`unin`),
    /// none for `setDocPath` (it names a doc, not a task). TITLE/REASON
    /// recovery is a narrower, separate switch over just `add`/`setTitle`/
    /// `setShort`/`setState` (the only kinds that carry one) — but every id an
    /// EARLIER version of this function would have silently dropped when its
    /// history held only non-naming events is still returned here, with those
    /// fields at their defaults. That gap was not hypothetical:
    /// `01KVR2E1KTXC65HD5175N373AH`'s full committed history (verified by a
    /// direct `git log --all -p` read, 01M2N8WMD) is exactly `setBody` + `dep`
    /// — no `add`/`setTitle`/`setShort`/`setState` event anywhere — which is
    /// precisely `compact`'s "ghost" class: an id the fold only ever saw
    /// REFERENCED, never `add`ed. A compaction that predates the tombstone
    /// index (01M2M2K1J) is the one place a ghost's entombment depends on THIS
    /// scan recovering it, so membership must not be keyed on the title-
    /// bearing ops alone.
    ///
    /// Strings are allocated out of `ra` (caller-owned; must outlive the
    /// returned map). The map's own storage is `self.gpa` — the caller frees
    /// it with `.deinit(self.gpa)`.
    fn scanLogHistoryForIds(self: *Cli, ra: std.mem.Allocator) Error!std.AutoHashMapUnmanaged([ulid.len]u8, RebuildRec) {
        const log_path = tracker.store.tracker_subdir ++ "/" ++ tracker.store.log_name;
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "git", "log", "--all", "-p", "--no-color", "--", log_path },
            .cwd = .{ .dir = self.dir },
        }) catch |e| {
            try self.print(
                "trk: tombstones: failed to run 'git log': {s} (is the store root a git repo, and is git on PATH?)\n",
                .{@errorName(e)},
            );
            return error.GitLogFailed;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const exited_ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!exited_ok) {
            try self.print("trk: tombstones: 'git log' failed: {s}\n", .{std.mem.trimEnd(u8, result.stderr, " \t\r\n")});
            return error.GitLogFailed;
        }

        var recs = std.AutoHashMapUnmanaged([ulid.len]u8, RebuildRec){};
        errdefer recs.deinit(self.gpa);

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw| {
            // Only ADDED diff lines are log content; `-` lines are the same
            // content leaving (a compact's truncation) and `+++`/`---` are
            // headers. A log line is a JSON object, so require the brace.
            if (raw.len < 2 or raw[0] != '+' or raw[1] != '{') continue;
            const line = std.mem.trimEnd(u8, raw[1..], " \t\r");
            const ev = codec.decode(self.gpa, line) catch continue;
            defer Store.freeEvent(self.gpa, ev);

            // Every id this event OWNS gets an entry, independent of whether
            // it also carries a title/state (see the doc comment above).
            for (model.eventTaskIds(ev)) |maybe_id| {
                const id = maybe_id orelse continue;
                const gop = try recs.getOrPut(self.gpa, id.text);
                if (!gop.found_existing) gop.value_ptr.* = .{};
            }

            switch (ev) {
                .add => |a| {
                    const gop = try recs.getOrPut(self.gpa, a.id.text);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    if (a.short) |s| gop.value_ptr.short = try ra.dupe(u8, s);
                    if (a.ts > gop.value_ptr.title_ts) {
                        gop.value_ptr.title = try ra.dupe(u8, a.title);
                        gop.value_ptr.title_ts = a.ts;
                    }
                },
                .setTitle => |s| {
                    const gop = try recs.getOrPut(self.gpa, s.id.text);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    if (s.ts > gop.value_ptr.title_ts) {
                        gop.value_ptr.title = try ra.dupe(u8, s.title);
                        gop.value_ptr.title_ts = s.ts;
                    }
                },
                .setShort => |s| {
                    const gop = try recs.getOrPut(self.gpa, s.id.text);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    gop.value_ptr.short = try ra.dupe(u8, s.short);
                },
                .setState => |s| {
                    const gop = try recs.getOrPut(self.gpa, s.id.text);
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    if (s.ts > gop.value_ptr.reason_ts) {
                        gop.value_ptr.reason = s.state.toString();
                        gop.value_ptr.reason_ts = s.ts;
                    }
                },
                else => {},
            }
        }
        return recs;
    }

    /// Back-fill the tombstone index from `.tracker/log.jsonl`'s FULL git
    /// history via `scanLogHistoryForIds`, entombing every recovered id that
    /// is neither live nor already recorded.
    fn rebuildTombstones(self: *Cli) Error!void {
        const log_path = tracker.store.tracker_subdir ++ "/" ++ tracker.store.log_name;
        // Every recovered title/short is copied out of a decoded event that is
        // freed on the next loop iteration, and there are thousands of them.
        // One arena freed at the end beats tracking each string: the records
        // are write-once and all die together, and the rows handed to
        // `appendTombstones` below borrow from it while it is still alive.
        var rec_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer rec_arena.deinit();
        var recs = try self.scanLogHistoryForIds(rec_arena.allocator());
        defer recs.deinit(self.gpa);

        // Entomb every recovered id that is neither live nor already recorded.
        // `appendTombstones` re-checks the index itself; the live check is here
        // because writing a tombstone for a LIVE id is the one error this
        // mechanism must never make — `show` would then call a live task gone.
        var rows: std.ArrayList(tracker.store.Tombstone) = .empty;
        defer rows.deinit(self.gpa);
        var it = recs.iterator();
        while (it.next()) |e| {
            const id = Ulid{ .text = e.key_ptr.* };
            if (self.store.get(id) != null) continue;
            try rows.append(self.gpa, .{
                .id = id,
                .short = e.value_ptr.short,
                .title = e.value_ptr.title,
                .reason = e.value_ptr.reason,
                .arcs = &.{},
                .ts = 0,
                .src = "git-history",
            });
        }
        std.sort.pdq(tracker.store.Tombstone, rows.items, {}, tombstoneIdLessThan);

        var sub = self.dir.createDirPathOpen(self.io, tracker.store.tracker_subdir, .{}) catch |e| {
            try self.print("trk: tombstones: cannot open .tracker/: {s}\n", .{@errorName(e)});
            return e;
        };
        defer sub.close(self.io);
        const written = try self.store.appendTombstones(sub, rows.items);
        // Re-fold so the listing below (and any later lookup in this process)
        // sees what was just written — the in-memory index was built at load.
        try self.store.loadTombstones();
        try self.print(
            "trk: tombstones: scanned {d} distinct id(s) in the full history of {s}; " ++
                "{d} new tombstone(s) recorded, {d} already known or still live.\n",
            .{ recs.count(), log_path, written, recs.count() - written },
        );
    }

    /// `trk tombstones --verify`: the STANDING CHECK 01M2N8WMD asked for —
    /// assert, rather than trust, that the tombstone index is COMPLETE.
    ///
    /// Computes the same structural id set `scanLogHistoryForIds` computes for
    /// `--rebuild`, then asserts (structural set) - (live) - (tombstoned) is
    /// EMPTY. Before this existed, the only thing anyone could check was the
    /// back-fill's OWN reported count ("N new tombstone(s) recorded") — which
    /// reads as coverage but proves nothing: a `--rebuild` that silently
    /// missed a class of ids (exactly what this file's `--rebuild` fix just
    /// closed) would report a clean run and never be caught by anything
    /// short of the by-hand cross-check 01M2N8WMD did manually. This is that
    /// cross-check, made a real command so a regression in `eventTaskIds`
    /// coverage — or a future op variant nobody remembered to wire in — FAILS
    /// LOUD instead of degrading back into the silent gap (rule 5,
    /// docs/debugging.md: a check must be able to fail, and something must
    /// assert on it).
    ///
    /// Read-only: unlike `--rebuild`, never writes `tombstones.jsonl` — a
    /// verify that could also silently repair would stop being a check that
    /// FAILS and just become `--rebuild` under another name.
    ///
    /// Cost: one `git log --all -p` walk, same as `--rebuild` (~31s on a
    /// 10,574-commit repo per that command's own measurement; ~80s measured on
    /// Enix's larger tracker history, 01M2N8WMD) — mechanical but NOT cheap
    /// enough to run on every `trk` invocation or every commit. See
    /// `docs/design.md` "Tombstone index completeness" for why this lives here
    /// (a `trk` subcommand) rather than as an Enix-side lint reimplementing the
    /// same walk, and why it stays an opt-in command rather than a `next`/
    /// `list`-style default.
    fn verifyTombstoneIndex(self: *Cli) Error!void {
        const log_path = tracker.store.tracker_subdir ++ "/" ++ tracker.store.log_name;
        var rec_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer rec_arena.deinit();
        var recs = try self.scanLogHistoryForIds(rec_arena.allocator());
        defer recs.deinit(self.gpa);

        var missing: std.ArrayList(tracker.store.Tombstone) = .empty;
        defer missing.deinit(self.gpa);
        var it = recs.iterator();
        while (it.next()) |e| {
            const id = Ulid{ .text = e.key_ptr.* };
            if (self.store.get(id) != null) continue; // live — not a gap
            if (self.store.lookupTombstone(&id.text) != .none) continue; // already entombed
            try missing.append(self.gpa, .{
                .id = id,
                .short = e.value_ptr.short,
                .title = e.value_ptr.title,
                .reason = e.value_ptr.reason,
                .arcs = &.{},
                .ts = 0,
                .src = "git-history",
            });
        }

        if (missing.items.len == 0) {
            try self.print(
                "trk: tombstones: verify OK — {d} distinct id(s) in the full history of {s}, " ++
                    "every one live or entombed.\n",
                .{ recs.count(), log_path },
            );
            return;
        }

        std.sort.pdq(tracker.store.Tombstone, missing.items, {}, tombstoneIdLessThan);
        try self.print(
            "trk: tombstones: verify FAILED — {d} of {d} distinct id(s) in the full history of {s} are " ++
                "neither live nor entombed (provably existed, provably gone, recorded nowhere):\n",
            .{ missing.items.len, recs.count(), log_path },
        );
        for (missing.items) |tb| {
            try self.print("  {s}  {s:<9}  {s}\n", .{
                &tb.id.text,
                tb.reason,
                if (tb.title.len != 0) tb.title else "(not recorded)",
            });
        }
        try self.print(
            "trk: tombstones: run `trk tombstones --rebuild` to entomb them, or investigate why " ++
                "--rebuild itself isn't (a regression in --rebuild's own id-membership coverage is " ++
                "exactly what this check exists to catch).\n",
            .{},
        );
        return error.TombstoneIndexIncomplete;
    }

    fn tombstoneIdLessThan(_: void, lhs: tracker.store.Tombstone, rhs: tracker.store.Tombstone) bool {
        return std.mem.lessThan(u8, &lhs.id.text, &rhs.id.text);
    }
};

// ----------------------------------------------------------- timestamp formatter

/// Format a Unix-epoch millisecond timestamp as "YYYY-MM-DD HH:MM:SS" (UTC).
/// ts=0 (unknown/legacy) renders as "????-??-?? ??:??:??".
/// `buf` must be at least 32 bytes; returns a slice into it.
/// Split a `--doc` value `doc_id` or `doc_id#section` into its parts.
fn splitDocRef(s: []const u8) struct { doc_id: []const u8, section_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, s, '#')) |h| {
        return .{ .doc_id = s[0..h], .section_id = s[h + 1 ..] };
    }
    return .{ .doc_id = s, .section_id = null };
}

fn fmtTs(ms: i64, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 32);
    if (ms == 0) {
        const s = "????-??-?? ??:??:??";
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    const secs = @divFloor(ms, 1000);
    const secs_in_day: u32 = @intCast(@mod(secs, 86400));
    const hour: u32 = secs_in_day / 3600;
    const min: u32 = (secs_in_day % 3600) / 60;
    const sec: u32 = secs_in_day % 60;

    // Civil-from-days algorithm (Hinnant): days since epoch -> year/month/day.
    const z: i64 = @divFloor(secs, 86400) + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const yr: i64 = y + if (m <= 2) @as(i64, 1) else 0;

    // Write into a fixed-size sub-buffer (19 chars for "YYYY-MM-DD HH:MM:SS").
    // Year is formatted unsigned: zero-padding a signed int prints an explicit
    // "+" sign (std.fmt since 0.15), which corrupted date slices like [0..10].
    var tmp: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&tmp, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(yr)), m, d, hour, min, sec,
    }) catch "0000-00-00 00:00:00";
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
}

// ----------------------------------------------------------- free helpers

fn containsId(haystack: []const Ulid, needle: Ulid) bool {
    for (haystack) |h| if (h.eql(needle)) return true;
    return false;
}

/// Equality over two optional strings: both null, or both non-null and
/// byte-equal. Used by `cmdArchive`'s destination grouping — two tasks share
/// a changelog group iff their resolved destinations compare equal here.
fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// DEPRECATED: the cosmetic pre-`arcDeclare` arc marker. Not a definition of
/// arc-ness (that's `Store.isArc`, which already reads this same `arc:` prefix
/// as a backward-compat fallback) — this standalone helper survives only as
/// `trk migrate-arcs`'s "does this task need converting" check.
fn hasArcTag(t: Task) bool {
    for (t.tags.items) |tg| {
        if (std.mem.startsWith(u8, tg, "arc:")) return true;
    }
    return false;
}

fn hasTag(t: Task, tag: []const u8) bool {
    for (t.tags.items) |tg| if (std.mem.eql(u8, tg, tag)) return true;
    return false;
}

/// True iff `t` carries ANY tag in `tags` — the `--not-tag` exclusion test
/// (repeatable, ANDed as an exclusion: absence of every listed tag is
/// required to pass). An empty `tags` list matches nothing (no `--not-tag`
/// given), so the filter is a no-op by default.
fn hasAnyTag(t: Task, tags: []const []const u8) bool {
    for (tags) |tag| if (hasTag(t, tag)) return true;
    return false;
}

/// True iff `word` appears (case-insensitively) in the task's title, body, or
/// any tag. Tags are included so `--word prism` catches `#arc:display-prism`.
fn wordMatches(t: Task, word: []const u8) bool {
    if (containsSubCI(t.title, word)) return true;
    if (containsSubCI(t.body, word)) return true;
    for (t.tags.items) |tg| if (containsSubCI(tg, word)) return true;
    return false;
}

/// AND across terms: every word must match (each via `wordMatches`). An empty
/// term list matches everything (no `--word`/positional filter given).
fn allWordsMatch(t: Task, words: []const []const u8) bool {
    for (words) |w| if (!wordMatches(t, w)) return false;
    return true;
}

fn containsSubCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Is this task still not-yet-built work (shown in the TODO projection)?
/// open + blocked + claimed + submitted are pending (a lease is work in hand;
/// a submission is a commit's self-report pending the orchestrator's verify —
/// see `State.submitted`); done/dropped/archived are finished or abandoned.
fn isRemaining(s: State) bool {
    return s == .open or s == .blocked or s == .claimed or s == .submitted;
}

/// One-char state marker for line output / the tree.
fn stateMarker(s: State) []const u8 {
    return switch (s) {
        .open => "[ ]",
        .done => "[x]",
        .blocked => "[~]",
        .dropped => "[-]",
        .archived => "[a]",
        // Both distinct from plain `open` on purpose — neither is work available
        // to pick up. The letters follow the state NAMES: TODO.md is regenerated
        // on every render, so unlike the wire token nothing persisted still
        // reads `[c]` as the pre-rename meaning.
        .claimed => "[c]",
        .submitted => "[s]",
    };
}

/// Same set, used in the markdown bullet (kept identical for consistency).
fn stateCheckbox(s: State) []const u8 {
    return stateMarker(s);
}

/// Sort children of a tree root by (arc-seq under that root, id) for a stable,
/// priority-ordered sibling list. Standalone so the `tree` root can reuse it.
fn sortByArcSeqThenId(cli: *Cli, arc: Ulid, items: []Ulid) void {
    const Ctx = struct {
        cli: *Cli,
        arc: Ulid,
        fn seqOf(c: @This(), id: Ulid) i64 {
            for (c.cli.store.ins.items) |e| {
                if (e.task.eql(id) and e.arc.eql(c.arc)) return e.seq;
            }
            return std.math.maxInt(i64);
        }
        fn less(c: @This(), x: Ulid, y: Ulid) bool {
            const sx = c.seqOf(x);
            const sy = c.seqOf(y);
            if (sx != sy) return sx < sy;
            return x.order(y) == .lt;
        }
    };
    std.sort.pdq(Ulid, items, Ctx{ .cli = cli, .arc = arc }, Ctx.less);
}

fn lessThanStrCli(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
