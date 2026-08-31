# Changelog — what's been built

The record of completed work in this repo. `trk archive` appends each graduated batch at the end
under a `## YYYY-MM-DD` run heading (config `archive.out` — unset today, so a real run still emits
to stdout; this file is hand-started because a landing needed recording before that config existed).
Forward-looking work is `docs/TODO.md` (generated); design rationale lives in `docs/design.md`.

## 2026-08-31

**The decision-guard escape's count assertion was defeated by a count-PRESERVING body edit
(01M13JXWN): delete one prose-shaped mention of `TODO`, append a real `OPEN QUESTION: …`, and the
count stays 15 — so the stale exemption still applies and the genuine fork is archived and buried.
Fixed by asserting the hit SET's identity rather than its size: the value is now
`--allow-buried-decisions-for <id>:<n>:<digest>`, where `digest` is FNV-1a/32 over the matched lines
in body order, and the exemption applies only while both still match.** A count answers "did the
number of hits change?"; what the operator asserted by exempting a task is "I read THESE lines and
none is a live fork", and those are different claims — which is why counting more finely
(marker-shaped vs prose-shaped sub-counts, the cheaper option the task also floated) was rejected: it
only moves the seam, since a marker-shaped line swapped for another defeats it too. The count is kept
alongside the digest for legibility (`15 → 16` is a diagnosis; a hash mismatch is only a verdict) and
the two cannot disagree dangerously, since both must match. **The digest is never hand-computed: the
guard's report now prints the paste-ready `<id>:<n>:<digest>` under each unexempted task's hits**, so
re-declaring after a body change is one paste — strictly less work than the old shape, which made the
operator count marker lines by hand. The pre-existing `<id>:<n>` syntax is a hard error rather than a
quiet downgrade to the weaker guarantee, and a swap at the same count reports itself by name ("same
hit COUNT, different hit CONTENT") so it does not read as a miscount.

**`looksIdShaped` hard-errored on ordinary English search words (01M13JXWS).** Crockford base32
excludes only `I/L/O/U`, so an alphabet-plus-length test matches `statement`, `namespace`,
`webserver`, `watermark`, `regressed`, `parameters`, `assessment`, `management` — every one of them
failed `trk archive <word>` on archive's only search surface. A ULID's leading character encodes the
top 5 bits of a 48-bit millisecond timestamp, so every mintable id starts with a digit and no English
word does: `looksIdShaped` now requires a leading digit. The hard error itself is kept and stays the
right response once the input is unambiguous; demoting an unresolvable id-shaped token to a search
term was rejected, because a mistyped id is the likeliest remaining case and that rule returns it to a
silent zero-match run.

Host-unit tests `zig build test`: **220 → 224**. Four new cases in `cli_test.zig` — the
count-preserving swap (both directions: the reviewed set still archives, the swapped set refuses and
the task stays `done`), the paste-ready-value round trip (refuse → capture the printed token → paste
it back → archives), the eight English words as search terms, and an id-shaped word that still
FILTERS while a real id in the same slot still hard-errors. Several existing cases were rewritten to
the new value shape via an `allowFor(alloc, short_id, hits)` helper that states the expected hit lines
LITERALLY rather than scraping them from the guard's own output, so a change in what the guard matches
fails the test instead of silently re-agreeing with it. Both fixes were sabotage-proved: reverting the
predicate to `count_matches` alone reds exactly the count-preserving test (223/224 — the swapped fork
archived); removing the leading-digit gate reds exactly the two word tests (222/224).

## 2026-08-28

**The per-task decision-guard escape (01M12ZG5ER) reintroduced the exact scroll-past failure it
existed to prevent — a bare `--allow-buried-decisions-for <id>` exempted every marker line a task
would EVER carry, including one appended after the operator looked and exempted it. Fixed: the
exemption now names its expected hit count, `--allow-buried-decisions-for <id>:<n>`, and
`reportBuriedDecisions` refuses to apply it unless the task's actual hit count still equals `n` — a
new marker line changes the count, the exemption stops applying, and every one of that task's hits
reverts to fatal.** The count is an assertion, not a label, matching this project's own
`enixedit`-style convention elsewhere in the Enix corpus (count is checked, not merely present). The
content-heuristic rejection from 1ae3cbc/eed4c74 stands — a marker discussed in prose has no
reliable syntactic tell distinct from a genuine one, and the false-negative cost (permanent burial) is
far worse than the false-positive cost (an extra `:n` to re-declare) — but the reporting now labels
each hit `marker-shaped` (colon-glued to content, e.g. `OPEN QUESTION: which way?`) vs `prose-shaped`
(a marker word merely discussed, e.g. a comma list), so a genuinely new hit stands out among a batch
of already-seen prose-shaped ones instead of blending in. Two smaller defects fixed alongside: the
`--dry-run` summary claimed "a real run would still refuse the remaining 0" when every hit was
exempted (guard was `fatal < hits`, true even at `fatal == 0`) — now says a real run would archive
anyway; and the synopsis rendered `--allow-buried-decisions-for <id> ...` as if a second bare id
extended the same flag, when the parser silently folded it into the title/body/tag search filter
instead (exempting only the first id and narrowing the archive set to a search term that almost
always matches nothing, with no error) — a bare id-shaped positional in `archive`'s arg list is now a
hard error naming the fix (repeat the flag), and the synopsis now renders the repeat-the-flag form.
`cli.zig`'s docstring previously asserted a per-task escape "has no false-negative risk of its own" —
false, and now corrected: the count assertion is *what* removes that risk, not the per-task
granularity alone. 8 new host-unit tests in `cli_test.zig` (`zig build test`: 220/220 pass), covering
both directions of the count assertion (accepts the declared count, refuses a changed one — asserted
on the `State` transition, not on output text), the finding-6 wording fix, the finding-7 hard error,
and the marker-shaped/prose-shaped reporting label. Verified against the real eeepc corpus
(`trk archive --dry-run`): `01M12D4EV` carries exactly 15 marker-shaped-and-prose-shaped hits as
measured in eed4c74, `--allow-buried-decisions-for 01M12D4EV:15` exempts it and 17 hits across
`01KXHHJQH`/`01M0VP7J3`/`01M0WJQPB`/`01M123V16`/others still refuse the run; `:14` (a stale count)
makes the exemption not apply and all 32 hits refuse.
