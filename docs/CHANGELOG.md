# Changelog — what's been built

The record of completed work in this repo. `trk archive` appends each graduated batch at the end
under a `## YYYY-MM-DD` run heading (config `archive.out` — unset today, so a real run still emits
to stdout; this file is hand-started because a landing needed recording before that config existed).
Forward-looking work is `docs/TODO.md` (generated); design rationale lives in `docs/design.md`.

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
