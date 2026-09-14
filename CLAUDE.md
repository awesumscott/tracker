# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`trk` — an in-repo, agent-first issue tracker: tasks are DAG nodes stored in an append-only JSONL log under `.tracker/`, projected to a generated `TODO.md`. One Zig binary, std-only, no dependencies. GPL-3.0-or-later; every source file carries the SPDX header + copyright line — add them to new files.

## Commands

Requires Zig 0.16 (uses the `std.Io`-threaded filesystem/time/random APIs; `std.time.milliTimestamp` and `std.crypto.random` no longer exist).

```
zig build                     # -> zig-out/bin/trk
zig build test                # all tests: library unit tests + store_test.zig + cli_test.zig
zig build run -- <args>       # run the CLI, e.g. zig build run -- next
zig build -Dtarget=x86_64-windows-gnu   # cross-compile check (must stay clean; std-only is a design rule)
```

There is no test-filter option wired in build.zig; `zig build test` runs everything (it's fast). Library tests aggregate through the `test {}` block in `src/tracker.zig` — a new test file must be `_ = @import(...)`'d there (or wired in build.zig like cli_test.zig / mcp_test.zig) or it silently won't run.

WSL note: this repo lives on ext4 at `~/dev/zig/trk` (moved off the `/mnt/c` DrvFs mount 2026-08-26, sibling to the Enix checkout that consumes it, so `../trk` resolves from there). Build bare into the in-tree `.zig-cache` — do NOT route `ZIG_LOCAL_CACHE_DIR` elsewhere. The trap that rule existed for (Windows file-locking wedging the cache so a build reports success while installing a stale artifact) was a DrvFs property and went away with the move.

## Architecture

Two compilation units, wired in `build.zig`:

- **`tracker` module** (root `src/tracker.zig`) — the platform-free library: `ulid.zig` (id minting), `model.zig` (Task/State/Event data, no I/O), `json_codec.zig` (event line codec), `store.zig` (the fold + queries + writes).
- **`trk` exe** — `src/main.zig` is a thin shell (build `Io`, find the store root by walking up for `.tracker/` git-style via `src/discover.zig`, map errors to exit codes); all verb logic and the render/tree projections live in `src/cli.zig`, which imports the `tracker` module.
- **MCP front end** — `src/mcp.zig` (`trk mcp-serve`, started from main.zig before any store loads). Tools derive from `Cli.verbs`, the one table dispatch/help/read-only/`tools/list` all read; a call builds argv and runs `Cli.dispatch`, never the store directly. Adding a verb means a `verbs` entry with `tools` (or a commented CLI-only `cli_only_tools`); every tool flag must appear in the verb's help text (mcp_test.zig asserts it). Every tool takes a required `tree` — see design.md "MCP front end" before touching tree resolution.

Core mechanic: **load = fold**. `Store.load` replays `snapshot.jsonl` (optional baseline) then `log.jsonl` in file order into an in-memory graph; every write is one appended JSON line. Layering is strict: model.zig has no I/O and no fold logic; store semantics never leak into cli.zig (writes go through `Store.append`); cli.zig writes output into a caller-owned `ArrayList(u8)`, never stdout — main.zig flushes it, tests assert against it.

`docs/design.md` is the authoritative design doc — data model, the `next` query, state lifecycle, merge model, and settled rulings. Consult it before changing semantics. Invariants most likely to bite:

- **Merge model**: `log.jsonl` union-merges across parallel writers (git `merge=union`). Events must stay idempotent and disjoint-task-commutative on fold; the acyclic invariant is re-checked on every load (`checkAcyclic`), not just on append, because a merge can introduce a cycle neither side had. Never add `merge=union` to `snapshot.jsonl` — it's a whole-file baseline, safe only because `compact` is serialized.
- **State machine** (`model.zig`): `done`/`dropped`/`archived` satisfy a prereq; only `open` is eligible for `next`; `blocked` blocks dependents. `claimed` (the lease) needs a holder; its fold and the `release` op are conditional (lease only on `open`, release only while that holder holds it) — that is what stops ts-ordered replay from letting a teardown release beat a later-merged `submitted`; never make either unconditional. `archived` is the changelog-graduation tombstone — its exclusion from every view is what makes changelog dedup structural. `compact` drops `dropped`+`archived` but must keep `done` (it's both a satisfied prereq and the un-graduated changelog queue). It also GCs **ghosts** — nodes the fold only ever saw referenced, never `add`ed (`Store.ghost_tasks`, `isCollectable`) — spooling their log lines to `.tracker/quarantine.jsonl` first; never emit a ghost as an `add`, that promotes a husk into a task nothing can tell apart from a real one.
- **Arc roots are containers** (drained-vs-complete ruling, design.md): `next` holds an open root back until the arc is drained (`arcDrained` — vacuously true when all members are parked), then surfaces it once as the close-out prompt. A `needs` edge targeting a root gates on the root's *state* (the explicit completion judgment), never on drainage — do not reintroduce an arc-target special case in `next`, and never derive `needs` edges from `in` membership (union-merge can forge a cycle that bricks the store).
- **Output semantics**: `render` truncate-overwrites its target; `archive` appends under a dated heading, never truncates; `init` never clobbers an existing file.
- **Merge attributes ship inside the store**: `trk init` writes `.tracker/.gitattributes` (`store.gitattributes_text`) — `log.jsonl merge=union`, `snapshot.jsonl`/`quarantine.jsonl` `merge=text`. Keep it INSIDE `.tracker/`, never at the repo root: git resolves attributes per directory and the nearest file wins, so a later root-level `*.jsonl` glob can't capture the baselines. `compact` warns when a pin is missing; it can't check what's actually in effect (std-only, never shells out to git), so the warning only ever claims what trk sees in its own file.
- **On-disk format**: the JSON emit is hand-rolled in `json_codec.zig` (deterministic key order) deliberately — don't migrate it to `std.json.Stringify`. Decode tolerates missing `ts` (legacy lines). State wire tokens are not all the state names: the lease (`State.claimed`) is written `leased`, and `"claimed"` is the spent legacy spelling of `submitted` — decode it as `submitted`, never write it.
- **IDs**: ULIDs are minted once at creation, never regenerated (uniqueness-at-birth is what makes parallel worktrees collide-free). CLI accepts unique prefixes; short-id floor is `min_short = 6` in cli.zig.
- **Help routing**: `--help`/`-h` anywhere in a verb's args must route to help *before* dispatch (positional-title verbs would otherwise mint junk tasks named "--help"). Every dispatched verb needs a `verb_help` entry — a test enforces this, so adding a verb without help text fails the suite.
- **Store-root discovery is worktree-bounded; `TRK_READONLY` is the hard stop.** `discover.findRoot` (`src/discover.zig`) never walks past a linked git worktree's root (its `.git` is a plain FILE, never a directory — the on-disk marker, no git binary needed) into an enclosing repo's tracker, even when the worktree lacks its own `.tracker`. But a `.claude/worktrees/<id>/` dir that isn't a *real* git worktree (no `.git` at all — e.g. a scratch/tool dir) has no boundary marker to stop at, so discovery legitimately (if dangerously, for an agent context) climbs into whatever `.tracker` sits above it. `TRK_READONLY=1` in the env is the structural fix for that case: `Cli.read_only` refuses every mutating verb (`mutating_verbs` in `cli.zig`, `doc set`/`doc unset` special-cased out of the read-only `doc` verb) before dispatch, independent of which root discovery resolved to.

Tests use `std.testing.tmpDir` + deterministic `ulid.mintAt` timestamps; nothing touches a real `.tracker/` or absolute paths — keep it that way.
