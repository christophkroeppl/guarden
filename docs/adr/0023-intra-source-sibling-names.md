# ADR-0023 — an intra-source sibling name resolves, and it is a port-translating name map

Status: accepted. Supersedes nothing; narrows spec 7.3 and the refusal of
ticket 285.

## The question

Ticket 316 asked for a decision: may a name declared **inside one unit source**
— another container key of the same Compose file, or another `.container` file of
the same `.guarden/quadlet/` directory — resolve to that sibling?

The refusal of ticket 285 said no, and named the reason: the alias is the host's
loopback, where each container answers on its allocated **publication** and never
on the container port the value dials, so `http://api:3000` would reach a port
nothing binds. Making it work "would need a port-translating name map, which is
the mechanism this design does not have".

The refusal was correct about the mechanism and wrong about the conclusion. The
mechanism is available: guarden already writes a name map of exactly this shape
for **edges** — `AddHost=<provider>:<alias>` — and the only thing an edge's name
map lacks is the port. A name map that translates a name to an address *and* a
port is the same mechanism with one more field, and every field of it is
already owned by guarden:

- the **name** is a container key of the unit source — the repository's, but
  scoped to one source, so it never leaves it;
- the **address** is `ingress.alias`, the pinned gateway;
- the **port** is the container's own port, which the unit source already
  declares.

## The decision

**A sibling name inside one unit source resolves.** The renderer writes, into
every unit of that source:

```
AddHost=<sibling>:<alias>
```

and the environment the sibling's port is reachable on is the sibling's own
**publication** — the loopback port guarden allocated for that container — not
the container port the value dials. A value written `http://api:3000` therefore
cannot reach the sibling: the port in the value is the container's port, and
nothing binds it on the host.

So the sibling name resolves as a **name**, and the **port** in the value is the
one thing that has to change. That is what the environment file is for: the
renderer writes `<SIBLING>_HOST` and `<SIBLING>_PORT` into the same
`guarden.env` the edges use, and the repository's entrypoint assembles the URL
from them — exactly the shape klimafit's own `deploy/guarden-entrypoint.sh`
already does for `DB_HOST`/`DB_PORT`.

**The value the repository writes is not rewritten.** Guarden does not
second-guess a port in a repository's URL; it writes the facts and the
repository composes. A repository that writes `http://api:3000` and reads
`API_HOST`/`API_PORT` gets the name and the publication; a repository that
hard-codes the container port dials a port nothing binds, and that is a fact
about the repository, visible in its own source.

### Why the port is the publication and not the container port

The host binds each container's **publication** — `PublishPort=127.0.0.1:<pub>:<container-port>` —
and the container's own port is what pasta forwards to it. From inside another
container, the only address that reaches the host is the alias, and the alias
reaches the host's loopback, where the container answers on the publication.
A publication is allocated per container (spec 7.4), so a sibling's publication
is exactly one number per sibling container, and it is stable across
regenerations because it is in the registry.

**This is the same mechanism an edge uses, and the same asymmetry.** An edge
provider's publication is the provider's own allocation, copied into the
consumer's edge record; a sibling's publication is the sibling container's own
allocation, in the same service's record. One writer, one place.

### What it costs, stated plainly

- **A sibling container now gets a publication it did not have.** The
  allocator (§7.4) allocates one for every container named in a `routes:` or
  `ports:` entry. A sibling that is only ever dialled gets one too, so the
  loopback namespace holds a number for it. This is the same namespace the
  edge's own API and every granted port already live in, and the range is
  `ingress.publication_range` — a host that runs out of publications runs out
  of them for edges too.
- **A sibling's publication is reachable by the service's own uid** — which is
  the point, and is not a widening: the containers of one service are one
  service's own uid, and they already share the service's home, its volumes and
  its credentials. The firewall's accept set (§7.6) grants a publication to
  `record.uid` by default, so nothing new is granted; a sibling is inside the
  boundary that already exists.
- **The name is scoped to the source.** A sibling name is never a service name
  and never appears in another service's units. The collision that matters —
  two sources each naming a container `api` — cannot happen, because each
  source's units are its own.

### What is refused

- **A name from another source.** A value naming a container that is not in
  this unit source is still refused, with 285's line. The refusal now names
  the difference: a name inside the source resolves, and a name outside it
  resolves to nothing.
- **`extra_hosts` and a repository's own `AddHost=`.** The key is the
  renderer's (spec 6.3), and the renderer writes the sibling names itself. A
  repository writing `AddHost=api:10.0.0.1` is still refused: it would
  overwrite the renderer's own entry, and the address it names is not one
  guarden owns.
- **A self-reference.** A container naming itself is refused.

### The manifest's half

The sibling's **port** has to reach the repository's value, and the repository
writes its value as a URL with a port in it. So the manifest has to say which
port a container serves, because the unit source does not declare it in a
place guarden reads:

```yaml
siblings:
  - container: api
    port: 3000
```

This is a new top-level manifest key, and it is the only one. It names a
container of **this** service — the same vocabulary `routes:` and `ports:` use
— and the port is the container's own port. The renderer turns it into a
publication and writes `<CONTAINER>_HOST`/`<CONTAINER>_PORT` into the
environment file, next to the edges' variables.

**The port in the manifest is the container's port, and the port in the
environment file is the publication.** The two are different numbers, and the
translation is guarden's. A repository that wants to dial `api` reads
`API_HOST`/`API_PORT` and gets the publication; it does not write the
container's port into its own URL and hope.

### Why not the other two answers

- **Refuse, and name a real migration** (the ticket's "if no" branch). A real
  migration does not exist: **one repository produces exactly one service.**
  The service name is `<project>-<track>` (`hose._target`), the manifest has no
  `services:` table, and a poke stages one tree for one service. The migration
  the refusal names — "split `api` into a service of its own and name it under
  `needs:`" — is **not reachable from one repository**: the second service would
  need a second project, a second poke key and a second repository. A refusal
  whose remedy does not exist is the worst of the three states ticket 285 named.
- **Give the containers a shared network.** The spec forbids it (§7.1, and
  AGENTS.md: "Do not add a shared podman network"), and it would be a much
  larger change: a shared network is a boundary change, not a name map.

## What this costs the operator

Nothing is granted. A sibling name is not a grant, a publication is not a
grant, and the firewall's accept set is unchanged: the sibling's uid is the
service's own uid, which the accept set already carries for every publication
that service holds. The grant surface is exactly what it was — an operator's
`overrides.toml`.

## The rustfs provider

Ticket 316's secondary item: `rustfs-production` is a provider of the `secret`
kind, and no template for it exists. It is added as `src/guarden/templates/
services/rustfs/`, in the same shape as the two shipped templates, and it
carries the `provides: secret` declaration the provider's registry needs —
which, for a template-created service, means the operator writes the manifest
the template does not ship (a template ships quadlet files and no manifest,
spec 4), exactly as the postgres provider does.
