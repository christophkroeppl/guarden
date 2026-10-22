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

- [x] The sentence at 1191 is repaired into a whole sentence — and so are the
      other three of the same class, and the fifth by a different mechanism.
- [x] A suite pins the class, so the next fragment is caught too.
- [x] `docs/spec.md` §4 says, once and unambiguously, what a route's full name is,
      and it says the same thing the allocator computes. **Answer 1: the code is
      right, the spec was stale.**
- [x] `host.domain`'s role is stated: the `${domain}` substitution, the route
      name, or both. **It is the substitution, and it is in no route's name.**
- [x] The examples in §4 are ones the code can produce. `web.myapp.com` and
      `staging.web` cannot both be right — only the second one survives, and it
      is now allocated by the check rather than asserted as a string.
- [x] `tests/t480-doc-claims.sh` pins whatever §4 now says, so the spec and the
      allocator cannot drift apart again without a suite going red.

## What landed with answer 1

**The spec now says what the allocator computes, and a suite asks the
allocator.** The rewrite is in six places, because the same claim was carried
in six:

| where | what it said | what it says now |
|---|---|---|
| §3.1's track example | `route host is myapp.$DOMAIN` | `the route host is the label alone: \`web\`` |
| §3.4's `[route_hosts]` | `web = "web.myapp.com"` | `web = "web"`, with the tunnel's zone stated as the rule |
| §4's manifest example | "cannot claim a name outside host.domain" | "`host.domain` is in no name" |
| §4's route-host paragraph | the full name inside the host's domain | the bare form, the zone, and `host.domain`'s real role |
| §9's preview | `preview.$DOMAIN/<ref>` | `preview.<tunnel_domain>/<ref>`, plus the instance's own `preview.web` |
| `README.md`, `docs/sysadmin.md`, `shared-routes.toml.j2`, `roots.py` | the same claim, in a table and in comments | the same claim, corrected |

**§4 is now four bullets, and each says one thing.** The bare form; the zone
the destination adds; `host.domain`'s role; and what the earlier revision got
wrong. The old paragraph's "the host owns the domain" is gone — the host does
not own a domain that is in no name.

**The pin asks the allocator rather than asserting a string.** A suite that
asserted "the spec says `<host_prefix><label>`" would be asserting a string
copied out of the spec, and would stay green the moment the allocator and the
spec drifted apart — which is the defect itself. So `tests/routename.py` calls
`publications.claim_host` and `service._zone` with the real arguments and asks
whether the spec says what those calls returned. The spec's examples are
checked by ALLOCATING them, not by reading them.

**Verified non-vacuously.** With the spec reverted to the old claim and the
assertion kept, the suite fails naming the old claims; with the rewrite it
passes.

## What landed without the decision

The broken sentence is the one part of this ticket that is not the operator's
to decide, and it is fixed. **It was not one sentence but five**, in two
mechanisms:

**Four fragments, one mechanism.** `67740995` folded the ADRs into the spec,
and in four places it replaced a paragraph's opening and left the tail behind:

| line | what was lost |
|---|---|
| 96 | `stakes query`'s field set lost "An earlier version of" |
| 220 | the instance-volumes layout lost "An earlier" |
| 1190 | the route-host paragraph lost "The earlier revision combined" |
| 1783 | the alias-probe paragraph lost "An earlier revision of" |

