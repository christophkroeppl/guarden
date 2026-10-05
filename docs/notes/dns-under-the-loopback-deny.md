# Does a service uid reach the stub resolver under the loopback deny?

**Status: open, and now reproduced with the render fixed. Measured twice, same
message. Do not "fix" this by loosening the deny without a decision.**

**Update 2026-10-05 (ticket 240 landed, `caa414d`→`13a76a9`).** The probe below that
"created no service, so `30-services.conf` did not exist" is no longer needed to see
this: `t50-slice.sh` creates `routed-staging`, `weedr service ingest` writes the
firewall, and `weedr service start` then fails with the message above. The generated
`ExecStart` is correct and the generator is reached — see
`ticket-250-is-not-a-generator-problem.md` — so **the loopback deny is now the
measured and only remaining blocker between that suite and green.**

## What is measured

`podman run` as a service user exits 125. The podman message is a DNS failure:

    pinging container registry registry-1.docker.io: dial tcp:
    lookup registry-1.docker.io on 127.0.0.53:53: write udp
    127.0.0.1:38904->127.0.0.53:53: write: operation not permitted

`write: operation not permitted` on a UDP send is the kernel refusing it, and
127.0.0.53 is systemd-resolved's stub listener on loopback. spec 7.6 (lines
2078-2086) argues the loopback deny "does not touch name resolution" because
**pasta** excludes its DNS forward from the loopback mapping. That argument is
about traffic from inside a container. This is the HOST: podman's pull runs as
the service user, and the packet goes out through `OUTPUT`, which jumps to
`guarden-svc`, whose deny is `daddr 127.0.0.0/8 jump DROP;`.

## MEASURED: the deny is the cause

`tests/t50-slice.sh` renders the firewall with a real service and reads
`guarden-svc`'s own packet counters across one UDP send from the service uid to
`127.0.0.53:53`:

```
DENY_COUNTER_BEFORE=0
DENY_COUNTER_AFTER=1
```

**`guarden-svc` drops it.** The rule is `-A guarden-svc -d 127.0.0.0/8 -j DROP`,
and the counter on it moves when a service uid sends one packet to systemd-resolved's
stub listener. So the first branch above is the true one and it has a consequence
larger than the spec's claim:

**No service can pull an image**, so every first deploy of a new workload fails. Not
"a hostname does not resolve" — the pull cannot complete, because the resolver is
unreachable from every service uid.

## A host fact that had to be established first

The measurement was misleading until this was accounted for: `/usr/sbin/iptables` on
this golden is **iptables-nft**, while guarden's rules are in **iptables-legacy** —
`update-alternatives --query iptables` reports `Value: /usr/sbin/iptables-nft`, and
`iptables -S guarden-svc` answers *"No chain/target/match by that name"* because the
chain is in the other table.

`ferm` invokes `iptables` by name, so whichever the alternatives system names when it
runs is the table that gets written, and on this host that was legacy. Reading
through `iptables` therefore looks for a chain that is not there, and an earlier
probe read that as "no rules exist at all".

**This is worth its own attention.** A host whose alternatives point at nft would
have guarden's rules written to legacy tables while every tool an operator reaches
for reads nft — the firewall would appear absent while the packets it was written to
drop still flow. Which table guarden converges should be stated rather than
inherited from whatever `update-alternatives` happens to say.

## Why this matters either way

- If the deny blocks it, then **no service can ever pull an image**, and every
  first deploy of a new workload fails. That is a much larger claim than the one
  the spec makes, and it is wrong as written.
- If it does not block it, this is a golden-VM artefact — the suite's resolver is
  the stub and the guest's network is incomplete — and the fix belongs in the
  harness, not in the firewall.

**What would settle it:** render the firewall with at least one service, then
`sudo iptables -S guarden-svc` and read its packet counters while a service uid
sends one UDP packet to 127.0.0.53. If the counter moves, the deny is the cause.

## The decision, when it is made

There is no `[loopback] allow` table, and there must not be one: a table whose
whole content is a destination is a second way to grant a destination beside the
publication set (spec 7.6). If DNS turns out to be blocked, the answer is not a
new table — it is either the stub resolver being moved off loopback, or pasta's
exclusion being extended to the host path the pull takes. Both are design
decisions and belong in an ADR.
