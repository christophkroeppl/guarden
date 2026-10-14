# 278 — the agent images are private packages, so a deploy cannot pull them

Blockers: **needs a credential from the operator.** Found 2026-10-14 deploying
`hermes-production`.

## What happens

`ghcr.io/nousresearch/hermes-agent:2026.9.3` — the image guarden's own reference
unit (`next/services/manual/agents/hermes/hermes.container:21`) pins — **cannot be
pulled without authentication**:

```
$ podman pull ghcr.io/nousresearch/hermes-agent:2026.9.3
Error: ... unable to retrieve auth token: invalid username/password: unauthorized
```

Measured against the registry's anonymous token endpoint, with a public control:

```
ghcr.io/token?scope=repository:nousresearch/hermes-agent:pull
  -> {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}

auth.docker.io/token?scope=repository:library/postgres:pull     (control)
  -> {"token":"eyJhbG..."}
```

So it is not a network problem and not a wrong tag: the package is **private**, and
the anonymous pull the deployment path uses is refused by design.

## Why it matters

`deployment.newest/260-agents.md` deploys `hermes-production` and
`zeroclaw-production` as the two agent services, and the standing instruction is
to test them with a provider API key. Neither can be pulled on a fresh host, so
**the agent half of the deployment set cannot be brought up at all** until the
image is reachable. The same applies to whatever `zeroclaw-production` will pin.

## What this ticket wants

One of:

- **A pull credential**, planted as the service's own podman auth
  (`~/.config/containers/auth.json` for the service uid) or a
  `registries.conf` credential helper — the operator holds the token, so this is
  the operator's action, not a repository's.
- **A public image** (publish the package, or an anonymous-pull mirror), which is
  the cleaner answer for a deployment that is meant to be reproducible.
- **A documented build step** — `weedr service build` already exists for a
  repository that builds its own image; if the agent image is meant to be built
  from source on the host, the manifest should say so and the reference unit
  should not pin a registry tag.

Until one of these is chosen, a deploy of `hermes-production` fails at the first
`podman pull`, before any guarden logic runs — so this is not a guarden defect,
it is a missing input, and it is filed here so the deployment's shape is not
mistaken for a guarden failure.