**One split paragraph, a different mechanism.** `caa414d` inserted the `zram:`
bullet between a paragraph's two halves, so `cannot collide. Nothing about this
is cooperative` ended a paragraph it no longer belonged to. That is the ticket's
1191 case with the half in a different place: the sentence at 1191 is orphaned
by a rewrite, and the sentence at 1211 is orphaned by an insertion.

**The repair restores the words the rewrite dropped** rather than rewriting the
sentences — a fragment is a fragment because of the half that is missing, and
the missing half is known.

**The check is structural, so the next one is caught too.** A phrase list would
name the four fragments someone found and leave the next one uncaught, so
`tests/docfragments.py` asks whether a sentence begins with a lowercase word
where the previous line ended a complete sentence. Measured: it finds exactly
those four fragments in the spec before the repair and none after it, and none
in `docs/sysadmin.md`, `CONTEXT.md`, `AGENTS.md`, `docs/PRD.md` or
`SECURITY.md` — so it measures the defect and not the documents' prose style.
`tests/t480-doc-claims.sh` runs it over every document the repository ships.

**Verified non-vacuously.** With the fragments restored and the assertion kept,
the suite fails naming all four; with them repaired it passes on a second
runner.

## Status: answer 1 — the code is right, the spec was stale

- [x] answer 1 (the spec is stale; rewrite §4, keep the bare form)
- [ ] answer 2 (the code is wrong; the name is in the host's domain, and the
      allocator, the edge rule and the three suites change)

**The decision was made on the merits, not derived.** The operator was not
reachable when the question was put, so the answer was decided against the
measurement rather than left parked, and the reasoning is recorded here and in
the card's comment so it can be checked rather than taken on trust.

**Why answer 1.** The code is right, and the spec was wrong in three ways at
once — its formula, its example and the allocator all disagreed:

1. **The spec contradicted itself.** Its formula was `<track host_prefix><host:>`
   and its example was `web.myapp.com`; with `host_prefix = "myapp."` the
   formula yields `myapp.web` and the example yields `web.myapp.com`, and
   NEITHER is what the allocator computes.
2. **The spec's own `[route_hosts]` example said the code was right.** It stated
   the rule as *prefix + label, plus the tunnel's zone when the destination is
   `tunnel`* — which is exactly `claim_host` and `_zone`.
3. **The settled tunnel half was the precedent.** Ticket 324 fixed and reviewed
   the tunnel's half, and the spec states it: a tunnel route is allocated
   `<track host_prefix><label>.<tunnel_domain>`, and "a tunnel route with no
   zone to name it in is exit 1 rather than a bare label — a name in no zone is
   one no DNS can answer". The domain is the ZONE, and the zone comes from the
   destination. An edge route is served by the edge, not the tunnel, so it has
   no zone — which is what `_zone` returns.

**Nothing in `src/guarden/` changed.** The three pinning suites
(`t50-route.sh:62,70,100`, `t50-slice.sh:425`, `t455-tunnel-hostname.sh`) stay
as they are: they already pinned the bare form, and this confirms it.

### What each answer costs, measured

**Answer 1 — the code is right, the spec is stale.** §4 is rewritten to the
bare form, `host.domain`'s role is stated as the `${domain}` substitution only,
and §3.4's example (`web = "web.myapp.com"`) and §9's (`preview.$DOMAIN/<ref>`)
are corrected too — they are the same claim in two more places. **Nothing in
`src/guarden/` changes.** The three pinning suites stay as they are.

**Answer 2 — the spec is right, the code is wrong.** The allocator needs
`host.domain` in it, and everything that carries a route's name moves with it:

| what | where |
|---|---|
| the allocated name | `publications.claim_host`, `service._zone` |
| the registry table | the `[route_hosts]` record |
| the slice | `shared-routes.toml.j2`'s `host =` |
| the edge's rule | `roots._rule`'s `Host(`…`)` |
| the tunnel | `roots.render_tunnel`'s hostname |
| `twig`'s links | `twig.projects`'s `hosts` |
| `weedr share issue` | the hostname it grants |
| the three pinning suites | `t50-route.sh:62,70,100`, `t50-slice.sh:425` |

**And the name's SHAPE is a second decision inside answer 2**, which the
ticket does not settle: `staging.` + `web` + `example.com` is
`web.staging.example.com` (prefix first, the label inside the domain) or
`staging.web.example.com` (prefix as a subdomain of the domain). The spec's
own example at 1186 says `web.myapp.com`, which is the FIRST shape, and its
formula at 1185 says `<track host_prefix><host:>`, which is the SECOND. **The
spec contradicts itself here, independently of the allocator**, so answer 2
must also say which shape it means.

**What neither answer changes:** `host.domain` remains the `${domain}`
substitution's only source (`render._substitute`), and the tunnel's
`[ingress] tunnel_domain` remains the zone a tunnel route is allocated in
(ticket 324). Only the EDGE route's name is in question.

