# The tunnel terminates at the edge; the edge gains a plaintext entrypoint

**Supersedes in part** ADR-0024 (tunnel route credential lives Cloudflare-side):
the *routing path* changes — cloudflared now dials Traefik instead of the
service's own publication — but ADR-0024's core decision stands: a tunnel route
carries no guarden middleware, and its protection is Cloudflare's Access policy
(or nothing). The basic-auth login and forward-auth remain edge-only.

**Amends** ticket 293's edge-accept scope: the edge now serves tunnel
hostnames, so the edge's uid gains accepts on those publications under a
dedicated reason (`cloudflared:<name>`), rather than the previous edge-only
filter. The accept is deliberate and named, not a wildcard.

**Amends** spec §7.5: the Traefik API/dashboard is still a control surface
and is never forwarded on the public ingress, but it MAY be exposed as a
tunnel-only route on the plaintext entrypoint, reachable only through the
Cloudflare tunnel (and localhost), never on the forwarded web/websecure ports.

**Amends** spec §7.3: `/etc/hosts` entries written for the cloudflared
service (mapping hostnames to the ingress alias) are retained as a pragmatic
exception; they are the cloudflared container's only resolution path for
private hostnames.

## Status

accepted (2026-11-11) — implemented on `develop`.

## The decision

**Cloudflared dials Traefik, not the service.** The tunnel's ingress rows for
non-preview (and preview) routes point at `http://<alias>:<cloudflared
publication>`, where `<cloudflared publication>` is Traefik's new plaintext
entrypoint. Traefik routes by `Host` header to the correct backend
publication, exactly as it does for edge hostnames. One terminator, one
routing table, one place to add a hostname.

**A new plaintext entrypoint.** Traefik's existing `web` entrypoint redirects
to `websecure`, so a request that reaches it is a 301 and cloudflared does
not follow redirects — using `web` as the origin would be an infinite loop.
The `cloudflared` entrypoint (container port 8081, its own loopback
publication) terminates no TLS and redirects nothing; it exists only to be
dialed by cloudflared (and by localhost health checks). It is not forwarded
and is not in the module's `ingress` list.

**No middleware on tunnel routes.** Traefik renders the routes but attaches
neither forward-auth nor basic-auth to a tunnel-only route, preserving
ADR-0024. A route that is both edge and tunnel keeps its edge middleware.

**Previews go through Traefik too.** Preview instances are reached at
`preview.<tunnel_domain>/<ref>`; cloudflared dials Traefik, and Traefik
routes on `Host(preview.<tunnel_domain>) && PathPrefix(/<ref>)` to the
instance's own publication. The direct service-host router is retained for
non-tunnel access.

**Dashboard is tunnel-only.** `traefik.guarden` routes to `api@internal` on
the `cloudflared` entrypoint only. It is never attached to `web`/`websecure`,
so it is not reachable from the public ingress; the Cloudflare tunnel is its
security boundary.

**Accepts are deliberate.** The edge gains accepts on tunnel publications
(reason `cloudflared:<name>`) because it now serves them; cloudflared gains
an accept on the edge's `cloudflared` publication (reason `tunnel:<name>`).
No blanket wildcard is introduced.