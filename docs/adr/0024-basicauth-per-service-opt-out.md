# The basic-auth opt-out: a per-service setting in `overrides.toml`

Ticket 318. Ticket 292 put a per-service basic-auth credential in front of every
new service that declares `routes:`, and refused every way of turning it off —
by design: "a manifest can never disable auth". What it left out is the operator's
own case. A machine-to-machine endpoint, a webhook target, a service the edge
never serves at all: no repository may ask for that, and no root-owned surface
could say so either. The flag was on and the only act that could take it off did
not exist.

This ADR records where the act lives and what it does. It is a spec decision
first, because a new table or a new key is a contract change and inventing one
in code is the mistake this repository keeps refusing.

## Status

accepted (2026-10-21) — the ticket's own decision, taken with the spec amendments
below. The implementation is ticket 318.

## The decision

**`overrides.toml` gains a `[basicauth]` table, and it is the only new surface.**

```toml
[basicauth]
required = false  # the default basic-auth middleware is not attached to this
  # service's edge routers. Absent is the default: the middleware is on.
```

The act is `weedr basicauth off <name>` and `weedr basicauth on <name>`, both
root-side and **on no sudoers rule** — the same place `weedr expose set` and
`weedr port open` sit, because a verb that widens authority is a verb and never
a flag.

## Why `overrides.toml` and not somewhere else

The three candidates were the registry, `guarden.toml`, and `overrides.toml`.

**Not the registry.** ADR-0021 drew this line and drew it about exactly this
kind of table: *"It is not in the manifest, and it is not in the registry. The
registry is the mutator's record of what IS; an override is what the admin
granted. Putting the grant in the registry would make a projection a grant,
which is the confusion ticket 291 was about."* The registry's own field is
`basicauth = true` — the record that the credential **was minted** at creation,
a fact about the past. The opt-out is a decision about the present, and a
decision that moves (an operator turns it off, then on again) is not a fact
about a mint that happened once. Putting a moving decision beside a fact is how
the two start disagreeing.

**Not `guarden.toml`.** That file decides the host's policy — the environment
set, the module set, the ingress, the weights. A per-service setting there is a
table of services in a file that has none, and a second place to set it is a
second place for it to be wrong.

**`overrides.toml`.** It is the root-owned per-service file, and it already
holds settings that are not grants: `[retention]` overrides the track's
defaults and is not a widening of anything. The spec's own sentence — *"Nothing
else is overridable"* — is what makes the file auditable: an operator reads one
file and knows every way the host has been widened beyond the repository's
request. This is such a widening, so it belongs there and the sentence is
amended to name it, exactly as ADR-0021 amended it for `[ownership]`.

## The load-bearing consequences

**The middleware is decided where the edge's own file is written, and not at
creation.** The registry's `basicauth` is the mint, and the slice carries it
unchanged; what the operator decided travels `overrides.toml -> roots -> the
edge's file provider`, and `roots` asks the file every time it syncs. So the
opt-out takes effect on the **next `roots sync`** — the act writes the setting
and syncs in the same breath, and a later sync reaches the same answer from the
same two files, so the two can never disagree — and the act says so rather than
leaving the operator to guess.

**A repository cannot reach it.** The manifest's key set is closed (§4), and a
`basicauth:` key in a manifest is refused **by name**, with a message naming
where the decision *is* recorded — the same shape `exposure:` gets. This is
load-bearing in both directions: the repository cannot remove the middleware,
and it cannot add it either.

**The credential is not destroyed, and the flag is not the credential's
existence.** Turning the middleware off does not un-mint the credential and does
not delete the htpasswd entry: the blob and the entry stay, and turning the
middleware back on re-attaches the same login. The reason is that the mint is a
**fact** (spec 3.4: "whether the default edge login was minted at creation") and
the opt-out is a **setting**. Un-minting would destroy a credential the operator
may still hold, on the strength of a setting they can reverse with one command.
The htpasswd entry is a login nobody can reach while the middleware is off, and
that is harmless; a deleted credential is not recoverable.

**A grandfathered service is unaffected.** A service created before the policy
was in force carries no `basicauth` flag in its registry and no middleware. The
opt-out is not performed on it, because there is nothing to turn off: the act
would report a change it did not make. It says so, and exits 0 — the state is
already the requested one.

**A service with no routes is unaffected**, for the same reason: it was never
minted anything.

## What it is NOT

- **It is not a manifest key.** §4's closed key sets are what make the default
  trustworthy, and a key that removes the middleware would put it back in the
  repository's hands.
- **It is not a per-route or per-label setting.** One service, one posture. A
  service with one public route and three private ones is not expressible here,
  and the ticket does not pretend otherwise: the same gap ticket 294 reports for
  per-port exposure is reported here, rather than solved by a second table.
- **It is not a way to remove the credential.** See above: the flag is the
  middleware's presence, not the login's existence.
- **It is not on the guarden sudoers rule.** A poke may deploy and may not
  re-posture the fleet. The same list that keeps `weedr port open` and
  `weedr expose set` away from a push keeps this away.
