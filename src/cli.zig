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
    /// `trk state <id> claimed|submitted` on a declared decision — a question
    /// is not work. See `store.StoreError.DecisionNotWork`.
    DecisionNotWork,
    /// A task may not be both an arc root and a decision (either direction).
    DecisionNotArc,
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
    /// `trk stale-rulings` found at least one open/blocked/claimed task whose
    /// own most recent `setBody` does not postdate the ruling of a decision it
    /// `raises` (01M31D03S). The offending raisers are already listed in `out`
    /// before this is returned; main.zig exits 1, same shape as
    /// `TombstoneIndexIncomplete`.
    StaleRulings,
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
    /// The verb `dispatch` is currently running. Set there and nowhere else,
    /// purely so `unknownFlag` can name the verb and search ITS flag vocabulary
    /// for a near-miss without threading a flag list through fourteen parse
    /// loops. Null when a `cmdX` is called directly (never in production —
    /// `main.zig` and `mcp.zig` both go through `run`/`dispatch`); the
    /// diagnostic then simply drops the verb-specific half rather than guessing.
    current_verb: ?*const Verb = null,

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

    /// One task as a JSON object: id (full), short, title, body, state,
    /// priority, [seq when an arc context is given], tags. Relations stay in
    /// `trk show`.
    ///
    /// `body` is emitted UNCONDITIONALLY, empty string included (01M1FMN25).
    /// It was omitted, and that made the mechanical full-frontier triage a
    /// fan-out mandates — every ready task, scripted, not the top N — impossible
    /// to script: the discriminators that decide a task's bucket (HOLD, DEFER,
    /// RULED, "your call", "NOT resolved") are APPENDED, so they sit at the END
    /// of a long body while the opening paragraphs still read like ordinary
    /// buildable work. Tags and titles were scriptable; everything else needed a
    /// `trk show` per candidate, over 280 tasks. trk already had the body in
    /// hand at that moment — `next`'s own search matches over title+body+tags,
    /// so the filter read it and the emitter dropped it.
    ///
    /// Unconditional, not behind `--with-body`: a flag's failure mode is
    /// forgetting to pass it, which is the silent omission this fixes, spelled
    /// differently. Always present, not omitted-when-empty like `holder`/`seq`,
    /// so a consumer can index it without a guard. And a plain string rather
    /// than a decision-marker boolean: that vocabulary is the caller's, not
    /// trk's — trk stays generic and the grep stays where it belongs.
    fn appendTaskJson(self: *Cli, id: Ulid, arc_id: ?Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);
        try self.print("{{\"id\":\"{s}\",\"short\":\"{s}\",\"title\":", .{ &id.text, sid });
        try self.writeJsonString(t.title);
        try self.write(",\"body\":");
        try self.writeJsonString(t.body);
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
        self.current_verb = v;
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
        /// Every flag THIS verb's parser accepts, for the near-miss suggestion
        /// in `unknownFlag` (01M1FMMFZ) — the whole class of error there is
        /// someone reaching for the plural of a repeatable option, and naming
        /// the right spelling turns a hunt into a glance. A verb that takes no
        /// flags leaves it empty. Kept in the table rather than beside each
        /// parse loop so the message does not need the loop's locals, and
        /// asserted against the verb's own help text by a cli_test arm — the
        /// same "flags live in one place" rule mcp_test.zig already enforces
        /// for the tool schemas.
        flags: []const []const u8 = &.{},
        /// Full synopsis + purpose + key flags + an example — `trk <verb>
        /// --help`, and the MCP tool description.
        text: []const u8,
    };

    /// THE verb table: dispatch, `--help`, the read-only gate and the MCP tool
    /// list all derive from it, so none of them can drift from the others.
    pub const verbs = [_]Verb{
        .{ .name = "init", .run = &cmdInit, .mutates = true, .tools = &cli_only_tools, .flags = &.{ "--out", "--force", "--no-gitattributes", "--no-gitignore" }, .text =
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
        .{ .name = "add", .run = &cmdAdd, .mutates = true, .tools = &add_tools, .flags = &.{ "--body", "--tag", "--needs", "--doc", "--in", "--seq", "--arc", "--priority", "-v", "--verbose" }, .text =
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
        .{ .name = "dep", .run = &cmdDep, .mutates = true, .tools = &dep_tools, .flags = &.{"--needs"}, .text =
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
        .{ .name = "undep", .run = &cmdUndep, .mutates = true, .tools = &undep_tools, .flags = &.{"--needs"}, .text =
        \\trk undep <needer> --needs <prereq> [--needs <prereq> ...]
        \\  Remove the <needer> needs <prereq> edge (tombstoned; a no-op if absent).
        \\  Exact argument shape as `trk dep`, so undoing an edge is the same sentence
        \\  with one verb changed. The bare two-positional form is a hard usage error.
        \\  e.g.  trk undep 01KX6H4V --needs 01KX6H48
        },
        .{ .name = "in", .run = &cmdIn, .mutates = true, .tools = &in_tools, .flags = &.{"--seq"}, .text =
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
        .{ .name = "arc", .run = &cmdArc, .mutates = true, .tools = &arc_tools, .flags = &.{ "--undo", "--standing" }, .text =
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
        .{ .name = "decision", .run = &cmdDecision, .mutates = true, .tools = &decision_tools, .flags = &.{ "--from", "--blocks", "--in", "--seq", "--tag", "--body", "-v", "--verbose" }, .text =
        \\trk decision "<question>" [--from <id>] [--blocks <id> ...] [--in <arc> [--seq <n>]]
        \\               [--tag <t> ...] [--body <s>] [-v]
        \\  Raise a fork as its OWN node, at the moment you write it. Prints ONLY the
        \\  new ULID (scriptable); -v prints the friendly form. A decision is a task
        \\  declared a decision — it is excluded from `next` (a question is not
        \\  buildable work), it cannot be leased or submitted, and it cannot also be an
        \\  arc root.
        \\  --from <id>: PROVENANCE — that task raised this fork. No scheduling effect.
        \\  --blocks <id> (repeatable): an ordinary `needs` edge — that task waits for
        \\  the ruling. SEPARATE from --from on purpose: a fork noticed while doing a
        \\  task usually does NOT stop it, so blocking is opt-in. --blocks names the
        \\  task that WAITS, so the edge direction is stated rather than positional.
        \\  Resolve it with `trk rule <id> "<the ruling>"`, which records the answer,
        \\  closes the decision and thereby releases everything --blocks held back.
        \\  Sweep the open ones with `trk list --decision --state open`.
        \\  -v/--verbose prints the friendly form instead of the bare id.
        \\  e.g.  trk decision "does TODO.md want the annotation?" --from 01M2V2TSA --blocks 01M2V2TSA
        \\        trk decision "should trk support multi-user?"
        },
        .{ .name = "migrate-decisions", .run = &cmdMigrateDecisions, .mutates = true, .tools = &cli_only_tools, .flags = &.{ "--from-tag", "--dry-run" }, .text =
        \\trk migrate-decisions --from-tag <tag> [--dry-run]
        \\  One-shot migration off a legacy decision CONVENTION (a tag plus forks
        \\  written in prose) onto the mechanism. No default tag: the convention is
        \\  your repo's, not trk's.
        \\  SPLITS each task carrying <tag>. Those are CARRIERS — work and fork in one
        \\  body — so declaring one a decision outright would let `rule` close unbuilt
        \\  work. Instead it mints a decision node, wires `raises` back to the
        \\  original, leaves the original as work, and strips the tag. The decision is
        \\  a SCAFFOLD: no body text is copied or parsed, because only you know which
        \\  sentence is the fork. Retitle it, then wire what waits on it with `trk dep`.
        \\  REPORTS prose forks: body lines matching the legacy markers (OPEN QUESTION,
        \\  FIX NOTE, your call, TODO, plus <tag> itself) on tasks with no tag. It
        \\  files NOTHING from that scan. This is the only body scan left in trk, and
        \\  the only one there will be — `archive` no longer scans at all, so nothing
        \\  else will ever find these.
        \\  Re-runnable, and idempotent: a second run finds no tags. Re-run it after
        \\  integrating a lane that forked from a pre-migration base, since such a lane
        \\  keeps appending the old tag. --dry-run reports without writing.
        \\  e.g.  trk migrate-decisions --from-tag scott-decision --dry-run
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
        .{ .name = "migrate-shorts", .run = &cmdMigrateShorts, .mutates = true, .tools = &cli_only_tools, .flags = &.{"--min"}, .text =
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
        .{ .name = "state", .run = &cmdState, .mutates = true, .tools = &state_tools, .flags = &.{"--holder"}, .text =
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
        .{ .name = "release", .run = &cmdRelease, .mutates = true, .tools = &release_tools, .flags = &.{"--holder"}, .text =
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
        .{ .name = "next", .run = &cmdNext, .tools = &next_tools, .flags = &.{ "--arc", "--not-tag", "--limit", "--json", "--word" }, .text =
        \\trk next [--arc <id>] [--not-tag <t> ...] [--limit <n>] [--json] [<term> | --word <term> ...]
        \\  The ready frontier: open tasks whose prereqs are ALL met. An arc root is
        \\  a container: it is held back until its non-parked members are finished,
        \\  then surfaces once as the close-out prompt (`trk state <root> done` marks
        \\  the goal complete and unblocks anything that needs the arc) — UNLESS the
        \\  arc is marked --standing (`trk arc`), in which case it never surfaces.
        \\  Bare <term>s (or --word <term>; repeatable, ANDed) are a case-insensitive
        \\  substring search over title+body+tags. --not-tag <t> (repeatable, ANDed
        \\  exclusion) drops any task carrying that tag. Whatever blocker tags a repo
        \\  uses, its autonomous-eligible bucket is then one bare command:
        \\    trk next --not-tag <blocker-tag> --not-tag <other-blocker-tag>
        \\  DECISIONS are excluded structurally, not by tag: a fork is a question, not
        \\  buildable work, so it never enters the frontier and no --not-tag term is
        \\  needed for it. When work is held back waiting on an unruled fork, a tail
        \\  line says how much and points at `trk list --decision --state open` — the
        \\  exclusion would otherwise make `next` go empty with no explanation.
        \\  --json carries no such tail (an array has nowhere to put one) and no
        \\  decision rows: ask `trk list --decision --state open` instead.
        \\  --json emits a machine-readable array, one object per task, carrying the
        \\  full BODY as well as id/short/title/state/priority/seq?/tags — the whole
        \\  frontier is then triageable in one call, markers and all, with no
        \\  follow-up `trk show` per candidate.
        \\  e.g.  trk next           trk next parser windowed
        },
        .{ .name = "list", .run = &cmdList, .tools = &list_tools, .flags = &.{ "--arc", "--no-arc", "--decision", "--all", "--state", "--tag", "--not-tag", "--limit", "--json", "--word" }, .text =
        \\trk list [--arc <id> | --no-arc] [--decision] [--all] [--state <s>] [--tag <t>]
        \\         [--not-tag <t> ...] [--limit <n>] [--json] [<term> | --word <term> ...]
        \\  REMAINING work by default — open/blocked/claimed/submitted. Completed
        \\  states (done/dropped/archived) are hidden unless you ask: --state done is
        \\  the archive queue, --state archived the graduated set, --all the union.
        \\  Filterable by arc/state/tag and
        \\  the same bare-term search as `next`. --not-tag (repeatable, ANDed
        \\  exclusion) drops any task carrying that tag. --no-arc lists every task in
        \\  NO arc (by the unified isArc/membership model, including needs-
        \\  reachability) — the completeness query for "sort everything into arcs";
        \\  mutually exclusive with --arc. --decision lists only declared decisions —
        \\  by default the OPEN ones, which is the pre-dispatch "what is still waiting
        \\  on a call" sweep. A declaration is nature and survives its ruling, so
        \\  `--decision --state done` is every fork ruled but not yet graduated, and
        \\  `--decision --all` adds the graduated ones. It is NOT a complete index of
        \\  every fork ever raised: `archive` graduates a ruled decision like any
        \\  other finished task, and the RULING (not just the question) is what lands
        \\  in the changelog — see `trk archive --help`. --json for machine-readable output (same
        \\  object shape as `next --json`, body included).
        \\  With --arc, a tail line reports the arc's COMPACTED members by count and
        \\  points at `trk tree <arc>`, which names them. `list` already shows closed
        \\  work (done/submitted), and `compact` deletes the `in` edge along with the
        \\  member it collects — so without this a fully-built, graduated arc lists
        \\  identically to one nobody ever sliced. In --json they arrive as extra rows
        \\  carrying \"compacted\": true (an array has nowhere to put a footer); filter
        \\  on that key for the live-only set. They pass the same filters as live rows:
        \\  a compacted member is completed work (hidden by default; shown by --all or
        \\  --state archived|dropped), and keeps no tags or decision flag, so --tag and
        \\  --decision drop it; search terms match its title. `next` and docs/TODO.md deliberately do
        \\  NOT report them: `next` is a ready frontier, and TODO.md projects only
        \\  not-yet-built work.
        \\  e.g.  trk list --state open net           trk list --no-arc
        \\        trk list --state submitted           (the awaiting-verification queue)
        \\        trk list --state claimed             (tasks currently leased)
        },
        .{ .name = "render", .run = &cmdRender, .mutates = true, .tools = &render_tools, .flags = &.{"--out"}, .text =
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
        .{ .name = "tree", .run = &cmdTree, .tools = &tree_tools, .flags = &.{"--json"}, .text =
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
        \\  renders with no such block — except in a store with NO tombstone index at
        \\  all, where the absence is unreadable and a one-line note says to run
        \\  `trk tombstones --rebuild` instead.
        \\  A COMPACTED root gets `show`'s answer, not "no task matches": the record
        \\  plus its graduated members, exit 2 (live 0 / compacted 2 / absent 1).
        },
        .{ .name = "compact", .run = &cmdCompact, .mutates = true, .tools = &compact_tools, .flags = &.{"--dry-run"}, .text =
        \\trk compact [--dry-run]
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
        \\  --dry-run: NAME every task this run would collect — id, short, why — and
        \\  write nothing. Same `collectableRows` the real run uses, never a second
        \\  implementation that could disagree with it. Use it when anything OUTSIDE
        \\  the tracker cites task ids (a registry column, a source comment, a design
        \\  doc): a tombstone keeps the id, title and end state, but NOT the body, and
        \\  trk cannot see external citations to check them for you.
        \\  e.g.  trk compact --dry-run
        },
        .{ .name = "archive", .run = &cmdArchive, .mutates = true, .tools = &archive_tools, .flags = &.{ "--out", "--dry-run", "--arc", "--tag", "--word" }, .text =
        \\trk archive [<term> | --word <term> ...] [--arc <id>] [--tag <t>] [--out <path>]
        \\            [--dry-run]
        \\  Graduate DONE tasks to changelog bullets (--out > config archive.out >
        \\  stdout), then flip each to `archived` so it leaves every view (structural
        \\  dedup — re-running finds nothing). A file target is APPENDED to under a
        \\  `## YYYY-MM-DD` run heading, never truncated. --dry-run previews on
        \\  stdout without flipping (and never touches the file).
        \\  NO DECISION GUARD, and none is needed: archive used to grep every closing
        \\  body for markers and refuse the run, because a fork living in prose died
        \\  the moment its task went `archived`. A fork is now its own node
        \\  (`trk decision`), so archiving the task that raised it cannot bury it.
        \\  For prose written before that existed, `trk migrate-decisions` scans for
        \\  the old markers once and reports them to file as real decisions.
        \\  A ruled DECISION graduates like any other finished task, and its entry
        \\  carries the RULING from its body, not just the question in its title —
        \\  that record is why the node is disposable afterwards. Set
        \\  archive.decisions_out in .tracker/config.json to send rulings to their own
        \\  file (routed on the task's NATURE, so nothing needs tagging); unset, they
        \\  go wherever ordinary work goes.
        \\  The <term> slot is a SEARCH filter, not a task to archive: a bare
        \\  id-shaped token there is a hard error, because it would match nothing and
        \\  report an empty run.
        \\  e.g.  trk archive                      trk archive --arc 01KVX4K0 --dry-run
        },
        .{ .name = "doc", .run = &cmdDoc, .mutating_subcommands = &.{ "set", "unset" }, .tools = &doc_tools, .text =
        \\trk doc set <doc_id> <path>   register/update a doc_id -> repo-relative path
        \\trk doc unset <doc_id>        unregister a doc_id (idempotent; refs fall back
        \\                              to the raw doc_id until it is re-set)
        \\trk doc list                  print all registered doc_id -> path mappings
        \\trk doc resolve <doc_id>      print the path for a doc_id
        \\  The registry backs the --doc/--add-doc design pointers on add/edit.
        },
        .{ .name = "show", .run = &cmdShow, .tools = &show_tools, .flags = &.{ "--body", "--json" }, .text =
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
        .{ .name = "edit", .run = &cmdEdit, .mutates = true, .tools = &edit_tools, .flags = &.{ "--title", "--replace-body", "--append-body", "--add-doc", "--rm-doc", "--add-tag", "--rm-tag", "--priority" }, .text =
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
        .{ .name = "rule", .run = &cmdRule, .mutates = true, .tools = &rule_tools, .text =
        \\trk rule <id> <ruling text|->
        \\  Record the answer to a DECISION and close it, atomically: appends the
        \\  ruling to the decision's body and sets it `done`. `-` reads the ruling
        \\  from stdin.
        \\  Closing is the point, not a side effect: `done` satisfies a prereq, so
        \\  every task wired `--blocks` on this fork becomes eligible the moment it is
        \\  answered — with no second command to forget. The tasks it released are
        \\  named in the output.
        \\  It does NOT clear the decision declaration. Declaration is NATURE, like
        \\  arc-ness: an arc stays an arc once done, and a ruled decision stays a
        \\  decision. Clearing it would turn the answered question back into an
        \\  ordinary open task and `next` would hand it out as work to go build.
        \\  REFUSES on a task that is not a declared decision — `rule` is the resolver
        \\  for forks, not a way to close work on the strength of a note; use
        \\  `trk edit <id> --append-body` for that. Refuses on an already-ruled one too.
        \\  e.g.  trk rule 01M2V2TSA "list --arc only; TODO.md stays forward-looking"
        },
        .{ .name = "log", .run = &cmdLog, .tools = &log_tools, .flags = &.{ "--limit", "--json" }, .text =
        \\trk log [<id>] [--limit <n>] [--json]
        \\  Event history, most-recent-last: the whole log, or one task's events.
        \\  --json: an array of {ts,op,task_id,summary}.
        },
        .{ .name = "stale", .run = &cmdStale, .tools = &stale_tools, .flags = &.{"--oneline"}, .text =
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
        .{ .name = "stale-rulings", .run = &cmdStaleRulings, .tools = &cli_only_tools, .flags = &.{"--json"}, .text =
        \\trk stale-rulings [--json]
        \\  Cross-reference: which OPEN/BLOCKED/CLAIMED task RAISES a decision that
        \\  is now RULED (done/archived) but has not touched its own BODY since?
        \\  `trk rule` appends the ruling and closes the decision (see `trk rule
        \\  --help`); it does NOTHING to the task that raised it, so the raiser can
        \\  keep advertising an already-answered question — to `next`, `list`,
        \\  TODO.md, a dispatcher, a compaction summary — none of which follow the
        \\  `raises` pointer to the ruling (01M31D03S, measured on 01M2GTWS2 /
        \\  01M2VMXA0C).
        \\  STRUCTURAL, not textual: the join is `Store.raisersOf` (tombstone-
        \\  correct) plus each side's own event TIMESTAMP, read off the raw
        \\  `model.Event` payload in `.tracker/snapshot.jsonl` + `log.jsonl` — never
        \\  a scan of body/title TEXT. A raiser is flagged unless its most recent
        \\  `setBody` ts is STRICTLY AFTER the decision's `setState -> done` ts
        \\  (a tie, or no setBody at all, flags it). Deliberately BODY-only, not
        \\  "body or title": measured on the carrier this check exists for, a
        \\  title-only edit written 23h after the ruling still left the actual
        \\  question unreconciled, so a title-inclusive form would have missed the
        \\  exact case that motivated this check.
        \\  KNOWN LIMITATION: this is a proxy, not a content check — ANY body edit
        \\  after the ruling clears the flag, including one that never mentions it.
        \\  A fully sound check needs an explicit reconciliation event; this reads
        \\  what the store has today rather than adding one (see 01M31D03S).
        \\  --json: an array of {raiser, raiser_short, decision, decision_short,
        \\  ruled_ts, body_ts}.
        \\  Exits nonzero iff it found at least one stale raiser.
        \\  e.g.  trk stale-rulings
        },
        .{ .name = "tombstones", .run = &cmdTombstones, .mutating_subcommands = &.{"--rebuild"}, .tools = &tombstones_tools, .flags = &.{ "--rebuild", "--verify", "--json" }, .text =
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
        \\  It also recovers ARC MEMBERSHIPS from the `in`/`unin` events in the same
        \\  history (a member iff some `in` survives with no `unin` for the pair) —
        \\  without them `trk tree <arc>` prints no compacted-members block for
        \\  anything compacted before the index existed, which is the same silence
        \\  that block exists to end.
        \\  Idempotent (an id already entombed is skipped); it never touches the
        \\  log, the snapshot, or any live task. Recovered rows are marked
        \\  src=git-history and carry no collection time. The ONE exception to
        \\  "already entombed is skipped": a row that strictly IMPROVES an existing
        \\  recovered record — memberships where it had none — is re-appended and
        \\  supersedes it, so a fix to the reconstruction reaches a store that
        \\  already ran the old one. A src=compact record is never overwritten.
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
        .{ .name = "decision", .kind = .boolean, .flag = "--decision", .desc = "Only declared decisions (open ones by default)." },
        .{ .name = "all", .kind = .boolean, .flag = "--all", .desc = "Include completed states, which the default hides." },
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

    const decision_tools = [_]Tool{.{ .name = "decision", .params = &.{
        .{ .name = "question", .kind = .string, .required = true, .desc = "The fork, as a question." },
        .{ .name = "from", .kind = .string, .flag = "--from", .desc = "The task that raised it (provenance; no scheduling effect)." },
        .{ .name = "blocks", .kind = .string_list, .flag = "--blocks", .desc = "Task ids that WAIT for this ruling." },
        .{ .name = "in", .kind = .string, .flag = "--in", .desc = "Add to this already-declared arc." },
        .{ .name = "seq", .kind = .integer, .flag = "--seq", .desc = "Arc sequence (with `in`)." },
        .{ .name = "tag", .kind = .string_list, .flag = "--tag", .desc = "Tags." },
        .{ .name = "body", .kind = .string, .flag = "--body", .desc = "Detail behind the question." },
    } }};

    const rule_tools = [_]Tool{.{ .name = "rule", .params = &.{
        p_id,
        .{ .name = "text", .kind = .string, .required = true, .desc = "The ruling. Appended to the decision's body; closes it, releasing whatever it blocked." },
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
            \\      (id/short/title/body/state/priority/seq?/tags).
            \\  trk render [--out <path>]    the TODO.md markdown projection (--out > config render.out > stdout)
            \\      Header reports an arc-less drift count every regeneration.
            \\  trk tree <arc-or-task>       the ASCII prereq hierarchy
            \\  trk archive [<term> ...] [--arc <id>] [--tag <t>] [--out <path>] [--dry-run]
            \\      Graduate DONE tasks to the changelog: emit them as markdown bullets
            \\      (appended to --out/config target under a dated heading, else stdout),
            \\      then flip each to `archived` so it leaves every view (structural
            \\      dedup). --dry-run previews on stdout without archiving.
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
            \\  trk decision "<question>" [--from <id>] [--blocks <id> ...]
            \\      Raise a fork as its own node, at the moment you write it. Excluded from
            \\      `next` (a question is not buildable work); --blocks wires the tasks that
            \\      WAIT for the ruling. `trk list --decision --state open` is the sweep.
            \\  trk rule <id> <ruling text|->   record the answer and CLOSE the decision,
            \\      atomically — which releases everything --blocks held back, with no second
            \\      command. Refuses on anything that is not a declared decision.
            \\  trk migrate-decisions --from-tag <tag> [--dry-run]
            \\      One-shot move off a legacy tag-plus-prose convention (see its --help).
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
        // A `-`-leading token in an id slot is a misspelled FLAG that the
        // parser swallowed as the positional, not an id anyone meant to type —
        // no ULID or short id begins with a dash. Same misdirection `cmdAdd`
        // carried (01M1FMMFZ): `trk edit --titel x` used to answer "no task
        // matches prefix '--titel'", sending the reader to look for a task.
        // Routing it through `unknownFlag` names the near-miss instead.
        if (s[0] == '-') return self.unknownFlag(s);

        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        // Exact tier first (01M2Y2JV5): a FROZEN short is a task's stable
        // printed name, so it must resolve to that task even when later mints
        // took longer shorts extending it — under the prefix rule alone the
        // input really is ambiguous, which is why this is a tier ahead of the
        // prefix matcher rather than a tweak to it. Only when the exact tier
        // is empty does prefix extension get a say. Two tasks CAN freeze the
        // same short (parallel worktrees minting in one millisecond); that
        // stays ambiguous, listed by the prefix path below.
        {
            var exact: ?Ulid = null;
            var n_exact: usize = 0;
            for (ids) |id| {
                const sh = (self.store.get(id) orelse continue).short orelse continue;
                if (std.ascii.eqlIgnoreCase(s, sh)) {
                    n_exact += 1;
                    exact = id;
                }
            }
            if (n_exact == 1) return exact.?;
            // No live task owns this short, but a COMPACTED one did: its
            // printed name must not resolve to whatever live task happens to
            // extend it, nor read as ambiguous among them. NoSuchId hands
            // `show`/`tree` to their tombstone path, where the same exact tier
            // (`Store.lookupTombstone`) names it.
            if (n_exact == 0 and self.store.exactTombstone(s) != null) {
                try self.print("trk: '{s}' names a compacted task, not a live one (`trk show {s}`)\n", .{ s, s });
                return error.NoSuchId;
            }
        }

        // Prefix match (case-insensitive, against the canonical upper-case text).

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
    /// Report an argument the parser could not use, and return the error to
    /// propagate. Every `unknown flag` site goes through here.
    ///
    /// What it exists to fix (01M1FMMFZ): the message used to be a bare
    /// `unknown flag '<arg>'`, and on a positional-title verb the `<arg>` it
    /// named was the wrong one. `trk add --tags=a,b "<title>"` swallowed
    /// `--tags=a,b` into the title slot, met the real title as an unexpected
    /// second positional, and blamed THAT — pointing at the one argument in the
    /// line that was correct. The cost is not cosmetic: it sends you to inspect
    /// a long, backtick-and-em-dash-bearing title written through a heredoc,
    /// hunting a quoting bug that was never there. `cmdAdd` now takes the first
    /// BARE token as the title so the blame lands on the token that actually
    /// failed to parse; this function makes the message worth reading when it
    /// gets there.
    ///
    /// Three shapes, because three different mistakes reach here:
    ///   * `--tag=x` — an `=`-joined value. No trk flag has ever taken one, and
    ///     that is exactly why it is worth saying out loud rather than just
    ///     "unknown flag": the spelling is plausible, and the fix is a space.
    ///   * `--tags` — a near-miss on a real flag. The whole class of error is
    ///     someone reaching for the plural of a REPEATABLE option (`--tag <t>
    ///     ...`), which is a one-character edit, so a bounded edit distance over
    ///     the verb's own vocabulary names the right spelling nearly every time.
    ///   * a bare token — not a flag at all, just one positional too many.
    /// Returns the ERROR VALUE rather than an error union, so every call site
    /// — including `parseNeedsArgs`, which returns a struct — is the same one
    /// line: `return self.unknownFlag(arg);`.
    fn unknownFlag(self: *Cli, arg: []const u8) Error {
        self.reportUnknownFlag(arg) catch |e| return e;
        return error.UnknownFlag;
    }

    fn reportUnknownFlag(self: *Cli, arg: []const u8) Error!void {
        const verb = if (self.current_verb) |v| v.name else "";
        const known: []const []const u8 = if (self.current_verb) |v| v.flags else &.{};

        if (arg.len == 0 or arg[0] != '-') {
            try self.print("trk: unexpected argument '{s}' — it is not a flag, and this verb has no", .{arg});
            if (verb.len > 0) {
                try self.print(" further positional to put it in (trk {s} --help)\n", .{verb});
            } else {
                try self.write(" further positional to put it in\n");
            }
            return;
        }

        // `--flag=value`: report the JOINED form, but search on the flag half —
        // `--tags=a,b` is both mistakes at once and the near-miss is the more
        // useful half to name.
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        if (eq != null and isKnownFlag(known, name)) {
            try self.print(
                "trk: '{s}' — trk flags never take an =-joined value; pass it as the next argument: {s} {s}\n",
                .{ arg, name, arg[eq.? + 1 ..] },
            );
            return;
        }

        try self.print("trk: unknown flag '{s}'", .{arg});
        if (nearestFlag(known, name)) |near| {
            try self.print(" — did you mean '{s}'?", .{near});
        }
        if (verb.len > 0) try self.print(" (trk {s} --help lists the flags it takes)", .{verb});
        try self.write("\n");
    }

    fn isKnownFlag(known: []const []const u8, name: []const u8) bool {
        for (known) |k| if (std.mem.eql(u8, k, name)) return true;
        return false;
    }

    /// The closest flag in `known` to `name` within an edit distance of 2, or
    /// null. Two, not one: it catches `--tags`/`--tag` (the plural, the case
    /// this was built for) and `--priorty`/`--priority` alike, while still
    /// being far too tight to suggest `--tag` for `--json`. Compared on the
    /// full spelling INCLUDING the dashes, so `-tag` (one dash) is a distance-1
    /// hit on `--tag` rather than a distance-0 tie with everything.
    fn nearestFlag(known: []const []const u8, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_d: usize = 3;
        for (known) |k| {
            const d = editDistance(name, k) orelse continue;
            if (d < best_d) {
                best_d = d;
                best = k;
            }
        }
        return best;
    }

    /// Levenshtein distance, or null if either side is longer than the row
    /// buffer (no trk flag comes close; a pasted-garbage "flag" can, and a
    /// suggestion is worthless there anyway).
    fn editDistance(a: []const u8, b: []const u8) ?usize {
        var prev: [64]usize = undefined;
        var cur: [64]usize = undefined;
        if (a.len + 1 > prev.len or b.len + 1 > prev.len) return null;
        for (0..b.len + 1) |j| prev[j] = j;
        for (a, 0..) |ca, i| {
            cur[0] = i + 1;
            for (b, 0..) |cb, j| {
                const sub = prev[j] + @intFromBool(ca != cb);
                const del = prev[j + 1] + 1;
                const ins = cur[j] + 1;
                cur[j + 1] = @min(sub, @min(del, ins));
            }
            @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
        }
        return prev[b.len];
    }

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
                return self.unknownFlag(args[i]);
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
        // The title is the first BARE token, not `args[0]` (01M1FMMFZ). Taking
        // args[0] unconditionally meant a misspelled leading flag was swallowed
        // as the title, and the REAL title then arrived as an unexpected second
        // positional and got blamed for it — `trk add --tags=a,b "<title>"`
        // printed `unknown flag '<title>'`, naming the one argument that was
        // correct. Scanning for the first bare token puts the blame on the token
        // that actually failed to parse, and makes `trk add --tag ui "<title>"`
        // (flags first) work as anyone would expect it to.
        var title: ?[]const u8 = null;
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

        // No MCP escape hatch is needed for the scan below, and none exists:
        // `mcp.zig`'s `buildArgv` already refuses a positional value beginning
        // with `-` at the boundary ("the value would be parsed as a flag"), so
        // a title arriving as a typed parameter is non-dash by construction and
        // the first bare token is always it.
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (arg.len == 0 or arg[0] != '-') {
                if (title != null) {
                    try self.print(
                        "trk: add takes exactly one positional (the title) — '{s}' is a second one. " ++
                            "Quote the whole title as ONE argument, and pass everything else as a flag " ++
                            "(trk add --help)\n",
                        .{arg},
                    );
                    return error.UsageError;
                }
                title = arg;
            } else if (std.mem.eql(u8, arg, "--body")) {
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
                return self.unknownFlag(arg);
            }
        }

        const the_title = title orelse {
            try self.write("trk: add needs a \"<title>\" — every other argument here is a flag.\n" ++
                "       A title that really does start with '-' has to be reworded; trk has no `--` terminator.\n");
            return error.MissingArgument;
        };

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
        try self.store.append(.{ .add = .{ .id = id, .title = the_title, .body = body, .tags = tag_slice, .short = short } });
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
            try self.warn.print(self.gpa, "trk: warning: {s} \"{s}\" is in no arc (pass --in <arc> or --arc)\n", .{ try self.shortId(id, &sb), the_title });
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
                return self.unknownFlag(arg);
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
                return self.unknownFlag(args[i]);
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
    /// Turn a nature conflict from `Store.append` into a message naming both
    /// natures and the way out. Shared by every `arcDeclare` call site in
    /// `cmdArc`, so none of them can fail silently (`main.zig` treats
    /// `DecisionNotArc` as "a clean message is already in `out`").
    fn arcDeclareFailed(self: *Cli, e: anyerror, sid: []const u8) Error {
        if (e == error.DecisionNotArc) {
            self.print(
                "trk: {s} is a DECISION, and a decision cannot also be an arc root. An arc contains " ++
                    "work; a decision is a question about it. If the fork is resolved, rule it " ++
                    "(`trk rule {s} \"<the ruling>\"`) and file the work as its own task.\n",
                .{ sid, sid },
            ) catch |pe| return pe;
        }
        return @errorCast(e);
    }

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
                return self.unknownFlag(args[i]);
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
            self.store.append(.{ .arcDeclare = .{ .id = id, .declared = true } }) catch |e|
                return self.arcDeclareFailed(e, try self.shortId(id, &sb));
            try self.store.append(.{ .arcStanding = .{ .id = id, .standing = true } });
            try self.print("{s} declared an arc and marked standing\n", .{try self.shortId(id, &sb)});
            return;
        }

        self.store.append(.{ .arcDeclare = .{ .id = id, .declared = !undo } }) catch |e|
            return self.arcDeclareFailed(e, try self.shortId(id, &sb));
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
    /// `trk migrate-decisions --from-tag <tag> [--dry-run]` — graduate a repo's
    /// legacy decision CONVENTION into the mechanism (01M2VFX26).
    ///
    /// Two jobs, and it NEVER guesses which sentence of a body is the fork.
    ///
    /// 1. SPLIT each task carrying `<tag>`. Those tasks are CARRIERS — work and
    ///    fork in one body — so simply declaring one a decision would let `rule`
    ///    close unbuilt work. Instead it mints a decision node, wires
    ///    `raises{original, D}`, leaves the original alone as work, and strips
    ///    the tag. D is a SCAFFOLD: its title names the task it came from and
    ///    its body is empty, for a human to write the actual question into. No
    ///    body text is copied or parsed. This split is precisely what lets
    ///    `cmdRule` be unconditional — no `--keep-open`, no behaviour keyed on
    ///    the target's nature.
    ///
    /// 2. REPORT prose forks: body lines matching the legacy markers
    ///    (`store.legacy_decision_markers`, plus `<tag>` itself) on tasks that
    ///    carry no tag. Those are the forks nothing else can find, and nothing
    ///    else ever will — `archive`'s guard is gone. It FILES NOTHING from a
    ///    scan; the operator reads the report and runs `trk decision`. That this
    ///    scan is opt-in, one-shot and human-reviewed is exactly what makes
    ///    archaeology acceptable here and not on every archive run.
    ///
    /// Re-runnable, which is also how lanes forked from a pre-migration base are
    /// handled: they keep appending the legacy tag, so the orchestrator re-runs
    /// this after integrating. A second run finds no tags and is a no-op.
    ///
    /// No default tag: trk ships no project's vocabulary.
    fn cmdMigrateDecisions(self: *Cli, args: []const []const u8) Error!void {
        var from_tag: ?[]const u8 = null;
        var dry_run = false;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--from-tag")) {
                from_tag = try self.flagVal(args, &i, "--from-tag");
            } else if (std.mem.eql(u8, args[i], "--dry-run")) {
                dry_run = true;
            } else {
                return self.unknownFlag(args[i]);
            }
        }
        const tag = from_tag orelse {
            try self.write(
                "trk: migrate-decisions needs --from-tag <tag> — the tag THIS repo used to mark a fork\n" ++
                    "       awaiting a call (e.g. `--from-tag scott-decision`). trk ships no default: the\n" ++
                    "       convention is the repo's, not the tool's.\n",
            );
            return error.MissingArgument;
        };

        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        // Pass 1: split the tagged carriers.
        var split: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (!hasTag(t, tag)) continue;
            // Already split by an earlier run (idempotence): the carrier keeps
            // no tag, so this only fires on a tag re-added by a merged lane.
            var sb: [ulid.len]u8 = undefined;
            const sid = try self.shortId(id, &sb);
            if (dry_run) {
                try self.print("would split {s}  {s}\n", .{ sid, t.title });
                split += 1;
                continue;
            }

            var title_buf: std.ArrayList(u8) = .empty;
            defer title_buf.deinit(self.gpa);
            try title_buf.print(self.gpa, "Decision raised by {s}: {s}", .{ sid, t.title });

            const d = ulid.mint(self.io);
            var db: [ulid.len]u8 = undefined;
            const short = try self.mintShortId(d, &db);
            try self.store.append(.{ .add = .{ .id = d, .title = title_buf.items, .short = short } });
            try self.store.append(.{ .decisionDeclare = .{ .id = d, .declared = true } });
            try self.store.append(.{ .raises = .{ .task = id, .decision = d } });
            try self.store.append(.{ .untag = .{ .id = id, .tag = tag } });

            var db2: [ulid.len]u8 = undefined;
            try self.print("split {s}  {s}\n      -> decision {s} (write the question into it)\n", .{
                sid, t.title, try self.shortId(d, &db2),
            });
            split += 1;
        }

        // Pass 2: find prose forks. REPORT ONLY — the tool cannot know which
        // sentence is the fork, and guessing is the failure this whole
        // mechanism exists to end.
        var markers: std.ArrayList([]const u8) = .empty;
        defer markers.deinit(self.gpa);
        try markers.appendSlice(self.gpa, tracker.store.legacy_decision_markers);
        try markers.append(self.gpa, tag);

        var prose_tasks: usize = 0;
        var prose_lines: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (t.body.len == 0) continue;
            if (self.store.isDecision(id)) continue; // already structured
            var hits: usize = 0;
            var lines = std.mem.splitScalar(u8, t.body, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                for (markers.items) |m| {
                    if (m.len == 0 or !containsIgnoreCase(line, m)) continue;
                    if (hits == 0) {
                        var sb: [ulid.len]u8 = undefined;
                        try self.print("\nprose fork? {s}  {s}\n", .{ try self.shortId(id, &sb), t.title });
                        prose_tasks += 1;
                    }
                    hits += 1;
                    prose_lines += 1;
                    try self.print("    {s}\n", .{line});
                    break;
                }
            }
        }

        try self.print(
            "\ntrk: migrate-decisions: {d} tagged task(s) {s}; {d} line(s) across {d} task(s) look like a fork in prose.\n",
            .{ split, if (dry_run) "would be split" else "split", prose_lines, prose_tasks },
        );
        if (prose_tasks != 0) {
            try self.write(
                "  Those are REPORTED, never filed: only you know which sentence is the fork, and\n" ++
                    "  guessing is the failure this mechanism exists to end. For each real one:\n" ++
                    "    trk decision \"<the question>\" --from <id> [--blocks <id>]\n" ++
                    "  Nothing else will find these again — `archive` no longer scans bodies.\n",
            );
        }
        if (split != 0 and !dry_run) {
            try self.write(
                "  Each split decision is a SCAFFOLD: write the real question into it with\n" ++
                    "  `trk edit <id> --title \"<the question>\"`, and wire what waits on it with\n" ++
                    "  `trk dep <blocked-id> --needs <decision-id>`.\n",
            );
        }
    }

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
                return self.unknownFlag(args[i]);
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
                return self.unknownFlag(args[i]);
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
            if (e == error.DecisionNotWork) {
                try self.print(
                    "trk: {s} is a DECISION, not work — it cannot be {s}. A decision is a question " ++
                        "awaiting a ruling; resolve it with `trk rule {s} \"<the ruling>\"`, which records " ++
                        "the answer and closes it.\n",
                    .{ sid, st.toString(), sid },
                );
                return e;
            }
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
                return self.unknownFlag(args[i]);
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
        var dry_run = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--dry-run")) {
                dry_run = true;
            } else {
                return self.unknownFlag(a);
            }
        }
        if (dry_run) return self.compactDryRun();
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

    /// `trk compact --dry-run` — name every task this compact WOULD collect, and
    /// write nothing (01M1FMNSZ).
    ///
    /// The gap it closes: trk's compaction rules were written about task-to-task
    /// references — `needs` edges, arcs, citations inside other task bodies — all
    /// of which trk can see and reason about. They say nothing about ids cited
    /// from files OUTSIDE the tracker, which trk cannot see and which are, in a
    /// real project, load-bearing: a registry column, a source comment, a design
    /// doc, a commit message. Measured: four `scenarios/registry.tsv` rows on the
    /// Enix side ended up holding ids that resolved to nothing, and `git log -S`
    /// proved all three ids were honestly cited in the very commits that landed
    /// their rows. Not typos — collected work.
    ///
    /// trk cannot own that problem: it would have to know its consumers. What it
    /// can do is make the moment VISIBLE and let the caller grep its own tree
    /// first, which is where the knowledge actually lives. So: a read-only
    /// listing, on demand, from the same `collectableRows` the real run uses —
    /// never a second implementation that could disagree with it.
    ///
    /// The tombstone index (01M2M2K1J) already made the AFTER side survivable:
    /// every id below still resolves after the compact, `trk show` reports it
    /// COMPACTED (exit 2) with title and end-state, and the footer names the
    /// git command that brings the body back. This is the BEFORE side — the one
    /// that lets an external citation be updated while the task is still there
    /// to read.
    fn compactDryRun(self: *Cli) Error!void {
        // `compact` re-scans ghosts before deciding; so must this, or the
        // preview and the run could classify the same id differently.
        try self.store.collectGhostTasks();
        const rows = try self.store.collectableRows(self.gpa, 0);
        defer self.gpa.free(rows);

        if (rows.len == 0) {
            try self.write("trk: compact --dry-run: nothing to collect — no dropped, archived or ghost task in this store.\n");
            return;
        }
        try self.print("trk: compact --dry-run: {d} task(s) WOULD be collected. Nothing was written.\n", .{rows.len});
        for (rows) |tb| {
            try self.print("  {s}  {s:<9}  {s}\n", .{
                tb.short orelse &tb.id.text,
                tb.reason,
                if (tb.title.len != 0) tb.title else "(title not recorded)",
            });
            try self.print("      {s}\n", .{&tb.id.text});
        }
        try self.write(
            "  Each id above still RESOLVES after the compact — it is entombed in .tracker/" ++
                tracker.store.tombstones_name ++ " first,\n" ++
                "  and `trk show <id>` then reports it COMPACTED (exit 2) with its title and end state.\n" ++
                "  What a tombstone does NOT keep is the BODY. If anything OUTSIDE the tracker cites one of\n" ++
                "  these — a registry column, a source comment, a design doc — grep for it now, while the\n" ++
                "  task is still here to read. trk cannot see those citations, so it cannot check them for you.\n",
        );
    }

    /// Warn (to stderr, never stdout) when `.tracker/.gitattributes` is absent or
    /// missing one of its pins. Called from `compact` — the verb which CREATES
    /// `snapshot.jsonl`/`quarantine.jsonl` and writes `tombstones.jsonl` — and
    /// from `tombstones --rebuild`, the other verb that writes
    /// `tombstones.jsonl` (and can be the FIRST thing ever to, in a store that
    /// has never run `compact`). Each is the exact moment one of these
    /// whole-file-or-append-but-must-not-union files comes into existence or
    /// changes, so each is where a missing pin needs to surface.
    ///
    /// The claim is deliberately narrow. THIS CHECK never shells out to git —
    /// `stale` and `tombstones --rebuild`'s own history scan do, but this
    /// function, even called from the latter, does not — so it cannot ask what
    /// attributes are actually in EFFECT (a parent
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
            } else if (std.mem.eql(u8, args[i], "--arc")) {
                arc_filter = try self.flagVal(args, &i, "--arc");
            } else if (std.mem.eql(u8, args[i], "--tag")) {
                tag_filter = try self.flagVal(args, &i, "--tag");
            } else if (std.mem.eql(u8, args[i], "--word")) {
                try words.append(self.gpa, try self.flagVal(args, &i, "--word"));
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                return self.unknownFlag(args[i]);
            } else {
                // A bare id-shaped token here can ONLY be a mistake (finding 7,
                // 01M12ZG5ER): this slot is a SEARCH TERM, so a bare token that
                // looks like an id silently narrows the archive set to (almost
                // always) zero matches and reports an empty run with no error at
                // all. A search term that happens to be id-shaped is not a real
                // use case worth keeping alive at that cost.
                if (looksIdShaped(args[i])) {
                    try self.print(
                        "trk: '{s}' looks like a task id, not a search word — `trk archive` takes a " ++
                            "SEARCH TERM here, not a task to archive, so this would match nothing " ++
                            "and report an empty run. Archive by filter (--arc/--tag/<term>), or " ++
                            "close the task first and archive the whole done queue.\n",
                        .{args[i]},
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

        // NO DECISION GUARD. `archive` used to grep every closing body for
        // decision markers and refuse the run on a hit, because a fork living
        // in prose was destroyed the moment the task went `archived`. That whole
        // apparatus is gone (01M2VFX25): a fork is now its own node, so
        // archiving the task that raised it cannot bury it, and there is nothing
        // left for a body scan to protect. The scan survives exactly once, as a
        // one-shot FINDER in `trk migrate-decisions`, for prose written before
        // the mechanism existed.
        //
        // Deleted rather than demoted to a warning: this file's own argument
        // against warning was that one inside a bulk run scrolls past, and what
        // it failed to stop is permanent — so an advisory would supply assurance
        // without protection. And the guard's measured behaviour was to block
        // queues for weeks and then be worked around, which is friction, not
        // protection.
        //
        // Accepted residual, recorded in design.md rather than buried: a prose
        // fork written AFTER migration and archived is lost, with nothing to
        // catch it. The structured path exists; a tool cannot force prose to be
        // structure.

        // Build the changelog-bullet draft, GROUPED BY DESTINATION (01M2F8GBQ):
        // an explicit --out sends every task to one file, same as always;
        // otherwise each task's own tags are checked against `archive.routes`,
        // so a task whose gate/home differs from the rest of the batch (a
        // sub-library task gated differently from the main tree's, say, sitting
        // in the same done queue) lands in ITS OWN changelog, in this SAME run —
        // no manual
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
        // A decision routes by NATURE, not by tag (01M2VPC6K). `isDecision` is
        // structural, so nothing has to be tagged and nothing can be forgotten —
        // which is what made a tag-keyed decisions route fragile. Unset falls
        // through to the ordinary destination, so a repo that does not care
        // loses nothing; a repo whose changelog doctrine is "verified code only"
        // configures `archive.decisions_out` and keeps rulings out of it.
        if (self.store.isDecision(t.id)) {
            if (self.store.config.decisions_out) |d| return d;
        }
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
    /// Heuristic (finding 7, 01M12ZG5ER's flag surface): does `s` plausibly
    /// look like a ULID or a frozen/dynamic short-id (Crockford base32,
    /// case-insensitive, no I/L/O/U, length in a short-id's plausible range)?
    /// Used only to refuse a bare positional in `archive`'s arg list that would
    /// otherwise silently fall through to the title/body/tag search filter. Its
    /// original occasion — a second id typed after
    /// `--allow-buried-decisions-for` — is gone with that flag (01M2VFX25), but
    /// the hazard it names is not: `archive` takes a SEARCH TERM there, so
    /// `trk archive <id>` reads as "archive everything matching this text",
    /// matches nothing, and reports an empty run with no error at all.
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

    /// One changelog-draft bullet for a graduated task: `- <title> #tags
    /// (doc#sec) (<short-id>)`. No checkbox — it is completed; the short id is
    /// kept for traceability back to the tracker/log.
    fn appendArchiveBullet(self: *Cli, buf: *std.ArrayList(u8), id: Ulid) Error!void {
        const gpa = self.gpa;
        const t = self.store.get(id).?;
        // A DECISION's record is its RULING, and the ruling lives in the body —
        // the title is only the question (01M2VPC6K). Graduating one on the
        // ordinary bullet published the question and discarded the answer, which
        // for a decision is the whole value of the node: verified end-to-end,
        // after rule -> archive -> compact the ruling text was in ZERO bytes of
        // `.tracker/` and the changelog said `- which way? (01M2VPP4VD)`.
        //
        // A decision is disposable BECAUSE the answer lands here. Most forks are
        // "implement it way A or B", where the code that results carries the
        // answer and the node has no further job; the few that constrain FUTURE
        // work get promoted to docs/design.md by hand, which is a judgment no
        // tool should make. Either way nothing is lost by graduating, provided
        // the ruling is what graduates.
        if (self.store.isDecision(id)) {
            try buf.print(gpa, "- **{s}**\n", .{t.title});
            if (t.body.len != 0) {
                var lines = std.mem.splitScalar(u8, t.body, '\n');
                while (lines.next()) |raw| {
                    const line = std.mem.trimEnd(u8, raw, " \t\r");
                    if (line.len == 0) try buf.print(gpa, "\n", .{}) else try buf.print(gpa, "  {s}\n", .{line});
                }
            } else {
                try buf.print(gpa, "  (no ruling recorded)\n", .{});
            }
            var db: [ulid.len]u8 = undefined;
            try buf.print(gpa, "  ({s})\n", .{try self.shortId(id, &db)});
            return;
        }
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
        // `trk next parser` is "the ready frontier, parser only".
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(self.gpa);
        // `--not-tag <t>` (repeatable, ANDed exclusion): drop any task carrying
        // ANY of these tags — a repo's own blocker-tag vocabulary, whatever it
        // is. Decisions are NOT in it any more: they are excluded from `next`
        // structurally (01M2VFV84), so no term is needed for them and none can
        // be forgotten.
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
                return self.unknownFlag(args[i]);
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
            // No footer and no rows: an array has nowhere to put a tail, and
            // adding decision rows would contradict the exclusion that just
            // kept them out. A machine reader asks `list --decision --state
            // open` instead — said in `next --help`, not left to be discovered.
            try self.write("]\n");
            return;
        }
        if (shown == 0) try self.write("(nothing ready)\n");
        try self.withheldByDecisionsTail();
    }

    /// Say what `next` withheld because it is waiting on an unruled fork
    /// (01M2VFV84).
    ///
    /// Without this, excluding decisions from the frontier is a REGRESSION
    /// dressed as a fix: a decision that blocks work makes `next` print
    /// `(nothing ready)` with nothing explaining why, where the old
    /// `--not-tag <tag>` convention was at least opt-in and left the fork
    /// visible in a bare `next`.
    ///
    /// The `list --arc` compacted-members tail (01M2V2TSA) declined to give
    /// `next` a tail of its own, on the grounds that a graduated member is never
    /// an answer to "what can I work on". That reasoning does not reach here: a
    /// PENDING DECISION is precisely the answer to "why is nothing ready".
    fn withheldByDecisionsTail(self: *Cli) Error!void {
        var n_decisions: usize = 0;
        const withheld = try self.store.blockedOnDecisions(self.gpa, &n_decisions);
        defer self.gpa.free(withheld);
        if (withheld.len == 0) return;
        try self.print(
            "\n  {d} task(s) withheld: waiting on {d} pending decision(s).\n" ++
                "  `trk list --decision --state open` to see them; `trk rule <id> \"<the ruling>\"` releases the work.\n",
            .{ withheld.len, n_decisions },
        );
    }

    /// `stateMarker`, except a DECISION gets `[?]` (01M2VFV84).
    ///
    /// `membersOf` closes over `needs`, so a decision filed `--blocks T` joins
    /// T's arc by reachability and lands in `render`'s TODO.md and in `tree`
    /// under T. Without a distinct marker it renders as an ordinary `[ ]`
    /// bullet — a question indistinguishable from a slice, in the projection
    /// whose entire contract is not-yet-built WORK. `[?]` only while it is still
    /// open: a ruled decision is `done` and reads `[x]` like anything else, so
    /// the marker tracks "awaiting a call", not the declaration.
    fn markerFor(self: *Cli, id: Ulid, st: State) []const u8 {
        if (st == .open and self.store.isDecision(id)) return "[?]";
        return stateMarker(st);
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
        // `--decision`: the pre-dispatch sweep — "what is still waiting on a
        // call" (01M2VFV83). This is the query the whole decisions mechanism
        // serves, and what replaces `list --tag scott-decision`. Combines with
        // `--state open` for the PENDING ones specifically: a declaration is
        // nature and stays true after a ruling, so `--decision` alone is every
        // decision ever raised, ruled or not.
        var decisions_only = false;
        // `--all`: include completed states (done/dropped/archived) that the
        // default hides. The escape hatch for the one-listing-of-everything
        // case, so nothing becomes unreachable.
        var show_all = false;
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
            } else if (std.mem.eql(u8, args[i], "--decision")) {
                decisions_only = true;
            } else if (std.mem.eql(u8, args[i], "--all")) {
                show_all = true;
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
                return self.unknownFlag(args[i]);
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

        const tomb_filter: TombFilter = .{
            .state = state_filter,
            .show_all = show_all,
            .decisions_only = decisions_only,
            .tag = tag_filter,
            .words = words.items,
        };

        if (json) try self.write("[");
        var shown: usize = 0;
        for (ids) |id| {
            const t = self.store.get(id).?;
            if (state_filter) |sf| {
                if (t.state != sf) continue;
            } else if (!show_all and !isRemaining(t.state)) {
                // COMPLETED work is hidden unless asked for (01M2VPC6K). This is
                // the rule `archived` already followed — "retired to the
                // changelog; hidden unless asked for explicitly so the live list
                // stays clean" — applied one state earlier, where the same
                // reasoning holds and the numbers are worse: measured on trk's
                // own store the default listing was 29 completed rows out of 31,
                // i.e. 94% of it was noise, while `next` and the TODO.md
                // projection were clean because they already filter to remaining
                // work.
                //
                // It matters more now that decisions are nodes: a ruled decision
                // sits `done` until an archive run graduates it, and rulings
                // arrive steadily, so without this the default listing trends
                // toward being mostly answered questions.
                //
                // `--state done` is the archive queue (and the natural
                // pre-archive check), `--state archived` the graduated set, and
                // `--all` the union for when everything really is wanted.
                continue;
            }
            if (members) |m| if (!containsId(m, id)) continue;
            if (decisions_only and !self.store.isDecision(id)) continue;
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
            // The machine half of the footer below. Rows, not a sibling key:
            // `list --json` is an ARRAY by contract and a footer has nowhere to
            // live in one, so the choice is rows or nothing — and nothing leaves
            // the agent-facing half of this view carrying the exact defect the
            // human half just stopped carrying. Each row carries
            // `"compacted": true`, the key `show --json` already uses and that
            // design.md rules a machine reader should branch on, so a consumer
            // that wants today's output filters on one key rather than parsing
            // for an absence.
            //
            // They pass the SAME filters as the live rows (01M31H1JA). Appended
            // unfiltered, `--arc X --state open` answered 45 rows of which 33
            // were closed-and-GC'd work with no state at all — and under
            // `--decision` they read as unanswered questions. `--arc` narrows;
            // it must never widen what the other flags excluded.
            if (arc_id) |a| {
                const gone = try self.store.compactedMembers(self.gpa, a);
                defer self.gpa.free(gone);
                for (gone) |tb| {
                    if (!tomb_filter.admits(tb)) continue;
                    if (limit) |lim| if (shown >= lim) break;
                    if (shown != 0) try self.write(",");
                    try self.tombstoneJsonOpen(tb);
                    try self.write("}");
                    shown += 1;
                }
            }
            try self.write("]\n");
            return;
        }
        if (shown == 0) try self.write("(no matching tasks)\n");
        try self.compactedMemberFooter(arc_id, tomb_filter);
    }

    /// Whether a compacted arc member passes `list`'s filters (01M31H1JA).
    /// A tombstone keeps id, short, title and end state — never tags, body or
    /// decision nature — so the rule is: admit only what the record can SHOW
    /// it satisfies. Its end state is `reason`; `ghost`/`unknown` match no
    /// state. A filter over a field it does not keep (`--decision`, `--tag`)
    /// drops it, and search terms are matched against the title alone.
    /// `--not-tag` can never exclude it: it carries no tag to exclude.
    const TombFilter = struct {
        state: ?State,
        show_all: bool,
        decisions_only: bool,
        tag: ?[]const u8,
        words: []const []const u8,

        fn admits(f: TombFilter, tb: *const tracker.store.Tombstone) bool {
            if (f.state) |sf| {
                if (State.fromString(tb.reason) != sf) return false;
            } else if (!f.show_all) {
                // Every tombstone is completed work, which the default hides.
                return false;
            }
            if (f.decisions_only or f.tag != null) return false;
            for (f.words) |w| if (!containsSubCI(tb.title, w)) return false;
            return true;
        }
    };

    /// `list --arc <id>`'s graduated tail (01M2V2TSA).
    ///
    /// `list` is the one member-enumerating view where this is a
    /// self-inconsistency rather than an extension: it ALREADY lists closed work
    /// — `done` and `submitted` rows are ordinary output — and a compacted
    /// member is the only kind it silently drops, because `compact` deletes the
    /// `in` edge along with the member it collected (`serializeState`'s
    /// `gc_set`; an edge naming a collected id would re-materialize it as a
    /// ghost). So an arc that was fully built and graduated reads identically to
    /// one nobody ever sliced.
    ///
    /// A COUNT plus a pointer, not the rows themselves: `trk tree <arc>` already
    /// renders the full graduated block in a shape that cannot be skim-read as
    /// live work, and duplicating it here would be a second copy to keep in
    /// step. `next` and `docs/TODO.md` deliberately get nothing — `next` is a
    /// ready frontier that already omits done/blocked/leased members without
    /// anyone calling that a silent absence, and the projection's own contract
    /// is "only not-yet-built work" (Scott's call, 2026-09-18).
    ///
    /// Counts only the members the listing's filters admit (`TombFilter`,
    /// 01M31H1JA): the footer is the human half of the `--json` rows, and the
    /// two halves answer one question.
    fn compactedMemberFooter(self: *Cli, arc_id: ?Ulid, filter: TombFilter) Error!void {
        const a = arc_id orelse return;
        const gone = try self.store.compactedMembers(self.gpa, a);
        defer self.gpa.free(gone);
        var n: usize = 0;
        for (gone) |tb| {
            if (filter.admits(tb)) n += 1;
        }
        if (n == 0) return;
        var sb: [ulid.len]u8 = undefined;
        try self.print(
            "\n  +{d} compacted member(s) not shown — graduated out of the live store;\n" ++
                "  `trk tree {s}` names them.\n",
            .{ n, try self.shortId(a, &sb) },
        );
    }

    /// list one-liner: `<state-marker> <short-id>  <title>  #tags`.
    fn printListLine(self: *Cli, id: Ulid) !void {
        const t = self.store.get(id).?;
        var sb: [ulid.len]u8 = undefined;
        try self.print("{s} {s}  {s}", .{ self.markerFor(id, t.state), try self.shortId(id, &sb), t.title });
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
                return self.unknownFlag(args[i]);
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
        const checkbox = self.markerFor(id, t.state);
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
        try buf.print(gpa, "{s} {s} {s}\n", .{ self.markerFor(root, rt.state), rsid, rt.title });
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
        if (members.len == 0) {
            // One state, and only one, where an empty block still cannot be
            // read (01M2V2TYC): a store with NO tombstone index at all. Then
            // "no compacted members" and "nothing has ever been recorded here"
            // are the same silence — which is the exact ambiguity this block
            // exists to end. Said once, only for an arc (a plain task's tree
            // has no membership question), and never when the index has
            // anything in it: after the rebuild learned to recover `in` edges,
            // a populated index with no hit for this arc is a real answer.
            if (self.store.tombstones.items.len == 0 and self.store.isArc(arc)) {
                try buf.print(gpa, "\n  (no tombstone index in this store — if it has ever run `trk compact`,\n" ++
                    "   run `trk tombstones --rebuild`: graduated members cannot be reported without it.)\n", .{});
            }
            return;
        }

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
        try buf.print(gpa, "{s}{s}{s} {s} {s}", .{ prefix.items, connector, self.markerFor(id, t.state), sid, t.title });
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

        // Decisions: what this task raised, or — if it IS one — who raised it.
        // Only printed when there is something to say, so an ordinary task's
        // `show` is unchanged.
        if (self.store.isDecision(id)) {
            try self.write("\nDECISION — a fork awaiting a ruling");
            if (t.state.satisfiesPrereq()) try self.print(" (ruled: {s})", .{t.state.toString()});
            try self.write("\n");
            const raisers = try self.store.raisersOf(self.gpa, id);
            defer self.gpa.free(raisers);
            const gone = try self.store.compactedRaisers(self.gpa, id);
            defer self.gpa.free(gone);
            if (raisers.len == 0 and gone.len == 0) {
                try self.write("  raised by: (not recorded)\n");
            } else {
                try self.write("  raised by:\n");
                for (raisers) |r| {
                    var rb: [ulid.len]u8 = undefined;
                    try self.print("    {s}  {s}\n", .{ try self.shortId(r, &rb), self.store.get(r).?.title });
                }
                // A raiser that has since been compacted still answers, from
                // the task-side `raised` field on its tombstone — the reason
                // that field is on the task side at all.
                for (gone) |tb| try self.print("    compacted: {s}  {s}\n", .{
                    tb.short orelse &tb.id.text,
                    if (tb.title.len != 0) tb.title else "(title not recorded)",
                });
            }
            if (!t.state.satisfiesPrereq()) {
                var idb: [ulid.len]u8 = undefined;
                try self.print("  resolve with: trk rule {s} \"<the ruling>\"\n", .{try self.shortId(id, &idb)});
            }
        } else {
            const raised = try self.store.raisedBy(self.gpa, id);
            defer self.gpa.free(raised);
            if (raised.len != 0) {
                try self.write("\ndecisions raised by this task:\n");
                for (raised) |d| {
                    var db: [ulid.len]u8 = undefined;
                    const dt = self.store.get(d).?;
                    try self.print("  {s} {s}  {s}\n", .{
                        self.markerFor(d, dt.state), try self.shortId(d, &db), dt.title,
                    });
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
        // `decision` only when true, matching how `compacted` marks a tombstone:
        // a machine reader branches on a key rather than on the absence of one,
        // and an ordinary task's object is unchanged.
        if (self.store.isDecision(id)) try self.write(",\"decision\":true");
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

        // Provenance, both directions, always present so a consumer indexes
        // without a guard: `raises` on a task, `raised_by` on a decision.
        try self.write(",\"raises\":[");
        {
            const raised = try self.store.raisedBy(self.gpa, id);
            defer self.gpa.free(raised);
            for (raised, 0..) |d, n| {
                if (n != 0) try self.write(",");
                try self.print("\"{s}\"", .{&d.text});
            }
        }
        try self.write("],\"raised_by\":[");
        {
            const raisers = try self.store.raisersOf(self.gpa, id);
            defer self.gpa.free(raisers);
            var n: usize = 0;
            for (raisers) |r| {
                if (n != 0) try self.write(",");
                n += 1;
                try self.print("\"{s}\"", .{&r.text});
            }
            // A raiser that has since been compacted still answers, from the
            // task-side `raised` on its tombstone.
            const gone = try self.store.compactedRaisers(self.gpa, id);
            defer self.gpa.free(gone);
            for (gone) |tb| {
                if (n != 0) try self.write(",");
                n += 1;
                try self.print("\"{s}\"", .{&tb.id.text});
            }
        }
        try self.write("]");

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
                return self.unknownFlag(arg);
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

    // ----------------------------------------------------------- decision

    /// `trk decision "<question>" [--from <id>] [--blocks <id> ...] [--in <arc>]
    /// [--tag <t> ...] [--body <s>]` — raise a fork as its own node
    /// (01M2VFV83).
    ///
    /// This is the authoring-time capture the whole mechanism rests on. A fork
    /// used to be a string in a body plus a tag, so intent was destroyed the
    /// moment it was written and every downstream mechanism was left grepping
    /// prose for it. Said here, once, it is structure.
    ///
    /// The two relations are SEPARATE because they are different facts:
    ///   * `--from <id>`   — provenance. This task raised it. No scheduling
    ///                       effect whatsoever.
    ///   * `--blocks <id>` — an ordinary `dep`: that task needs this ruling.
    /// A fork noticed while doing T usually does NOT stop T, so non-blocking is
    /// the default and `--blocks` is opt-in. `--blocks` names the task that
    /// WAITS, so the edge direction is stated as an effect rather than as two
    /// interchangeable endpoints — the same hazard that made the bare
    /// `trk dep A B` form a hard error.
    fn cmdDecision(self: *Cli, args: []const []const u8) Error!void {
        if (args.len == 0) {
            try self.write("trk: decision needs a \"<question>\"\n");
            return error.MissingArgument;
        }
        var question: ?[]const u8 = null;
        var body: []const u8 = "";
        var body_owned = false;
        defer if (body_owned) self.gpa.free(body);
        var from_arg: ?[]const u8 = null;
        var in_arc: ?[]const u8 = null;
        var seq: i32 = 0;
        var verbose = false;
        var blocks: std.ArrayList([]const u8) = .empty;
        defer blocks.deinit(self.gpa);
        var tags: std.ArrayList([]const u8) = .empty;
        defer tags.deinit(self.gpa);

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (arg.len == 0 or arg[0] != '-') {
                if (question != null) {
                    try self.print(
                        "trk: decision takes exactly one positional (the question) — '{s}' is a second one. " ++
                            "Quote the whole question as ONE argument (trk decision --help)\n",
                        .{arg},
                    );
                    return error.UsageError;
                }
                question = arg;
            } else if (std.mem.eql(u8, arg, "--from")) {
                from_arg = try self.flagVal(args, &i, "--from");
            } else if (std.mem.eql(u8, arg, "--blocks")) {
                try blocks.append(self.gpa, try self.flagVal(args, &i, "--blocks"));
            } else if (std.mem.eql(u8, arg, "--in")) {
                in_arc = try self.flagVal(args, &i, "--in");
            } else if (std.mem.eql(u8, arg, "--seq")) {
                seq = try self.parseI32(try self.flagVal(args, &i, "--seq"));
            } else if (std.mem.eql(u8, arg, "--tag")) {
                try tags.append(self.gpa, try self.flagVal(args, &i, "--tag"));
            } else if (std.mem.eql(u8, arg, "--body")) {
                const b = try self.bodyArg("--body", try self.flagVal(args, &i, "--body"));
                body = b.text;
                body_owned = b.owned;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else {
                return self.unknownFlag(arg);
            }
        }

        const the_question = question orelse {
            try self.write("trk: decision needs a \"<question>\" — every other argument here is a flag.\n");
            return error.MissingArgument;
        };

        // Resolve every referenced id BEFORE minting, so a bad --from/--blocks/
        // --in fails without leaving a half-built decision in the log — the same
        // rule `add` follows.
        const from_id: ?Ulid = if (from_arg) |f| try self.resolve(f) else null;
        const arc_id: ?Ulid = if (in_arc) |a| try self.resolve(a) else null;
        if (arc_id) |a| {
            if (!self.store.isArc(a)) {
                var ab: [ulid.len]u8 = undefined;
                const as = try self.shortId(a, &ab);
                try self.print(
                    "trk: refusing: {s} is not a declared arc — declare it first with `trk arc {s}`, then retry\n",
                    .{ as, as },
                );
                return error.UndeclaredArc;
            }
        }
        const blocked = try self.gpa.alloc(Ulid, blocks.items.len);
        defer self.gpa.free(blocked);
        for (blocks.items, 0..) |b, bi| blocked[bi] = try self.resolve(b);

        const id = ulid.mint(self.io);
        // Freeze the short id before `id` is in the store, so the collision
        // check runs against the pre-add id set (mintShortId's contract).
        var sb: [ulid.len]u8 = undefined;
        const short = try self.mintShortId(id, &sb);
        const tag_slice = try self.gpa.alloc([]const u8, tags.items.len);
        defer self.gpa.free(tag_slice);
        for (tags.items, 0..) |tg, ti| tag_slice[ti] = tg;

        try self.store.append(.{ .add = .{
            .id = id,
            .title = the_question,
            .body = body,
            .tags = tag_slice,
            .short = short,
        } });
        try self.store.append(.{ .decisionDeclare = .{ .id = id, .declared = true } });
        if (from_id) |f| try self.store.append(.{ .raises = .{ .task = f, .decision = id } });
        if (arc_id) |a| try self.store.append(.{ .in = .{ .task = id, .arc = a, .seq = seq } });
        for (blocked) |b| try self.store.append(.{ .dep = .{ .from = b, .to = id } });

        var idb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &idb);
        if (verbose) {
            try self.print("raised decision {s} ({s})\n", .{ sid, &id.text });
            if (from_id) |f| {
                var fb: [ulid.len]u8 = undefined;
                try self.print("  raised by {s}\n", .{try self.shortId(f, &fb)});
            }
            for (blocked) |b| {
                var bb: [ulid.len]u8 = undefined;
                try self.print("  blocks {s}\n", .{try self.shortId(b, &bb)});
            }
        } else {
            // Scriptable, exactly like `add`: stdout is the id and nothing else.
            try self.print("{s}\n", .{&id.text});
        }
        if (blocked.len == 0) {
            try self.warn.print(
                self.gpa,
                "trk: note: {s} blocks nothing — it will not hold any task back. " ++
                    "If work is waiting on this ruling, say so: `trk decision ... --blocks <id>`.\n",
                .{sid},
            );
        }
    }

    /// `trk rule <id> <ruling text|->` — record the ruling and CLOSE the
    /// decision, atomically (01M2VFV83).
    ///
    /// Resolution is STATE; declaration is nature and is never touched here.
    /// That split is what makes the blocking `dep` release on the ruling with no
    /// second command: `done` satisfies a prereq, so every task that was waiting
    /// on this fork becomes eligible the moment it is answered. The earlier
    /// tag-based shape appended the ruling and untagged WITHOUT closing, which
    /// under `dep`-based blocking would leave the work blocked pending a
    /// separate, forgettable `trk state <id> done` — the exact failure `rule`
    /// exists to eliminate — and would leave the answered question sitting in
    /// `next` as work to go build.
    ///
    /// REFUSES on anything that is not a declared decision. The direct analogue
    /// of the old "refuses on a task not currently carrying the tag": `rule` is
    /// the resolver for decisions, and using it on ordinary work would close
    /// that work on the strength of a note.
    fn cmdRule(self: *Cli, args: []const []const u8) Error!void {
        if (args.len < 2) {
            try self.write("trk: usage: trk rule <id> <ruling text|->\n" ++
                "  Appends <ruling text> to the decision's body and closes it, atomically.\n");
            return error.MissingArgument;
        }
        const id = try self.resolve(args[0]);
        if (args.len > 2) {
            try self.print("trk: rule takes exactly one ruling-text argument, got {d} extra\n", .{args.len - 2});
            return error.UsageError;
        }
        const b = try self.bodyArg("rule", args[1]);
        defer if (b.owned) self.gpa.free(b.text);

        var sb: [ulid.len]u8 = undefined;
        const sid = try self.shortId(id, &sb);

        if (!self.store.isDecision(id)) {
            try self.print(
                "trk: {s} is not a decision — `rule` records the answer to a fork and closes it. " ++
                    "To raise one, `trk decision \"<question>\" --from {s}`; to add a note to ordinary " ++
                    "work, `trk edit {s} --append-body`.\n",
                .{ sid, sid, sid },
            );
            return error.UsageError;
        }

        const t = self.store.get(id).?; // resolve() already proved it exists
        if (t.state.satisfiesPrereq()) {
            try self.print(
                "trk: {s} is already {s} — it has been ruled. `trk show {s}` for the ruling; " ++
                    "`trk edit {s} --append-body` to add to it.\n",
                .{ sid, t.state.toString(), sid, sid },
            );
            return error.UsageError;
        }

        try self.applyBodyEdit(id, sid, b.text, true);
        try self.store.append(.{ .setState = .{ .id = id, .state = .done } });
        try self.print("{s}: ruled and closed\n", .{sid});

        // Name what the ruling just released. The whole point of blocking on a
        // decision is that answering it unblocks the work, and an agent that
        // cannot see which work moved has to go looking for it.
        const freed = try self.store.reverseDeps(self.gpa, id);
        defer self.gpa.free(freed);
        if (freed.len != 0) {
            try self.print("  unblocks {d} task(s):\n", .{freed.len});
            for (freed) |f| {
                var fb: [ulid.len]u8 = undefined;
                try self.print("    {s}  {s}\n", .{ try self.shortId(f, &fb), self.store.get(f).?.title });
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
                return self.unknownFlag(arg);
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

    /// Scan one append-log-shaped file (`.tracker/snapshot.jsonl` or
    /// `.tracker/log.jsonl`) for the two raw signals `stale-rulings` needs and
    /// nothing else: `ruled_ts[id]` = the ts of a decision's first `setState ->
    /// done` (the exact moment `cmdRule` fires — see its doc comment), and
    /// `body_ts[id]` = the max ts of any `setBody` targeting that task. Both are
    /// read straight off `model.Event`'s own typed payload via `codec.decode` —
    /// never a scan of generated summary TEXT (`readLogEntries` collapses a
    /// `raises`/`setState` event into prose; this reads the payload itself, the
    /// same as `cmdTombstones`'s git-history scan does).
    fn scanRulingEvents(
        self: *Cli,
        name: []const u8,
        ruled_ts: *std.AutoHashMapUnmanaged(Ulid, i64),
        body_ts: *std.AutoHashMapUnmanaged(Ulid, i64),
    ) Error!void {
        var sub = self.dir.openDir(self.io, tracker.store.tracker_subdir, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
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
            const ev = codec.decode(self.gpa, trimmed) catch continue;
            defer Store.freeEvent(self.gpa, ev);
            switch (ev) {
                .setBody => |x| {
                    const cur = body_ts.get(x.id) orelse 0;
                    if (x.ts > cur) try body_ts.put(self.gpa, x.id, x.ts);
                },
                .setState => |x| {
                    // First transition INTO `done` only — a later `archive`
                    // flips the SAME id to `archived`, which must never
                    // overwrite the ruling moment we actually want.
                    if (x.state == .done) {
                        const cur = ruled_ts.get(x.id);
                        if (cur == null or x.ts < cur.?) try ruled_ts.put(self.gpa, x.id, x.ts);
                    }
                },
                else => {},
            }
        }
    }

    /// `trk stale-rulings [--json]` — see its help text for the full argument;
    /// in one line, a raiser is flagged unless its own most recent `setBody`
    /// postdates the ruling of a decision it `raises` (01M31D03S).
    fn cmdStaleRulings(self: *Cli, args: []const []const u8) Error!void {
        var json = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else {
                try self.write("trk: usage: trk stale-rulings [--json]\n");
                return error.UsageError;
            }
        }

        var ruled_ts = std.AutoHashMapUnmanaged(Ulid, i64){};
        defer ruled_ts.deinit(self.gpa);
        var body_ts = std.AutoHashMapUnmanaged(Ulid, i64){};
        defer body_ts.deinit(self.gpa);
        try self.scanRulingEvents(tracker.store.snapshot_name, &ruled_ts, &body_ts);
        try self.scanRulingEvents(tracker.store.log_name, &ruled_ts, &body_ts);

        const ids = try self.store.allIds(self.gpa);
        defer self.gpa.free(ids);

        const Hit = struct { raiser: Ulid, decision: Ulid, ruled: i64, body: i64 };
        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(self.gpa);

        for (ids) |id| {
            if (!self.store.isDecision(id)) continue;
            const d = self.store.get(id) orelse continue;
            if (d.state != .done and d.state != .archived) continue;
            // No observed `done` transition for a task that currently reads
            // done/archived: shouldn't happen (both states are reached only
            // through it), but this is a read-only diagnostic — skip rather
            // than guess a timestamp for it.
            const rts = ruled_ts.get(id) orelse continue;

            const raisers = try self.store.raisersOf(self.gpa, id);
            defer self.gpa.free(raisers);
            for (raisers) |tid| {
                const t = self.store.get(tid) orelse continue;
                if (t.state != .open and t.state != .blocked and t.state != .claimed) continue;
                const bts = body_ts.get(tid) orelse 0;
                // STRICTLY after, not "at or after": a same-millisecond write
                // is not a meaningfully later one. Production timestamps are
                // wall-clock ms and typically hours-to-days apart, so this
                // only bites a fast synthetic fixture (see the selftest).
                if (bts <= rts) {
                    try hits.append(self.gpa, .{ .raiser = tid, .decision = id, .ruled = rts, .body = bts });
                }
            }
        }

        std.sort.pdq(Hit, hits.items, {}, struct {
            fn lt(_: void, a: Hit, b: Hit) bool {
                return std.mem.lessThan(u8, &a.raiser.text, &b.raiser.text);
            }
        }.lt);

        if (json) {
            try self.write("[");
            for (hits.items, 0..) |h, i| {
                if (i != 0) try self.write(",");
                var rb: [ulid.len]u8 = undefined;
                const rsid = try self.shortId(h.raiser, &rb);
                var db: [ulid.len]u8 = undefined;
                const dsid = try self.shortId(h.decision, &db);
                try self.print(
                    "{{\"raiser\":\"{s}\",\"raiser_short\":\"{s}\",\"decision\":\"{s}\",\"decision_short\":\"{s}\",\"ruled_ts\":{d},\"body_ts\":{d}}}",
                    .{ &h.raiser.text, rsid, &h.decision.text, dsid, h.ruled, h.body },
                );
            }
            try self.write("]\n");
        } else if (hits.items.len == 0) {
            try self.write("trk: stale-rulings: nothing — every open/blocked/claimed raiser has touched its body since its decision was ruled\n");
            return;
        } else {
            try self.print("trk: stale-rulings: {d} raiser task(s) not reconciled since their decision was ruled:\n", .{hits.items.len});
            for (hits.items) |h| {
                const t = self.store.get(h.raiser).?;
                var sb: [ulid.len]u8 = undefined;
                const sid = try self.shortId(h.raiser, &sb);
                var db: [ulid.len]u8 = undefined;
                const dsid = try self.shortId(h.decision, &db);
                try self.print("{s} {s}  {s}\n    raises ruled decision {s}\n", .{ stateMarker(t.state), sid, t.title, dsid });
            }
        }

        if (hits.items.len != 0) return error.StaleRulings;
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
        if (rebuild) {
            try self.rebuildTombstones();
            // Same reason `compact` checks: `--rebuild` is the OTHER verb that
            // writes tombstones.jsonl, and can be the FIRST one to (a store
            // that has never run `compact` still has a rebuildable git
            // history). Without this, a repo whose only tombstones.jsonl write
            // ever came from `--rebuild` would carry an unpinned file with no
            // warning until some later `compact` happened to run.
            try self.warnUnpinnedAttrs();
        }

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
        /// The arcs this id was a direct member of, reconstructed from the
        /// `in`/`unin` events in the same history (01M2V2TYC). Allocated out of
        /// the caller's `ra` arena, like `title`/`short`.
        arcs: std.ArrayListUnmanaged(Ulid) = .empty,
        /// The decisions this id raised, reconstructed from the `raises`/
        /// `unraises` events in the same history by the identical
        /// surviving-pair rule (01M2VFW5F).
        raised: std.ArrayListUnmanaged(Ulid) = .empty,
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

        // Membership reconstruction (01M2V2TYC). `compact` records a task's
        // arcs at the moment it collects it, when the edges are still in the
        // store — which is why the feature works going FORWARD, and why every
        // record this scan back-filled before now carried `"arcs":[]` by
        // construction (measured: 2521 of 2521 on the Enix store). The `in`
        // edges are right here in the same history the scan already reads end
        // to end; they just were not being read.
        //
        // The rule mirrors the FOLD exactly (`Store.apply`'s `.unin`), and is
        // NOT the largest-ts last-write-wins used for title/state above: `unin`
        // records a permanent tombstone for the (task, arc) pair, so a later
        // `in` for the same pair is blocked regardless of append order. So a
        // member iff some `in` for the pair exists and no `unin` for it does,
        // anywhere in history. Two flat pair sets say that without needing the
        // history in order — just as well, since `git log --all -p` is not in
        // any order the fold would recognize.
        //
        // Direct `in` edges only, matching what `compact` writes — not
        // reachability-derived membership, which `dep` can create as a side
        // effect. A tombstone answers "what was this", and `in` is the part
        // that was DECLARED about it.
        const Pair = [2 * ulid.len]u8;
        var in_pairs = std.AutoHashMapUnmanaged(Pair, void){};
        defer in_pairs.deinit(self.gpa);
        var unin_pairs = std.AutoHashMapUnmanaged(Pair, void){};
        defer unin_pairs.deinit(self.gpa);
        // `raises`/`unraises` follow the IDENTICAL rule, for the identical
        // reason: `unraises` is a permanent fold tombstone for the pair, so a
        // later `raises` is blocked regardless of append order (01M2VFW5F).
        var raises_pairs = std.AutoHashMapUnmanaged(Pair, void){};
        defer raises_pairs.deinit(self.gpa);
        var unraises_pairs = std.AutoHashMapUnmanaged(Pair, void){};
        defer unraises_pairs.deinit(self.gpa);

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
                .in => |x| try in_pairs.put(self.gpa, pairKey(x.task, x.arc), {}),
                .unin => |x| try unin_pairs.put(self.gpa, pairKey(x.task, x.arc), {}),
                .raises => |x| try raises_pairs.put(self.gpa, pairKey(x.task, x.decision), {}),
                .unraises => |x| try unraises_pairs.put(self.gpa, pairKey(x.task, x.decision), {}),
                else => {},
            }
        }

        // Every surviving `in` becomes an arc on its task's record.
        var pit = in_pairs.keyIterator();
        while (pit.next()) |pk| {
            if (unin_pairs.contains(pk.*)) continue;
            const task: [ulid.len]u8 = pk[0..ulid.len].*;
            const arc: [ulid.len]u8 = pk[ulid.len..][0..ulid.len].*;
            const gop = try recs.getOrPut(self.gpa, task);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.arcs.append(ra, .{ .text = arc });
        }
        // Every surviving `raises` becomes a `raised` entry on its RAISER's
        // record — the task side, matching where the tombstone keeps it.
        var qit = raises_pairs.keyIterator();
        while (qit.next()) |pk| {
            if (unraises_pairs.contains(pk.*)) continue;
            const task: [ulid.len]u8 = pk[0..ulid.len].*;
            const decision: [ulid.len]u8 = pk[ulid.len..][0..ulid.len].*;
            const gop = try recs.getOrPut(self.gpa, task);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.raised.append(ra, .{ .text = decision });
        }

        // Sorted, because hash-map iteration order would otherwise make the
        // rebuilt file differ run to run for no reason — and it is committed.
        var rit = recs.valueIterator();
        while (rit.next()) |rec| {
            std.sort.pdq(Ulid, rec.arcs.items, {}, Ulid.lessThan);
            std.sort.pdq(Ulid, rec.raised.items, {}, Ulid.lessThan);
        }

        return recs;
    }

    /// The (task, arc) key the membership sets above are built on: the two
    /// 26-char ULID texts concatenated, so an edge is one hashable value.
    fn pairKey(task: Ulid, arc: Ulid) [2 * ulid.len]u8 {
        var k: [2 * ulid.len]u8 = undefined;
        @memcpy(k[0..ulid.len], &task.text);
        @memcpy(k[ulid.len..], &arc.text);
        return k;
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
                .arcs = e.value_ptr.arcs.items,
                .raised = e.value_ptr.raised.items,
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
                "{d} new tombstone(s) recorded, {d} existing record(s) upgraded, " ++
                "{d} already complete or still live.\n",
            .{ recs.count(), log_path, written.new, written.upgraded, recs.count() - written.total() },
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

/// Case-insensitive substring search — the legacy marker match `trk
/// migrate-decisions` scans bodies with. Case-insensitive because the prose it
/// is looking for was written by hand over months ("FIX NOTE", "Fix note",
/// "fix note" all appear).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, haystack[i..][0..needle.len]) |n, h| {
            if (std.ascii.toUpper(n) != std.ascii.toUpper(h)) continue :outer;
        }
        return true;
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
/// any tag. Tags are included so `--word parser` catches `#arc:parser-rewrite`.
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
