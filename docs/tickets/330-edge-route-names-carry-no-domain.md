Blockers: none. Carried out of ticket 324's scope decision so that closing the
tunnel's half does not look like the name question is settled.

## What happens

A route's recorded name is `<track host_prefix><label>` and nothing else, and
both terminators consume that value verbatim.

Ticket 324 fixed the tunnel's half: a tunnel route is now allocated in the
tunnel's own zone, `<host_prefix><label>.<tunnel_domain>`, because that is the
name cloudflared matches on and a bare label is one no DNS can answer.

The **edge's** half is untouched and has the same shape. `roots.render_service`
writes `Host(`staging.web`)` into the edge's file provider, so the rule matches
only a request whose `Host` header is the bare recorded name. Measured on this
branch: `[route_hosts] web = "staging.web"` in the registry, `host =
"staging.web"` in the slice, and `Host(`staging.web`)` in the rendered file —
`tests/t50-route.sh` pins all three, and `tests/t50-slice.sh` curls the edge
with `-H 'Host: staging.web'`, which is why the suite is green over it. `twig`
links to the same bare value.

Spec §4 says the opposite: "The full name is `<track host_prefix><host:>`, and
`host_prefix` is root-owned. So with `host_prefix = "myapp."` a manifest writing
`web` claims `web.myapp.com`". That example puts the prefix *inside* the domain
as a subdomain, and nothing reads `[host] domain` when allocating a route name
today — its one use is the manifest's `${domain}` substitution (§4).

## What to build

One decision, then the code follows it: the edge's route name is a name in
`[host] domain` and the track's `host_prefix` is the part of it that varies per
environment, so `staging.` + `web` + `example.com` is `web.staging.example.com`
or `staging.web.example.com` — whichever the spec's example is meant to say,
stated once in §4 and computed by the one allocator (`publications.claim_host`).

Whatever the answer, these move with it: the record's `[route_hosts]`, the
slice's `host`, the edge's `Host(`…`)` rule, `weedr share issue` (which must
still refuse an edge route), `twig`'s links, and the three suites that pin the
bare form.

## Status: ready-for-agent

- [ ] `[host] domain` is what the edge's route names are allocated in, or the
      spec says why it is not.
- [ ] The edge's `Host(`…`)` rule matches the name a browser sends, asserted
      with a real request and not a hand-written `Host:` header.
- [ ] Red first, in the t450–t459 range.
