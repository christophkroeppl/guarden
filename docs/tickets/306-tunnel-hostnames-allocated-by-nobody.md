Blockers: none. Carried out of ticket 293's "Known gaps" so that merging the
exposure cluster does not erase it (review-exposure.out finding 10 and §4b).

## What happens

Tunnel hostnames are allocated by nobody. `roots.render_tunnel` publishes a
tunnel route at the host the mutator allocated in `[host] domain`
(e.g. `web.example.com`), while the zone the tunnel actually serves is
`[ingress] tunnel_domain`, which is used for **previews only**. So on a host
whose `host.domain` is not inside the tunnel's zone, ticket 293's derived
default — "behind the tunnel" for every new service when `cloudflared` is
enabled — publishes a hostname the tunnel does not serve: the service is
strictly fail-closed (no edge file, no edge accept) and also unreachable, and
nothing says so. The t452 assertion was a substring that could not tell the two
apart; it now asserts the full allocated FQDN (review finding 9), which makes
the gap visible rather than papered over.

## What to build

Per-service hostnames inside the tunnel's zone: either the mutator allocates a
`tunnel_domain`-zone name for a route whose destination resolves `tunnel`, or
`roots` maps the destination at render time — one writer, decided the way spec
3.3's precedence decides everything else. Until then, an operator installs
`cloudflared` with `host.domain` pointed at the tunnel zone, by hand.

## Status: ready-for-agent

- [ ] A new service whose destination resolves `tunnel` gets a hostname in the
      tunnel's own zone, or the host says why it cannot.
- [ ] The tunnel ingress file carries that hostname, asserted in full.
- [ ] Red first, in the t450–t459 range.
