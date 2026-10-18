# 285 — a container cannot reach a sibling container in its own compose file

Found 2026-10-14, verifying the adversarial review's claim against a rendered unit.
**This is the blocker in front of the odoo-btc-bcr deployment, not the database
count.**

## What is measured

A two-service compose where one names the other by service name:

```yaml
services:
  api:
    image: docker.io/library/alpine:3.20
    command: ["sh","-c","sleep 300"]
  worker:
    image: docker.io/library/alpine:3.20
    command: ["sh","-c","sleep 300"]
    environment:
      API_URL: http://api:3000
```

renders the worker's unit as:

```
[Container]
Environment=API_URL=http://api:3000
Image=docker.io/library/alpine:3.20
ContainerName=sibtest-staging-worker
Network=pasta:--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2
```

**There is no `AddHost=api:...`.** The name `api` resolves to nothing, so the
worker cannot reach its sibling. The `api` unit does get a `PublishPort`, but on the
*host* loopback (`127.0.0.1:20005`), which is not the worker's network namespace —
`pasta` gives each container its own.

## Why

`AddHost` is a **guarden-owned key** (`render.OWNED_KEYS`, and it appears in
`GUARDEN_OWNED_ORDER`): the renderer writes it and a repository cannot. The only
thing that produces an `AddHost=` line is an **edge** — `AddHost=<provider>:10.0.2.2`
— so the sole way one container can name another is for the target to be a
**provider service** with a `needs:` edge. Two containers in one compose file are
siblings, not provider and consumer, and nothing maps one sibling's name to an
address the other can dial.

So intra-compose connectivity is **not expressible**, and the reason is not an
oversight in the converter: the design has exactly one inter-container mechanism,
and it is the edge, which is cross-service by construction.

## Why this is the real blocker for odoo-btc-bcr

That stack's topology is almost entirely intra-compose:

- `nbxplorer` → `bitcoind` (RPC at `http://bitcoind:8332`)
- `btcpay` → `bitcoind` (RPC), → `nbxplorer` (`http://nbxplorer:32838`), → `db`
- `odoo` → `db`, and to the addons it binds
- `nbxplorer-seed` → `bitcoind`

Every one of those is a sibling reference. Under guarden the only kinds an edge can
carry are `db` and `secret`, so there is no `bitcoin-rpc` or `nbxplorer` kind to
declare, and even if there were, an edge is between *services* — it cannot express
"the bitcoind container inside this same service". The stack would have to be split
into one service per dependency (bitcoind a provider, nbxplorer a consumer that is
also a provider, btcpay a consumer of both), which is a real architecture and a
large piece of work, not a manifest edit.

The database-count question (ticket 284) is the **third** thing that breaks here,
not the first. The order is: (1) `build:`/`extends:`/`profiles:` refuse the whole
file; (2) a 20-service internal topology has no way to connect at all; (3) a
consumer can have one database and this needs three.

## What this ticket wants

A decision, recorded:

- **Intra-compose connectivity is out of scope by design** — then say so in the
  spec, and a repository with a multi-container topology knows it must be split
  into provider/consumer services before it can be deployed. That is a legitimate
  answer and it is cheap to state.
- **A sibling `AddHost`** — the renderer could emit `AddHost=<sibling>:10.0.2.2`
  for every container in the same compose that publishes a port, which would make
  the topology work the way Compose does. This weakens the "each container is its
  own namespace" story and needs its own reasoning about name collisions, but it is
  the smaller change and it would unblock this stack.

Either way the current state is the worst of the three: the compose file converts,
the units render, and the service silently cannot reach the thing it names.

## Decision — 2026-10-18, option (a)

**Intra-compose connectivity is out of scope by design, and the refusal is what
makes it visible.** The spec's whole of name resolution is
`AddHost=<service>:<ingress.alias>` for a declared edge (§7.3), the names are
service names with no suffix and no alias, and there is no name map to put a
container in — so a compose service name that is not a declared edge has no
rendered entry, and `loom` now refuses the file that names one instead of
rendering units in which the name is dead.

The sibling `AddHost` this ticket sketches as option (b) was rejected on the
mechanism, not on taste: from inside a container the alias is the **host's**
loopback, where each container answers on its allocated publication (§7.4) and
never on the container port the compose value dials — `AddHost=api:10.0.2.2`
resolves `api` and `http://api:3000` then reaches a port nothing binds.
Delivering Compose's semantics needs a port-translating name map, which §7.3
forbids, so (b) would have traded one silent failure for another.

The refusal is one line, exit `2`, naming the container, the sibling, the key
and the value, and it ends with the answer: split the target into a service of
its own and name it under `needs:`. The rule is stated in spec §7.3; the
implementation is `compose.check_siblings`, reached by `loom check` and
`loom render` before the converter runs; the suite is `tests/t400-sibling.sh`.
