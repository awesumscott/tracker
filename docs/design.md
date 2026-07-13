# In-repo issue tracker — a task DAG with an agent-first API

`[active]` · a developer tool.

**Thesis.** An in-repo, agent-first task tracker where tasks are **nodes** and two edge kinds wire them: a
**`needs`** prerequisite (the DAG) and an **`in`** membership (a task belongs to an arc). An **arc** is a goal
root; the **`next`** query returns the prereqs-met *ready frontier*. It **replaces** a hand-edited backlog
file, which becomes a generated projection — structure the value once, render the human-readable view. It is
dogfooded: the tool tracks its own development.

The tool is `trk` (a small Zig host tool). Subcommands:
`add`/`dep`/`undep`/`in`/`state`/`edit`/`show`/`next`/`list`/`render`/`tree`/`log`/`doc`/`compact`/`archive`.

What this doc owns: the **data model** (the two-edge DAG, edge-attribute priority, doc-refs), the **`next`
query**, the **arc/wave tree-print**, the **state lifecycle / changelog handoff**, and the **merge model +
vs-harness rulings** below. Storage and the backend seam are covered in their own sections.

## vs. the harness task tools (why this isn't a reinvention)

A typical agent environment ships ephemeral task tools (`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet` here).
They are the **ephemeral, per-session, flat** scheduler — gone when the session ends, no prereq graph, no
arcs, no edge-priority, not in the repo, not diffable. This tracker is the **persistent, in-repo,
DAG-structured** backlog they structurally can't be: it survives sessions, versions with the code, models
prerequisites and arcs, and projects to a human-readable backlog file. The harness tools schedule *this
session's* work; this tracker *is the backlog* across all of them. They compose — the orchestrator can pull a
`next` result into harness tasks for a given fan-out.

## Why this exists (the pain it kills)

A flat-prose backlog with **free-text "triggers"** is why prereqs get forgotten, items go stale (repeatedly
measured ~60% stale — "grep before you spawn, the backlog lies"), and the "multiple consumers" gate
preferences (build for a known need, not a speculative one) have nowhere structured to live. A real DAG turns
each of those into a queryable fact. The consumers are the multi-agent orchestrator and the developer.

## Data model (the owned rulings)

Defined in `model.zig` (`Task`, `Needs`, `In`, `DocRef`, `State`, the `Event` union over `Op`).

- **Task = node** `Task{ id, title, body, state, priority, tags[], docrefs[] }`. `id` is a **ULID** (`Ulid`
  in `ulid.zig`) — a 48-bit ms timestamp + 80 random bits, minted **once** at creation. It is
  *unique-at-birth without coordination*: the 80 random bits make ids minted in two worktrees collide-free,
  which is what lets two writers append concurrently (the merge ruling below). It is **not** a monotonic int
  (would collide across worktrees) and **not** content-addressed/derived-from-title (a slug both regenerates
  and collides). *(Two distinct ID disciplines, easily conflated: a **task id** is minted* once *at creation
  and must be unique-at-birth; a **doc `section_id`** is assigned by an* idempotent fill-gaps *pass and must
  be durable-across-reruns. Opposite concerns — which is why slug-from-title fits neither.)*
- **Two edge kinds, both day-one:**
  - **`A needs B`** (`Needs{ from, to }`) — a prerequisite, forming a DAG; declared by the *dependent*
    (`A`). A cycle is a rejected write (`error.DependencyCycle` in `store.zig`), and the acyclic invariant
    is **re-checked on fold/load** (`checkAcyclic`), not only on append — a merge can introduce a cycle
    neither side had (see storage).
  - **`T in X`** (`In{ task, arc, seq }`) — direct membership of task `T` in arc `X`. This is
    **load-bearing, not optional**: pure reachability cannot express an arc's *first* task or an orphan goal
    (nothing depends on it yet), so "slot a new issue into an arc" needs a membership primitive, not just a
    prereq edge.
