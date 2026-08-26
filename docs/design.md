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
- **`claimed`** — a CLAIM, not a verdict: "the commit I'm riding completes this task, pending verification."
  Weaker than `done` in both directions on purpose — does **not** satisfy a prereq (`satisfiesPrereq` is
  false: a dependent waits for the real, verified `done`) and is **not** `next`-eligible (a claim is not
  available work; surfacing it there would let a second writer redo already-claimed work). It **does** count
  as remaining for `render`'s TODO.md projection, with its own marker (`[c]`, distinct from open `[ ]`) — an
  explicit, scannable "awaiting verification" queue (`trk list --state claimed`). See "Settled rulings" below
  for the motivating case.

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
model rests on git attributes — `log.jsonl` union-merged, `snapshot.jsonl` and `quarantine.jsonl` left on the
default text driver — and nothing wrote them, so every repo re-derived them by hand or (measured across six
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

**The check is narrow on purpose.** `compact` warns (stderr) when a pin is missing, because it is the verb
that *creates* the two files that must never be union-merged. It cannot verify what is actually in effect:
trk is std-only and never shells out to git (`discover.zig` reads `.git` as a plain file for exactly this
reason), and attributes resolve through parent directories, `.git/info/attributes` and `core.attributesFile`
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

**The render/archive destination is persisted, not re-specified per call** (`.tracker/config.json`, added
2026-07-10). Where `trk render` writes was previously a mandatory `--out docs/TODO.md` on every invocation —
a ritual that also invited "forgot where it renders" drift. An optional `config.json` (`{"render":{"out":…},
"archive":{"out":…}}`) persists it, with precedence **explicit `--out` > config value > stdout**. The stdout
fallback is load-bearing: a repo with no config behaves *exactly* as before, so the feature is purely
additive (no migration, no forced adoption). Config load is **best-effort and never fatal** — a malformed
file warns to stderr and falls back to defaults rather than blocking a mutating command, because the tracker
must never be un-writable due to a cosmetic config typo. `render` still truncate-overwrites its target (the
projection is regenerated by design); config changes only *where*, never the clobber semantics.

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
The per-verb text lives in one `verb_help` table with a test asserting an entry per dispatched verb, so the
contract can't rot as verbs are added.

**`--not-tag <t>` (repeatable, ANDed) on `next`/`list` derives a query set as a complement, not a
positive filter — deliberately.** A consumer of `next` (a metal-vs-host axis, e.g.) often wants "everything
EXCEPT what's blocked", not "everything tagged X". A positive membership tag (`auto`, say) makes an untagged
task ambiguous — not-eligible, or simply not-yet-triaged? — so the query can never answer "is the eligible
bucket actually empty" with confidence, and a missed triage silently reads as ineligible. Blocker tags
(negative, applied only where a real blocker exists) make absence mean eligible: the safe default, and the
residual triage cost (a task that IS blocked but not yet tagged so) stays visible rather than silently
hidden. `--not-tag metal --not-tag scott-testing --not-tag scott-decision` is then one bare command for the
autonomous-eligible bucket — no `--json` + external filtering required.

**`trk stale` cross-references git history against tracker state — read-only, best-effort, LANDED commits
only.** The motivating case: an implementing commit routinely NAMES the task id it completes, and nobody
runs `trk state done` — the evidence was sitting in `git log` the whole time. `trk stale` runs `git log
--oneline` (no flags beyond that) with cwd set to the STORE ROOT (`Cli.dir`, resolved by `discover.findRoot`
— the repo housing `.tracker/`, which the tool itself may not live in), tokenizes the output once (maximal
alphanumeric runs), and looks each token up against an index of every OPEN task's full id + displayed short
id (exact-token match, not substring — a short id can never accidentally match as part of an unrelated
longer token). `claimed` tasks are excluded: a claim already IS the self-reported signal this verb exists to
surface for a task that never got one.

**Deliberately `git log`, never `git log --all`.** `--all` walks every ref, including a parallel fan-out's
unmerged worktree branches — a commit hit there is not proof the work is at HEAD (measured in the field: a
reconciliation pass mis-marked tasks BUILT this way before catching itself with `git merge-base
--is-ancestor`). `trk stale` wants only LANDED evidence, so it scopes to the current branch's ancestry by
construction rather than asking the caller to filter `--all`'s output after the fact.

## Storage, merges, and auth

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
    `01KZTV44M` — see below).
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
