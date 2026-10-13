# Connectivity: one loopback, host entries, no shared network

Rootless podman networks are per-user. A `myapp-production` container cannot join a
`postgres-production` container's network, and no amount of configuration changes that; a
shared network would require giving up rootless multi-user podman. So services share nothing
but the host's loopback.

A service publishes on host `127.0.0.1` and nowhere else. A consumer reaches a publication
through pasta's host-loopback alias, which `loom` writes into the consumer's own units as
`AddHost=<provider>:<alias>` for each declared edge. There is no name map and no `/etc/hosts`:
the name a consumer resolves is the provider's service name, with no suffix and no alias.

**The edge is a consumer and gets nothing special.** A routed service is reached by the edge
like any other service, by the same `AddHost=` entry in the edge's own units, and by the same
uid-matched accept rule. The only asymmetry in the whole design is that the edge is
`traefik-production` and everything else is a project. One declaration — an entry in the
manifest's `needs` — produces three
things: the name the consumer resolves, the port it dials, and the credential it
authenticates with. There is no DNS daemon, no discovery protocol, no per-group address
space, and no second name to keep in sync.

Two facts about the platform set the whole shape of this. A rootless container cannot join
another user's podman network, so a shared network is not available at any privilege level
that keeps the services rootless. And a container's `127.0.0.1` is its own loopback: pasta
exposes the host's loopback at exactly one alias, so a per-group address scheme would be
unreachable from the consumer side and could not be tested even on a real machine. Everything
below follows from those two.

Isolation between services is therefore two layers plus one limit, and it is worth being exact
about which is which:

- **A service that did not declare the edge cannot connect.** For each declared edge, the
  firewall gets an `OUTPUT` accept rule matching the consuming service's uid and the
  dependency's port, plus a drop for every other uid. The rules come from the dependency
  graph, so their number is the number of edges, not the square of the number of services.
  The word doing the work is *connect*: the rule is matched on the uid of the connecting
  process.
- **A service cannot be stopped from binding.** Nothing polices what a service listens on. A
  service that binds a port it was never granted is caught by none of these rules, and two
  compromised services can talk over any port they both choose. Bindings are cooperative, and
  the only place they are policed is install time, where the port allocator refuses the second
  publication of a port that is already taken.
- **The credentials are per consumer.** Each database edge gets its own role and its own
  minted password, planted as a podman secret in the consumer's store. A consumer that gets
  hold of another consumer's secret gains nothing it was not already given.

The address a consumer *dials* is the host-loopback alias as the machine actually has it, and
the address the *host firewall* matches on is `127.0.0.1`. Those are two different addresses and
conflating them produces a rule set that matches nothing. Pasta maps the container's default
gateway onto the host's loopback in userspace, so by the time the connection reaches the kernel
it is already `127.0.0.1`; the alias exists only in the `AddHost=` line. Ticket 15 exists to
measure the alias before anything is built on it, and the measurement also confirms that the
connection arrives with the consuming uid as the socket owner, which is the only host-side
control that can see it. The measured value is recorded in `guarden.toml` as `ingress.alias` — a
normative key of the `[ingress]` table, empty until the measurement, and written by
`soil install` from the probe it runs rather than left to the operator. The edge does not start
without it. Because the alias comes from the host's default route and pasta recomputes it per
container, `soil sysctl --check` reports drift when the recorded value no longer matches the
route, since a stale alias silently points every rendered `AddHost=` at an address that no
longer means this host.

> **Amended 2026-10-13 (ADR-0018):** the alias this paragraph describes is no longer measured,
> and the probe that was to measure it is deleted — `soil install` is root, podman 5.7 refuses
> `--network pasta:` as root, and the probe image is external to this repository. `ingress.alias`
> is now a constant derived from the pinned `[network] pasta_options` (`-g 10.0.2.2`), and the
> drift re-check is deleted because a constant cannot drift. Everything else in this document
> stands.

