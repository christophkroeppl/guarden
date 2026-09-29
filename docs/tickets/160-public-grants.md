# 160: public ingress grants

**What to build:** A granted public port is reachable from outside the host because the kernel
translates it onto the service's own loopback publication. Nothing is ever bound on a
non-loopback address, so there is no such thing as a private grant versus a public one — a
grant is a translation and nothing else.

The edge is how HTTP and HTTPS are published; a grant is how a service is reachable by a
protocol the edge cannot speak — a bitcoin node's peer port, a WireGuard endpoint. Public access
for web traffic is the edge's job and false for everything else, and a platform that cannot run
a full node is not general.

Nothing about the grant mechanism changes: it is still a manifest request and a root-owned
grant, and the repository still cannot make one.

**Blocked by:** 80 (declared edges), and 15 for the reach evidence

**Status:** ready-for-agent

- [ ] `weedr port open <name> 8080/tcp` is the whole argument form: the service, then the port.
      **There is no `private|public:` prefix and no bare-port shorthand**
- [ ] `weedr port open` creates the service's `overrides.toml` if absent, adds the port to
      `[ports] open`, and re-renders `30-services.conf` in full, printing the diff, under the
      `firewall` lock
- [ ] **A grant renders a nat PREROUTING DNAT rule** from `<ingress-if>:<port>` to
      `127.0.0.1:<publication>`, **no `nat POSTROUTING` rule**, and no `PublishPort` line for a
      non-loopback address. The service's publication already
      exists; the grant only makes the public port reach it
- [ ] **The absence of a masquerade is the asserted behaviour.** A `PREROUTING` DNAT to
      `127.0.0.1` makes the packet local, so it is delivered to `INPUT` and never reaches
      `POSTROUTING`; on the reply conntrack unwinds the translation and rewrites the source to
      the address the client dialled. A rule matching `-d 127.0.0.1 --dport <pub>` matches no
      packet in either direction, so a grant carrying one would be a rule that looks load-bearing
      and is inert
- [ ] `weedr port close` removes the DNAT; neither a rule nor a publication is left orphaned
- [ ] The publication is allocated from `ingress.publication_range` and is unique per service and
      instance, so two services can each be granted the same public port only one at a time: a
      second grant of a port another service already forwards is refused with **exit `1`** naming
      the holder
- [ ] `weedr port list` shows requested, granted and pending for every service, so the reachable
      surface of the host is readable in one command. A pending request is sticky
- [ ] A requested port with no grant is simply not forwarded — the container comes up without the
      port rather than with it silently half-working — and the request stays pending
- [ ] A port no manifest requested may still be granted; the grant is the admin's, not the
      manifest's
- [ ] The `firewall` render is a union of every grant and every allocation, rewritten atomically
      with the diff printed before installation, so two mutations in a row cannot install out of
      order and duplicate rules cannot exist
- [ ] Removing a grant removes the forwarding rule, and `weedr port list` shows the port closed- [ ] **`30-services.conf` is disjoint from `20-ingress-nat.conf`.** The edge's three forwarding
      rules are written by `soil firewall` from the enabled modules' declared ingress; a service's
      own granted forwarding is written by the mutator. Each file has exactly one writer
- [ ] The dead-man timer still restores firewall access, and a grant cannot disable it
- [ ] On the golden VM: **a granted public port answers from off the box**, an undeclared port
      does not, and no unprivileged process on the box can bind below 1024. The request cannot
      come from the box itself: locally generated traffic does not traverse PREROUTING, which is
      why this criterion rather than a loopback health check is the only thing that can
      demonstrate forwarding at all
- [ ] `docs/notes/repo-ports.md` still describes promotion of pending requests as an
      administrator's option and still says it is not installed
- [ ] Verified at the CLI seam with the fast harness
