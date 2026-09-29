# 50: modules, the edge, and the first vertical slice

**What to build:** The `gate` module installs `traefik-production` and `roots`. A manifest goes
in and an HTTP request comes out. This is the tracer bullet: user, render, install, runtime,
ingress, with nothing else in the way.

**Blocked by:** 20 (soil), 30 (weedr), 40 (loom)

**Status:** ready-for-agent

- [ ] `/usr/lib/guarden/modules/gate/module.toml` declares the edge service, the shared program
      it switches on, the ingress it declares for forwarding, and whether the service has an
      API; `weedr module list` and `weedr module add` read the directory plus `guarden.toml` and
      nothing else
- [ ] `weedr module add gate` on a host that already has soil run creates the edge service and
      its publications, without re-running soil and without touching other modules. It is also
      what creates the `edge` group and adds the edge's user to it
- [ ] **The edge binds no privileged port, and no port at all that is not loopback.** It holds no
      capability, exactly like every other service, and what it binds are allocations from
      `ingress.publication_range`. The public ports belong to the kernel
- [ ] The edge unit has two entrypoints: one issues the HTTP-to-HTTPS redirect, the other
      terminates TLS. One entrypoint doing both is refused
- [ ] **`soil firewall` writes `20-ingress-nat.conf`**: nat PREROUTING DNAT on the ingress
      interface for the edge's three ingress ports, `80/tcp` to the edge's redirect publication
      and `443/tcp` and `443/udp` to its TLS one, from the enabled modules' declared ingress,
      **and no `nat POSTROUTING` rule at all**. The mutator never writes a rule for the
      edge
- [ ] **The absence of a masquerade is asserted, not overlooked.** A `PREROUTING` DNAT to
      `127.0.0.1` makes the packet local, so it is delivered to `INPUT` and never reaches
      `POSTROUTING`; on the reply, conntrack unwinds the translation and rewrites the source to
      the address the client dialled. A rule matching `-d 127.0.0.1` in `POSTROUTING` matches
      nothing in either direction. What the golden VM still checks is `route_localnet` on the
      ingress interface, and it can only check forwarding from a second machine, because traffic
      the box generates itself never traverses `PREROUTING`
- [ ] **Only DNAT, never `REDIRECT`.** `redirect` rewrites the destination to the incoming
      interface's own address; the edge listens on loopback only, so nothing would be there
- [ ] Three ingress ports and no more, and **three forwarding rules**: a forwarded udp port is a
      different protocol and a different nat rule, so anything that counts the rules counts
      three. `443/udp` is HTTP/3 and the edge serves it from the same TLS publication as
      `443/tcp`. It is an additive optimisation — a client that cannot use HTTP/3 loses nothing,
      and no other mechanism in guarden depends on it. A publication the edge dials — 8096,
      32400, 5001, 20000 and the rest — needs no grant and gets no forwarding rule
- [ ] **The edge's own API and dashboard is a control surface, not ingress.** It is published on
      a loopback port with its accept set restricted to `host.admin_user`, or disabled
      entirely, and it is never forwarded from outside. The module declares which, and
      `weedr port list` shows it on its own line
- [ ] `roots sync` writes the edge's file-provider configuration into
      `/var/lib/guarden/edge/dynamic/`, which is owned by `guarden`, group `edge`, mode `2750`
- [ ] The edge's user is in `edge` and is not `guarden`; `roots` can write the directory and
      cannot write anywhere the edge can
- [ ] A manifest with a `routes:` section produces a route that answers a request with the right
      `Host` header
- [ ] `loom` writes `AddHost=<service>:<alias>` into **the edge's units** for every routed
      service, and `weedr` renders the edge's accept rule for that publication. Without both,
      the edge cannot resolve its own configuration — this is a defect found by trying to deploy
      a real service, and it is the first thing to check when a route 502s
- [ ] The route target in the rendered file is `<name>:<publication>` — the service's own name
      and its allocated loopback port, never a loopback address and never a suffix: the edge is
      a container, and the host's loopback is not its own
- [ ] The intra-host rule set accepts exactly three uids per publication — the owner, the edge,
      and the declared consumers — and drops everyone else, and the host name comes from the
      track's `host_prefix`
- [ ] A route's container port is allocated from the shared namespace, so several preview
      instances of one service each get their own publication and none of them contends for one
- [ ] A route change appears without restarting the edge
- [ ] A service with no `routes:` produces no route and no error
- [ ] The call log shows the edge's units installed by `weedr` and rendered by `loom`, with the
      edge reading the shared directory read-only in its unit
- [ ] On the golden VM, a request with the right `Host` header reaches the container through the
      edge, addressed at the edge's **published loopback port** rather than the host's port 80 —
      locally generated traffic does not traverse PREROUTING, so a request to the public address
      from the box itself never reaches the forwarding rules. Over http, since a throwaway
      machine cannot complete ACME
- [ ] `just test` exits 0 and stays in seconds

- [ ] **`weedr service gate <name>` evaluates and changes nothing else**: it reads the schema and
      the service's own secret store, writes `[gate] state`/`reason`/`checked` to the registry,
      and returns. It is a mutator verb because the store is inside a `0700` home
- [ ] **A blocked gate is a state, not a failed deploy.** A push to a gated track with a missing
      required key creates the service, builds, installs, does **not** start the container, and
      `furrow` **exits `0`** with a `warning:` naming the missing key
- [ ] **`weedr service start` re-evaluates the gate every time**, so an operator who plants the
      credential and runs it starts the service with no second push. A raw `systemctl --user
      start` bypasses it, and that is stated as a deliberate act by someone with those powers
- [ ] `weedr service list` distinguishes **blocked** from **crashed** from **never started**, in
      words, and prints the `[gate] reason` for a blocked one
- [ ] A service with **no** `[gate]` table has never been evaluated, which is reported as
      "not evaluated" and is not the same as `ready`
- [ ] On a `gated = false` track the same missing key is one `warning:` line, the gate records
      `not-required`, and the start proceeds
