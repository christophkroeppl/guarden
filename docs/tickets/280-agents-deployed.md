# 280 — the two agents are deployed and connected to the shared RustFS

2026-10-14. Closes the deployment half of `deployment.newest/260-agents.md` for the
test VM. Six services now run on `guarden-deploy`, all sharing one postgres, one
umami and one rustfs.

## The final shape

```
20000  postgres-production   docker.io/library/postgres:17-alpine   (official, per instruction)
20001  umami-production      ghcr.io/umami-software/umami:postgresql-latest
20002  rustfs-production     docker.io/rustfs/rustfs:latest         (S3 API)
20003  hermes-production     docker.io/nousresearch/hermes-agent:v0.22.0
20004  zeroclaw-production   ghcr.io/openclaw/openclaw:2026.9.3
```

`hermes-production` and `zeroclaw-production` each carry `RUSTFS_ACCESS_KEY`,
`RUSTFS_SECRET_KEY` and a gateway token as `type=env` secrets, and each declares a
`needs:` edge to `rustfs-production`. Verified: hermes resolves the provider
through the edge's `AddHost=rustfs-production:10.0.2.2` and opens a socket to
`http://rustfs-production:20002`; zeroclaw carries the same five variables.

## What the deployment taught (all now in the deploy reference)

- **A `needs:` edge is what makes a provider reachable, not an env var.** Hermes
  carried `RUSTFS_ENDPOINT` pointing at `rustfs-production:9000` and could not
  resolve the name — because it had **no edge**. The edge is what emits
  `AddHost=<provider>:10.0.2.2`; without it the name does not exist. Adding the
  edge made the name resolve and the connection succeed.
- **`as:` must equal the provider's `provides:` kind.** `as: s3` is refused when
  the provider lists `secret` — `klimafit`'s manifest has the same defect and is
  being corrected on its branch. The rendered variables are then `<AS>_HOST` and
  `<AS>_PORT`, so `as: secret` yields `SECRET_HOST`/`SECRET_PORT`, not `S3_*`.
- **The edge's port is the provider's host-side publication, not the container's
  port.** The rendered `SECRET_PORT` is `20002`, not `9000`; a consumer that dials
  `:9000` times out. The endpoint is `http://<provider>:<SECRET_PORT>`.
- **An edge must be installed before it renders.** A first render before
  `service ingest` has allocated the publication fails with *"its registry entry
  names no allocated publication for that edge"* — correctly, since the renderer
  will not guess a loopback port. And re-ingesting to allocate it hits **ticket
  275** (`converged` short-circuits, so the edge never installs); the workaround is
  a full service drop and fresh ingest, which is what 275 exists to remove.
- **Secrets go in through `weedr secret set <service> <KEY>`, not `podman secret
  create`.** The production gate reads guarden's encrypted store
  (`/etc/guarden/creds/<service>/<KEY>.cred`), so a secret planted directly in
  podman leaves the gate reporting *"missing required key"* while `podman secret
  ls` shows it present. The verb also materialises it to the service's podman
  store, which is the only supported path.

## Restart durability

The VM was restarted mid-session (to grow its disk); every service came back with
`weedr service start`, and the RustFS bucket and object written before the restart
were still readable after it — so the state volume is real persistence, which is
the doubt ticket 279's review raised against the earlier S3 round-trip.
