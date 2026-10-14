# 278 — the agent image: found, and this ticket's original claim was wrong

**Closed 2026-10-14, the same day it was filed.** The original claim — "the agent
images are private packages, so a deploy cannot pull them" — was **wrong**, and
the correction is the finding.

## What was actually true

`ghcr.io/nousresearch/hermes-agent:2026.9.3` (the reference unit's tag) does not
exist, and the registry answered `UNAUTHORIZED` for it. I read that as "private
package". It was not: **the image is not on ghcr at all.** It is on Docker Hub:

```
docker.io/nousresearch/hermes-agent        # official, published 2026-10-14
  latest, stable, v0.22.0, v0.22.1, rc.*, *-desktop, *-amd64, *-arm64
```

Pulled and ran on the deploy VM with no credential:

```
$ podman pull docker.io/nousresearch/hermes-agent:v0.22.0   -> ok
User=root  Entrypoint=[/opt/hermes/docker/entrypoint-dispatch.sh]
```

So the deploy path was never blocked by a credential. It was blocked by a **wrong
registry host** in guarden's own reference unit
(`next/services/manual/agents/hermes/hermes.container:21`), which pins a `ghcr.io`
tag that does not exist. A wrong reference looks exactly like a private package
from the outside — both answer `UNAUTHORIZED` — and that is the lesson worth
keeping: **"unauthorized" from a registry does not mean "private"; it means the
repository could not be resolved at all, and the host is the first thing to check.**
The `podman pull` output said so and I read past it: it printed
`Trying to pull ghcr.io/...` and the token failure, and the tag was simply absent
from that registry.

## The corrected reference

```
Image=docker.io/nousresearch/hermes-agent:v0.22.0
```

Pin a version tag (`v0.22.0`), not `latest`/`stable`, per guarden's pinned-artefact
rule. The image's own docs (`hermes-agent.nousresearch.com/docs/user-guide/docker`)
give the runtime shape the deployment needs:

- **The data directory mounts at `/opt/data`**, not `$HOME/.hermes` — the image is
  stateless and keeps config, keys, sessions, skills and memories there. Mounting
  it anywhere else gives a gateway with no config, which starts and serves nothing.
- **`gateway run` is the long-running command**; the default CMD runs the CLI and
  exits. Port **8642** is the gateway's OpenAI-compatible API and health endpoint.
- `gateway run` is **s6-supervised inside the image**, so a container that stays
  up is not by itself evidence that the gateway is serving.
- The HTTP API on 8642 is **opt-in** (`platforms.api_server` in the config), so
  the port answers only once that platform is enabled.

## Verified on the deploy VM

`hermes-production` runs: container up, gateway started under s6 supervision,
`/opt/data` populated (`config.yaml`, `.env`, `SOUL.md`). The published port maps
`127.0.0.1:20003 -> 8642`. The API server platform is not yet enabled, so the port
does not answer — recorded rather than claimed.

## What the ticket still wants

The reference unit in `next/services/manual/agents/hermes/hermes.container:21`
still pins the non-existent `ghcr.io` tag. It should be corrected to the Docker Hub
reference, and `next/services/manual/agents/zeroclaw/` (currently only a `.keep`)
should name its image — `ghcr.io/openclaw/openclaw:2026.9.3` is public and was
pulled successfully, which is the sibling the deployment actually used.
