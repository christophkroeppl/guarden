# 269: the override reader refuses a quoted number a track row accepts

**Blocked by:** nothing — on the frontier, and it needs a decision rather than a dependency.

**What to build:** a rule, or a wider reader. `overrides.toml`'s `[retention] free_limit` is read by
`overrides._float`, which raises on any value that is not an `int` or a `float` — so
`free_limit = "0.08"`, the spelling `docs/sysadmin.md` used to show, is refused by
`weedr service ingest` at the moment the service is created. A `[[environments]]` row's
`free_limit` is read by `config.float_value`, which accepts the quoted form because the shipped
template writes `"0.20"` on two of its three rows. One admin-facing file accepts two spellings of a
number and the other accepts one, and nothing states why.

The asymmetry is undocumented rather than documented-wrong: spec §3.3 shows the
override unquoted **by example** and states no rule. Spec §3.1 was worse than silent — its comment
claimed the table held "a TOML float, not a string" while its own staging and preview rows, twelve
lines below, wrote `free_limit = "0.20"`; the review of `0d23f92` found the self-contradiction and
this branch made the comment spelling-neutral, but that leaves the rule itself unstated, which is
this ticket's question.

Whichever way it goes, the two readers have to agree: either both accept a number however it is
written, or both refuse the quoted form and §3.1 and §3.3 say so by rule rather than by example.

## What would settle it

Either `overrides._float` accepts a numeric string the way `config.float_value` does — one spelling
rule across both readers, a number is a number however it is written — or it keeps refusing and
spec 3.1 and 3.3 state the unquoted form by rule. That is a call about the admin surface, not a
defect the suites can feel: no suite drives a quoted override today, and the refused form only ever
cost an operator an error message at ingest time.

Found by the review of `c5f74b5`, which asked for the follow-up the commit message had claimed and
the tree did not hold.
