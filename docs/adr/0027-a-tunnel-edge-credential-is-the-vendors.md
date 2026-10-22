# A tunnel edge's credential is the vendor's, so the edge plants nothing

Ticket 307f made a `needs:` entry able to name a service on **another host** (`via:
tunnel`, spec §4 and §7.3). `edges._credential` had one rule for every `auth: secret`
edge: mint a value and plant it. For a local edge that rule is right — the same value
goes into the provider's own store, and the provider verifies what the consumer
presents. A tunnel edge has no provider store here and no local verifier: its
credential is a Cloudflare Access service token, issued by the vendor, and guarden
cannot mint one that authenticates.

The plant still happened, because `_credential` does not distinguish the two. What it
left was worse than nothing: a value in the consumer's store that **satisfies the
gate** and authenticates nowhere. On a gated track the gate counted it as present and
recorded `ready`, the container started, and the producer's route answered `401` —
the false green §6.6 exists to prevent, reached through the one door §6.6 does not
police. `docs/notes/tunnel-edge-manual-check.md` told the operator to replace the
placeholder with `weedr secret set`; honest, but after the gate had already said yes.

## Status

accepted (2026-10-22) — implemented on `fix/t307f-tunnel-credential`. The test is
`tests/t457-tunnel-edge-host.sh`.

## The decision

**A tunnel edge plants nothing.** The key stays a credential *request* —
`Secret=<AS>_SECRET` in the consumer's unit — with no value behind it, and
`weedr secret set` is the only way a value arrives. That is the state §6.6 already has
an answer for: a request nobody satisfies blocks a gated track and refuses a start on
either track, in words that name the key and the command that plants it.

Three options were open (plant nothing; keep the placeholder and mark it as minted;
keep it and document the consequence). **Planting nothing is the decision**, for the
reason §6.6 already states about a gated track's schema keys: *a generated value would
hide exactly the condition this exists to catch*. A vendor-issued token is the same
condition with a vendor in the issuer's place, and the other two options keep the lie
and describe it:

- **A minted marker is the same refusal with a lie kept.** The gate cannot distinguish
  the value by looking at it, so the store would have to carry a new field saying
  guarden wrote this one — and until every reader honours that field, `weedr secret
  list` reports a set credential the operator never set. Nothing is bought that
  planting nothing does not buy, and the store grows a second meaning for "set".
- **Documenting it leaves the false green in place.** The gate saying `ready` about
  presence is true of every value an operator plants; it is not true of a value nobody
  can use, and writing down that guarden fabricates one is a spec sentence about a
  defect rather than a description of the design.

## What the operator meets, on each track

- **A gated track: the gate holds.** The deploy stops at the gate, exits `0`, and
  `[gate] reason` names the missing key. `weedr service gate` and `weedr service start`
  exit `1`, name the key, and name the command that plants it:
  `` `weedr secret set <name> API_SECRET` plants it, and this verb re-checks ``.
  After the plant the same verb answers `ready` — presence, which is now the operator's
  and not guarden's fabrication.
- **An ungated track: nothing is minted there either, and the start refuses.** §5.3
  step 9 mints a `@sensitive` schema key on an ungated track so a service can run
  without ceremony, because that value only has to be *internal* to the service. An
  edge's token is presented to somebody else's server, so a generated one is not a
  convenience, it is a container that starts and cannot talk. The start refuses in the
  words tickets 305 and 313 established — the key, and the command that plants it —
  and the deploy reaches that refusal and fails there, rather than starting a container
  that will 401.
- **`restart` asks the gate before it stops anything**, and gives the same two
  refusals. A restart is a stop and a start, and the start half is the one podman
  would answer `125 no such secret` for; asking first is also what keeps a blocked
  gate from taking a running container down on its way to saying no (spec §6.6).

## What it costs, stated

- **An edge a previous guarden planted keeps its placeholder.** The secret store
  carries no record of *who* wrote a value, so the alternative to leaving it is
  deleting a value the operator may have planted themselves. The change is
  forward-only: a new edge mints nothing, and an existing one is fixed by the act the
  manual note already prescribes — `weedr secret set` with the vendor's token. Until
  then a gated consumer's gate reports `ready` about a value that cannot authenticate,
  which is exactly the residual this ADR cannot remove without the marker it rejects.
- **An ungated tunnel consumer's first deploy fails at the start.** It failed before
  too — at runtime, with the vendor's `401`, in the container's log. The failure is now
  at the start, names the key, and names the command; it is earlier and legible rather
  than late and mute.

## What this is NOT

- **It is not a second credential and not a vendor-side act.** Guarden still does not
  create the Access policy; `weedr share` is the operator's instrument for that, and
  the producer's half of the edge is the route's policy (ADR-0024, "a tunnel route's
  credential lives Cloudflare-side").
- **It is not a change to a local `secret` edge.** A pasta edge still mints one value
  and plants it in both stores, because there the provider verifies what the consumer
  presents — a minted value that works.
- **It is not a gate change.** The gate's subject is still the set of requests the
  units make; what changed is that guarden no longer fabricates presence for a request
  only the vendor can satisfy.
