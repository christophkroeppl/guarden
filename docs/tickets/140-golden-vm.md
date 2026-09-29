# 140: the golden VM, end to end

**What to build:** One run on a throwaway machine that proves the claims the fast harness cannot:
name resolution from a rootless container, isolation between services, a clone of a live data
volume recovering, a rollback, a lock being a file, and an edge answering a request. It ends in
an evidence tarball.

**Blocked by:** 50 (the edge), 60 (the gate), 70 (state and snapshots), 80 (edges), 90 (a poke
creating a service), 110 (two previews from one snapshot), 120 (the queue), 130 (cloud-init boot)

**Status:** ready-for-agent

- [ ] A throwaway machine boots from cloud-init, converges soil, and captures an evidence
      tarball of journals, unit states and `soil --check`
- [ ] Two projects are installed from manifests: one that needs a database and one that does not
- [ ] A request with the right `Host` header reaches each service through the edge, addressed at
      the edge's **published loopback port** — `weedr service list` prints it — because locally
      generated traffic does not traverse PREROUTING. Over http, since a throwaway machine cannot
      complete ACME
- [ ] **A forwarded public port answers from off the box, and nothing unprivileged on the box can
      bind a port below 1024.** The request comes from a second machine, not from the box: traffic
      the box generates itself never traverses PREROUTING, so a request the box makes to its own
      port 80 proves nothing about the forwarding rules and is not a substitute. The criterion
      distinguishes working forwarding from none; what the ticket asserts about the rule set is
      that the installed `nat PREROUTING` chain has one `DNAT` per forwarded port and **no**
      `POSTROUTING` masquerade, since such a rule matches no packet in either direction and its
      presence would mean the render carries a claim it cannot keep
- [ ] A member service reaches its declared dependency by name; a service that did not declare
      the edge cannot open the port, and both facts are captured as evidence
- [ ] A snapshot of the live database is taken with the service running, a staging service is
      forked from it, and the clone starts, recovers, and holds the data
- [ ] A preview instance is forked from staging, a second is forked from the same snapshot, the
      first is evicted, and the snapshot is still protected and still forkable
- [ ] A rollback restores a state volume and the service comes up with the old data
- [ ] A service with two state volumes — one configuration, one large — snapshots both in one
      operation and forks as a complete set; a fork naming a number one of the two volumes does
      not have is refused with exit `1` and changes nothing. The two volumes are not required to
      agree to the byte, and the run does not claim they do
- [ ] A deploy of a service in a gated track with a missing credential installs and waits without
      starting the container, and the deploy **exits 0** while the gate names the key. The
      running container is still running afterwards
- [ ] A poke through `hose` creates a service, builds it, and deploys it, and the box is
      left with no clone and no checkout
- [ ] Every write-lock is demonstrated: a concurrent writer produces a complete file, never a
      torn one, and the lock is a file under `/run/guarden/locks`
- [ ] The run is minutes long and fails with one clear message naming the phase
- [ ] `just test` stays green and stays in seconds