- **Arc = a goal root.** A task is **in an arc** if it carries an `in X` edge **or** is reachable from a
  member via `needs` edges (`membersOf` / `arcsOf` in `store.zig`). Membership-as-reachability is the *read
  projection* (it auto-surfaces a shared prereq in every arc that reaches it); the `in` edge is the
  *authoring primitive*. A new prereq of an existing arc member auto-joins that arc; a genuinely new arc
  task is added with one `in` edge.
- **Arc-as-prereq.** A `needs` edge whose *target is an arc root* is an **ordinary prereq on the root's
  state** — it opens when the root is closed (`done`/`dropped`/`archived`), exactly like any other edge.
  There is no special arc-gate in the DAG: the root's state *is* the arc's completion (the
  drained-vs-complete ruling below). *(Supersedes the 2026-07-10 rule that gated such edges on
  member-drainage via `arcComplete` — drainage-gating let a half-filed arc unblock dependents and made an
  all-parked arc block them forever.)* `parked` members (optional/future stubs) are excluded from
  drainage so the close-out prompt never waits on them.
- **Priority = an edge/membership attribute**, the `seq` on the `in` edge — **not** a task property — so one
  task holds different positions in different arcs. **Lower `seq` sorts first.** Plus one global
  **personal-preference** priority (the `priority` field on `Task`, lower-first, matching `seq` so the two
  compose) as the cross-arc tiebreaker. Arc roots carry priority too, so arcs and stray arc-less tasks
  order in one list.
