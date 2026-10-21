# 316 — a multi-container compose cannot reference its own siblings: klimafit has no working path

Blockers: none. Found 2026-10-19 by the gitops deploy run on e2e-fresh-cinit
(deploy-fresh-gitops-apps.md §3; verbatim refusal below).

**Resolved by ADR-0023.** The rule below is what the ticket asked; the ADR is
what was decided, and this file records the decision and the one place the
ticket's own wording did not match the code.

## What happens
klimafit's compose.yaml is ONE source with three containers (api, worker, nuxt) where
`nuxt` calls `http://api:3000`. The renderer refused it (285's rule, spec 7.3):

```
the service 'nuxt' names its sibling container 'api' as a host in environment
NUXT_API_BASE_INTERNAL ('http://api:3000'), and a name inside one unit source
resolves to nothing: the renderer writes AddHost= only for a declared edge ...
split 'api' into a service of its own and name it under `needs:` ...
```

The refusal is correct per today's spec, but "split api into its own service" is the
wrong demand for a tightly-coupled app trio that ships as one compose and one build:
the three containers DO land on the same podman netns/network reality, and an
intra-source name is resolvable if the renderer says so. The gap is the rule's
missing middle: a name declared INSIDE one unit source (another container key of the
same compose) could get an AddHost pointing at that sibling, exactly like a declared
edge gets one, with no grant surface (it never leaves the source).

Secondary: klimafit also needs a `rustfs-production` edge (`as: secret`), and no
rustfs provider template/registry entry exists on a fresh box — a template gap in
the same family as the e2e rustfs+jellyfin work.

## What to build
Decide from spec 7.3 whether intra-source sibling names may resolve (if yes: the
renderer emits AddHost for sibling container keys of the same source + a test that
pins the boundary — an intra-source name resolves, a name from ANOTHER source still
refuses with 285's line; if no: the refusal must name a real migration for
multi-container apps). Plus a rustfs provider example/registry entry (provides secret)
so the e2e pair has a provider. Red-first with a klimafit-shaped fixture.

## The decision (ADR-0023)

**Yes, an intra-source sibling name resolves.** The renderer writes
`AddHost=<container>:<ingress.alias>` into every unit of the source, and the
manifest's new `siblings:` block says which container and which port it serves:

```yaml
siblings:
  - container: api
    port: 3000
```

The port in the manifest is the **container's own port**. The port the consumer
dials is the **publication** — the loopback port guarden allocated for that
container — and the renderer writes it into the environment file as
`<NAME>_HOST` and `<NAME>_PORT`, next to the edges' variables. The repository
composes its URL from them; the value it writes is not rewritten.

The refusal that remains: **a container of this source that the manifest did not
declare under `siblings:`**, because guarden cannot allocate a publication for a
container whose port it was never told. The diagnostic names the declaration
that fixes it.

**A `rustfs` provider template ships** at
`src/guarden/templates/services/rustfs/`. A template carries no `provides:` —
a template ships quadlet files and no manifest (spec 4) — so the operator writes
the provider's manifest and `weedr service add <name> --from <name>` reconciles
it in, exactly as the postgres provider does.

## The one place the ticket's wording did not match the code

The ticket asked that "a name from ANOTHER source still refuses with 285's line".
**It never did.** 285's rule fired only for a name that *was* a container of the
source — the loop was `for sibling in sorted(declared)`, over the source's own
container keys — and a value naming an external host was never inspected, because
guarden neither knows nor resolves such a name. The rule was about a name guarden
could speak about.

So the boundary that is pinned instead is the one the code actually has, and it is
the sharper one: a name that IS a container of this source and is not declared
under `siblings:` is refused, and the diagnostic carries the remedy. An external
host is the repository's own business and is not refused.

**A refusal whose remedy does not exist is the worst of the three states 285
named**, and the `needs:` remedy 285 gave was one of them: one repository produces
exactly one service, so "split `api` into a service of its own" was not reachable
from the repository that needed it. The new refusal's remedy is reachable from the
same file.

## Files

- `docs/adr/0023-intra-source-sibling-names.md` — the decision.
- `src/guarden/manifest.py` — the `siblings:` block, the `Sibling` type, the
  variable name derivation.
- `src/guarden/render.py` — the publication lookup, the environment rows, the
  `AddHost=` entries, the refusals.
- `src/guarden/compose.py` — the narrowed source check.
- `src/guarden/service.py` — the allocator's wanted set.
- `src/guarden/templates/services/rustfs/` — the provider template.
- `tests/t316-sibling.sh`, `tests/t400-sibling.sh`, `tests/t430-quadlet-sibling.sh` —
  the boundary, pinned three ways.
