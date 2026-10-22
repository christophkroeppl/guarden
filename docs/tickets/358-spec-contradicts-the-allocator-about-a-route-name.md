# 358 — the spec contradicts the allocator about a route's name, and one of its sentences is broken

## What is measured

`docs/spec.md` §4 says a route's full name is
`<track host_prefix><host:>` **inside the host's domain**:

```
1184| - **A route's `host:` is a label, not a domain, and the host owns the domain.** The full name is
1185|   `<track host_prefix><host:>`, and `host_prefix` is root-owned. So with `host_prefix = "myapp."`
1186|   a manifest writing `web` claims `web.myapp.com` and a manifest writing
1187|   `www.elsewhere.com` claims `www.elsewhere.com.myapp.com` — inside the domain, unreachable,
1188|   and visibly wrong to the developer rather than silently successful. **A repository therefore
1189|   cannot claim a name outside `host.domain`, and the only way to serve another domain is for the
1190|   operator to set `host.domain` or the track's `host_prefix`.**
1191|   these two with a `${domain}` substitution and validated nothing, which meant any repository
1192|   could claim any name in the operator's domain and two services claiming one was undefined.
```

**Line 1191 is a broken sentence.** It has no subject and no verb — "these two with a
`${domain}` substitution and validated nothing" — so the paragraph does not parse. It
reads like the remains of a sentence whose beginning was rewritten at 1184-1190 and
whose tail was left behind.

**The code does the other thing.** `publications.claim_host` allocates
`<host_prefix><label><zone>`, and `service._zone` returns `""` for every route that
is not a tunnel route:

```python
def _zone(track, destination: str, tunnel_domain: str, service: str) -> str:
    """The zone a route's allocated name is published in: `""` or `.`+domain.
    ...
    if destination != exposure.TUNNEL:
        return ""
```

So an edge route's name is `staging.web` — **no domain at all** — and `host.domain`
is not consulted.

**`host.domain` reaches exactly one thing.** It is a real config key
(`src/guarden/config.py:315`, `domain=_str(host, "domain", ...)`) and it has
exactly one consumer:

```
src/guarden/render.py:1275:    domain = context.config.domain if context else ""
src/guarden/render.py:1611:    """`${domain}` is the only substitution, from `host.domain` (spec 4).
```

the `${domain}` **manifest substitution**. It never reaches the allocator. So the
spec's sentence at 1189-1190 — *"the only way to serve another domain is for the
operator to set `host.domain`"* — is true only of a manifest that writes
`${domain}` itself, and false of the allocator, which publishes `staging.web` in
whatever zone the destination names.

**The bare form is pinned by three suites**, so the code and the tests agree with
each other and it is the spec that is out:

```
tests/t50-route.sh:62:  assert_file_has "$registry" 'web = "staging.web"'
tests/t50-route.sh:70:  assert_file_has "$slice" 'host = "staging.web"'
tests/t50-route.sh:100: assert_file_has "$rendered" 'Host(`staging.web`)'
tests/t50-slice.sh:425: assert_stdout_has "https://staging.web/"
```

## Why it matters

`spec.md` is the document the suites check the code against — `tests/t480-doc-claims.sh`
exists for exactly that, and the t353 fix in this repo was a `t480` assertion that
contradicted its neighbour. A spec that says `web.myapp.com` where the code writes
`staging.web` is a spec that will send the next author to the wrong answer, and
`tests/t50-route.sh` will then be the thing that has to change.

**But the fix is not mechanical, and that is why this is a ticket and not an edit.**
Two answers are defensible, and they are not the same change:

1. **The code is right and the spec is stale.** The bare form is what three suites
   pin, what `Host(`staging.web`)` in the edge file matches, and what a browser
   sends. The spec's `web.myapp.com` example is the wrong shape — it puts the
   prefix *inside* the domain as a subdomain, which the spec itself calls
   "unreachable". Then §4 is rewritten to describe the bare form, `host.domain`'s
   role is stated as the `${domain}` substitution only, and the broken sentence at
   1191 is repaired or removed.

2. **The spec is right and the code is wrong.** A route's name should be a name in
   the host's domain, so the allocator needs `host.domain` in it, `t50-route.sh` and
   `t50-slice.sh` change, and the edge's `Host(`…`)` rule changes with it.

Answer 2 is a behaviour change to how every route is named, on a host where the
route host is also the thing the edge file matches and the thing `twig` links to.
That is an operator's decision, and ticket 330 already says so:

> One decision, then the code follows it: the edge's route name is a name in
> `[host] domain` and the track's `host_prefix` is the part of it that varies per
> environment.

**The one part that is not the operator's decision is the broken sentence.** Line
1191 is objectively broken — it has no subject and no verb — and it can be repaired
or removed without changing what any code does. That is worth doing whichever way
the naming question is answered, and it is worth doing now rather than leaving a
half-paragraph in the document the suites check the code against.

## What is measured here, and what is not

Measured, on `develop` at `8a26b16`:

- `docs/spec.md:1184-1190` states the `<track host_prefix><host:>` form and the
  `web.myapp.com` example.
- `docs/spec.md:1191` is a broken sentence.
- `publications.claim_host` allocates `<host_prefix><label><zone>`;
  `service._zone` returns `""` for a non-tunnel destination.
- `host.domain` has one consumer, `render.py:1611`, the `${domain}` substitution.
- `tests/t50-route.sh` and `tests/t50-slice.sh` pin the bare form.

Not measured, and deliberately: whether a route's name *should* be in the host's
domain. That is the decision, and it is not this ticket's to make.

## A second observation, from the t357 measurement

`t120-deploy.sh` and `t60-gate.sh` both use the service name `qapp-production`, and
on a shared machine the second one to run finds the first one's `qapp-production.toml`
already carrying a `[gate]` table — so `t60-gate.sh:103`'s
`assert_file_lacks "$production" "[gate]"` fails, and in the other order the route
host `staging.web` is already held and the allocator refuses the second claimant:

```
error: quadlet-app-staging claims the route host 'staging.web', and
       qapp-staging already holds it; a route host is allocated and the
       allocator refuses the second claimant
```

That is ticket 330's subject seen from the allocator's side — not a naming
question but a stale claimant — and it is ticket 357's teardown work. It is
recorded here because it is the second piece of evidence that route-name state is
**global to the host** and not per service, which is the assumption answer 2 above
would have to confront.

## Acceptance

- [ ] `docs/spec.md` §4 says, once and unambiguously, what a route's full name is,
      and it says the same thing the allocator computes.
- [ ] The sentence at 1191 is either repaired into a whole sentence or removed —
      it is not left as a fragment.
- [ ] `host.domain`'s role is stated: the `${domain}` substitution, the route
      name, or both — and if it is the route name, the allocator and the three
      pinning suites change with it.
- [ ] The examples in §4 are ones the code can produce. `web.myapp.com` and
      `staging.web` cannot both be right.
- [ ] `tests/t480-doc-claims.sh` pins whatever §4 now says, so the spec and the
      allocator cannot drift apart again without a suite going red.

## Status: needs-a-decision

- [ ] answer 1 (the spec is stale; rewrite §4, keep the bare form) — **or** —
- [ ] answer 2 (the code is wrong; the name is in the host's domain, and the
      allocator, the edge rule and the three suites change)
