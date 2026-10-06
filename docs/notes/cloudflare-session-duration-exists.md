# An Access policy *does* carry a duration — `session_duration`

**Not an ADR.** This note records a measured correction to a claim that `docs/tickets/220-tunnel-module.md`
and `docs/adr/0015-pinned-artefacts.md` both rest on. The design decision is unchanged; the
justification for it is.

## The claim, as the ticket states it

Ticket 220, in "The grant: temporary, revocable, and guarden's to answer for":

> **Expiry is enforced by that reconciler on a root-owned timer, not by the vendor.** An
> Access policy has **no expiration field at all** — the policies API schema carries no
> `expir*` key, and the only durable-duration primitive is a *service token*, which is
> machine-to-machine and not a browser login.

ADR-0015 repeats the conclusion: expiry is enforced by guarden's reconciler "and not by
the vendor".

## What is actually true

Read from the Access policies API reference
(`developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/policies/`)
and confirmed independently by reading the rendered page:

- The **first half is right.** There is no `expir*` field anywhere in the schema: zero hits
  for `expir`, `expires`, `expires_at`, `expiration`, `ttl`, `valid_until`, `not_after`.
- **The second half is wrong.** A policy response object carries a top-level
  `session_duration`, described as *"The amount of time that tokens issued for the
  application will be valid"*. It is a durable-duration primitive that applies to a
  **browser login**, which is exactly the thing the claim said did not exist. A separate
  `mfa_config.session_duration` bounds an MFA session specifically.

So "the only durable-duration primitive is a service token" is false, and the sentence
"a stopped timer means the grant outlives its deadline" is misleading: if guarden's timer
stops, the email stays in the policy, but a live session still ends when
`session_duration` expires — though the user can re-authenticate while the email remains.

## What this changes, and what it does not

**Unchanged:** the record of who may reach what is guarden's, the vendor's policy is a
**projection** of it, and the **issuance deadline** is guarden's absolute value. A
session duration bounds one authenticated session; it does not express "this grant ends on
2026-11-01", and it cannot remove an address from the policy. Removing the email is still
the act that ends a grant, and it is still guarden's.

**Changed:** the ticket must stop asserting that no vendor duration exists, and must
decide what `session_duration` is — a **second, shorter bound** under guarden's deadline,
or left at the vendor's default. Either is defensible; silence is not, because a reader
who checks the schema finds the field and stops trusting the paragraph.

## Open, and cheap to settle in the VM

Whether `session_duration` is **settable through the API** or only through the dashboard.
The field appears in all four policy response objects but is absent from the `Policy`
model definition on the same page — a discrepancy in the vendor's own reference, not a
conclusion. A create/update call with the field, or a `curl` against the API with a real
token, settles it. That is an operator step against a real account, like the rest of
ticket 220's live criterion.

## Source

Vendor API reference for Access policies, and the session-management documentation. The
claim above was re-measured against the rendered API page rather than taken from a
summary; the hit counts are in this note's git history if they need re-deriving.
