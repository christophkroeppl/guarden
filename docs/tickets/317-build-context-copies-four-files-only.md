# 317 — `weedr service build` copies four files into the home, so a source-hungry Containerfile cannot build

Blockers: none. Found 2026-10-19 by the gitops deploy run on e2e-fresh-cinit
(deploy-fresh-gitops-apps.md §4, blocker 1; verbatim error below).

## What happens
The build copies only `.guarden/`, `compose.yaml`, `Containerfile`, `.dockerignore`
into the service home. bases-mcp's Containerfile starts `COPY Cargo.toml Cargo.lock ./`
and the build dies:

```
error: podman build exited 125: ... COPY Cargo.toml Cargo.lock ./: no such file or directory
```

A gitops app that BUILDS its image (rather than pulling one) needs its source in the
build context — today the staged tree has it and the home does not.

## What to build
**The build context is the full staged tree**, honouring the source's `.dockerignore`,
which is already copied. The home stays as-is for runtime; only the build context changes.
The spec now says this — see §6.6, "The build context is the service's own tree, and the
tree is the whole staged source" — so there is no second reading to choose between and no
reason to re-derive it. Do not add a schema/manifest way for the source to name what the
build needs: the whole tree is the context, and a manifest that narrows it is a second
answer to a question the spec has answered.
Red-first: a Containerfile with a COPY outside the four-file set builds green.
