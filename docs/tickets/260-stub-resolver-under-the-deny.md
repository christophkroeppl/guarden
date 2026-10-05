# 260: the loopback deny refuses the stub resolver, so no service can pull an image

**Blocked by:** nothing. **Blocks:** `t50-slice`, and every first deploy of a workload
whose image is not already in the service user's store.

**What to build:** A decision, recorded as an ADR, and then whichever answer it
carries. The question is narrow and it is measured.

## Measured

`tests/t50-slice.sh` renders the firewall with a real service and reads
`guarden-svc`'s own counters across one UDP send from a service uid to
`127.0.0.53:53`:

```
DENY_COUNTER_BEFORE=0
DENY_COUNTER_AFTER=1
```

`guarden-svc` has `-A guarden-svc -d 127.0.0.0/8 -j DROP`, and the counter moves.
**The deny is what refuses systemd-resolved's stub listener.**

## Why this is bigger than the spec's claim

spec 7.7 argues the deny "does not touch name resolution" because **pasta** excludes
its DNS forward from the loopback mapping. That is true of traffic from *inside* a
container. This is the **host**: `podman pull` runs as the service user, the packet
leaves through `OUTPUT`, `OUTPUT` jumps to `guarden-svc`, and the deny is on
`127.0.0.0/8`. So the resolver is unreachable from every service uid and **no first
deploy of a new workload can complete.**

## The options, and what each costs

**A. Let the stub through, narrowly.** One accept rule above the deny, for
`daddr 127.0.0.53 udp dport 53` and `tcp dport 53`, owner-matched to service uids.
It is narrow, it is not a `[loopback] allow` table, and it is exactly what the deny's
own docstring already claims pasta handles. It also grants a service uid the ability
to speak to the stub resolver and nothing else on loopback.

**B. Publish the resolver on a non-loopback address and point the services at it.**
More machinery, and it changes name resolution for every service.

**C. Pull images as root into a shared store, and let containers read it.** Changes
where images live and who owns them, and reintroduces a shared root-owned artefact
the per-service-user design deliberately avoids.

**D. Concede that a service cannot pull, and require every image to be placed.**
That is not guarden.

**A is the recommendation** and it is the smallest change that is also correct. It
does not widen what a service reaches on loopback beyond the resolver, which is the
one thing on loopback it is supposed to reach.

## This is a security decision and needs an ADR

The deny is a load-bearing guardrail and ADR-0013 removed `[loopback] allow` on the
grounds that "a table whose whole content is a destination is a second way to grant
one beside the publication set". **An accept rule for the resolver must not become
that table.** It is one rendered rule at a known position, like every other
publication accept, and the ADR should say why the resolver is not a grant surface.

## A second, separate finding

`/usr/sbin/iptables` on the golden is **iptables-nft**, while guarden's rules are in
**iptables-legacy** — `update-alternatives` reports `iptables-nft`, and
`iptables -S guarden-svc` answers *"No chain/target/match by that name"* because the
chain is in the other table. `ferm` invokes `iptables` by name, so whichever the
alternatives system says at the time is the table that gets written.

**A host whose alternatives point at nft would have guarden's rules written to legacy
tables while every tool an operator reaches for reads nft** — the firewall would
appear absent while the traffic it was written to stop still flows. Which table
guarden converges should be stated by guarden rather than inherited from
`update-alternatives`. This is independent of the resolver and belongs in its own
ticket.

## Suites

- **`tests/t50-slice.sh`** — the counter measurement already lands here, and it fails
  today because the container cannot pull. It goes green when this lands.
- A refusal suite: a service cannot bind or dial `127.0.0.53` itself, and the
  resolver accept is owner-matched, so no other uid's traffic uses it.
