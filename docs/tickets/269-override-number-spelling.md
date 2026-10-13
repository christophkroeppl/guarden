# 269 — the override reader refuses a quoted number a track row accepts

**Status:** open, recorded by the review of `c5f74b5`.

`overrides.toml`'s `[retention] free_limit` is read by `overrides._float`, which raises on any value
that is not an `int` or a `float` — so `free_limit = "0.08"`, the spelling `docs/sysadmin.md` used
to show, is refused by `weedr service ingest` at the moment the service is created. A
`[[environments]]` row's `free_limit` is read by `config.float_value`, which accepts the quoted form
because the shipped template writes `"0.20"` on two of its three rows. One admin-facing file
accepts two spellings of a number and the other accepts one, and nothing states why.

## What would settle it

Either `overrides._float` accepts a numeric string the way `config.float_value` does — one spelling
rule across both readers, a number is a number however it is written — or it keeps refusing and
spec 3.1 and 3.3 state the override spelling is unquoted, by rule. That is a call about the admin
surface, not a defect the suites can feel: no suite drives a quoted override today, and the refused
form only ever cost an operator an error message at ingest time.

Found by the review of `c5f74b5`, which asked for the follow-up the commit message had claimed and
the tree did not hold. The sysadmin example is unquoted now; the question is this ticket's.
