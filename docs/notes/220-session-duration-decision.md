# Ticket 220: what `session_duration` is, and why it is a constant

`docs/notes/cloudflare-session-duration-exists.md` settles the measurement: an Access
policy response **does** carry a top-level `session_duration`, it bounds one browser
login, and the create-policy body accepts it (`"300ms"` or `"2h45m"`, Go duration
syntax). The note leaves one decision to the implementation: a **second, shorter bound
under guarden's deadline**, or the vendor's default.

**Decided: guarden sets it, to the root-owned maximum grant duration — `[share] max`,
which ships as `"168h"`.**

## Why not the vendor default

The failure this ticket exists to bound is a stopped reconciler: if the timer that
removes an expired email stops, the email stays in the policy and the grant outlives
its deadline. The note is right that a live session still ends when `session_duration`
expires, so setting it explicitly is a real second bound where the vendor's default is
an unknown one. Leaving it at the default is defensible and would have been the honest
answer, but it makes the bound somebody else's number and it is not the one the ticket
is about.

## Why a constant and not `min(deadline) - now`

The stronger-sounding choice is per-policy: `session_duration` = the time remaining
until the earliest live deadline, capped at the vendor's own `720h` maximum. It is
**rejected on idempotency**, which the ticket requires in the same breath as the
projection:

- A deadline-derived value is a function of the clock, so it changes on every run. A
  reconciler whose desired state changes while its inputs do not is not idempotent:
  "a second run makes no calls" — the property `weedr pin sync` has and this ticket
  says this verb has — would be false, and every reconcile would write the vendor.
- Worse, it would rewrite the policy of a hostname whose emails had not changed,
  which is the churn the add-before-remove rule exists to avoid.

A constant is the only form that keeps the projection a pure function of the record.
The bound it gives is "no session outlives the longest grant guarden will issue",
which is weaker than per-grant but is still a bound guarden chose and can state, and
the act that ends a grant is still the reconciler removing the email.

## The shape it takes

`session_duration` on the projected policy is `go_duration(seconds([share] max))` —
`168h` for the shipped maximum. The conversion is not cosmetic: guarden's own duration
syntax accepts `d` and Cloudflare's Go syntax does not, so a `max = "7d"` written in
`guarden.toml` becomes `168h` in the request body.

## What is still open, and it is an operator step

Whether the field is settable **through the API** or only through the dashboard was the
note's own open question, and the create-policy body's `session_duration` parameter
answers it on paper but cannot be exercised without a real account. It is part of
ticket 220's live acceptance step, with the rest of the vendor path.
