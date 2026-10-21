Blockers: none. Carried out of ticket 293's "Known gaps" so that merging the
exposure cluster does not erase it (review-exposure.out finding 10 and §4b).

## What happens

Tunnel hostnames are allocated by nobody. `roots.render_tunnel` publishes a
tunnel route at the route's allocated name, and the mutator's allocator
(`publications.claim_host`) returns `<host_prefix><label>` with **no domain
appended at all** — measured on this branch: the tunnel ingress for a
production service whose route label is `web` and whose track prefix is empty
carries the bare line `hostname: "web"`, a name in no zone whatsoever. The
zone the tunnel actually serves is `[ingress] tunnel_domain`, which is used for
**previews only**. So ticket 293's derived default — "behind the tunnel" for
every new service when `cloudflared` is enabled — publishes a hostname no DNS
can answer: the service is strictly fail-closed (no edge file, no edge
accept) and also unreachable, and nothing says so. (An earlier draft of this
ticket, following the adversarial review's §4b, assumed the allocated name
were a zone-qualified FQDN like `web.example.com`; the measured value is the
bare label, which is strictly worse and still this ticket.) The t452 assertion
is now a whole-line match, so it measures the current value exactly and cannot
pass on a longer name (review finding 9).

## What to build

Per-service hostnames inside the tunnel's zone: either the mutator allocates a
`tunnel_domain`-zone name for a route whose destination resolves `tunnel`, or
`roots` maps the destination at render time — one writer, decided the way spec
3.3's precedence decides everything else. **The mutator allocates it**: the
record is the authority (§3.4), and it is what the tunnel's ingress, a grant,
`weedr service list` and `twig` all read, so a name derived at render time would
be a second answer a grant could disagree with.

## Status: verified

- [x] A new service whose destination resolves `tunnel` gets a hostname in the
      tunnel's own zone, or the host says why it cannot. — `tests/t455-tunnel-hostname.sh`
      reads the record's `[route_hosts]` back as TOML and asserts
      `web.tunnel.example.net` for a production route labelled `web`, and
      `staging.web.tunnel.example.net` for the staging one. An empty
      `tunnel_domain` with a tunnel route is exit `1`, one `error:` line naming
      the key, with no passwd entry and no registry file left behind.
- [x] The tunnel ingress file carries that hostname, asserted in full. — the
      whole line `  - hostname: "web.tunnel.example.net"` is matched (a
      substring would pass on the bare label), and the file is re-read as the
      YAML cloudflared parses, where the rule must carry a `service`.
- [x] Red first, in the t450–t459 range. — `t455` went red on 709f9dd,
      "the production service claims the route host web, expected
      web.tunnel.example.net", and green on 9c68bc7.

**The scope decision, so it is not re-litigated:** the mutator allocates the
name, because the record is the authority (§3.4) and it is what `roots` renders,
what `weedr share issue` grants and what `twig` links to. A preview instance
keeps its bare name — spec §9 publishes every preview of every project at one
host — and the edge's still zone-less route names are carried as ticket 330.

