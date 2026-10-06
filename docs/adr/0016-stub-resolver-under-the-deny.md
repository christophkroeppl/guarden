# the loopback deny carries one accept for the host's stub resolver

Accepted 2026-10-05. Ticket 260. Amends spec §7.6 and §7.7, and corrects a claim
that those sections, `SECURITY.md` §2.6, ADR-0004, `AGENTS.md` and
`docs/tickets/80-edges.md` all repeated. **It does not reopen ADR-0013** — see
"Why this is not the `[loopback] allow` table" below, which is the whole of what
this document has to settle.

## What was measured

The deny is `-A guarden-svc -d 127.0.0.0/8 -j DROP`, `OUTPUT` jumps to
`guarden-svc`, and a service uid's one UDP datagram to `127.0.0.53:53` moves the
deny's own packet counter:

```
DENY_COUNTER_BEFORE=0
DENY_COUNTER_AFTER=1
```

`127.0.0.53` is systemd-resolved's stub listener. **The deny refuses it**, so
`podman pull` as a service user cannot resolve the registry and no first deploy
of a new workload can complete. Not "a hostname does not resolve" — the pull
cannot complete at all, because the resolver is unreachable from every service
uid on the box.

## The claim that was wrong

Spec §7.6 said the deny "does not touch name resolution", arguing from pasta(1):
traffic identified as DNS, directed at the `--map-host-loopback` address, "is
not translated to loopback, but rather handled in the same way as if specified as
`--dns-forward`".

**That is true of traffic from inside a container, and false of the host.**
Pasta's exclusion is about the hop a container's own DNS packet takes. `podman
pull` is not inside a container: it runs on the host as the service user, its
packet leaves through `OUTPUT`, `OUTPUT` jumps to `guarden-svc`, and the deny is
on `127.0.0.0/8` — which contains the resolver. The sentence was correct as
written about the case it described and wrong as a claim about the host, and it
survived because nobody read `iptables -S`.

The outbound half of the same sentence was and remains true: a package update, a
git fetch and a call to the outside world leave on the real interface and never
meet a `127.0.0.0/8` destination.

## The decision

The rendered `OUTPUT` set carries **one accept above the default deny, per
service uid and per protocol, for `127.0.0.53` port 53** — `udp` and `tcp`,
because systemd-resolved's stub listens on both:

```
mod owner uid-owner <service-uid> daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;
mod owner uid-owner <service-uid> daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;
```

Four things about it are load-bearing, and each is one thing it deliberately is
not:

- **It is one of the accepts, not an exception to the deny.** It is rendered by
  the same code that renders the publication accepts, into the same chain, in
  the same list. There is no special case in the deny and no second pass over
  the file: the deny is the last line of the chain and nothing is ever written
  after it.
- **It is owner-matched to service uids, exactly like a publication accept.** A
  uid that is not a service user gets no use of it, and no path — manifest,
  `overrides.toml`, module, poke — can widen the uid set.
- **It names the one address, not the network.** `127.0.0.53`, never
  `127.0.0.0/8`, which is the thing being denied. `127.0.0.53` on port 54, on
  port 22, or on any other port is still refused by the same deny, and the
  assertion is measured on a real machine rather than read off the render.
- **It is rendered from guarden's own knowledge of the host's resolver, not
  from configuration.** There is no key that adds one, no key that removes one,
  and no address an operator may substitute. The alternative designs are
  refused here rather than deferred: publishing the resolver on a
  non-loopback address is more machinery and changes name resolution for every
  service; pulling images as root into a shared store moves where images live
  and who owns them; requiring every image to be placed by hand is not guarden.

## Why this is not the `[loopback] allow` table

ADR-0013 removed `[loopback] allow` — a table whose entire content is a
destination — because "a key whose whole content is 'this destination' is a
second way to grant a destination beside the publication set, and two ways to
grant one thing are two ways for it to be wrong". **That decision is right and
this document does not undo it.** The distinction is not "one rule is narrower
than a table"; it is **who decides what is in the set**:

| | `[loopback] allow` (removed) | this accept |
|---|---|---|
| who chooses the destination | an operator, by configuration | nobody — guarden derives the one it needs from what the host already runs |
| how many destinations | any number, added at will | exactly one, fixed |
| how many ports and protocols | whatever the entry names | `53`, `udp` and `tcp`, fixed |
| which uids | whatever the entry names | every service uid, and nothing else |
| where it lands | wherever the grant's position put it | with guarden's own accepts, above the deny, always |
| how to add another | add a key | change this file and the code, reviewed as a decision |

The shape that matters is the last row. A grant surface is a surface somebody
can *use*; this is a rendered rule somebody would have to *write a patch to
add*. A repository cannot ask for it, an `overrides.toml` cannot hold it, and
`weedr firewall open` cannot install it — the closed request shape in
`src/guarden/rules.py` describes repository input and this rule is not
repository input. So it is not a second way to grant a destination: it is the
absence of a way, filled once for the one destination guarden already depends on
being able to reach.

## What it costs, stated here rather than discovered

**A service uid can speak DNS to the host's resolver.** That is the whole of it.
The resolver is the host's own `systemd-resolved`, not another service's
publication; the rule opens no publication, no other loopback port, and no
`127.0.0.53` port other than 53. A service that can resolve a name could always
resolve names through its own container's network path; what this adds is the
host path `podman pull` takes, and that is what makes a deploy possible.

**A uid that is not a service user is still refused, and that is deliberate
rather than an oversight.** The deny names no uid — that is what makes it a
default deny (spec §7.6) — so `root`, `guarden` and `hose` are refused
`127.0.0.53` exactly as they are refused every publication unless an accept
names them. Images are pulled as the service user, so the path this opens is the
one guarden uses; if a verb running as `root` ever needs the stub on the host's
loopback, it needs an accept naming that uid and that is a separate decision
rather than something this rule quietly does.

**The measurement that motivated this was a host-path fact, not a container
one, and the distinction is the thing a future reader has to keep.** Pasta
excludes DNS from the *loopback mapping*; that says nothing about a packet a
host process sends to `127.0.0.53`. The first correction to this document's
predecessors was made for exactly that reason and has to be made again by anyone
who reads the deny and concludes that name resolution cannot be affected.

## What did not happen

No grant surface, no `[loopback] allow` table, no key, no flag and no
configuration. No widening past `127.0.0.53:53`. No uid other than a service
uid. No second firewall engine, no `ufw` rule, no change to the publications, no
change to the deny itself — which is still `daddr 127.0.0.0/8 jump DROP`, still
carries no owner match, and is still the last rule of the chain.