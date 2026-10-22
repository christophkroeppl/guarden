# The cross-host tunnel edge: the live round trip is a MANUAL check

Ticket 307f T2 makes a `needs:` entry able to name a service on **another host**,
reached through that host's cloudflared ingress at its route hostname
(`via: tunnel`, spec §4 and §7.3). Everything about it that a machine can answer is
answered by two suites:

- `tests/t456-tunnel-edge.sh` — the renderer's half: the hostname, `443`, the
  credential request, nothing local written, and the pasta edge's own bytes
  unchanged. Staged host, no VM state.
- `tests/t457-tunnel-edge-host.sh` — the mutator's half and the machine's: the
  registry record, the refusal for a producer recorded `loopback`, `50-services.conf`
  naming no `443`, and a real container in a pasta namespace resolving a public name.

## What they cannot answer

**A live round trip between two hosts.** It needs an account at the tunnel's vendor:
a tunnel with an ingress rule pointing at the producing host's service, the route
exposed `tunnel` on that host, and — for `auth: secret` — an Access service token.
The harness has no such account, and a suite that appeared to make the trip would be
asserting a fake. So it is not asserted anywhere.

## MEASURE: the live round trip — not performed

**Result: not run.** No Cloudflare account, no second guarden host, and no tunnel
zone are available to the machine these suites run on. Nothing in the two suites
above claims otherwise, and `t457` prints the lookup of the producer's hostname as
its own measurement and asserts that the name does **not** resolve there.

## What `t457` measures instead: the composition, with the policy in force

A container's lookup does not leave the host as the container. pasta forwards it to
the host's stub resolver **from the uid that started the container**, and §7.6's
default deny drops every loopback packet from every service uid except the accepts
above it — so whether a container is a client those accepts admit is a question
about two mechanisms at once, and it is not obvious from either file.

The suite answers it on the deployed state: `soil firewall --apply` writes and
starts `guarden-firewall.service`, which loads `50-services.conf`, and the same
lookup then runs twice.

    row                                          uid                        expected
    nslookup example.com                         the consumer's own          Name: line, deny counter unchanged
    nslookup example.com                         ubuntu (1000)               no Name: line, deny counter moves

The second row is what makes the first one evidence. Without it, a suite passes on
a machine where the deny was never installed — which is exactly the state this
measurement was corrected for — and the deny's own packet counter is what tells a
refused lookup from one that simply had none.

The output `t457` recorded on 2026-10-22, a fresh cut of the golden:

    MEASURE: SERVICE_UID_LOOKUP DENY=0->0 ACCEPT=0->2
    MEASURE: NON_SERVICE_UID_LOOKUP DENY=0->4
    MEASURE: the non-service uid lookup printed:
    ;; connection timed out; no servers could be reached
    MEASURE: the producer hostname from inside a pasta container:
    Server:		169.254.1.1
    Address:	169.254.1.1:53

    Non-authoritative answer:

    Non-authoritative answer:

Row by row:

- **The consumer's uid: the deny's counter did not move and its own accept's did
  (`0->2`)**, and `Name:` came back. The query left the container, pasta
  forwarded it from the consumer's uid, and the udp accept at `127.0.0.53:53`
  took it. That is §7.6's composition measured rather than inferred — the accept
  counter is what says the answer came through the path under test and not
  around it.
- **`ubuntu`: the deny's counter moved (`0->4`) and the lookup timed out.** uid
  1000 is not a service uid, the deny names no uid, and nothing accepts it.
- **The producer's hostname: no `Name:` line**, from the consumer's uid, at the
  same forwarder. No Cloudflare zone publishes that name here, so nothing
  answers: that is the harness saying it could not have made the trip, not
  evidence about the vendor.

**Every row passes `169.254.1.1` as the server explicitly, and that is
load-bearing.** podman writes the container's `resolv.conf` with pasta's
forwarder **and the host's own nameserver beside it** (measured on the golden:
`nameserver 169.254.1.1`, then the machine's), so an unqualified `nslookup`
falls back to the second one and answers a uid the deny has just refused. The
first cut of this measurement did exactly that — `ubuntu` printed `Name:` and
`Server: 10.26.102.1` while the deny's counter moved — so the row read as
"accepted" whatever the policy said: the same "green because the environment
provides it" failure the suite exists to avoid. Naming the forwarder is what
makes the row a measurement of pasta's path.

## The procedure, for the operator who has the account

On the **producing** host:

1. `[ingress] tunnel_domain` is the zone the tunnel serves; the `cloudflared` module
   is enabled. A route on a service whose destination is `tunnel` is published at
   `<track host_prefix><label>.<tunnel_domain>` — read it from
   `weedr service list --json <name>` (`route_hosts`), not from the manifest.
2. Confirm the vendor's ingress carries that hostname: `cloudflared` reads
   `/var/lib/guarden/tunnel/config.yml`, and the hostname must appear there with an
   `http://<service>:<publication>` target.

On the **consuming** host, the manifest:

```yaml
needs:
  - service: orders
    as: api
    auth: secret
    via: tunnel
    hostname: orders.tunnel.example.net
```

3. `weedr service ingest <consumer>-<track> …`, then
   `weedr secret set <consumer>-<track> API_SECRET` with the vendor's Access service
   token (guarden minted a placeholder when it planted the edge's credential; the
   token is the vendor's to issue, and `weedr secret set` replaces the placeholder).
4. From inside the consumer's container, the round trip:

   ```
   podman exec <consumer>-web nslookup orders.tunnel.example.net
   podman exec <consumer>-web wget -qO- https://orders.tunnel.example.net/
   ```

   The first must answer with the tunnel's address rather than NXDOMAIN — that is
   the half `t457` measures only for a public name — and the second must answer with
   the producer's body, or `401` when `needs.auth` is absent and the route is behind
   Access. **A `401` without the credential is the intended failure**, not a defect:
   the route is protected at the vendor and the consumer has nothing to present.

5. Record the result here, with the date and the two commands' output.