One consequence is a hard constraint rather than a design choice: **all services share one
port namespace**, so two services cannot both publish 5432. `weedr` refuses the second one and
says which service holds the publication. On a single-operator box with one database, one cache
and one web server, that is the correct trade against a per-service address scheme that does not
work. One shared namespace policed by uid-matched rules is a deliberate concession, not a claim of
isolation by namespace: what a service cannot do is connect to an edge it did not declare.

Sharing one namespace is also what makes the edge work. A port listed under `ports:` is a
request for a door from outside the host: it needs an administrator's grant, and the grant
becomes an address translation from that public port to the service's own loopback publication.
A port listed under `routes:` is an internal hop from the edge to a container, it is never a
door, it needs no grant, and it is given an allocated publication out of the same namespace as
everything else. That is what lets several instances of one preview service coexist: the
branches do not contend for a port, they are each handed one, and the edge is pointed at the
instance it meant. ADR-0006 covers the two kinds separately, because they are governed by
different rules.

The drop set is **all of loopback for every service uid**, not only the published ports — a
default deny on `-d 127.0.0.0/8` with the per-publication accepts above it. The earlier
version policed each publication and left the rest alone, on the stated grounds that a blanket
drop "would break name resolution and package updates inside their containers". The package-
update half was wrong — package updates are outbound. **The name-resolution half was right, for
the wrong layer**: pasta excludes DNS from the *loopback mapping*, which is a claim about a
container's own packets, and `podman pull` is on the host as the service user, through
`OUTPUT`. That claim was corrected and answered by ADR-0015, which renders one accept for the
host's stub resolver above the deny. The edge's uid is
deliberately permitted, by uid, to reach every allocated route publication,
because reaching the container is the edge's entire job. A compromised edge can therefore reach
anything routed to it, and the blast radius of that compromise is the routed surface.

Every rule is IPv4. `soil` disables IPv6, so there is no `[::1]` form of any of these
addresses to forget and no second address family in the rule set. An operator who re-enables
IPv6 is outside this design and outside what the golden VM proved.

The other consequence is that **the edge is the way HTTP and HTTPS are published, not the only
way a service is reachable.** A bitcoin node's peer port, a WireGuard endpoint, a database
somebody else connects to: none of them is a web request, and routing them through a reverse
proxy would be nonsense. What makes them reachable is the same mechanism the edge uses — a
granted port, translated by the kernel to a loopback publication, with nothing beyond the
`route_localnet` the `DNAT` needs — a translated packet is delivered locally and never
traverses `POSTROUTING`, and conntrack unwinds the translation on the reply, so no masquerade
is involved — with one difference in who may
reach the publication: for a granted port the allowed set is the service itself, its declared
consumers and the admin, not the edge. No service ever binds a non-loopback address, so there is
no private-versus-public grant to get wrong and no second mechanism beside this one. The
repository still cannot make a grant; the administrator still can.

**The loopback is closed by default, and the publications are the only way in.** The earlier
version policed each publication and left everything else alone, which meant
that because pasta maps the gateway, any container could open a connection to any host loopback
port — `sshd` on 22 included. The rendered set is a default deny on `-d 127.0.0.0/8` for
every service uid, with the accept rules above it. The stated objection was that a blanket drop
would break name resolution and package updates. Package updates are outbound and are untouched.
**The name-resolution half was right and was measured to be so**: pasta excludes DNS from the
loopback mapping, which is a claim about a container's own packets, and `podman pull` runs on
the **host** as the service user through `OUTPUT`, where the deny is. ADR-0015 answers it with
one owner-matched accept for `127.0.0.53:53` above the deny, and nothing else on loopback. The
objection was believed partly because the runbook claimed the live ruleset was not
inspectable. It is — ferm compiles to iptables, and `iptables-save -t nat` is how you check.

The golden VM proves the isolation claim the only way it can be proven: from a service that
did not declare the edge, the connection fails; from one that did, it succeeds.
