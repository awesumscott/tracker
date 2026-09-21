# In-repo issue tracker — a task DAG with an agent-first API

`[active]` · a developer tool.

**Thesis.** An in-repo, agent-first task tracker where tasks are **nodes** and two edge kinds wire them: a
**`needs`** prerequisite (the DAG) and an **`in`** membership (a task belongs to an arc). An **arc** is a goal
root; the **`next`** query returns the prereqs-met *ready frontier*. It **replaces** a hand-edited backlog
file, which becomes a generated projection — structure the value once, render the human-readable view. It is
dogfooded: the tool tracks its own development.

The tool is `trk` (a small Zig host tool). Subcommands:
`add`/`dep`/`undep`/`in`/`unin`/`arc`/`migrate-arcs`/`state`/`edit`/`show`/`next`/`list`/`render`/`tree`/`log`/`doc`/`compact`/`archive`.

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
  - **Cycle-checking is NOT `needs`-only — it spans `needs` and `in` together.** Treat `in(task, arc)` as
    an implicit reverse dependency (`arc -> task`, "an arc structurally depends on completing every direct
    member before IT can be considered done" — exactly the `needs` shape, just spelled the opposite
    direction from the authored edge). `append` rejects a new `dep` or `in` that would close a cycle in
    this COMBINED graph (`combinedReaches`, an incremental single-edge check), not only in the plain
    `needs` subgraph — a pure `needs`-only checker is blind to a task that `needs` an arc it is itself a
    member of, which is a genuine self-wait (see "Arc-as-prereq" below), not a lesser case. A pre-existing
    log already carrying one (predates this check, hand-edited, bad merge) is not refused at load — see
    "Arc-as-prereq".
  - **`T in X`** (`In{ task, arc, seq }`) — direct membership of task `T` in arc `X`. This is
    **load-bearing, not optional**: pure reachability cannot express an arc's *first* task or an orphan goal
    (nothing depends on it yet), so "slot a new issue into an arc" needs a membership primitive, not just a
    prereq edge.
