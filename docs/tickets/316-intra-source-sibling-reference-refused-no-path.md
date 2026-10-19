# 316 — a multi-container compose cannot reference its own siblings: klimafit has no working path

Blockers: none. Found 2026-10-19 by the gitops deploy run on e2e-fresh-cinit
(deploy-fresh-gitops-apps.md §3; verbatim refusal below).

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
