# Services: one word, one user, one slot

Everything guarden deploys is a **service**: a workload in one environment, named
`<workload>-<environment>`, owning exactly one Linux user, one home, one unit directory, and
whatever state it declares. A database is a service. The reverse proxy is a service. There is
no second class of thing.

One class of thing means one set of rules. A system that distinguishes a workload from a
shared database by a prefix on its name enforces nothing, because a prefix is a string: every
distinction has to be checked twice, and a check that is only in one code path is not a rule. A
service that talks to another service says so once, in its manifest, and gets an `AddHost=`
entry in its own units, a firewall rule and a credential for exactly that edge.

Consequences, all of them intended:

- A self-contained service that runs its own database is a service with a state volume, not a
  special case. Nothing about it is privileged.
- The edge is `traefik-production`, an ordinary service with no capability and no privileged
  port. `soil firewall` translates 80/tcp, 443/tcp and 443/udp onto its published loopback
  ports, so the kernel owns the public ports and the edge binds only loopback ones. There is no
  exception in this system. Each translation is a `PREROUTING` `DNAT` plus the `route_localnet`
  set once on the ingress interface, and nothing else: the translated packet is delivered
  locally, never reaches `POSTROUTING`, and conntrack unwinds the translation on the reply.
- The environment is the last `-`-separated segment of the name, and the set of environments is
  a root-owned table in `guarden.toml` rather than a list in the code. Each row is a **track**,
  carrying its own host prefix, gate, weight, retention defaults and `slot`/`instance` kind;
  adding `preprod` is appending a row. The environment is not a trust level and nothing in
  guarden branches on its name — the gate's strictness is the track's `gated` flag, and the
  authelia module is a service that lives in a gated track like any other.
- The word "container" is reserved for what `compose.yaml` calls `services:`, so a service
  and a container are never confused.

We keep the garden names for guarden's own programs — soil, weedr, loom, roots, twig, furrow,
hose, stakes — and for nothing else. A metaphor that leaks into the domain model becomes an
invitation to build a second concept; that is what happened, and this is the correction.