- **Arc-ness is a DECLARED property (`isArc`, `store.zig`) — one definition, not three, and NEVER inferred
  from an edge.** A task is an arc iff it is **explicitly declared** (`trk arc <id>` / `trk add --arc`, an
  `arcDeclare` event — last-write-wins on fold, `--undo` retracts) **or** (back-compat, read-only) it carries
  the deprecated `arc:<slug>` tag. Declaring makes an arc with **genuinely zero members** expressible (a real
  goal with no work filed yet, previously inexpressible by either structural check alone).
  *(Supersedes an earlier state where `isArc` (direct `in` only), `membersOf`/`arcsOf` reachability, and the
  `arc:<slug>` tag — introduced in a render-polish commit purely to keep an empty arc out of the "Arc-less"
  section — silently disagreed: an arc populated only via `dep`/`needs` edges could read `isArc`-false while
  `list --arc` showed it full. The tag is still honored read-only for backward compatibility — DEPRECATED,
  `trk migrate-arcs` converts every tagged task to a real declaration and strips the tag; `add`/`edit` warn
  on stderr if a new `arc:` tag is written.)*
  **The direct-`in`-edge inference clause was ITSELF deleted (01KYTFRD7, 2026-07-30)** — `isArc` no longer
  returns true merely because some task carries `in X`. It had looked like the harmless, migration-free third
  path (any arc built before `arcDeclare` existed "just worked"), but it meant `trk in <anything> <X>`
  silently MINTED `X` as an arc root with no declaration and no check: a reversed-argument call
  (`trk in <arc> <task>` instead of `<task> <arc>`) turned the intended *task* into a spurious arc, four
  times in one session, and twice left a task a member of *itself* (permanently unschedulable — see
  "Arc-as-prereq" below). **`Store.append` now requires `T in X`'s `X` to already satisfy `isArc` before the
  edge is written** — declared first, membership second, exactly what legitimate nested-arc authoring
  (`trk arc P`, then `trk in A P`) already looked like; a prior lane had judged "reject the mistake shape
  without rejecting genuine nesting" impossible precisely because arc-hood was inferred, which made the two
  shapes structurally identical at write time. Requiring declaration first makes them different by
  construction: the mistake targets an UNDECLARED id, genuine nesting never does. Rejected with a distinct
  `error.UndeclaredArc` (never conflated with `DependencyCycle`), except for a literal self-membership
  (`T in T`) — left to the existing self-loop rejection regardless of declaration, since that shape is
  nonsensical independent of `T`'s declared-ness. **`trk migrate-arcs` backfills a real `arcDeclare` for
  every id that was an arc ONLY via this inference** (a second pass alongside its pre-existing `arc:`-tag
  migration) — run once, before the inference clause was deleted, so every arc that existed *before* the fix
  answers `isArc` identically *after* it; only a brand-new, never-declared `in` target is affected going
  forward. `trk unin` (mirrors `undep`) remains the recovery mechanism for a wrong-*direction* `in` between
  two ids that are BOTH already-declared arcs — the declared-arc gate closes the "mint a spurious arc" shape,
  not a swap between two arcs that already legitimately exist.
  **`membersOf`/`arcsOf` stay the strictly WIDER read projection**: a task is *in* an arc if it's a direct
  `in` member **or** `needs`-reachable from one (it auto-surfaces a shared prereq in every arc that reaches
  it) — never conflate this with `isArc` (arc-ness of the root itself); this projection is **unaffected** by
  the inference deletion (it never consulted `isArc`, only the raw `in` edge set). A new prereq of an
  existing arc member auto-joins that arc via reachability; a genuinely new arc task is added by declaring
  its arc (if not already one) and then one `in` edge.
  **`Store.arcless`** is the completeness counterpart — every task in NO arc by this unified model
  (`trk list --no-arc`; `render`'s header counts it as drift every regeneration) — the terminating
  condition for "sort everything into arcs". `trk add` warns to stderr (escalate to a hard error via
  `.tracker/config.json`'s `add.arcless`) when a new task lands in no arc.
- **Arc-as-prereq.** A `needs` edge whose *target is an arc root* is an **ordinary prereq on the root's
  state** — it opens when the root is closed (`done`/`dropped`/`archived`), exactly like any other edge.
  There is no special arc-gate in the DAG: the root's state *is* the arc's completion (the
  drained-vs-complete ruling below). *(Supersedes the 2026-07-10 rule that gated such edges on
  member-drainage via `arcComplete` — drainage-gating let a half-filed arc unblock dependents and made an
  all-parked arc block them forever.)* `parked` members (optional/future stubs) are excluded from
  drainage so the close-out prompt never waits on them.
  - **An arc member cannot `needs` its own arc — directly or transitively.** The arc is held back from
    `next` until every direct member drains (above), so a member that also needs the arc waits on the arc,
    while the arc waits on the member: neither can ever finish. This is fatal whether the membership is
    direct (`task in arc`) or nested (`task in C`, `C in arc` — an arc can itself be a member of another
    arc), because `arc`'s own drained-ness transitively bottoms out on `task` either way; it is emphatically
    NOT fatal for a task in one arc to need a task — or the whole — of a genuinely *different*, unrelated
    arc (ordinary cross-arc sequencing, used constantly). `trk dep`/`trk in` both reject whichever side
    would close the loop (`Store.append`'s `combinedReaches` check — see the cycle-checking note above),
    naming both ids and stating the consequence ("would wait on itself forever") rather than a bare
    `DependencyCycle`. **A log that already contains one (from before this check existed, a hand edit, or a
    bad merge) still loads** — `Store.load` warns to stderr, once per pair found (`self_wait_cycles`, plural
    — a log can carry more than one independent stuck pair, and reporting only the first would leave every
    other cycled task exactly as silently invisible as the bug) instead of refusing, because bricking an
    already-affected repo would be strictly worse than the bug; going forward, `append`
    means no NEW one can be created (found and fixed 2026-07-28, task `01KYJEDX2`).
- **Priority = an edge/membership attribute**, the `seq` on the `in` edge — **not** a task property — so one
  task holds different positions in different arcs. **Lower `seq` sorts first.** Plus one global
  **personal-preference** priority (the `priority` field on `Task`, lower-first, matching `seq` so the two
  compose), which **leads** the `next` ordering with `seq` breaking its ties. Arc roots carry priority too,
  so arcs and stray arc-less tasks order in one list.
  **Stored `0` means UNSET and ranks at `default_priority` (100), not first** (`model.effectivePriority`;
  2026-08-19, tasks `01KZD94QX`/`01KZD94QY`). It was the raw field and the raw default was `0`, which made
  the default the *strongest* value: every explicit priority is a positive int, so `--priority 10` sank a
  task below every untouched one (measured in the Enix backlog: 257 of 259 open tasks at `0`), and only an
  undocumented negative could raise anything. Reading `0` as a sentinel fixes it **without migrating stored
  data** — `compact` already declines to emit a `0`, so the sentinel reading was already in the format —
  and the untouched majority still ties on priority and falls through to `seq`, so only deliberately
  prioritised tasks move. `--priority 0` is the documented way back to the default rank.
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
- **`claimed`** — the LEASE: "this task is taken." Written when work is handed out so `next` stops offering
  it, and always by a named holder (`--holder`). Not `next`-eligible, does **not** satisfy a prereq (the work
  isn't done), counts as remaining in `render` (marker `[c]`), keeps its arc undrained. Only an `open` task
  can be claimed (`State.claimRefusal`, enforced in `Store.append`). Released by `trk release`.
- **`submitted`** — completion PENDING VERIFICATION, not a verdict: "the commit I'm riding completes this
  task." Weaker than `done` in both directions on purpose — does **not** satisfy a prereq (a dependent waits
  for the real, verified `done`) and is **not** `next`-eligible (surfacing it would let a second writer redo
  submitted work). It **does** count as remaining for `render`, marker `[s]` — the scannable "awaiting
  verification" queue (`trk list --state submitted`), which the orchestrator's post-gate reconcile promotes
  to `done` or demotes to `open`. Named `claimed` until the lease existed; see "Settled rulings" for the
  rename, its encoding, and the release path.

Lifecycle for handed-out work: `open` → `claimed` → `submitted` → `done`, with `claimed` → `open` as the
release. `open` → `submitted` stays legal (a lane's worktree store never saw the main checkout's lease).

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
(`done`/`dropped`/`archived`), ordered by effective personal `priority`, then best (smallest) arc-`seq`,
then ULID (a stable, time-ascending tiebreak; `Ranked.less` in `store.zig`). An arc-less task still
appears, sorted after arc'd tasks **of the same priority** via a sentinel. That dissolves "I must remember
to queue the next task" into a command.

**Priority leads; `seq` breaks its ties** (2026-08-19, task `01KZD94QY`). The reverse — `seq` first — made
priority vestigial, because `best_arc_seq` is a task's position *within* its arc, not the arc's rank: it
only ever separated tasks sharing a `seq`, and the arc-less `maxInt` sentinel buried every standalone task
under every arc member no matter how extreme its priority. Measured in the Enix backlog 2026-08-16: the
single highest-priority task (`01M05NB5N`, priority −50) sat at **row 131 of 211**, below 130 arc members
at the default, and `--limit` truncates *after* ranking — so the top-priority item was invisible in the
default view and in every limited one. The ready-frontier query has exactly one job, telling you what you
did not already have in mind, and that shape defeated it.

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

**A standing arc never surfaces, drained or not** (`trk arc <id> --standing`; `Store.isStanding`). Some arc
roots name a perpetual CATEGORY — housekeeping, the debug/observability substrate — not a completable goal;
the drained-vs-complete mechanism above assumes an arc eventually finishes, which is exactly wrong for one of
these. Closing it would assert a completion that never happens (and leaves a future child with no home);
leaving it undrained-gated means it periodically surfaces as a false close-out prompt the moment its members
happen to empty out. `arcStanding` is a first-class marker (mirrors `arcDeclare`'s shape exactly — an
independent bool event, last-write-wins, carried through `compact`'s re-emission like `declared_arcs`) rather
than a tag: it is a statement about the task's *nature*, the same kind of statement `trk arc` already makes
for arc-ness itself, not an ad-hoc label. `next` checks it unconditionally (before the drained check), so a
standing arc is excluded whether or not it currently has open members; membership (`in`) is untouched — it
still accepts new children like any other arc, it just never itself becomes "the thing to do next."

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

**The merge semantics ship with the store, inside `.tracker/.gitattributes`** (2026-08-20). The whole merge
model rests on git attributes — `log.jsonl` and `tombstones.jsonl` union-merged (both append-only, per-line
independent), `snapshot.jsonl` and `quarantine.jsonl` left on the default text driver — and nothing wrote them, so every repo re-derived them by hand or (measured across six
of seven repos on one machine) simply didn't have them, leaving the log conflicting instead of unioning
under live fan-out. `trk init` now writes them, and the placement is the ruling: **inside `.tracker/`, not at
the repo root**. Git resolves attributes per directory and the file *nearest the path wins*, so pins there
cannot be overridden by a later root-level `*.jsonl merge=union` — measured both ways: root-level pins flip
to `union` under such a glob, `.tracker/`-level pins do not. That converts "keep these lines last, never
widen the union pattern" from a convention someone has to remember into something git enforces. It also
keeps `init` non-destructive in the existing sense (the file lives in a directory trk owns, so there is no
appending to a project's own root attributes, and an existing one is never overwritten), and needs no
git-root discovery, since patterns are relative to the file's own directory — `.tracker/` need not be at the
repo root, which `discover.findRoot` already never assumes. `--no-gitattributes` opts out for a repo that
manages attributes centrally.

**`.tracker/.gitignore` ships with the store the same way** (01M21BJFB, 2026-09-08). `compact`'s
pre-rewrite backup (see below) is a full copy of `snapshot.jsonl`/`log.jsonl` on every run, and nothing
ignored it — measured on the Enix tracker: three compacts in one day left 29 MB across three run
directories, untracked forever in `git status` until a human either hand-patched the host repo's root
`.gitignore` or learned to read past the noise. The argument for putting the rule inside `.tracker/` is
the identical one made for `.gitattributes` two paragraphs up — git resolves ignores per directory too,
so the pattern travels with the store into every repo that runs `trk init`, rather than being a local
patch someone has to remember to re-add elsewhere. `trk init` writes it alongside `.gitattributes`
(never overwritten; `--no-gitignore` opts out for a repo managing ignores centrally), covering
`backup/` and a crash-orphaned `atomicWrite` temp file (`.<name>.tmp.<hex>`, left behind only if a
process dies between the temp write and its rename). `log.jsonl`, `snapshot.jsonl`, `config.json`,
`.gitattributes`, `quarantine.jsonl` and `tombstones.jsonl` are deliberately NOT listed — all six are meant
to be committed, so an ignore rule that swept up the store directory itself (or a glob wide enough to catch
them) would be a data-loss footgun of a different kind. Re-running `init` in a repo that predates this
file is the migration: idempotent-by-construction, it backfills the missing `.gitignore` without
touching anything else already there (asserted in `cli_test.zig`).

**The check is narrow on purpose, and it is the closer for `init`'s own non-destructive promise.** `init`
never overwrites an existing `.tracker/.gitattributes` — correct, since clobbering a repo's attribute choices
would be worse — but that means a pin *added to the template after a store already exists* (as
`tombstones.jsonl merge=union` was, in the same commit that added the tombstones index) can never reach that
store by any `init` re-run. `compact` and `tombstones --rebuild` warn (stderr) when a pin is missing instead,
because between them they are every verb that writes one of the files these pins govern — `compact` *creates*
`snapshot.jsonl`/`quarantine.jsonl` and writes `tombstones.jsonl`, `--rebuild` is the other, and can be the
*first* write ever, in a store that has never run `compact` (01M2N0QW2). It cannot verify what is actually in
effect: this check itself never shells out to git — `discover.zig` reads `.git` as a plain file for exactly
this reason, and `stale`'s and `--rebuild`'s own history scans spawn it only for a question git alone can
answer — and attributes resolve through parent directories, `.git/info/attributes` and `core.attributesFile`
— reimplementing that resolution would be worse than not checking. So the warning claims only what trk can
see about its OWN file ("absent, and here is what it would do"), never "your repo is wrong": a repo pinning
these at the root is correct too, just not visibly so from here. The pins are matched as whole lines, since
the shipped file names every pattern in its own comments and a substring check would pass on a file that
only *talks* about them.

**Bodies render folded, not flattened** (2026-08-20). A body long enough to hide — multi-line, or a single
line past the summary cap — is emitted inside a `<details><summary>…</summary>` disclosure, teased by its
first line. The projection then reads as an outline of *titles* in any HTML view (GitHub, an IDE preview)
with the prose one click away, which is what keeps a backlog of prose-heavy tasks navigable. Two properties
are load-bearing: the raw bytes are **unchanged** — nothing is dropped or elided, so the plain-text/agent
reader (`cat docs/TODO.md`, a grep) still sees every body in full; and a short one-line body stays **inline**,
because a disclosure whose summary *is* the whole body hides nothing and only adds markup. The teaser is
HTML, not markdown, so it is entity-escaped (`&`, `<`) and cut at a word/UTF-8 boundary — the same class of
care as the heading-hazard escaping applied to body lines, which still runs inside the disclosure.

**An arc heading with zero renderable members is marked, not left bare** (2026-08-27, task `01M0ZC286J`).
Scott reported several arcs in `TODO.md` with no tasks under their `## <title> (id)` heading, reading as "here
is a goal" with nothing behind it. Measured: render was faithful to the tracker (`trk list --arc <id>` agreed
exactly) — the emptiness has two distinct real causes (all member work already `archived`, or a goal whose
slices were never carved) that render cannot and should not try to tell apart, since it can only observe
presence/absence of renderable members, not which cause produced the absence; that distinction needs a human
judgment about whether the goal was actually met, which is orchestrator/Scott's call, not a mechanical
reconcile. So the fix stays render-side and cause-agnostic: an arc heading now tracks whether it printed any
bullet under it, and if not, emits `*(no open members under this arc)*` right after the heading (or the arc's
own body, if it has one) — visible noise instead of invisible noise, either way pointing at the same next
step (close the arc, or carve its slices).

**The render/archive destination is persisted, not re-specified per call** (`.tracker/config.json`, added
2026-07-10). Where `trk render` writes was previously a mandatory `--out docs/TODO.md` on every invocation —
a ritual that also invited "forgot where it renders" drift. An optional `config.json` (`{"render":{"out":…},
"archive":{"out":…}}`) persists it, with precedence **explicit `--out` > config value > stdout**. The stdout
fallback is load-bearing: a repo with no config behaves *exactly* as before, so the feature is purely
additive (no migration, no forced adoption). Config load is **best-effort and never fatal** — a malformed
file warns to stderr and falls back to defaults rather than blocking a mutating command, because the tracker
must never be un-writable due to a cosmetic config typo. `render` still truncate-overwrites its target (the
projection is regenerated by design); config changes only *where*, never the clobber semantics.

**`archive.routes` — a repo can own more than one changelog** (2026-09-18, task `01M2F8GBQ`, filed from the
Enix consumer repo). `archive_out` names exactly one destination, but a consumer can have a *ruled* split: the
filing repo records work gated by its emulator suite in one changelog and vendored-library work — gated by host
tests plus a cross-build instead — in a second, so each changelog's contents match the gate that verified them. Before
this, `trk archive` had no way to express that: every `done` task in one run graduated to the same file
regardless of which policy actually covered it, so a task whose real destination was the second changelog
silently landed in the first, and the structural dedup that makes `archive` safe (an `archived` task can never
be re-emitted) made the mistake permanent. `trk` itself has no opinion on *what* the split is — that is a
policy fact about the consumer repo, not something to hardcode — so the mechanism is a config-level map,
`archive.routes: { "<tag>": "<path>" }`: a task carrying a configured tag routes to that path instead of
`archive_out`, resolved per task inside ONE `archive` run (`Cli.resolveDestination`), so a mixed done queue
fans out correctly without a manual `--tag`-filtered second invocation — the "remember to split the run" ritual
that `archive_out`'s own persistence was built to kill in the first place; reintroducing it here would have been
the same regression one layer down. Precedence is unchanged: an explicit `--out` still overrides *everything*,
including every configured route, because the operator asked for one file, full stop — the same rule
`--out`/config already applies to `archive_out`. A task cannot match two configured routes: which tag wins
would be a silent runtime pick trk has no basis for making, so it is a hard error naming the task and both
routes, refusing the whole run (an authoring conflict in `config.json`, not something to resolve by picking
one arbitrarily). A task matching no route falls back to `archive_out` exactly as before this feature existed
— a repo with no `archive.routes` configured always resolves to one group, which is byte-for-byte the prior
single-destination behavior. `--dry-run` previews stay a single undifferentiated list in that common case;
splitting across more than one destination labels each group with its path so the preview reads as more than
one list, not one destination's bullets interleaved with another's.

*Rejected: `archive` REFUSES a mixed batch and makes the operator split the run by hand
(`--tag sublib --out vendor/sublib/CHANGELOG.md`, then a second call for the rest).* Cheapest to build, and
consistent with the guard's existing fail-loud posture — but it reintroduces exactly the "forgot where it
writes" ritual `archive_out`'s config persistence exists to kill, this time per-tag instead of per-repo. A
config-level route is no more work to write than the guard's refusal message would be to read, and it never
needs re-typing on the next run.

**A body is edited through a PIPE, not through the shell** (2026-08-20, task `01M0EM10X`). `trk show <id>
--body` prints the raw body bytes as the read half of a round trip; the write half was
`--body "$(trk show <id> --body)"`, which is lossy (`$(...)` eats every trailing newline) and length-capped.
`--body -` now reads the whole of stdin, the conventional meaning of `-` — and it was chosen over the other
option on the table (refuse `-` loudly) because refusing leaves the round trip without a safe write half at
all. What it replaced was worse than either: `-` was taken as a *literal body*, so `trk edit <id> --body -`
silently overwrote a multi-paragraph body with a one-character string, and an agent lost one that way and
caught it only by re-reading. Exactly **one** trailing newline is trimmed (CRLF-aware) — the one `show
--body` adds when the body lacks it — so `trk show <id> --body | trk edit <id> --body -` is byte-stable, and
stable on every later round trip. Two refusals guard the flag rather than guessing: **no stdin wired** and
**stdin empty** both abort with a message and leave the body untouched, because an empty read is far more
often a pipe whose upstream never ran than an intent to blank a body — `--body ""` still says that
explicitly. `add` takes the same flag for symmetry (an agent that learns it on `edit` will try it on `add`).
*Superseded in spelling only* (2026-08-23, see the direction-naming ruling below): on `edit` the flag is now
`--replace-body`/`--append-body`, and the round trip reads `trk show <id> --body | trk edit <id>
--replace-body -`. Every semantic above — the one-newline trim, both refusals, `-` meaning stdin — is
unchanged and applies to both. `add --body` and `show --body` keep their spelling: creation has nothing to
replace and `show`'s is a READ flag, so neither is a two-direction mutation.

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
The per-verb text lives in the `Cli.verbs` table that dispatch itself reads (see "MCP front end"), so a verb
cannot exist without its help.

**`--not-tag <t>` (repeatable, ANDed) on `next`/`list` derives a query set as a complement, not a
positive filter — deliberately.** A consumer of `next` (one filtering on a hardware-vs-host axis, say) often wants "everything
EXCEPT what's blocked", not "everything tagged X". A positive membership tag (`auto`, say) makes an untagged
task ambiguous — not-eligible, or simply not-yet-triaged? — so the query can never answer "is the eligible
bucket actually empty" with confidence, and a missed triage silently reads as ineligible. Blocker tags
(negative, applied only where a real blocker exists) make absence mean eligible: the safe default, and the
residual triage cost (a task that IS blocked but not yet tagged so) stays visible rather than silently
hidden. `--not-tag <blocker-tag> --not-tag <other>` is then one bare command for the autonomous-eligible
bucket — no `--json` + external filtering required. The tags themselves are the CONSUMER's vocabulary; trk
ships none and has no opinion on what a repo calls its blockers. (Decisions are no longer among them: they
are excluded from `next` structurally, so no term is needed for them and none can be forgotten — see
"Decisions" below.)

**`trk stale` cross-references git history against tracker state — read-only, best-effort, LANDED commits
only.** The motivating case: an implementing commit routinely NAMES the task id it completes, and nobody
runs `trk state done` — the evidence was sitting in `git log` the whole time. `trk stale` runs `git log
--oneline` (no flags beyond that) with cwd set to the STORE ROOT (`Cli.dir`, resolved by `discover.findRoot`
— the repo housing `.tracker/`, which the tool itself may not live in), tokenizes the output once (maximal
alphanumeric runs), and looks each token up against an index of every OPEN task's full id + displayed short
id (exact-token match, not substring — a short id can never accidentally match as part of an unrelated
longer token). `submitted` tasks are excluded: a submission already IS the self-reported signal this verb
exists to surface. Leased (`claimed`) tasks are **included**: a lane's commits reach this ancestry only when
it merges, and its `submitted` line merges with them — so a landed citation on a task still leased means
the lane merged without submitting (or wrote `claimed` out of the pre-rename habit), stranding it out of
both `next` and the verification queue.

**Deliberately `git log`, never `git log --all`.** `--all` walks every ref, including a parallel fan-out's
unmerged worktree branches — a commit hit there is not proof the work is at HEAD (measured in the field: a
reconciliation pass mis-marked tasks BUILT this way before catching itself with `git merge-base
--is-ancestor`). `trk stale` wants only LANDED evidence, so it scopes to the current branch's ancestry by
construction rather than asking the caller to filter `--all`'s output after the fact.

## MCP front end — `trk mcp-serve` (01M2GJV9S)

An additional surface for agents, not a replacement: the CLI stays what docs cite, humans use, and ssh
reaches. JSON-RPC 2.0, one message per line on stdio; `initialize`, `ping`, `tools/list`, `tools/call`,
id-less notifications ignored. What a typed call removes is the shell: no pipe to mask an exit, no
backtick executed inside a body, no swappable positionals, no body edit without a direction.

- **One table.** `Cli.verbs` holds each verb's handler, whether it writes, its help text and its tool
  specs; CLI dispatch, `--help`, the `TRK_READONLY` gate and `tools/list` all read it. A tool call
  validates its typed arguments, builds argv and runs `Cli.dispatch` — the verb's own code, so a body
  append still reads through the snapshot+log fold. Every tool flag must appear in its verb's help
  (asserted), so a renamed flag cannot leave a stale tool.
- **One tool per verb** (`doc` splits into `doc_set`/`doc_unset`/`doc_list`/`doc_resolve`). The server
  cannot tell an orchestrator's call from a lane's — subagents share the session's one server — so verb
  scope (`archive`/`compact`/`render` for orchestrators only) is enforced by per-agent tool allowlists on
  the client, which needs the verbs to be separate tools. `readOnlyHint` derives from the verb.
- **CLI-only:** `init` (the server serves existing stores), `migrate-arcs`/`migrate-shorts` (one-time,
  deliberate repairs; `--min` rewrites frozen ids) and `mcp-serve`.
- **Read tools return JSON** (`show`/`list`/`next`/`tree`/`log` run with `--json`, which the CLI gained
  alongside), removing the reason anyone pipes them.
- **Typed values stay data.** `Cli.dispatch` skips help routing, so a body reading `--help` is text; a body
  of `-` is text, not a stdin read (`body_dash_reads_stdin = false`). A *positional* string starting with
  `-` is refused — the verb parsers would read it as a flag.
- **Failures are results.** A refused argument, a refused tree or a failing verb is a `tools/call` result
  with `isError: true` and trk's message; only an unknown tool or malformed request is a JSON-RPC error.
  Load warnings (ghosts, withheld events, …) ride along as a second text block.

**Tree selection.** Claude Code spawns one stdio server per session with cwd at the session's repo root,
and subagents multiplex over it, so a worktree lane's calls reach a server whose cwd is the main checkout
— walk-up discovery would silently retarget every lane write to main's store. Every tool therefore takes
a **required** `tree`, with no default: `"main"` or a linked worktree's path (absolute, or relative to the
main checkout). The store is opened at exactly that root — no walk-up — re-read on every call, and a tree
with no `.tracker/` is refused rather than silently created. The server enforces only validity; *which*
tree a write belongs in (is the fact true only if the lane's commit lands?) is the caller's policy.

- **Validation without git** (std-only, never shells out). At start the server finds the repository from
  its cwd: a `.git` directory is the common dir and its parent is "main"; a `.git` file (started inside a
  worktree) is followed to its gitdir and `commondir`. A tree path is accepted only if, after resolving
  real paths, `<tree>/.git` is a file whose `gitdir:` is `<common>/worktrees/<name>` **and** that
  registration's `gitdir` file points back at `<tree>/.git`. The two-way check is what refuses a forged or
  copied `.git` file claiming another worktree's registration, a stale registration whose worktree moved,
  and a separate repository. Outside git, "main" is the start directory and no other tree exists; a bare
  repository has no "main".



Storage is an append-log of events + a full-state snapshot baseline + adopt/condemn compaction. It is realized
as `.tracker/log.jsonl` (one JSON event per line) plus an optional `.tracker/snapshot.jsonl`, both written via
**write-temp-then-rename** (`Store.atomicWrite`: a temp file in the same dir, atomically renamed over the
target). Load = fold: replay the snapshot (if any) **in file order**, then the log **in `ts` order**
(`Store.load` → `replayFile`).

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
  - **The merge driver is also not sufficient *within one working tree* — the append itself needs a lock**
    (01M2V2NPA, 2026-09-18). `merge=union` reconciles two committed **copies** of the file; it says nothing
    about two processes writing **one** file in **one** tree — which is precisely the case the
    parallel-write permission above creates, and which the fan-out pattern then maximizes by ruling that a
    defect a lane *discovers* is filed against the MAIN checkout (deliberately, so an abandoned lane cannot
    take the filing down with it). Worktree isolation separates lanes' code; it gives their tracker appends
    no separation at all. `persistAppend` was a bare length-then-pwrite — a read-modify-write — so two
    writers both read `end = N`, both wrote at `N`, and the second overwrote the first; when the lines
    differed in length the survivor kept a tail of the loser, producing **one line holding two JSON
    objects**, which fails the entire load with `NotAnObject`. Measured: 24 concurrent `trk add` → 5 lines,
    6 of 24 titles, store unloadable. Not a degraded read — every consumer goes down with it. **The
    ruling:** the whole read-modify-write is taken under an **exclusive advisory lock on `log.jsonl`
    itself** (`createFile(.{ .lock = .exclusive })`, acquired at open before `length`, released at close;
    blocking, since an append is microseconds and `WouldBlock` would only move the loss to the caller).
    The lock is on the log's own inode rather than a sibling lockfile: no new on-disk artifact, no
    `.gitignore` entry, and it works unchanged in a store created before the fix. It deliberately does not
    cover a whole-file **rewrite** by something that does not ask for the lock — `compact`'s rename, or a
    git merge/checkout in a tree where an agent is appending (see the lost-update hazard above) — and a
    sibling lockfile would not cover those either, because git does not ask. Shipped with a
    concurrent-writer arm (`store_test.zig`), because every other test in the suite is single-writer and
    the defect was invisible to all of them: 8 writers × 16 appends, asserting **both** that all 128 events
    survive and that the log still folds. Against the unfixed append that arm sees 68 of 128.
- **Merge-*safe* by construction; merge-*free* is still a later goal.** The fold-time acyclic re-check
  (`checkAcyclic` on every `load`) means a textual union-merge of parallel-worktree appends can't silently
  corrupt state or smuggle a cycle, and disjoint-task `setState` events commute — which is exactly why
  disjoint-writer close-out is safe. What's *not* safe (and *not* built) is two writers mutating the
  **same** task: that needs a **commutative event schema** (a CRDT-shaped log) — an explicit, gated
  aspiration (the open fork below).
  - *Why a blanket "all appends commute" claim was rejected for the general case:* independent top-level
    declarations commute unconditionally; *same-task* events don't. *Disjoint*-task events do — which is the
    narrower property disjoint-writer actually rests on.
- **Edge removal (`undep`/`unin`) is a fold-time tombstone, log-replay-scoped.** `undep` appends an
  edge-tombstone the fold applies as *tombstone-beats-`dep`* — order-independent under union-merge (a
  concurrent same-edge `dep` loses regardless of append order). `unin` is the exact mirror for the `in`
  edge kind (tombstone-beats-`in`, over `(task, arc)` instead of `(from, to)`) — added 2026-07-30 (01KYSYBVK)
  to close a gap where `dep`/`undep` were a matched append/tombstone pair but `in` had no inverse at all, so
  a task/arc argument-order slip on `trk in` was permanently uncorrectable (the cycle-detector treats a
  wrongly-directed `in` edge as equivalent to a `needs` edge, so even the CORRECT-order `in`/`dep` call is
  then rejected as closing a cycle — the only way out is removing the bad edge itself). Both tombstone sets
  are a **fold-time** construct: `compact`/`serializeState` neither emit `undep`/`unin` ops nor persist
  tombstones, and correctly so — by compaction every tombstoned edge is already folded out of `needs`/`ins`
  (absent) and the snapshot emits only surviving edges, so no stray `dep`/`in` line survives to need
  blocking. A literal self-membership `trk in X X` is rejected outright (both at the CLI, with a dedicated
  message, and structurally via the cycle-detector, which treats `start == target` as trivially reachable).
  A *backwards* two-distinct-id `in` (task/arc swapped) is **now hard-rejected at write time for the common
  case** (01KYTFRD7, 2026-07-30, superseding the reasoning below): the declared-arc requirement (see
  "Arc-ness is a DECLARED property" above) makes "an established arc's first member is another
  already-established arc" (legitimate nested-arc authoring) and "an established id becoming a member of a
  not-yet-declared id" (the mistake) DIFFERENT pre-write graph states, not the same one — genuine nesting
  always declares the outer arc first, the mistake never declares its accidental "arc" at all. *(Superseded
  reasoning, kept for the record: a heuristic reject based on prior-graph-shape alone genuinely was
  impossible to make safe, because — before arc-hood required declaration — both shapes looked identical at
  write time; the fix wasn't a smarter heuristic, it was removing the ambiguity the heuristic would have had
  to resolve.)* `unin` remains the general recovery mechanism for the shape the declared-arc gate does NOT
  catch: a wrong-*direction* `in` between two ids that are BOTH already legitimately declared arcs (e.g. two
  sibling arcs, swapped) — it removes whichever `in` edge was actually written, by replaying the SAME
  (possibly wrong-order) arguments with `unin` in place of `in`.
- **The LOG folds by `ts`, deduped; the SNAPSHOT folds in file order** (2026-08-20, task `01M0EJGYH`).
  `log.jsonl` carries `merge=union`, so its line order is whatever the merge driver produced by
  concatenating two writers' regions — not chronological order, while every event already carries the `ts`
  that is. Folding it in file order let a merge decide which of two same-task `setTitle`s won, and let a
  lane's resurrected pre-compact events land *after* the state that superseded them. `replayFile` now sorts
  the log by `(ts, file position)` — a total order, so the fold is deterministic without a stable sort — and
  drops byte-identical duplicate lines first (a resurrection re-concatenates whole already-folded regions;
  the copies match to the byte, `ts` included, and `apply` was always idempotent over them, so collapsing
  them is a no-op that keeps the fold linear in the DISTINCT event count — counted in
  `Store.deduped_log_lines`). `snapshot.jsonl` is deliberately NOT reordered: it is a whole-file baseline
  written only by a serialized `compact` and never union-merged, so its file order IS its authored order.
  Beyond determinism within the log, this also buys nothing about log-vs-snapshot on its own — that is
  what the per-task watermark below adds.
- **A node with no `add` behind it is a GHOST, and is reported** (2026-08-20, task `01M0EJGYH`).
  `ensureNode` deliberately tolerates an event that references an id before its `add` — a union-merged log
  legitimately interleaves that way, and rejecting it would make a merge-safe log unloadable. The tolerance
  is only wrong *after the whole fold*, when no `add` ever arrived: the node is then reconstructed from
  whatever single event survived, so it reads as a real task with an empty title, no tags and no arcs
  rather than as missing data. Measured in the Enix tracker: two June-era tasks in exactly that state, their
  adds GC'd by a `compact` and a lone `setBody` union-merged back in afterwards; recovering the titles took
  digging the original `add` lines out of git history. `load` now collects every such id into
  `Store.ghost_tasks` (sorted, since map iteration order is not stable) and main.zig warns once per id —
  non-fatal, on the same footing as `self_wait_cycles`, because the data that IS there stays readable.
- **`compact` GCs a ghost and quarantines its log lines — it does not refuse** (2026-08-20). A ghost is not
  a task; it is the residue of events about an id that no longer exists. `serializeState` therefore treats
  `!has_add` as a collection class alongside `dropped`/`archived` (`isCollectable`), dropping the node *and
  every edge touching it*, and `compact` first spools every log line referencing a ghost id to
  `.tracker/quarantine.jsonl` (append-only, headed by a `{"op":"quarantine",…}` line naming the run's ids,
  never `merge=union`, never read back — an unknown `op` is skip-and-warn, so a human can cat the spool back
  onto the log to recover it). The result is reported by id, never a bare count.
  - **Why GC rather than the refusal this replaced.** The irreversible step was never the truncation — the
    log lines are in git either way — it was the *promotion*: writing an `add` for the husk makes it
    indistinguishable from a real task (it now HAS an add, so the load-time ghost warning goes quiet
    forever) and surfaces it in `next`/`render` as nameless open work. Refusing also had no reachable exit
    but `--force`, which did exactly that promoting: the ghost's events live in `log.jsonl`, every load
    re-materializes it, and nothing but `compact` clears that file — so the refusal was a deadlock whose
    only key was the destructive path. Both remedies it printed were unreachable from the CLI: `add` mints
    a fresh ULID (so re-filing cannot re-home the orphaned events), and appending a recovered `add` by hand
    is exactly the `.tracker/` hand-edit the tool exists to remove. The load-time warning already fires on
    **every** command, so dropping the refusal costs no signal.
  - **What a ghost actually means**, narrowed: the snapshot re-emits an `add` for every live task, so a live
    task cannot be a ghost unless the snapshot itself was clobbered or a conflict hand-resolved badly. The
    ordinary cause is that the task was `dropped`/`archived`, a `compact` GC'd it, and a stale lane then
    appended an event to it — where "discard the stale event" *is* the right answer. The rarer clobbered-
    snapshot case is what the quarantine spool is for: restore `snapshot.jsonl` from git, append the spool
    back onto the log, ids intact.
  - The ghost set is re-scanned inside `compact` rather than trusted from load time, but only to stay
    aligned with this process's own appends. It cannot see another writer's post-load appends — those lines
    were never folded, and this compaction truncates them regardless. That hazard is bought off by the
    standing operational rule, not by a rescan: **never compact while fan-out worktrees are in flight** — a
    lane whose base predates the compact will union-merge the GC'd events straight back in.
- **Compaction leaves a TOMBSTONE, so a compacted id still resolves** (2026-09-16, task `01M2M2K1J`).
  Compaction is the only thing in trk that destroys an id: `serializeState` skips every `isCollectable`
  task and every edge touching one, then the log is truncated, and afterwards nothing under `.tracker/`
  mentions the id at all. `trk show <that id>` therefore answered `no task matches` — *the same words, and
  the same exit code, as for an id that never existed*. Those are opposite facts. The expensive direction
  is the one that actually bit: a wrong "dangling" verdict invites someone to "fix" a citation that was
  correct. Measured on the Enix tracker 2026-09-12 — `show` called `01M1RQ7XK` and `01M0QJWJ7` dangling
  while `scripts/dangling-tracker-id-lint.sh`, which knows the difference, scanned 29,792 citations and
  found 11,207 live, 18,585 historical and **0** dangling.
  - **The information was always recoverable; the store just wasn't the one keeping it.** That lint
    recovers it from `git log --all -p -- .tracker/log.jsonl` — the pre-compact log lines survive in git
    even though the working tree no longer has them. Correct, and unusable as a lookup: measured on a
    repo where 10,574 commits touch that path, that scan is ~31 s and ~162 MB of diff output to answer one
    yes/no question. So the store keeps its own record instead. `compact` appends one line per collected
    task to `.tracker/tombstones.jsonl` — id, frozen short id, title, why it left (`archived`/`dropped`/
    `ghost`), the arcs it belonged to, when — **before** any destructive write, because that is the only
    moment the information still exists; `load` folds the file into `Store.tombstones`, and a lookup is a
    hash probe. Deliberately no body: the index is read on every command, and the body is still in git
    history and in `.tracker/backup/`.
  - **Three answers, three exit codes.** `trk show` exits `0` for a live task, **`2`** for a compacted one
    (the record is printed under a `COMPACTED` banner, in a shape that cannot be skim-read as a live task),
    and `1` for an id nothing has ever heard of. Collapsing `2` into `0` would tell the dangling-id lint
    that a graduated id is live; collapsing it into `1` puts it back where it started. `--json` carries a
    `"compacted": true` key the live view never emits, so a machine reader branches on a key rather than on
    the absence of one. `--body` is the exception: it is the read half of a pipe into `trk edit
    --replace-body -`, and a tombstone has no body, so stdout stays **empty** (which that flag refuses) and
    the explanation goes to stderr — never plausible-looking body bytes.
  - **This does not un-GC anything.** The task stays out of the graph, out of `next`, out of every view.
    The index is the difference between forgetting a task and forgetting *that it ever was*.
  - **`trk tombstones --rebuild` is the one-shot migration** for ids compacted before the index existed —
    the lint's own git-history scan, run once and persisted rather than once per question. MEMBERSHIP (does
    this id get an entry at all) is decided by `model.eventTaskIds` over EVERY event kind history holds for
    it — one id for a scalar op, two for an edge (`dep`/`undep`/`in`/`unin`), none for `setDocPath`. TITLE
    and END-OF-LIFE STATE are recovered separately, from just the `add`/`setTitle`/`setShort`/`setState`
    events (largest `ts` wins, so the answer does not depend on git's walk order) — an id can be, and often
    is, entombed with neither: `reason` stays `"unknown"` and `title` prints `(not recorded)`.
    Skips anything still live, and is idempotent. Uses `--all` — unlike `trk stale`, which is deliberately
    ancestry-only — because the question is "did this id ever exist", and an id minted on an unmerged
    branch still existed; a false *live* would be dangerous, a false *existed* is not, since the record
    says plainly that it is gone. CLI-only: it is not an MCP tool, both because an orchestrator runs it once
    and because `readOnlyHint` is derived from a tool's fixed argv and could not have seen a `rebuild: true`
    argument coming.
    - **Membership was originally keyed on the four title-bearing ops alone, and that missed GHOSTS**
      (2026-09-18, task `01M2N8WMD`). A ghost — an id `compact`'s own live entombment already classifies
      `"ghost"` (`!t.has_add`, `isCollectable` unconditionally) — is exactly the id class whose committed
      history can hold NO `add`/`setTitle`/`setShort`/`setState` event at all, only the edges/body/tags
      that referenced it. The original switch built a `recs` entry only from those four op kinds, so such an
      id was invisible to the scan outright — not misclassified, absent. Found live on the Enix tracker:
      `01KVR2E1KTXC65HD5175N373AH`'s full history is exactly one `setBody` and one `dep`, with five live
      citations in the Enix tree depending on `trk show` answering `COMPACTED` rather than "never existed".
      Its compaction predates the tombstone index outright, so `--rebuild` is its only path back; fixed by
      seeding a `recs` entry from `model.eventTaskIds` for every decoded event, independent of the
      title-recovery switch.
    - **And it recovered no ARC MEMBERSHIPS at all, so the two fixes composed only going forward**
      (2026-09-18, task `01M2V2TYC`). `compact` records a task's arcs at the moment it collects it, when
      the edges are still in the store — which is why `trk tree`'s compacted-members block (`01M29P5T7`)
      works for anything compacted *after* the index existed. `--rebuild` reconstructed title and
      end-of-life state and nothing else, so every back-filled record carried `"arcs":[]` **by
      construction**: measured on the Enix store immediately after the one-time rebuild, 2521 of 2521
      records, and `trk tree 01M0JN18R` — the very arc whose misreading motivated `01M29P5T7` — printed no
      block at all. A reader following `01M29P5T7`'s own install note ("run `trk tombstones --rebuild` and
      the block will fill") would conclude the install failed, or that the arc genuinely had no compacted
      members: the exact wrong inference that whole line of work exists to prevent, one layer up.
      - *The fix reads the `in`/`unin` events already in the scanned history.* The rule mirrors the fold
        (`Store.apply`'s `.unin`) and is **not** the largest-`ts` last-write-wins used for title/state:
        `unin` writes a permanent tombstone for the `(task, arc)` pair, so a later `in` is blocked
        regardless of append order. A member iff some `in` for the pair exists and no `unin` for it does,
        anywhere in history — two flat pair sets, needing no ordering, which is just as well since
        `git log --all -p` has none the fold would recognize. DIRECT `in` edges only, matching what
        `compact` writes; reachability-derived membership (which `dep` can create as a side effect) is out
        of scope for a tombstone, which answers "what was this" and `in` is the part that was *declared*.
      - *`--rebuild` gained one exception to "an already-entombed id is skipped".* It is idempotent by id,
        so without this the 2521 membership-less records would stay membership-less forever and the fix
        would only ever reach stores that had never been rebuilt. A row that STRICTLY IMPROVES an existing
        record is re-appended and supersedes it (`tombstones.jsonl` is last-line-wins per id, so nothing is
        rewritten in place). Strictly two cases: a `git-history` record replaced by a `compact` one, and a
        `git-history` record that gains memberships it had none of. A `compact`-sourced record is never
        overwritten by a reconstruction, and nothing is overwritten merely for being newer — so a rebuild
        with nothing to add stays a no-op, and the report distinguishes "N new" from "N upgraded".
      - *`trk tree` now says when an empty block is unreadable.* In a store with NO tombstone index at all,
        "this arc had no graduated members" and "nothing has ever been recorded here" are the same silence.
        One line, printed only in that state and only for an arc, points at `--rebuild`. Once the index has
        anything in it, an empty block is a real answer and the line is gone.
  - **`trk tombstones --verify` is the STANDING CHECK that catches a regression in the above** (2026-09-18,
    task `01M2N8WMD`). Before it existed, the only evidence `--rebuild` did its job was `--rebuild`'s own
    printed count ("N new tombstone(s) recorded") — coverage as reported by the mechanism being checked,
    which is precisely the shape `docs/debugging.md`'s rule 5 forbids: a check that reads as assurance while
    resting entirely on the thing it is meant to catch failing. `--verify` re-derives the SAME structural
    id set `--rebuild` computes (`scanLogHistoryForIds`, shared — one authoritative parse of "what ids does
    history own", not two that can independently drift) and asserts, against the CURRENT contents of the
    live store and `tombstones.jsonl` — not against `--rebuild`'s self-report — that (structural set) −
    (live) − (tombstoned) is EMPTY. A non-empty result exits `error.TombstoneIndexIncomplete`, listing every
    gap; it never writes (a verify that also repairs stops being a check that can fail). Same cost as
    `--rebuild` (one `git log --all -p` walk; ~80 s measured on the Enix tracker's larger history, vs. the
    ~31 s figure `--rebuild`'s own doc cites on a smaller repo) and the same CLI-only, non-MCP reasoning.
    - **Lives in `trk`, not as an Enix lint row, because `trk` owns the Event model the check depends on.**
      The alternative — reimplementing "every id an event names" as a second, independent parser (e.g. a
      shell/jq scan of raw JSON field names, which is what `scripts/dangling-tracker-id-lint.sh` does on the
      Enix side) — is a proven failure mode here, not a hypothetical one: that lint's own step 2 went through
      two revisions to reach a correct field-based extraction (2026-09-16, `01M2N6RQJ`), and a naive
      add-events-only tightening it CONSIDERED would have broken exactly the ghost class this fix addresses.
      Two implementations of "what does history own" is two places for that knowledge to drift out of sync;
      one, inside the tool that owns `Event`/`Op` and is already exhaustively switched over every variant
      (`model.eventTaskIds` has no `else` arm — the compiler refuses to build if a future `Op` variant is
      left unhandled), is the one that cannot silently fall behind the model it is checking.
    - **Residual risk, stated rather than hidden:** sharing `scanLogHistoryForIds` means a regression that
      guts the shared DISCOVERY step itself (not a newly-unhandled `Op` variant, which the exhaustive switch
      already prevents, but an outright deletion or logic bug in an already-handled arm) would blind
      `--rebuild` and `--verify` together, the same way the pre-fix code was blind to ghosts in both the
      entombing and the (nonexistent, at the time) verification. This is an inherent limit of any
      self-hosted check built from the mechanism it verifies, not specific to this design; the alternative
      (an independent, drift-prone second parser) has a worse measured failure history. `--verify` fully
      covers every OTHER incompleteness class: a compaction that predates the index, a bug in
      `appendTombstones`'s write path, a hand-deleted tombstone line, a future entomb path that forgets to
      call `appendTombstones` at all.
  - **A refused compact rolls the index back with everything else.** The tombstones are written before the
    round-trip self-verify can fail, so `CompactVerifyFailed` restores `tombstones.jsonl` alongside
    `snapshot.jsonl`/`log.jsonl`. The one error this mechanism must never make is the mirror of the one it
    fixes: a tombstone for a task that is still live would make `show` report live work as gone.
  - **`trk tree` reports an arc's GRADUATED members instead of omitting them** (task `01M29P5T7`). The
    measured cost of not doing so was one wasted dispatch: `trk tree` on an arc whose members had all been
    archived and compacted printed a well-formed one-line tree, indistinguishable from a never-sliced arc,
    and a lane was briefed to "design and slice" work that had already shipped. That is the *asymmetry*
    this whole mechanism is about, one level up — `show` on a collected id at least said something
    distinctive, while `tree` said something entirely **normal**. Absence is only dangerous in the shape
    that looks like an ordinary answer.
    - *Root cause, and why it is a display fix and not a recovery one.* `renderTree`/`treeJson` iterate
      `store.ins` with no state filter, so an archived-but-not-yet-compacted member renders fine, marked
      `[a]`. An arc can therefore only render empty once the `in` EDGES are gone, which happens in exactly
      one place: `serializeState`'s `gc_set` drops every edge with a collectable endpoint alongside the
      member tasks. The tombstone already records each collected task's arc memberships, so the fact was in
      the store and only the view was silent. `Store.compactedMembers` is that read.
    - *Emitted unconditionally, not behind a `--archived` flag.* A flag leaves the silence exactly where it
      did the damage: the reader who was misled did not know to ask, because the empty tree gave him no
      reason to. Under the arc's live children, `tree` prints `compacted members (N)` and one
      `compacted: <short>  was <reason>  <title>` row each — no state marker, no box-drawing connector, so
      a graduated member cannot be skim-read as a live one (`showTombstone`'s rule, applied to a list).
      `--json` carries `compacted_members` at the ROOT, always present and possibly empty, each entry keyed
      `"compacted": true`.
    - *The paired negative is the other half of the fix.* An arc that genuinely has no graduated members
      still renders as a bare one-line tree with no block at all. Making absence speak is only an
      improvement while presence still reads as presence; a block printed unconditionally would have
      swapped one indistinguishable pair for another, pointing the other way.
    - *A COMPACTED root gets `show`'s verdict, not "no task matches".* `trk tree <collected-arc>` prints
      the tombstone record, its graduated members, and exits **2** — the same three-way contract as `show`,
      since a graduated ARC read as never-existed is the identical misreading aimed at the root instead of
      at the members.
    - *`show`'s own sections, checked and made consistent.* `prereqs`, `dependents (needs this)` and `arcs`
      all iterate live edges with no state filter, so they behave exactly like `tree`: an archived member
      still lists, a compacted one vanishes with its edge. Only ONE of those is recoverable — an arc's
      compacted MEMBERS — because the index records the task→arc direction and nothing else. So `show`'s
      arc-prereq line, whose `(0/0 done)` was the same silent-absence shape, now reads
      `(0/0 done, +N compacted)` when there are graduated members and stays unchanged when there are none
      (`--json` always states `arc_progress.compacted`, because a machine reader wants a stable schema
      where a human wants a quiet line). A compacted DEPENDENT is not recoverable: the index records no
      `needs` edges. Nor is a live task's compacted ARC: the live task has no tombstone of its own, and the
      arc's own record says only what *it* was a member of. Both are limits of what compaction kept, not
      oversights — recovering either means recording edges the index deliberately does not carry.
    - *Still omitting them, and knowingly:* `render` (`docs/TODO.md`), `list --arc` and `next` enumerate arc
      members the same way and say nothing about graduated ones. Not folded in here because the TODO.md
      projection's format is load-bearing for readers outside this tool and the right shape there is a
      judgment, not an obvious repair. Carrier: Enix task `01M2MWB6Q`, which also holds the open question
      of whether a forward-looking projection wants the annotation at all.
- **The snapshot carries a PER-TASK watermark, and a log event older than it is withheld and reported**
  (2026-08-20, task `01M0EM3G6`). `compact` stamps each `add` it writes with `wm` — the `ts` of the newest
  event folded into the state being written (carried forward, so a task nothing has touched since an earlier
  compact keeps the bar it already had). On replay, a log event for that task whose `ts` predates its `wm` is
  **not applied**, and the task is reported in `Store.superseded` with a count (per task, not per event — a
  resurrection re-merges whole regions, and a warning per line is a wall nobody reads). This is what kills
  the reopened-tombstone shape: a `setState open` a compact had already superseded no longer un-closes a
  genuinely finished task. `wm` is an extra JSON key on a line an older binary already parses and whose
  unknown keys it already ignores, so no migration and no forward-compat break; `wm = 0` (legacy snapshot,
  or a task with no timestamped events) disables the check for that task.
  - **Why this is sound rather than a guess: the disjoint-writer rule.** Two writers never mutate the same
    task (see above), so for a task the snapshot already knows, a log event older than its watermark cannot
    be a concurrent edit — only an event some `compact` already folded. Under the *unsupported* same-task
    concurrent-write pattern the rule can withhold a genuinely newer field write (watermarks are per task,
    not per field); that pattern is already outside the model, and the withheld event is reported, never
    silently dropped, and still sits in the log for a deliberate re-apply.
  - **Only last-write-wins SCALARS are withheld** (`add`, `setState`, `setTitle`, `setBody`, `setPriority`,
    `setShort`). An edge, tag, or docref event is additive — or a tombstone that wins regardless of order —
    so a stale one converges to the same state and withholding it would drop a lane's real work for no
    safety gain. A stale `setState done` that *is* withheld costs nothing either: the orchestrator's
    per-wave reconcile re-closes done tasks idempotently.
  - **An id the snapshot does NOT know is never judged.** Once compaction has erased a GC'd task, it is
    indistinguishable from a task that never existed, so an event for an unknown id is applied — a lane's
    newly filed task must survive a compact it raced. A resurrection of that shape instead surfaces through
    `ghost_tasks` (no `add` ever arrives for it), which is exactly how the measured Enix instance presented.
    Distinguishing the two would need GC tombstones in the snapshot, which trades away the retention ruling
    above; field-granular watermarks would need the commutative event schema named in the open forks.
- **Store-root discovery is bounded at a worktree; `TRK_READONLY` backstops the rest.** `findRoot`
  (`src/discover.zig`) walks up for `.tracker/`, git-style, but never past a linked worktree's root
  (its `.git` is a plain FILE, never a directory — the on-disk marker, no git binary needed): a
  worktree missing its own `.tracker` stops the walk *there* rather than escaping into the enclosing
  repo's live tracker. This closes an incident (2026-07-22) where a dispatched agent's directory —
  not always a *real* git worktree; some are `.claude/worktrees/<id>/` scratch dirs with no `.git` at
  all — walked all the way up into the orchestrator's live `.tracker/log.jsonl`, and an agent
  "reverting" what it believed was its own copy wiped a concurrent append there. A directory with no
  `.git` marker at all has no boundary to detect, so this fix is necessary but not sufficient — the
  belt-and-suspenders layer is `TRK_READONLY=1` in the environment, which refuses every mutating verb
  outright regardless of which root discovery resolves to. The orchestrator sets it when dispatching
  an agent that should only read the tracker.
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

## Decisions — a fork is a node, not a marker in prose (2026-09-18, arc 01M2VFTG4)

**Status: BUILT.** Shipped across seven slices; the tag + body-grep convention it replaces is deleted. Read
this before touching `cmdDecision`, `cmdRule`, `Store.isDecision`, or the `raises` edge.

### The problem

"This is a fork only the repo owner can rule on" was a *convention*, in two halves, and both are archaeology:

1. A `#scott-decision` TAG. `store.zig`'s `default_decision_tag` hardcoded that string — the owner's name —
   as a library default, under a doc comment asserting "`trk` itself has no opinion on it".
2. `trk archive` grepping each closing body for `scott-decision` / `OPEN QUESTION` / `FIX NOTE` / `your
   call` / `TODO` and REFUSING the run on any unexempted hit, because `archived` is hidden from every view
   and graduating a task with an unresolved fork in its body loses the fork permanently.

The guard's false positives were dominated by bodies that quote the markers BECAUSE the markers are their
subject — including the tasks that built the guard. Queues of 36–62 `done` tasks sat unarchived across
sessions, and the escape (`--allow-buried-decisions-for <id>:<n>:<digest>`) lived for one process, so the
same bodies were re-read every run.

**The diagnosis that decides the design: the guard is archaeology because a fork has no representation in
the model.** It is a string in a body, so intent is destroyed at authoring time and every downstream
mechanism is left guessing at it. Sharpening the guess — a better classifier, a persisted clearance, a
per-task exemption — is remediation of a loss that should never have happened. Capture the intent as
structure when it is written, and the guessing has nothing left to do.

Secondary, and why this is a trk mechanism rather than one project's convention: every project reinvents
this independently, and the owner's name must not appear anywhere in the tool.

### The mechanism

- **A decision is a DECLARED PROPERTY of a task**, exactly parallel to `arcDeclare`. New event
  `decisionDeclare { id, declared: bool, ts }`. Not a new node type: it inherits states, `show`, `--json`,
  edges, tombstones and compaction, the same way an arc root is an ordinary task that has been declared.
- **Declaration is NATURE, not lifecycle.** An arc stays an arc when it is done; a decision stays a
  decision when it is ruled. The declaration is retracted only by `--undo`, never by resolving. *Resolution
  is STATE.* This is the joint the first draft got wrong (see "Rejected" below).
- **No `owner` field.** In a single-human repo it is a constant, so it carries no information; and real
  multi-user support would need actual identity and would likely rework the lease's `holder` at the same
  time, so a bare string here is a weaker version of a system we would design differently. A project that
  needs to distinguish uses an ordinary tag — the same line trk draws everywhere else about not knowing its
  consumers.
- **Blocking is the existing `dep` edge.** `trk decision "<q>" --blocks <id>` writes `dep{from: id, to: D}`:
  the work needs the ruling, which is a prerequisite relation without stretching the word. Repeatable — a
  decision can gate work that did not raise it. The existing satisfaction rule maps unchanged: a ruled
  decision is `done` and satisfies; `dropped` ("moot, not deciding") also unblocks, which is correct and
  worth naming.
- **Provenance is a NEW edge `raises { task, decision }`**, with an `unraises` fold-time tombstone mirroring
  `undep`/`unin` (union-merge needs order-independent removal, and a mis-attributed origin must be
  correctable rather than only overwritable). Many-to-many in both directions: several tasks legitimately
  hit the same fork, and one task raises several. `unraises` must not `ensureNode`, exactly as `undep` does
  not, or a removal could mint a ghost.
  - *Why an edge and not prose in the raiser's body:* a body is a `setBody` LWW scalar, so recording it
    there is a read-modify-write on a task other lanes may be appending to — two concurrent
    `--append-body`s lose one, which is the six-lost-bodies class this doc already documents. An edge is
    additive and commutes. (An earlier justification — "structured relations survive compaction better" —
    is only half true now that the tombstone index makes a body citation of a compacted id RESOLVE, and
    should not be relied on.)
  - *Why not a `from: ?Ulid` field on the declaration:* it is single-valued where the relation is
    many-to-many, it is lost on `--undo` + re-declare, it makes a declare event reference a second task and
    so needs a special case in `model.eventTaskIds` — the one function `compact`'s ghost detector and the
    tombstone rebuild both depend on — and it makes provenance the only second-class relation in a model
    where every relation is an edge.
- **`raises` is EXCLUDED from the combined acyclic graph** (`needs` ∪ reversed `in`). It encodes no waiting,
  so it cannot close a self-wait, and `combinedReaches`/`checkAcyclic` must not walk it. (The first draft
  claimed the exclusion was *forced*, because "T needs D and T raised D" would otherwise be a cycle. That is
  wrong: it holds only if provenance were spelled as a `dep`. With `raises` as its own kind the question
  never arises. The exclusion is correct, but by the argument above, not that one.)
- **`trk rule <id> <text>` resolves: append the ruling AND `setState done`, unconditionally, and REFUSE on a
  task that is not a declared decision.** That refusal is the direct analogue of today's "refuses on a task
  not currently tagged". The old doctrine — a ruling deliberately does not close, because the task may be
  the carrier for the ruled work — does not survive, and does not need to: after migration (below) a
  decision node is never a carrier.
- **Write-time refusals** (`Store.append`, where `in` already refuses an undeclared arc): a task may not be
  both an arc and a decision, and a decision may not be `claimed` or `submitted`. A decision is not work;
  without the second refusal an agent leases a question and `stale`/`release` start tracking it.
- **`next` excludes declared decisions structurally**, the way standing arcs are excluded — but see the
  views ruling below, because exclusion alone trades one problem for a worse one.

### The views (without these, exclusion is a regression)

Excluding decisions from `next` while they block work via `dep` produces a frontier that goes empty with
nothing explaining why. The old `--not-tag <decision-tag>` was at least opt-in, and a tagged task still
appeared in a bare `next`. So the exclusion ships with all of:

- **`trk list --decision`** — the pre-dispatch sweep ("what is still waiting on a call"), replacing
  `trk list --tag scott-decision`. This query is the one the whole feature serves; without it the mechanism
  has no reader.
- **A `next` tail** naming withheld work — "N ready task(s) withheld: they wait on M pending decision(s);
  `trk list --decision`" — in the shape `list --arc`'s compacted-members tail already uses (01M2V2TSA).
  That ruling declined to give `next` a tail on the grounds that a graduated member is never an answer to
  "what can I work on"; a PENDING DECISION is the answer to "why is nothing ready", so it does not apply.
  `--json` has no footer and rows would contradict the exclusion, so machine readers use `list --decision`.
- **A distinct marker in `render` and `tree`.** `membersOf` closes over `needs`, so a decision filed with
  `--blocks T` joins T's arc by reachability and would otherwise render in `docs/TODO.md` and `tree` as an
  ordinary `[ ]` bullet — a question indistinguishable from a slice, in the projection whose whole contract
  is not-yet-built work.
- **`trk decision` takes `--in`**, and does NOT inherit the raiser's arcs. Inference is what this codebase
  keeps deleting. A decision filed with an explicit `--in` DOES gate its arc's close-out via `arcDrained`,
  which is intended — a fork about the arc blocks "is the goal achieved" — and is visible through the tail
  above.

### What is DELETED, not demoted

Once a fork is structured, new work has nothing to scan for; a body scan only ever fires on prose written
before the mechanism existed. That is a one-time FINDER, not a standing guard, and its home is the
migration. So `archive` loses the guard outright rather than being demoted to an advisory:
`reportBuriedDecisions`, `isMarkerShaped`, `hitDigest`, `AllowFor`, `lineCitesLiveTask`, both
`--allow-buried-decisions` flags and their digest protocol, `Config.decision_markers`,
`default_decision_markers`, `Config.rule_tag` and `default_decision_tag` all go.

Deleting is more honest than demoting. This doc's own argument against a warning is that it scrolls past in
a bulk run and what it failed to stop is permanent — an advisory would supply assurance without protection.
And the guard's measured behaviour was to block queues for weeks and then be worked around, which is
friction rather than protection.

**The residual cost, stated rather than buried:** a person who writes a prose fork AFTER migration and
archives it loses it, with nothing to catch them. Accepted. The structured path exists, and a tool cannot
force prose to be structure.

### Migration

`trk migrate-decisions --from-tag <tag>`, modelled on `migrate-arcs`/`migrate-shorts`, and re-runnable —
which is also how lanes forked from a pre-migration base are handled (they keep appending the legacy tag;
the orchestrator re-runs migration after integrating). No default tag: trk ships no name.

It does two things, and **it never guesses which sentence is the fork**:

1. **Splits each legacy tagged task**, because those tasks are CARRIERS — work and fork in one body — and
   declaring one a decision would let `rule` close unbuilt work. Migration mints a decision node per tagged
   task, wires `raises{original, D}`, leaves the original alone as work, and removes the tag. D is a
   scaffold the human writes the actual question into; no body text is copied or parsed. This is what lets
   `rule` be unconditional, with no `--keep-open` flag and no behaviour keyed on the target's nature.
2. **Scans bodies for the legacy markers and REPORTS them** — the prose forks that were never tagged, which
   nothing else can find. It files nothing from a scan; the operator reads the report and runs
   `trk decision`. This is the body-grep's only remaining appearance anywhere in trk, and it is opt-in,
   one-shot and human-reviewed, which is what makes archaeology acceptable here and not in `archive`.

### Compaction and tombstones

The silent-loss class, so it lands with the implementation and not after:

- `serializeState` emits `decisionDeclare{true}` for live declared ids (as it does `arcDeclare`) and emits
  `raises` edges skipping `gc_set` endpoints.
- `taskFingerprint` includes the declaration bit and the task's owned `raises` edges. **Without this a
  compact that silently drops them passes the round-trip verify** — precisely the class 01M0YESW6 exists to
  catch.
- `model.eventTaskIds` reports both endpoints of `raises`/`unraises`, which is what lets `quarantineGhosts`
  and `scanLogHistoryForIds` see the edge. `scalarTarget` must NOT include the new ops: they are
  additive/LWW-bool and are never watermark-withheld, exactly like `arcDeclare`.
- **The tombstone carries `raised` on the TASK side** — T's record lists the decisions T raised — not the
  decision side. The case that matters is T archived+compacted while D is still live: `serializeState`
  drops every edge with a collected endpoint, so D would lose its provenance. `show D` then does the
  reverse lookup `compactedMembers` already does for arcs. `collectableRows` records it at collection time,
  mirroring `arcs`.
- `tombstones --rebuild` reconstructs `raises` from history by the same surviving-pair rule it uses for
  `in`/`unin` (a pair is live iff some `raises` exists and no `unraises` does), and `supersedes` gains a
  third case — "gained raises it had none of" — or the upgrade never reaches an already-rebuilt store.
  That is the 01M2V2TYC lesson, applied in advance this time.

### Forward compatibility

The new ops are SKIPPABLE, per the codec's unknown-op contract, matching `arcStanding`. A binary that
predates them sees a decision as an ordinary open task and surfaces it in `next` — the "falsely ready"
direction this doc elsewhere calls unsafe, so it is an explicit, recorded exception rather than an
oversight. A wasted dispatch is corrected by the agent's first read of the body; bricking every read of the
store is worse. The stale-binary window was closed OPERATIONALLY here (one other session, restarted after
install), not structurally — do not read this as a guarantee.

### What the build changed, relative to the ruling above

Recorded because the ruling is the reasoning and the code is the fact; where they diverged, the code won
for a stated reason.

- **`serializeState` + `taskFingerprint` landed in slice 1, not slice 4.** Leaving them to the compaction
  slice would have meant an installable binary whose `compact` silently dropped every decision and `raises`
  edge. Verified the other way round: with the emission removed, `compact` REFUSES itself with
  `CompactVerifyFailed` rather than losing data — which is what putting the new fields in the fingerprint
  buys, and why they belong with the fold rather than after it.
- **`rule` refuses an already-ruled decision** rather than appending to it. A second ruling on a settled
  fork is a mistake, not an edit.
- **`markerFor` renders an open decision `[?]`** in `list`, `tree` and `TODO.md`. The ruling said "a
  distinct marker or grouping"; this is the marker, and it tracks the STATE (`open` and declared), not the
  declaration — so a ruled decision reads `[x]` like anything else finished.
- **`looksIdShaped` survived slice 5.** Its original occasion was a second id typed after
  `--allow-buried-decisions-for`, but the hazard is independent of that flag: `archive`'s positional is a
  SEARCH TERM, so a bare id there matches nothing and reports an empty run. Kept, message rewritten.
- **The `--not-tag` example was a CONSUMER's tag vocabulary, and is gone.** Removing the decision tag left
  two more of another repo's tags sitting in trk's own help text and in this doc, reading as if they were
  trk concepts. They were never trk's to ship. Every example is now a `<blocker-tag>` placeholder, and the
  same sweep took the other borrowed nouns out of `next`'s examples, `wordMatches`'s doc comment and
  `archive.routes`'s. What stays is evidence attribution — "measured on the Enix tracker, 2026-09-12" is
  where a finding came from, which is provenance rather than vocabulary.

### A ruled decision GRADUATES, and its ruling is what graduates (01M2VPC6K, 2026-09-19)

Filed by the Enix-side agent during its migration, after ruling 14 forks in a day — and it was right, on a
point the red team had already raised and this design had failed to close.

**The defect.** `rule` sets a decision `done`; `done` is the archive queue; `archive` graduated it and
`archived` is hidden from every view. So `list --decision` silently became "every fork since the last
archive run", and the shipped help text claimed the opposite. Worse, and understated in the filing: the
changelog bullet is built from the TITLE, and a decision's title is the QUESTION — the ruling lives in the
body. Verified end to end: after `rule` → `archive` → `compact`, the ruling text appeared in **zero bytes**
of `.tracker/`, the tombstone kept `"title":"which way?"`, and the changelog read `- which way? (…)`. The
mechanism was publishing the question and destroying the answer.

**The ruling, and why it is not "never archive".** The first answer considered was to exempt decisions from
`archive` entirely, keeping them `done` and visible forever, on the grounds that a ruling is institutional
memory. That is true of a minority — the standing kind (*arcs are containers*, *compact keeps done*) — and
those belong in THIS DOCUMENT, promoted by hand, which is where that class has always lived. Most forks are
"implement it way A or B", and their answer is legible in the code that resulted; the node has no further
job once the work lands. Exempting them would trade a fixable bug for a permanent one: a monotonically
growing pile of spent questions that real work sweeps away around.

So a decision graduates like anything else. What changes is what graduates:

- **`appendArchiveBullet` emits a decision's BODY**, indented under its question, because the ruling is the
  record. A decision is disposable precisely BECAUSE the answer lands somewhere durable first.
- **`archive.decisions_out` routes decisions to their own file, keyed on NATURE (`isDecision`), never on a
  tag.** A tag-keyed decisions route was the obvious shape and the fragile one — it needs discipline the
  tool cannot verify. Structural routing needs none. Unset falls through to the ordinary destination, so a
  repo that does not care loses nothing, while one whose changelog doctrine is "completed, verified code
  only" keeps answered questions out of it.
- **`list` defaults to REMAINING work**, hiding done/dropped/archived unless asked (`--state done`,
  `--all`). This is the rule `archived` already followed, applied one state earlier, and the numbers say it
  was overdue independently of decisions: trk's own default listing was 29 completed rows out of 31 — 94%
  noise — while `next` and the TODO.md projection were clean because they already filter this way.
- **`list --decision` stops claiming to be a complete index** of every fork ever raised, because it is not
  and cannot be.

*Deciding which rulings outlive their node stays a human act.* The tool cannot tell a spent implementation
fork from a standing constraint, and a flag for it would be one more thing to forget. Promotion to this
document is the mechanism, and it is deliberate by design.

### Rejected

- **`rule` clearing the declaration instead of closing the node.** The first draft's shape, and it does not
  compose with `dep`-based blocking: `cmdRule` never sets state, so after a ruling the `dep` would still not
  be satisfied and the work would stay blocked pending a second, forgettable `trk state done` — the exact
  failure `rule` was built to eliminate, reintroduced one op later. Worse, the now-undeclared decision would
  surface in `next` as ready work: a question with its answer appended, handed out as a task.
- **An `owner` field.** See above.
- **Per-task persisted clearances / a sharper marker classifier / narrowing the refusal to colon-glued
  "marker-shaped" hits.** All remediation of the authoring-time loss rather than repair of it. The
  classifier point specifically: `isMarkerShaped` requires the marker be colon-glued to content, so a real
  fork written "FIX NOTE — do X" reads as prose, and narrowing the refusal to marker-shaped would bury it
  silently.
- **`in` (arc membership) as the provenance link.** A decision in an arc is held by `arcDrained`, and the
  fix would be an arc special case in `next`, which this doc forbids.

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

- **Only `list --arc` reports an arc's compacted members; `next` and `docs/TODO.md` do not** (01M2V2TSA,
  Scott's call 2026-09-18). `01M29P5T7` established that a view which ENUMERATES ARC MEMBERS must never
  present a short-or-empty list as if nothing was ever there — `compact` deletes the `in` edge along with
  the member it collects (`serializeState`'s `gc_set`; an edge naming a collected id would re-materialize
  it as a ghost), so a fully-built, graduated arc renders identically to one nobody ever sliced. It fixed
  `tree` and `show` and left three views behind. The ruling splits them, and not by the invariant:
  - **`list --arc` gets it, because there it is a self-inconsistency.** `list` can show closed members on
    request (`--state done`, `--all`) and a compacted member is the only kind it can NEVER show, at any
    filter. (When this was ruled, `list` showed closed work by DEFAULT; `01M2VPC6K` later made the default
    remaining-work-only. The inconsistency survives the change, one filter deeper: ask for everything and
    you still do not get the graduated members.) A count plus a pointer to `trk tree <arc>`, not the rows: `tree` already renders the full block
    in a shape that cannot be skim-read as live work, and a second copy here would be one to keep in step.
    In `--json` they arrive as extra rows carrying `"compacted": true` — an array has nowhere to put a
    footer, so the choice is rows or nothing, and nothing would leave the agent-facing half of the same
    view carrying the defect the human half just stopped carrying. The key is the one `show --json`
    already uses, so filtering it yields exactly the pre-fix set.
  - **`next` does not, because it is not that kind of view.** A ready frontier already omits done, blocked
    and leased members and nobody calls that a silent absence; a graduated member is never an answer to
    "what can I work on".
  - **`docs/TODO.md` does not, because the projection's contract excludes it.** `renderMarkdown` states
    its own domain — only not-yet-built work; `done` graduates to `CHANGELOG.md` via `archive` — and a
    compacted member is archived-then-collected, the most finished state there is. Annotating it in would
    put back the one class the projection exists to exclude, and would be a second, drifting copy of what
    `CHANGELOG.md` already holds in curated form.
  - *Not recoverable, and deliberately so — do not re-file these:* a COMPACTED DEPENDENT (the tombstone
    index records no `needs` edges) and a LIVE task's COMPACTED ARC (the live task has no tombstone, and
    the arc's own record says only what IT was a member of). Both mean recording edges the index
    intentionally does not carry.

- **Ids cited from OUTSIDE the tracker are the caller's to protect; `compact --dry-run` is what trk owes
  them** (01M1FMNSZ, 2026-09-18). trk's compaction rules were written about task-to-task references —
  `needs` edges, arcs, citations inside other task bodies — all of which trk can see and reason about.
  They said nothing about ids cited from files trk cannot see, and which in a real project are
  load-bearing: a registry column, a source comment, a design doc, a commit message. Measured on the Enix
  side: four `scenarios/registry.tsv` rows held ids that resolved to nothing, and `git log -S` proved all
  three ids were honestly cited in the very commits that landed their rows. Not typos — collected work.
  The cost was specific: seven sibling rows were resolved by READING the archived owner's body to see
  whether a verification had actually happened; for a GC'd id there was no body to read, so "verified,
  write-back forgotten" and "never booted" became indistinguishable.
  - **Most of this is already answered by the tombstone index** (`01M2M2K1J`, above): the id resolves,
    `trk show` reports it COMPACTED with title and end state, and the footer prints the `git log --all -p`
    line that brings the body back. What a tombstone deliberately does not keep is the body itself.
  - **What was still missing is the BEFORE side** — the chance to update an external citation while the
    task is still there to read. `trk compact --dry-run` names every task the run would collect (id, short,
    reason, title) and writes nothing. It reads from the same `Store.collectableRows` the real run uses,
    never a second implementation: a preview whose whole job is to be trusted ahead of a destructive-looking
    step is worth less than nothing if it can disagree with the step.
  - **trk does not grep its consumers, and will not.** The rejected shape was an opt-in "cited externally"
    pin — a tag, or a config-listed glob trk scans before compacting. It would make the tracker know its
    consumers' file layout to do its own GC, which is the coupling this project spends most of its rules
    avoiding. The check belongs where the knowledge is; trk's job is to make the moment visible and say
    plainly that it cannot see those citations.

- **`next`/`list --json` carry the body, unconditionally** (01M1FMN25, 2026-09-18). The emitter dropped
  it, and that made the mechanical full-frontier triage a fan-out mandates — *every* ready task, scripted
  over the whole list, not the top N — impossible to script. The discriminators that decide a task's
  bucket (`HOLD`, `DEFER`, `RULED`, "your call", "NOT resolved") are APPENDED, so they sit at the END of a
  long body while the opening paragraphs still read like ordinary buildable work. Tags and titles were
  scriptable; everything else needed a `trk show` per candidate, over 280 tasks — and that step is exactly
  where tasks already done, already ruled, or blocked on someone else kept turning up. trk already had the
  body in hand: `next`'s own search matches over title+body+tags, so the filter read it and the emitter
  dropped it.
  - *Unconditional, not behind `--with-body`/`--body-tail`.* A flag's failure mode is forgetting to pass
    it — the silent omission this fixes, spelled differently. Size is not the concern it would be for the
    human view: `--json`'s consumer is a machine, and a caller who wants less already has `--limit`,
    `--state`, `--tag`, `--not-tag` and the term search.
  - *Always present, never omitted-when-empty* (unlike `holder`/`seq`), so a consumer indexes it without a
    guard.
  - *A string, not a decision-marker boolean.* The cheapest-looking option was a per-task flag for "the
    body matches a marker", and it was rejected: that vocabulary belongs to the caller, not to trk. trk
    stays generic and the grep stays where it belongs.

- **A parse failure names the argument that FAILED, and guesses the spelling** (01M1FMMFZ, 2026-09-18).
  `trk add --tags=a,b "<title>"` printed `unknown flag '<the title>'` — blaming the one argument in the
  line that was correct, and sending the reader to hunt a quoting bug in a long heredoc-written title.
  `add` took `args[0]` as the title unconditionally, so the misspelled flag was swallowed into the title
  slot and the real title arrived as an unexpected second positional. Three parts to the ruling:
  - **The title is the first BARE token**, not `args[0]`. The blame then lands on the token that actually
    failed to parse, and `trk add --tag ui "<title>"` (flags first) works as anyone would expect. A second
    bare token is its own message — "add takes exactly one positional (the title)" — because that is a lost
    quote, not an unknown flag. A title that genuinely starts with `-` has to be reworded; trk has no `--`
    terminator, and adding one would buy a case nobody has hit at the cost of a second parsing mode.
    No MCP escape hatch is needed: `buildArgv` already refuses a dash-leading positional at the boundary,
    where the message can say what really happened, so a typed `title` is non-dash by construction.
  - **`Verb.flags` joins the table**, alongside `run`/`mutates`/`tools`, and every `unknown flag` site goes
    through one `Cli.unknownFlag`. It names a near-miss within an edit distance of 2 over that verb's own
    vocabulary (`--tags` → `--tag`, `--limt` → `--limit`), because the whole class of error is reaching for
    the plural of a repeatable option; 2, not 1, also catches `--priorty`, and is far too tight to suggest
    `--tag` for `--json`. An `=`-joined value on a real flag (`--tag=ui`) gets its own line — no trk flag
    has ever taken one, which is exactly why the spelling is plausible and worth saying out loud. A
    cli_test arm asserts every listed flag appears in its verb's help text, mirroring the rule mcp_test
    already enforces for the tool schemas.
  - **A dash-leading token in an ID slot is a flag too.** `trk edit --titel x` answered "no task matches
    prefix '--titel'", which sends the reader looking for a task. No ULID or short id begins with a dash,
    so `Cli.resolve` routes it to the same diagnostic — one fix covering every id-positional verb.

- **The lease, and `claimed` → `submitted`** (01M2GGFGR, 2026-09-14). In fan-outs the only thing stopping
  two lanes or sessions from starting the same task was the orchestrator's memory, and `claimed` already
  read as "this task is taken" while meaning "this commit completes it". So `claimed` became the lease and
  the completion report became `submitted`, semantics unchanged.
  - **Encoding.** The lease is written `"state":"leased"`; `submitted` is written `"submitted"`. The token
    `"claimed"` is **spent**: every existing line means submitted, and a long-lived branch can union-merge
    more pre-rename lines in at any time, so it decodes as `submitted` forever and is never written again
    (`json_codec.stateToWire`/`stateFromWire`). The CLI, `--json` output and `list --state` all use the
    state *names* (`claimed` = lease); only the codec knows the wire token. `compact` rewrites legacy lines
    as `submitted`. A pre-rename binary meets `leased`/`submitted` as `BadState` and refuses to load —
    loud, never a misread.
  - **Markers.** The lease keeps `[c]`, `submitted` gets `[s]`: the letters follow the names, and TODO.md is
    regenerated on every render, so no persisted artifact still reads `[c]` as the old meaning.
  - **What the refusals catch.** A lease needs `--holder`, and the habit never named one, so bare `trk
    state <id> claimed` fails everywhere — including a lane's worktree store, where the main checkout's lease
    is invisible and the task reads `open`. Independently, `claimed` from anything but `open` is refused:
    `claimed` → `claimed` (the mutual exclusion itself), `submitted` → `claimed` (would pull a task out of
    the verification queue), `done`/`archived`/`dropped`/`blocked` → `claimed`. Every refusal names
    `submitted`. **Not caught:** a deliberate `--holder` lease written where nobody else reads it (a lane's
    worktree) — it merges in as a stranded lease, which `trk stale` surfaces once the citing commit lands;
    and two writers claiming the same task in the same store within the read-append window (the append
    itself is now locked — see the merge model — but the lease CHECK still runs against each writer's own
    pre-append fold, so both can pass it and both appends then land).
  - **Release path: a recorded holder, a conditional release, no expiry.** The lease event carries
    `holder` and its `ts` is the lease's age (`Task.holder`/`lease_ts`, shown by `list`/`show`/`--json`,
    kept by `compact`). `trk release <id>` / `trk release --holder <h>` append a `release` op naming the
    holder, which the fold applies **only while that holder still holds the task**; the fold likewise
    applies a lease only to an `open` task. Replay is ts-ordered last-write-wins, and that is what the
    conditions are for: a lane's `submitted`, written in its worktree before main's teardown release but
    merged after it, sorts before the release, so the release finds a submitted task and does nothing — a
    plain `setState open` would win and silently drop the submission. The same shape keeps a stale release
    from undoing someone else's newer lease, and a lease taken on a not-yet-merged view from overwriting a
    submission. Liveness stays with the orchestrator (release a lane's leases when it merges or is
    discarded); `trk state <id> open` remains the unconditional override.
    *Rejected: expiry.* It makes `next` a function of the clock rather than the fold, and a lease lapsing
    under hours of gated work hands the task out twice — the failure the lease exists to prevent.

- **Compaction & history retention.** `compact` (`Store.compact`) writes a fresh full-state snapshot then
  truncates the log. It **drops `dropped` AND `archived` tasks** (and edges touching them) — abandoned work
  has no structural future, and a graduated task is already preserved in the changelog + git log. It
  **keeps `done` tasks** — a `done` prereq is what makes its dependents eligible AND `done` is the
  un-graduated changelog queue, so dropping it would silently corrupt the graph. (Crash-safe: the snapshot
  is renamed durably *before* the log is truncated; every event is idempotent on re-fold, so the inter-step
  window loses nothing — a dropped/archived task may transiently reappear until the next compact.)
- **Compaction round-trip self-verify + bounded backup** (01M0YESW6, 2026-08-26) — the last open member of
  the silent-data-loss family this doc already documents two instances of (the ghost/tombstone shear above,
  and `01M0EM3G6`'s watermark fix). Before this, `compact` had no check that its own rewrite preserved what
  it started with: `01KZTV44M`'s 2026-08-19 body correction vanished across a compact/merge window with no
  conflict reported (the Enix tracker's `finding-20260820074254`), root-caused here (see below) to a
  transitional gap in the watermark fix itself, not a defect the verify below would have caught — which is
  exactly why a SEPARATE, unconditional check earns its place alongside it rather than superseding it.
  - **The verify.** `compact` fingerprints every LIVE (non-collectable) task's `(title, body, tags, short,
    state, priority, docrefs, arc-declared, arc-standing, its OWN needs/in edges)` — the same
    canonicalization `serializeState` persists, hashed to one `u64` per id (`taskFingerprint`) — BEFORE
    touching any file. After the snapshot+log rewrite, it reloads a FRESH `Store` from exactly what was just
    written (never trusting the in-memory `self` for the "after" side) and re-fingerprints. Any live id
    whose fingerprint changed, or that vanished entirely, is collected into `Store.diverged_on_verify`; the
    ORIGINAL snapshot/log bytes (captured before the rewrite) are restored byte-for-byte via the same
    atomic write-temp-then-rename `compact` already uses, and `compact` returns `error.CompactVerifyFailed`
    naming every diverged id — `trk compact`'s CLI wrapper prints them and points at `.tracker/backup/`.
    A `dropped`/`archived`/ghost id is never a key in either fingerprint map (`fingerprintLiveTasks` skips
    exactly what `isCollectable` does), so legitimate GC can never read as a divergence — only a live task
    compact was contracted to KEEP can trigger this.
  - **The backup.** Before the rewrite, `compact` also copies the pre-compact `snapshot.jsonl`/`log.jsonl`
    (whichever existed) into `.tracker/backup/<ms-epoch>/`, then evicts down to `config.backup_retain`
    (default 10; `compact.backup_retain` in `config.json`). This is orthogonal to the verify above — the
    verify's restore only fires ON a caught divergence; the backup exists so a human has a same-machine,
    no-git-archaeology recovery path even for a loss this mechanism does NOT catch (a bad merge whose
    corrupted state a *later* compact then faithfully re-persists, which is what actually happened to
    `01KZTV44M` — see below). Bounding the count does not by itself keep the directory out of `git
    status` — see the `.gitattributes`-adjacent `.gitignore` ruling above for why `backup/` also
    needed an ignore rule, not just a retention cap.
  - **Root cause of `01KZTV44M`'s loss, isolated (not merely narrowed) from the Enix tracker's own git
    history:** the correction (commit `eb677cb1`) landed on a worktree branched BEFORE a compact
    (`2155deea`) had already run on main; union-merging that stale branch back in later (the `adc8f879`
    merge, whose own message already read "log re-bloated by the pre-compact-base merge") resurrected the
    branch's entire pre-compact log tail for that task — including a run that ENDED one `setBody` short of
    the correction (an even-staler sibling worktree off the same base). A second compact (`83a37d85`, run
    at 21:22 on 2026-08-19) folded that resurrected log and wrote a fresh snapshot — using the trk binary
    from BEFORE `01M0EM3G6`'s watermark fix (which landed in THIS repo at `7977e9d`, 00:03 the following
    night), so the `add` event it wrote for that task carried no watermark. A LATER union-merge then
    resurrected the even-staler sibling's log tail again; because the snapshot's `add` had watermark `0`,
    `supersededBy`'s protection never engaged for this id (`t.watermark == 0` short-circuits to "never
    judged" — see the watermark bullet above), so the stale tail's `setBody` silently replayed last and
    reverted the body. This is a one-time transitional gap — a compact that ran with the OLD binary,
    upgraded mid-session, whose OWN output never got retroactively re-stamped — not a standing hole in the
    watermark mechanism itself: every compact from `d870f9d4` onward (the first run under the fixed binary,
    which re-stamped every task's watermark) closes it going forward. It is a DIFFERENT failure shape from
    what the verify above catches (that compact's fold was internally faithful to the corrupted state it was
    handed; nothing about ITS OWN rewrite was unfaithful), which is why root-causing this incident and
    building the verify are two separate deliverables, not one.
- **Short-id stability — frozen at mint time, never recomputed.** `Cli.shortId` originally computed "the
  shortest CURRENTLY-unambiguous prefix" fresh on every call, against the live id set — a pure function of
  that set, so it moved whenever the set moved. Measured in production: a `compact` GC'd the dropped/
  archived backlog, the id set shrank, and prefixes got SHORTER — `01KYJTYBT` silently became `01KYJTYB`.
  Every written reference (commits, task bodies, docs, the CHANGELOG, a human's own memory) went stale in
  one stroke; lookup still worked (any unique prefix resolves), but *recognition* broke. The fix: a task's
  short id is minted ONCE (`Cli.mintShortId`, floor `min_short_mint = 9` — chosen to match the dominant
  historical id length so a fresh mint less often needs extending) and persisted forever (`Task.short`, the
  `add` event's own `short` field) — never recomputed on add, archive, or compact. `compact`'s
  `serializeState` re-emits each live task's `add` event (the canonicalization step); it MUST carry
  `.short` through verbatim, because that re-emission is exactly where the original bug bit. Collision
  handling is one-sided: a new mint's candidate extends past an existing id's collision; an already-frozen
  short is never touched. A task with no frozen short (every task minted before this landed) falls back to
  the original dynamic computation at the original `min_short = 6` floor — intentionally left unstable and
  un-lengthened, since retroactively changing it would just move the staleness rather than fix it.
  `trk migrate-shorts` is the opt-in retrofit: freeze every un-frozen task at its CURRENT computed short (a
  `setShort` event). This is a **best-effort baseline, not a repair** of PRE-compact drift — a short already
  shortened by a PRIOR compact has no recorded prior value anywhere to restore. Idempotent (an already-long-
  enough short is skipped), safe to re-run blind.
  - **`--min <n>` is the one exception that deliberately lengthens.** Freezing bare `migrate-shorts` at each
    task's current computed length (floor 6) landed exactly the instability it was meant to end, just at a
    new low: the repo owner's most-referenced task froze at 8 chars, a freshly-minted one at the bare 6-char
    floor — both stable now, but neither matching the 9-char shape every existing written reference assumed.
    `--min <n>` freezes (or RE-freezes) every task at `max(its current short length, n)`, still collision-
    checked like any mint — the one place an already-frozen short is intentionally overwritten, because
    "stable but wrong length" isn't the goal; "stable and recognizable" is. Gated behind an explicit flag
    (never the default) because it changes ids a prior run already froze — a one-time, deliberate repair,
    not something to run routinely.
  - **Resolution has an exact tier ahead of prefix extension (01M2Y2JV5).** Freezing made the DISPLAY
    stable, but resolution still went through the prefix matcher alone: a 9-char short that later mints
    extended (`01M2VMXA3` beside `01M2VMXA3B`/`M`/`X`) became an ambiguous prefix, so the id trk printed for
    a task stopped resolving to it. That input genuinely is ambiguous under the prefix rule, which is why
    the fix is a tier, not a matcher tweak: `Cli.resolve` first looks for a task whose frozen short EQUALS
    the input (case-insensitive) and returns it outright; prefix extension is consulted only when none
    does. The same tier covers the tombstone index — an exact compacted short answers COMPACTED rather than
    resolving to a live task that happens to extend it, and `Store.lookupTombstone` checks exact first too.
    Two tasks that froze the same short (parallel mints in one millisecond) are never picked between; they
    fall through to the ambiguous listing.
- **Doc-id registry ownership — folds into the store as events.** A `setDocPath { doc_id, path }` event
  (not a separate file) — one append-log, one compaction story, the same merge-safety model as every other
  event (last-write-wins on fold; `Store.docPath` resolves). A doc move is one `trk doc set <doc_id>
  <new-path>`; every task's doc-ref stores the `doc_id` (not the path), so all refs survive. Render
  resolves `doc_id → path#section`, falling back to the raw `doc_id#section` when unregistered.
  `trk doc unset <doc_id>` tombstones a mapping via an empty-path `setDocPath` — the fold removes the
  entry (refs fall back to the raw `doc_id`), the snapshot never emits it, so `compact` GCs the
  tombstone; idempotent, and a later `set` revives it under the same last-write-wins fold.
- **An unrecognized log op is skip-and-warn by default, never fatal — with an explicit escape hatch for a
  genuinely unsafe future one (01KYT2QET, 2026-07-30).** `Store.load` used to hard-fail the instant it hit a
  line whose `op` wasn't in `model.Op` — a single line written by a NEWER binary broke `load` for EVERY
  not-yet-updated one, reads included, not just writes (measured: `trk unin`'s own rollout — see the `unin`
  entry above — made itself unusable on any checkout that hadn't picked up the new op, for hours, on a
  single-user machine; the next new op would have repeated it). Now `replayFile` catches exactly
  `error.UnknownOp` (never a genuinely malformed line — bad JSON or a KNOWN op missing a field stays fatal,
  scoped by the error variant, not a blanket catch), records it into `Store.skipped_unknown_ops` (same
  reporting shape as `self_wait_cycles` — plural, main.zig warns once per line, load still succeeds), and
  keeps folding every other line in the file.
  - **Why skip is the SAFE default for every op that exists today, not a blind guess:** every current op is
    monotonic in one direction — an old binary that misses an edge-ADD (`dep`/`in`/...) under-connects (a
    task reads more blocked than truth) and one that misses an edge-REMOVE (`undep`/`unin`) over-connects
    (an edge that should be gone lingers) — both directions can only make the old binary MORE conservative,
    never let it see something as falsely ready, satisfied, or done. That property is what makes "just
    ignore it" safe; it is NOT a property the reader can verify about an op it has never heard of.
  - **The escape hatch: `"breaking":true` in the op's own JSON envelope, decided by the WRITER, never
    inferred by the reader.** A future op whose skip would NOT stay in the safe direction (e.g. it revokes a
    prior satisfaction, or deletes a task outright rather than an edge — either could let a stale binary
    treat something as ready/done that truth says it isn't) sets this field in its own `encode()` case;
    `json_codec.peekUnknownOp` reads it back on the unknown-op fallback path ONLY (never on a line whose op
    IS recognized) and `replayFile` propagates the fatal error instead of skipping for that op specifically.
    Nothing is retrofit onto the 15 ops that exist today — the field is consulted, never written, until a
    future op's author needs it. This is the same "require the explicit call, don't infer it" shape as the
    arc-declaration ruling above — same root cause (the tracker inferring something it should have required
    stated), same fix shape, different surface.
  - *Rejected: a schema/version field on the log, checked at load.* Works, but couples every future addition
    to a single global version bump and forces an explicit compatibility matrix; a per-op flag is
    finer-grained (most future ops likely ARE safe to skip, so most additions need no version bump at all)
    and keeps the safety judgment next to the code that best knows it — the op's own definition.
  - *Rejected: status quo (hard-fail) + an explicit flag-day process.* Solves nothing for the single-user,
    continuously-updated case this incident actually was — the flag-day discipline is exactly the thing that
    was skipped under real work pressure, which is how the incident happened in the first place.

- **Every mutation names its direction; the destructive one is unspellable by accident** (2026-08-23, tasks
  `01M0QJ8K4`, `01M0QK1C4`, `01M0QKHWQ`). Three verbs escaped a rule the tool had already adopted four times
  (`--add-tag`/`--rm-tag`, `dep`/`undep`, `in`/`unin`, `doc set`/`doc unset`): a mutation with two directions
  must make the caller name the one it wants.
  - **`--body` REMOVED, replaced by `--replace-body` and `--append-body`.** It was the one flag that implied a
    direction, and it implied the destructive one. Six body losses over seven weeks traced to the same root
    cause: with no append verb, "add a note to this task" was a hand-built read-modify-write performed by the
    CALLER. That is the wrong place for it, and not merely inconvenient — **only trk can read its own body
    correctly.** The current body is the fold of `snapshot.jsonl` and `log.jsonl`'s `setBody` events, so a body
    last written before the newest `compact` lives in the snapshot and NOWHERE else; a helper scanning only the
    log sees an empty body and truncates the task. `--append-body` deletes the reconstruction step entirely.
  - *Removed, not deprecated,* and this is the load-bearing half. An honor-with-a-warning deprecation performs
    the replace anyway: the warning scrolls past in an agent's tool output and the body is gone regardless,
    preserving the exact failure mode for every existing caller. A hard parser error converts each wrong call
    site into a loud, one-time fix. Contrast the `--add-tag arc:<slug>` deprecation, which is correctly
    honor-with-warning *because its legacy behaviour is harmless* — the tag still lands, just via the old
    spelling. Honoring the old spelling IS the bug here; that is what makes the instrument different.
  - **The byte-identical-write warning is scoped to `--replace-body` only.** A replace that writes the same
    bytes "succeeded" while adding nothing (2026-08-21: a task read as investigated twice while holding one
    pass of content, because each pass silently overwrote the last). An append that happens to produce no
    change is a different and far less interesting event; warning there would be noise.
  - **`--rm-doc` pairs `--add-doc`.** A typo'd doc-ref was permanent short of hand-editing `.tracker/` — the
    one operation every consuming runbook forbids. The new `undocref` op mirrors `untag`'s fold shape (a plain
    list removal, no tombstone map) rather than `undep`/`unin`'s: a docref is a per-TASK attribute, and under
    the disjoint-writer rule two lanes never edit the same task, so only a single lane's own append order
    matters — which a union merge preserves within each side. An EDGE needs the tombstone map precisely because
    it can be authored from either endpoint and so genuinely can be raced. Matching is by `doc_id` alone, so one
    removal clears every section ref to that doc. *Audited while in there:* with this and the body split landed,
    no one-directional mutation remains (`setState` is bidirectional by construction, and a scalar like `title`
    has only one meaningful direction).
  - **`dep`/`undep` take `<needer> --needs <prereq>`.** Two bare positionals of the same type could be swapped,
    and the swap produced a VALID edge pointing the wrong way — wrong DAG, wrong ready frontier, no error. The
    asymmetry IS the mechanism: you cannot swap two things when only one is spellable positionally. *Rejected:
    both flagged* (`--needer`/`--prereq` — moves the confusion from position to vocabulary rather than removing
    it), and *an infix keyword* (`trk dep A needs B` — reads best, but is undiscoverable from `--help`
    conventions and inconsistent with trk's flag-based surface). The bare form hard-errors for the same reason
    `--body` does. This one is honestly POLISH, not a defect: `dep --help` already named the direction and `dep`
    already echoed the resulting sentence, which is probably WHY the repeated early reversals stopped — but
    documentation-as-the-only-guard is exactly what the other two entries are about.

- **`archive` refuses to bury a decision** (2026-08-23, task `01M0QK25Q`). A task body routinely accumulates
  more than the work: an open fork, a "your call", a FIX NOTE, an OPEN QUESTION. The work can be genuinely
  finished — the task is legitimately closeable — while the DECISION was never that task's scope. `archived` is
  a tombstone hidden from every view, so archiving graduates the decision out of sight along with the work (one
  measured loss, 2026-08-12, recovered only by accident). `archive` is the right place for the check and the
  only one: it already walks every body it is about to graduate, it is the only actor that sees the whole done
  queue at that moment, and it is the last actor that can act before the tombstone hides the text.
  - **It REFUSES without `--allow-buried-decisions`, rather than warning.** Same reasoning as the `--body`
    removal: a warning inside a bulk archive run scrolls past, and what it failed to stop is permanent. Markers
    default to `scott-decision`, `OPEN QUESTION`, `FIX NOTE`, `your call`, `TODO`, matched case-insensitively —
    a body written by a human or an agent will not match a configured casing reliably, so the guard must not
    depend on shouting. `--dry-run` reports the hits without refusing, because a preview buries nothing.
  - `archive.decision_markers` in `config.json` overrides the set. An explicitly EMPTY array disables the check
    and is deliberately distinct from an ABSENT key (which means "use the default set") — an opt-out has to be
    spellable, and it has to be different from saying nothing.
  - *Not a bug in the tombstone model.* `archived` hiding from every view is correct and deliberate; this is
    about what rides along with it. The mitigation it replaces was prose in two runbooks that fired only if the
    operator remembered — the same shape as the three-runbook `--body` workaround, which kept failing until the
    primitive changed.
  - **The `TODO` marker fired on a filename, not a word** (2026-08-27, task `01M12D4EV`). The scan was a raw
    case-insensitive substring match, so the letters `TODO` inside `docs/TODO.md` (a file every task discussing
    the render projection mentions in prose) tripped the guard — 6 of 9 hits in one real sweep, 0 of them a
    buried decision. A pure word-boundary check does not fix this: `/` and `.` are already non-word characters,
    so `TODO` in `docs/TODO.md` already sits on a word boundary. What actually distinguishes the two is
    path/filename SHAPE: `isFilenamePosition` (`cli.zig`) skips an occurrence immediately preceded by `/` (a
    path component) or immediately followed by `.<letter>` (a file extension) — a marker used AS a marker is
    never glued to a path separator, and a `.` after it ends a sentence (whitespace or EOL follows), never
    another letter. This can only ever SUPPRESS a filename-shaped occurrence; a line carrying both a filename
    mention and a genuine marker still refuses, because the scan keeps looking past the filename-shaped hit.
  - **A per-task escape, `--allow-buried-decisions-for <id>:<n>:<digest>`** (2026-08-27, task `01M12ZG5ER`; the
    count assertion added 2026-08-28 and promoted to a hit-SET assertion 2026-08-31, `01M13JXWN` — each an
    independent review of the shape before it). The filename fix does not touch the
    other false-positive shape: a task whose body DISCUSSES the guard's own marker vocabulary as its subject (a
    task ABOUT this very check, like `01M12D4EV` itself) has no filename-like syntax to key off — the markers sit
    in plain prose, with no reliable syntactic tell apart from a real one. Content heuristics for that shape were
    rejected: whatever pattern would catch "a body about markers" risks suppressing a real marker phrased
    similarly, which is exactly the failure the guard exists to prevent (the false-negative cost — permanent
    burial — dominates the false-positive cost — an extra flag). So the fix is procedural rather than semantic:
    `--allow-buried-decisions-for` exempts only the named task's hits, leaving every other hit in the same run
    fatal under `--refuse`. This removes the actual danger `--allow-buried-decisions` (whole-run override)
    creates — one false positive pressuring the operator into waving through the entire done queue, exactly when
    it is largest (a session-ender) — without weakening the guard for anything not explicitly named.
    **The exemption is per-TASK, not per-LINE** — a bare `--allow-buried-decisions-for <id>` (the first shape
    shipped) makes EVERY marker line in that task non-fatal forever, including one appended to the SAME task
    after the operator looked and exempted it: the exact scroll-past-and-bury failure the guard exists to
    prevent, reintroduced one level down. So the value names what the operator actually asserted by exempting
    the task — **the hit SET they read**, not merely how many lines it had: `<id>:<n>:<digest>`, where the digest
    is FNV-1a/32 over the matched lines in body order. The guard treats it as exempt only while BOTH still match.
    **A cardinality assertion is not the honest invariant** (`01M13JXWN`): a count-preserving edit — delete one
    prose-shaped mention of `TODO`, append a real `OPEN QUESTION: …` — leaves the count untouched while
    replacing the very thing that was reviewed, so the stale exemption still applies and the genuine fork is
    archived out of sight. That is the same scroll-past-and-bury failure, one level further down again. Counting
    more finely (marker-shaped vs prose-shaped sub-counts) only moves the seam, since a marker-shaped line
    swapped for another defeats that too; identity is the check that closes it, so identity is what is asserted.
    The count is kept alongside the digest purely for legibility — `15 → 16` is a diagnosis, a hash mismatch is
    only a verdict — and the two cannot disagree dangerously because both must match. The declaration is an
    assertion (the `enixedit` `count` convention), not a label, and it is never hand-computed: **the guard's own
    report prints the paste-ready `<id>:<n>:<digest>` under each unexempted task's hits**, so re-reading and
    re-declaring after a body change is one paste, which is the cost of keeping the escape's teeth. Reordering
    the hit lines without changing any of them also drops the exemption — a false positive, and the intended
    direction of the trade (a spurious refusal costs one re-look; a missed change is permanent). Reporting
    (not fatality) also labels each hit `marker-shaped` (colon-glued to content, e.g. `OPEN QUESTION: which
    way?`) or `prose-shaped` (a marker word merely discussed, e.g. a comma list) so a newly-added hit stands out
    among a batch of already-seen prose-shaped ones. The two escapes compose: `--allow-buried-decisions-for` only
    has teeth under `--refuse`/`--dry-run`; `--allow-buried-decisions` (bare) still overrides everything,
    unchanged.
  - **A bare id-shaped positional in `archive`'s arg list is a hard error**, because the parser takes exactly one
    value per flag: a second id typed after `--allow-buried-decisions-for` without repeating the flag exempts
    only the first and silently becomes a title/body/tag search term, narrowing the archive set with no error at
    all. **What counts as "id-shaped" is settled structurally, not by degree** (`01M13JXWS`): Crockford base32
    excludes only `I/L/O/U`, so an alphabet-plus-length test alone matches ordinary English words of 9+ letters
    — `statement`, `namespace`, `webserver`, `watermark`, `regressed`, `parameters`, `assessment`, `management`
    — and made `trk archive statement` a hard failure on archive's *only* search surface. A trk id is a ULID or
    a prefix of one, and a ULID's leading character encodes the top 5 bits of a 48-bit millisecond timestamp
    (`0` for every id mintable before roughly year 3084), so `looksIdShaped` requires a leading DIGIT: no English
    word passes, every real id does. With that gate the hard error stays proportionate and is kept. Demoting it
    — "treat an id-shaped token that resolves to no task as a search term" — was rejected: a mistyped id is the
    likeliest remaining case, and that rule turns it back into a silent zero-match archive run, which is the
    failure the error was added to close.
  - **A marker naming a LIVE task id is a CITATION, not a burial — silent, no exemption needed**
    (2026-09-18, task `01M29VWW9`, filed from the Enix consumer repo). Measured 2026-09-11: across two
    productive sessions the guard's dry-run went from 20 to 36 marker lines in the done queue, and a hand
    audit of the first batch found **19 of 20 were prose MENTIONS of a fork that lives at a DIFFERENT,
    still-open task** — "follow-ons filed: 01M296E8F (scott-decision)", a ruling quoted verbatim from
    elsewhere, "file a live scott-decision if it's genuinely still open." That is exactly the practice the
    tracker's own doctrine asks for — a good closing body NAMES its follow-ons — so the guard's population
    became "every well-written closing body" and its measured false-positive rate was 95%: an operator
    trained to override 19 times out of 20 is an operator who overrides the twentieth without reading it,
    which is the one case the guard exists for. The discriminator was already sitting in the text: a marker
    glued to a task id names where the fork is actually CARRIED, and archiving the closing task cannot lose
    a fork that lives somewhere else. So a hit line is scanned for Crockford-shaped id tokens (the same
    alphabet/length test `looksIdShaped` already uses for the CLI's own positional-arg guard), each resolved
    the way `resolve` does — case-insensitive prefix match against the live id set — but SILENTLY: no
    output, no error, and an unresolvable or ambiguous token simply doesn't count, falling through to the
    ordinary fatal-hit path unchanged. Two things stop this from becoming a loophole: a token resolving to
    the CLOSING task's own id doesn't count (citing yourself is not evidence the fork lives elsewhere), and
    neither does one resolving to a task already `state == .archived` (an already-hidden id cannot be
    trusted as a live carrier — that state is exactly what a real burial produces, so treating it as proof
    of safety would defeat the guard on its own output). A citation is stronger than an
    `--allow-buried-decisions-for` exemption, not merely another way to grant one: it is never reported at
    all, because archiving the citing task was never capable of burying anything. Both directions are
    asserted in `cli_test.zig`, each sabotage-proven (revert the citation check → the citation test fails;
    drop the archived-state check → the archived-citation-still-refuses test fails): a genuine unresolved
    fork — no id, or an id naming an archived/nonexistent task — still refuses exactly as before; a
    citation of a genuinely live id is silent and the run archives clean.

- **`trk rule <id> <text>` — record a ruling and remove the decision tag, atomically** (2026-09-18, task
  `01M298M9Z`, Enix). A `#scott-decision` tag marks a fork awaiting a call only the repo owner can make;
  `trk list --tag scott-decision` is the pre-dispatch sweep for "what is still waiting on him," and the
  value of that query is that it stays short. Once the call is made and appended to the body via `trk edit
  --append-body`, the tag survives — `edit` is generic and has no notion that the text it is appending
  settles the very fork the tag exists to flag — so a ruled question keeps reappearing in the one query
  whose entire point is to be trustworthy. Measured in the originating incident: three of one task's
  rulings (two appended 09-07, one 09-09) were on record and the tag was still there for a fourth session
  to trip over; eleven stale tags came off in one sweep once someone finally went looking.
  - **Chosen: a dedicated verb, not a lint on `edit`.** Three shapes were weighed. (1) A `trk rule` verb
    that performs the append and the untag as one call — this. (2) A lint (in `make lint` or similar) that
    fails on an open, tagged task whose body carries a "RULED" marker — cheap, but it is the SAME failure
    class one level down: a free-text marker convention an author can forget to write is exactly as
    forgettable as the tag it would be catching, and the task that proposed it named its own weakness
    ("the phrasings differ, so the matcher needs care"). (3) Splitting the decision from its carrier task
    at ruling time (close the decision task outright, let a separate task carry the resulting work) — this
    does not by itself remove anything: `01M29P00C`, the concrete case that motivated this entry, was
    `state: done` and STILL carried `#scott-decision` when this was built, proving that closing (or even
    archiving) a task is not what strips the tag; (3) just moves WHERE the same forgettable step would need
    to happen, not whether it does.
  - **What "atomic" means here, precisely.** Not a filesystem transaction — `trk`'s append-log has no
    multi-event transactions, and `rule` writes a `setBody` then an `untag` as two ordinary log lines, same
    as `edit --append-body --rm-tag <t>` would. What's atomic is the CALLER'S action: `rule`'s own code
    always performs both, so there is no way to invoke it and get only the append — unlike `edit`, which
    has no opinion on whether a given body edit was a ruling and so never prompts for the untag. This is
    the same "verb-shaped correctness" trk already uses elsewhere (`release` exists so nobody hand-crafts
    an untag+lease-clear; `state submitted` exists so nobody hand-picks between `done` and `open`).
  - **Still depends on an author reaching for `rule`.** It does not make forgetting IMPOSSIBLE: an author
    can still run `trk edit --append-body "RULED: ..."` and never touch the tag, exactly as before. What
    changes is the SIZE of the thing that must be remembered — one correctly-named verb instead of two
    generic flags used together, every time — and that a task cannot end up half-ruled by the verb whose
    whole job is recording a ruling. This is an ergonomic/discoverability fix, not a hard guarantee; a lint
    layered on top (option 2, not built here) would close the residual gap for callers who still reach for
    `edit`, at the cost re-introducing the free-text-marker fragility named above. Left for later if the
    residual gap proves to matter in practice.
  - **Refuses on a task not currently tagged** (the configured tag; default `#scott-decision`) — the
    discriminator between "settle this fork" and "add a note," and the guard against `rule` silently
    closing out a genuinely open question it was pointed at by mistake (the shape of Enix's `01M12CKRK`: a
    live, still-undecided fork that must never be untagged by a tool that doesn't know it's still open). The
    check is structural, not textual: it reads the task's actual `tags`, not the body, so it cannot be
    fooled by prose that merely mentions the tag word.
  - **Does not close the task.** A ruling sometimes leaves the task alive as the carrier for the ruled work
    (rename/re-scope it); sometimes the work is done too. Which is a separate, judgment call — `rule` only
    removes the ONE thing that is never a judgment call once the ruling exists: the tag that says "still
    waiting."
  - **Composes with, rather than duplicates, the buried-decision guard above.** The two sit at opposite
    ends of a ruled task's lifecycle and neither can see what the other catches: the guard fires at
    `archive` time and scans body TEXT for marker words in tasks about to be hidden forever; `rule` fires
    while a task is still OPEN and clears a TAG field. A task `rule` untags but that stays open as a
    carrier never reaches `archive` at all under this ruling, so the guard never sees it — which is exactly
    the gap this verb exists to close (nothing at archive time can catch a decision stuck open-but-answered,
    because archive only ever looks at the done queue). Conversely the guard's own default marker set
    still lists `scott-decision` as a body-text substring, unrelated to `rule`'s tag check, so a task whose
    BODY still discusses an unresolved fork in prose is caught there regardless of what `rule` did to any
    tag.
  - **`rule.tag` in `config.json`, default `default_decision_tag` ("scott-decision")** — configurable for
    the same reason `archive.decision_markers` is: `trk` has no opinion on what a repo calls its "needs a
    human call" tag, and Enix's choice of literal string is a convention, not something the tool should
    hardcode. The two knobs (`rule.tag`, `archive.decision_markers`) are independent even though their
    defaults share a literal value.
  - Sabotage-proven in `cli_test.zig`: drop the `untag` append → the tests asserting the tag is gone fail
    (`expected 0, found 1`, and a tag-still-present `expect`); drop the not-tagged refusal → the tests
    asserting `error.UsageError` on an untagged task fail (`expected error.UsageError, found
    error.TestUnexpectedSuccess`) while the unrelated tests (arg-count validation) stay green either way.
