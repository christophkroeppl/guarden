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

## MEASURE: not performed

**Result: not run.** No Cloudflare account, no second guarden host, and no tunnel
zone are available to the machine these suites run on. Nothing in the two suites
above claims otherwise, and `t457` prints the lookup of the producer's hostname as
its own measurement and asserts that the name does **not** resolve there — the
positive half (`example.com` resolving from inside a pasta container) is the
mechanism the edge relies on, and the negative half is the harness saying it could
not have made the trip.

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