- **Doc-refs = a list of `DocRef{ doc_id, section_id? }`.** `doc_id` indirects through a small `id → path`
  registry (the `setDocPath` events, folded into `Store.docPath`), so a doc can move/rename and every ref
  survives. (Bare-filename cross-refs are robust when doc-to-doc links are few; tracker→doc refs can be many,
  so the indirection earns its keep here.) `section_id` is **optional** — a
  stable anchor that lets an agent do a focused read instead of a grep. Anchors are added
  **opportunistically** (where a large doc demonstrably wastes an agent's time), **not** mandated
  corpus-wide; slug-derived anchors drift on retitle, so an explicit marker is preferred where one is added
  at all.

## State lifecycle — `open` → `done` → `archived`, and the changelog handoff

The `State` enum (`model.zig`) is the lifecycle, and it is shaped so changelog dedup is **structural, not
date-based**:

- **`open`** — remaining work; the *only* eligible state for `next` (`State.isEligible`). It is what
  `render`/the backlog file show.
- **`blocked`** — an explicit human annotation: `next` treats it as not-eligible (you wouldn't hand it out)
  but, unlike `done`, it **still blocks its dependents** (it isn't finished). Authoring convenience.
- **`done`** — finished. Leaves the backlog view immediately and forms the **changelog queue**. A `done`
  prereq *satisfies* its dependents (`State.satisfiesPrereq`), so it must be kept until graduated — dropping
  it would silently un-block dependents.
- **`dropped`** — abandoned. Excluded from `next`; like `done` it does **not** block dependents (a dropped
  prereq is gone, not pending) and satisfies a prereq.
- **`archived`** — completed *and recorded* in `docs/CHANGELOG.md`. The graduation tombstone: excluded from
  every working view, retained in the log for audit until `compact` physically GCs it. Still satisfies a
  prereq (it is finished).

**`trk archive` is the graduation step** (`cmdArchive` in `cli.zig`): it **emits each `done` task as a
markdown bullet, then flips it to `archived`** in one move — the act of recording is the act of retiring.
Because an `archived` item is gone from every working view, it can **never** be re-emitted: dedup is a
property of the state machine, not of a date filter.

- **A file target is appended to, never truncated** (under a `## YYYY-MM-DD` run heading; `--dry-run`
  previews on stdout and never touches the file). `render` truncates because it regenerates its whole
  projection each run; `archive` emits *increments* — structural dedup guarantees a bullet is emitted
  exactly once, so append can never duplicate, while truncation destroyed a changelog's accumulated
  history when `archive --out` was pointed at it (2026-07-10).
- *Rejected alternative: a `--since <date>` filter on `list`.* It pushes the "already-changelogged?"
  bookkeeping onto the caller; the tombstone state makes that bookkeeping impossible to get wrong.
- *Why a dedicated `trk archive` and not folding it into `compact`:* the two have different cadences —
  changelog handoff runs per closed batch, `compact` (heavier log GC) runs rarely; coupling them forces one
  to the other's rhythm.
- The emitted bullets are a **draft** — curate them into CHANGELOG prose (in place, when appending
  straight to the changelog); the CHANGELOG is narrative, not 1:1 with tasks.
- `archived` is a tombstone, not a hard delete — a condemn/adopt (tombstone-then-GC) model rather than a
  destructive removal.

## `next` — the ready-frontier query (mechanism, not the whole scheduler)

`Store.next` returns the **eligible set**: every `open` task whose `needs` are all satisfied
(`done`/`dropped`/`archived`), ordered by best (smallest) arc-`seq`, then personal `priority`, then ULID (a
stable, time-ascending tiebreak; `Ranked.less` in `store.zig`). An arc-less task still appears, sorted
after arc'd tasks via a sentinel. That dissolves "I must remember to queue the next task" into a command.

**An arc root is a container, and `next` treats it as one** (2026-07-13; the drained-vs-complete ruling).
"Do this arc" means *do its non-parked members* — the root is not itself a unit of work, so `next` holds an
open root back while any direct non-`parked` member is unsatisfied (`arcDrained` in `store.zig`), then
surfaces it **exactly once, as the close-out prompt**. Two distinct facts, never conflated:

- **Drained** — every currently-filed, non-parked member is satisfied. *Observable, computed, never
  stored*: it flaps by design (a newly filed member un-drains the arc), which is why nothing durable may
  key off it. An arc with **no** non-parked members is **vacuously drained** — nothing actionable is
  pending, so the root surfaces rather than black-holing (parked members stay `open` forever and are never
  GC'd, so a "wait" here would be a wait with no exit).
- **Complete** — the *goal* is achieved: the root's own `state = done`, set **explicitly**. Member
  exhaustion can't imply this (the member set is open-ended); only a human/agent judgment converts drained
  into complete. `next` offering the drained root *is the tool asking for that judgment*, and everything
  downstream — `needs`-the-arc gates, `archive` graduation — reads only this fact.

*Rejected: a `done-when-complete` auto-close field on the arc.* It hard-wires "drained ⇒ complete", which
is wrong exactly while an arc is still growing, and it breaks the event model both ways: state derived at
fold time makes the views disagree with the log, while state written on observation makes readers into
writers that cross the disjoint-owner boundary — and a momentarily-drained arc that auto-dones can be
graduated by `archive` into an `archived` tombstone (structurally barred from every view) while the goal
is still alive. *Rejected: deriving `root needs member` edges at authoring time* (the hand-repair pattern
observed in the field): a reversed `in` in a parallel worktree union-merges into a `needs` cycle that
makes the whole store unloadable at fold; a plain derived edge ignores `parked` and gates forever on
stubs; and derived edges are byte-identical to authored ones in the log, so no later pass can retract them.
A root closed early, with members still open, unblocks its dependents — explicit judgment wins; the
leftover members are candidates for `dropped`.

But it is **mechanism, not the scheduler** (the mechanism/policy split): critical-path
choice, agent-count budgeting, and cost are **orchestrator policy on top** of the eligible set, not stored
here.

**File-conflict is an annotation, not an inference.** Which files a task will touch is a *human/agent
judgment at fan-out time* (decompose by file-conflict), not knowable before the task
runs. So a task may carry an **optional, explicitly-may-be-stale** path-glob hint to help the orchestrator
parallelize disjoint work; `next` surfaces it but never pretends it's authoritative. (No smuggling free-text
staleness back in as a "fact.") Other reads — by word(s), arc, tag, state, priority — run **in memory** over
a fresh fold each invocation (an issue set is KB–MB; no daemon, no lock server).

## The human face — projection + the tree-print

One structured value, three projections: the **data** face (the log +
snapshot, in-repo, diffable), the **agent** face (the CRUD + query API, the primary consumer), and the
**human** face — the rendered backlog projection (`trk render`, written to `docs/TODO.md`) plus the
differentiator: a **pretty-printed hierarchy of an arc or issue wave** as a tree (`trk tree`, prereqs nested
under dependents). Because prereqs are explicit edges, two things fall out that no tracker we've seen does —
**adjacent-prereq visibility** (a parent's *sibling* prereqs surfaced together) and that whole-arc
tree-print. The hierarchy *is* the view, not a flat list.

**Write-through is via the CLI, and the hand-edit affordance is consciously traded.** The log is the source;
the rendered backlog file is **generated, read-only** (it carries a "generated, do not edit" header). Humans
no longer hand-edit backlog prose — they mutate through the same `add`/`dep`/`in` CLI the agent uses (faster
than editing prose anyway, and the point). This is a real, owned cost: the "open the file, append a line"
affordance is gone, replaced by a command.

**The render/archive destination is persisted, not re-specified per call** (`.tracker/config.json`, added
2026-07-10). Where `trk render` writes was previously a mandatory `--out docs/TODO.md` on every invocation —
a ritual that also invited "forgot where it renders" drift. An optional `config.json` (`{"render":{"out":…},
"archive":{"out":…}}`) persists it, with precedence **explicit `--out` > config value > stdout**. The stdout
fallback is load-bearing: a repo with no config behaves *exactly* as before, so the feature is purely
additive (no migration, no forced adoption). Config load is **best-effort and never fatal** — a malformed
file warns to stderr and falls back to defaults rather than blocking a mutating command, because the tracker
must never be un-writable due to a cosmetic config typo. `render` still truncate-overwrites its target (the
projection is regenerated by design); config changes only *where*, never the clobber semantics.

**`trk init` scaffolds a fresh tracker, and is non-destructive by construction.** The storage is lazily
auto-created on first write, but the *conventions* (a `config.json`, a `TODO.md` with the generated header)
were not — a gap that mattered the moment trk was considered as a shareable plugin (a consumer project would
inherit an empty `.tracker/` and none of the doctrine). `init` creates `.tracker/` + an empty log, a
`config.json` (default `render.out = docs/TODO.md`, or `--out`), and a starter `TODO.md` — **each only if
absent**. The asymmetry with `render` is deliberate and is the crux: `render` overwrites `TODO.md` (it owns
that generated file), but `init` must **never** clobber it — an existing `TODO.md` is either a live
projection or a user's file, so init leaves it and reports it. Re-running init is a no-op that reports each
pre-existing artifact (`--force` rewrites only `config.json`, never a `TODO.md`). This makes init safe to run
blind on any directory, which is what a plugin's setup step needs.

**Every verb self-documents via `--help`, and that is an agent-first requirement, not a nicety** (added
2026-07-10). `trk <verb> --help`/`-h` (and `trk help <verb>`) print that verb's synopsis + flags + an example;
bare `trk`/`trk help` print the overview. The forcing case is concrete and measured: agents exploring the tool
would run `trk add --help`, and because `add`'s first positional is the title, `--help` was parsed *as the
title* — every such probe minted a junk task literally named "--help". So help routing lives **before
dispatch** (a standalone `--help`/`-h` anywhere in a verb's args routes to help), which both closes that trap
and makes the CLI legible without an external cheat-sheet — the point being that an agent should be able to
*discover* the tracker's surface from the tool itself, since the tool is the primary consumer.
The per-verb text lives in one `verb_help` table with a test asserting an entry per dispatched verb, so the
contract can't rot as verbs are added.

## Storage, merges, and auth

Storage is an append-log of events + a full-state snapshot baseline + adopt/condemn compaction. It is realized
as `.tracker/log.jsonl` (one JSON event per line) plus an optional `.tracker/snapshot.jsonl`, both written via
**write-temp-then-rename** (`Store.atomicWrite`: a temp file in the same dir, atomically renamed over the
target). Load = fold: replay the snapshot (if any) then the log, in file order (`Store.load`).

The merge model is **owned** here, because it gates how parallel agents may touch the backlog:

- **Disjoint-writer.** A subagent MAY close its OWN slice's tasks (`trk state <id> done`) from its worktree
  and read freely; the orchestrator owns everything else. This rests on the merge property below + the
  fan-out invariant that the orchestrator never assigns one task to two agents — so two writers never touch
  the *same* task. The log carries a `merge=union` driver (`.gitattributes`, on `/.tracker/log.jsonl`) so
  concurrent appends combine instead of conflicting. (This **supersedes** an earlier single-writer rule that
  forbade any subagent write; the merge property below shows the stricter rule was unnecessary.)
  - **The merge driver is necessary, not sufficient — the close must be *staged*.** `trk state done` appends
    to `.tracker/log.jsonl`, but a fan-out subagent commits *explicit paths* (its source files); if it omits
    the tracker log, the close-append is never committed and never merges, so the task reads `open` after its
    code lands + the gate greens. The failure is upstream of the union driver, at the agent's commit. Two
    invariants close it: (a) a subagent that closes a task MUST also `git add .tracker/log.jsonl`; (b) the
    orchestrator **re-verifies and re-closes done tasks idempotently** during each per-wave reconcile
    (`trk state done` is append-idempotent, so a redundant close is free). Cross-cuts any union-merged
    append-log a writer mutates but does not stage.
- **Merge-*safe* by construction; merge-*free* is still a later goal.** The fold-time acyclic re-check
  (`checkAcyclic` on every `load`) means a textual union-merge of parallel-worktree appends can't silently
  corrupt state or smuggle a cycle, and disjoint-task `setState` events commute — which is exactly why
  disjoint-writer close-out is safe. What's *not* safe (and *not* built) is two writers mutating the
  **same** task: that needs a **commutative event schema** (a CRDT-shaped log) — an explicit, gated
  aspiration (the open fork below).
  - *Why a blanket "all appends commute" claim was rejected for the general case:* independent top-level
    declarations commute unconditionally; *same-task* events don't. *Disjoint*-task events do — which is the
    narrower property disjoint-writer actually rests on.
- **Edge removal (`undep`) is a fold-time tombstone, log-replay-scoped.** `undep` appends an edge-tombstone
  the fold applies as *tombstone-beats-`dep`* — order-independent under union-merge (a concurrent same-edge
  `dep` loses regardless of append order). The tombstone set is a **fold-time** construct: `compact`/
  `serializeState` neither emit `undep` ops nor persist tombstones, and correctly so — by compaction every
  `undep` is already folded into `needs` (the tombstoned edge absent) and the snapshot emits only surviving
  edges, so no stray `dep` line survives to need blocking.
- **Compaction/render/archive are orchestrator-only and serialized.** `compact` rewrites the whole snapshot —
  the one merge-flashpoint — so it never runs in a worktree; `render` writes the generated backlog file;
  `archive` is the changelog handoff. None is a subagent operation.
  - **Only `log.jsonl` carries the union driver; `snapshot.jsonl` deliberately does not.** The snapshot is a
    whole-file baseline — a union-merge of two snapshots would interleave two full states into garbage — so it
    is safe *only* because compaction is orchestrator-only/serialized (never two concurrent writers). Do not
    add `merge=union` to the snapshot.
  - **Compact AFTER integrating worktree branches, never before.** A subagent worktree branched *pre-compact*
    still carries the pre-truncation log lines; union-merging it against the orchestrator's truncated log
    re-adds them, transiently resurrecting `compact`-GC'd `dropped`/`archived` tasks. It is **not** corruption
    (every event is idempotent on re-fold and the resurrected states are hidden from every view; healed at the
    next compact — the same window the crash-safety ruling notes), but the clean ordering is: integrate all
    branches, *then* compact.

**Auth:** the host-file v1 is open (git history is the audit trail). A future datastore backend (below) is
where close/edge authority would become **capability-scoped**; an unscoped API is acceptable only while git
*is* the authority log.

## Backend: host file now; datastore later, with a caution

One source, but **no vtable** — the host **file backend** is a concrete struct (`Store` in `store.zig`):
defer the injected seam until a *second* implementor can actually run. It cross-compiles to
Linux/macOS/Windows for any user.

A **datastore backend** is a *possible future* impl. **Caution, not a selling point:** the tracker's
multi-axis query (word/arc/tag/state/priority) is exactly the open-attribute, cross-attribute access pattern
that an EAV/relational store handles awkwardly — a reason **not** to rush a database backend before the query
surface genuinely justifies it.

## Migration off a hand-edited backlog

Breaking-changes-over-compat: two task systems drift, so replace rather than sync. But the migration is
**not** a mechanical 1:1 projection — a flat backlog runs ~60% stale, so a faithful encode would fossilize
the staleness as structured edges. It is a **one-time human triage pass** (drop the done/dead, then encode
the survivors: free-text trigger → a `needs` edge, doc pointer → a doc-ref). The cutover is atomic: once the
survivors are encoded, the backlog file becomes the generated projection (`trk render --out docs/TODO.md`).

## Honesty check

The *storage* (issues + edges + tags, in-repo) is solved — git-bug, Fossil's built-in tracker, ditz. This
earns its existence on the **model + interface**: the two-edge DAG shared across arcs, edge-attribute
priority, the agent-first API, `next` as the ready-frontier query, and the arc/wave tree-print +
adjacent-prereq view. No novelty is claimed for the append-log or the record store.

## Open forks

- **Anchor adoption — opportunistic *or* a cheap automated full-corpus pass.** The "never mandate
  corpus-wide, it's a tax" framing assumed *manual* anchoring. A one-time automated pass inverts the
  economics: ~1hr, repo-agnostic, re-runnable — paid once against focused-reads that save tokens dozens of
  times per session, forever. Split by tier: **heading anchors = a deterministic script** (slugify + dedup,
  no LLM, trivially idempotent — the safe 90%); **semantic-span anchors = an optional LLM fan-out** (tag a
  named argument/ruling that isn't a heading — where judgment pays). **The load-bearing constraint is
  idempotency:** a re-run must *read existing anchors and only fill gaps*, never regenerate ids, and use
  explicit stable markers (not slugs-from-title, which break refs on retitle — that was the real "drift"
  risk). Not ruled in: nothing forces it yet (no consumer requires anchors); not dismissed either.
- **The commutative event schema:** the CRDT-shaped log that would promote merge-*safe* → merge-*free*,
  unlocking *same-task* parallel-agent writes. Gated on a consumer that needs concurrent writers to the same
  task; disjoint-writer may suffice indefinitely.

## Settled rulings

- **Compaction & history retention.** `compact` (`Store.compact`) writes a fresh full-state snapshot then
  truncates the log. It **drops `dropped` AND `archived` tasks** (and edges touching them) — abandoned work
  has no structural future, and a graduated task is already preserved in the changelog + git log. It
  **keeps `done` tasks** — a `done` prereq is what makes its dependents eligible AND `done` is the
  un-graduated changelog queue, so dropping it would silently corrupt the graph. (Crash-safe: the snapshot
  is renamed durably *before* the log is truncated; every event is idempotent on re-fold, so the inter-step
  window loses nothing — a dropped/archived task may transiently reappear until the next compact.)
- **Doc-id registry ownership — folds into the store as events.** A `setDocPath { doc_id, path }` event
  (not a separate file) — one append-log, one compaction story, the same merge-safety model as every other
  event (last-write-wins on fold; `Store.docPath` resolves). A doc move is one `trk doc set <doc_id>
  <new-path>`; every task's doc-ref stores the `doc_id` (not the path), so all refs survive. Render
  resolves `doc_id → path#section`, falling back to the raw `doc_id#section` when unregistered.
  `trk doc unset <doc_id>` tombstones a mapping via an empty-path `setDocPath` — the fold removes the
  entry (refs fall back to the raw `doc_id`), the snapshot never emits it, so `compact` GCs the
  tombstone; idempotent, and a later `set` revives it under the same last-write-wins fold.
