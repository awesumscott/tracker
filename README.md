# trk — an in-repo issue tracker

A small, agent-first task tracker that lives **in your repo** as an append-only log and projects to a
generated `TODO.md`. Tasks are **nodes** wired by two edge kinds — a `needs` prerequisite (a DAG) and an
`in` arc membership — and the headline query, `next`, returns the prereqs-met *ready frontier*. It is
self-contained: one Zig host tool, no daemon, no database.

Why it exists: a flat prose backlog forgets prerequisites and goes stale. A real DAG makes "what's ready
to work on now" a query instead of a memory exercise, and the whole surface is explorable from the tool
itself (`trk <verb> --help`) — designed to be driven by agents as much as by humans.

## Install

`trk` needs only a [Zig](https://ziglang.org) toolchain and builds native for Linux, macOS, and Windows
(`trk.exe`, chosen automatically from the build target).

```
git clone <this-repo> trk && cd trk
zig build -Doptimize=ReleaseSafe            # -> zig-out/bin/trk
```

Install onto your PATH with Zig's built-in `--prefix` (installs to `<prefix>/bin`):

```
zig build --prefix ~/.local -Doptimize=ReleaseSafe        # Linux/macOS -> ~/.local/bin/trk
zig build --prefix C:\Tools -Doptimize=ReleaseSafe        # Windows     -> C:\Tools\bin\trk.exe
```

If your PATH directory is *flat* (no trailing `bin`), drop the binary straight in with `--prefix-exe-dir .`:

```
zig build --prefix <dir> --prefix-exe-dir . -Doptimize=ReleaseSafe   # -> <dir>/trk
```

Re-run the same command to redeploy after pulling changes. Run `zig build test` to run the host test suite.

## Quick start

```
cd your-project
trk init                          # scaffold .tracker/ + config.json + a starter TODO.md
trk add "Add dark mode" --tag ui  # create a task (prints its id)
trk next                          # the ready frontier (prereqs met)
trk render                        # regenerate TODO.md (destination from .tracker/config.json)
```

`trk` finds `.tracker/` by walking up from the current directory (git-style), so it runs from any
subdirectory of a project.

## Model in one screen

- **Task** = a node with `id` (a ULID, minted once), `title`, `body`, `state`, `priority`, `tags`, doc-refs.
- **`A needs B`** — a prerequisite edge, forming a DAG. Cycles are rejected. `trk dep <needer> <prereq>`.
- **`T in X`** — task `T` belongs to arc `X`. An **arc** is a goal-root task. `trk in <task> <arc>`.
- **State** — `open` → `done` → `archived` (via `trk archive`, which graduates done tasks to changelog
  bullets and tombstones them), plus `blocked` (held) and `dropped` (won't-do).
- **`next`** — the ready frontier: every `open` task whose prerequisites are all satisfied.
- **`.tracker/`** — the append-only `log.jsonl` (+ an optional compacted `snapshot.jsonl`). It union-merges
  on concurrent appends, so parallel workers on disjoint tasks can each close their own without conflict.

## Commands

`add · dep · undep · in · state · edit · show · next · list · render · tree · log · doc · compact · archive · init`

Every verb self-documents: `trk <verb> --help` (or `trk help <verb>`) prints its synopsis, flags, and an
example; bare `trk` prints the overview.

## Config

`.tracker/config.json` (written by `trk init`) persists where `render`/`archive` write, so you don't pass
`--out` every time:

```json
{ "render": { "out": "docs/TODO.md" }, "archive": { "out": null } }
```

Precedence for the output path: explicit `--out` > config value > stdout. A repo with no config behaves
exactly as if the fields were unset.

## Design

The full rationale — the two-edge data model, the `next` query, the state lifecycle, the union-merge model
for parallel writers, and the rejected alternatives — is in [`docs/design.md`](docs/design.md).

## License

GPL-3.0-or-later — see [`LICENSE`](LICENSE). Copyright (C) 2026 Scott Lowe.
