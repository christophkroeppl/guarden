# A tunnel route's credential lives Cloudflare-side, and the act that promotes a service says so

Ticket 323 asked one question the code had not answered: **a tunnel route carries no
middleware — so where does a tunnel route's credential live, and what tells the operator
which answer it is?** The per-service basic-auth gate lives in traefik's file provider at
the edge (ticket 292), and cloudflared dials the service's publication **directly** —
`http://<name>:<publication>` in the tunnel ingress `roots` renders. The edge is never in
that path, so the edge's middleware is never in that path either.

**The answer: Cloudflare-side.** The protection on a tunnel route is the vendor's Access
policy, and the operator's own instrument for it is the `weedr share` family — a
time-bounded issuance projected onto the vendor's `Allow` policy (ticket 220, spec 6.2).
The basic-auth login a service was minted at creation protects that service's **edge**
route, and it does not follow the service to the tunnel.

## Status

accepted (2026-10-21) — implemented on `fix/t323-work`. The test is
`tests/t453-tunnel-credential.sh`.

## The decision

**A tunnel route is protected by the vendor's Access policy, or by nothing.** Guarden's
own `weedr share issue` is the way to put one there; the basic-auth login is the edge's
half and does not travel.

Two things follow, and both are load-bearing:

- **The act that promotes a service to the tunnel says so.** `weedr expose set <name>
  tunnel` prints, on stdout, that the route is reached through the tunnel and that the
  edge's basic-auth login does not protect it. This is not a courtesy line: an operator
  who promoted a service to `tunnel` and saw only `<name> exposure tunnel` would
  reasonably believe the credential followed it, and the split between the two
  terminators is invisible from the guarden side. The line names what protects the route
  and what does not, so the answer is read where the decision is made.

- **No rendered artefact implies a middleware on a path that has none.** The tunnel's
  ingress file is cloudflared's own configuration and carries no traefik vocabulary at
  all: no `middlewares:`, no `basicAuth`, no `usersFile`. The edge's per-service file is
  written only for `edge`-destination routes, so a tunnel route has no edge file to
  mislead anybody. A service that carries a basic-auth login and is published on the
  tunnel therefore has a login that protects nothing — and that is a **state to be
  reported**, not a defect to be hidden.

## What this is NOT

- **It is not a second credential.** There is one basic-auth login per service and it
  lives in the edge's path. Guarden does not mint a tunnel-side password, does not write
  a second htpasswd entry, and does not teach cloudflared about basic auth — cloudflared
  has no such middleware to teach.
- **It is not a repository's to decide.** No manifest key reaches this, and no
  `overrides.toml` entry does. The posture of a route is the root-owned `expose` field and
  the recorded `[exposure]` value (spec 3.3, 3.4); the credential that covers it is the
  vendor's.
- **It is not the edge's forward-auth either.** `auth: true` in a manifest means
  forward-auth at the edge, and a tunnel route never passes the edge — so a route that
  asked for it and is published on the tunnel has no middleware either, and saying so is
  the same statement.

## What it costs, stated

- **A service promoted to the tunnel may lose its protection, and the act is what says
  so.** That is the honest shape of the thing: the two terminators have two different
  credential families, and moving a route between them moves which family is in the
  path. The act names the move; nothing else can.

- **The warning is a warning, not a refusal.** Refusing `expose set … tunnel` for a
  flagged service would make the operator's own decision — "publish this through the
  tunnel" — unavailable to them, and the design's rule is that the operator decides the
  posture while the programs report the consequences. `weedr expose set` is not on a
  sudoers rule and is a root-side act an operator takes deliberately.

- **The vendor's policy is only in force if the reconciler runs.** `weedr share
  reconcile` projects the record onto the vendor, and the timer runs every ten minutes on
  a host with the `cloudflared` module. A host with the tunnel and no reconciler has a
  route that reaches its publication with whatever the vendor's default is — which is
  the same truth `docs/sysadmin.md` already states about a stopped timer.

## The one canonical statement

**The rule is stated once, here, and every other document points at it.** The edge's
basic-auth middleware protects an **edge** route; a **tunnel** route's protection is the
vendor's Access policy and guarden's instrument for it is `weedr share issue`. `roots`
does not render a tunnel route into the edge's file provider at all — it is a different
terminator, not a route the edge declines to serve.
