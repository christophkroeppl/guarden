Blockers: none. Carried out of ticket 292's "Known gaps" so that merging the
exposure cluster does not erase it (review-exposure.out finding 10).

## What happens

A tunnel route carries no middleware. Cloudflared dials the service's
publication directly (`http://<name>:<publication>` in the tunnel ingress the
renderer writes), so the per-service basic-auth gate — which lives in traefik's
file provider at the edge — is never in the path. Protecting a tunnel route is
Cloudflare-side (Access policies, or the share family's grants), and the split
is invisible from the guarden side: an operator who promoted a service to
`tunnel` may believe the credential followed it.

## What to build

Decide and state where a tunnel route's credential lives — most probably
"Cloudflare-side, and `weedr expose set <name> tunnel` says so on stdout when
the service is flagged" — and enforce whatever the decision is. If the answer
is "nowhere", the act must say it rather than leaving the operator to infer it
from the middleware's absence.

## Status: done, verified by `tests/t454-tunnel-credential.sh`

- [x] The `expose set … tunnel` act (or the docs the operator reads) states
      what protects a tunnel route and what does not. — `weedr expose set
      <name> tunnel` prints the line for a service that carries the edge login,
      and says nothing for one created before the policy existed: there is no
      credential that could have failed to follow it. ADR-0024 is the canonical
      statement; spec §6.2 and §6.4 and `docs/sysadmin.md` point at it.
- [x] No rendered artefact implies a middleware on a path that has none. —
      `roots` writes the edge's file provider only for `edge`-destination
      routes, so a tunnel route has no edge file at all; the tunnel's ingress
      is cloudflared's own configuration and carries no traefik vocabulary
      (`middlewares`, `basicAuth`, `usersFile`, `forward-auth`). Both are
      asserted, and a neighbouring edge service's rendered file is asserted in
      the same run as the control.
