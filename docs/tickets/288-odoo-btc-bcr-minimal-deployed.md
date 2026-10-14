# 288 — the first odoo-btc-bcr service is deployed and serving

2026-10-14. The minimal first service from `GUARDEN-DEPLOY.md` is deployed, verified
end to end, and serving the Odoo login page.

## What is live

```
20005  odoo-btc-bcr-staging   Odoo 19.0  login HTTP 200  <title>Odoo</title>
                             database selector HTTP 200, root 303 -> /web/login
```

It connects to the **shared** `postgres-production` (`odoo@postgres-production:20000`)
against the `odoo` database, on a `filestore` state volume. The bitcoin stack is
deferred by design — see the three blockers below.

## The end-to-end path, each link measured

1. `weedr service ingest odoo-btc-bcr-staging --from poke odoo-btc-bcr@odbt` creates
   the service (uid 978) and renders `odoo.container`.
2. `loom` allocates `PublishPort=127.0.0.1:20005:8069` from the manifest's `routes:`
   and emits `AddHost=postgres-production:10.0.2.2`.
3. `podman build` produces `localhost/odoo-btc-bcr-odoo:latest` from `Containerfile`.
4. `weedr secret set` plants the credential; the materialiser puts it in podman at
   `/run/secrets/DB_PASSWORD` (**now working** — see ticket 287).
5. The baked-in bridge maps `DB_HOST`/`DB_PORT` → the image's `HOST`/`PORT` and
   points `PASSWORD_FILE` at the secret, then execs the image's own entrypoint,
   which writes `odoo.conf` and `wait-for-psql.py`.
6. Odoo authenticates as the edge-minted role and serves HTTP.

## Three defects fixed to get there

- **The entrypoint path did not exist.** The first version set
  `Entrypoint=["/deploy/guarden-entrypoint.sh"]`; neither the image nor the unit
  contains it (`ls: cannot access '/deploy/': No such file or directory`), so the
  container failed at exec. Fixed by baking it into a `Containerfile` and pointing
  `Entrypoint` at `/usr/local/bin/guarden-entrypoint.sh`. A bind mount is not an
  option — guarden refuses a host path outside the service's own volumes.
- **`USER root` then `USER odoo` in the Containerfile.** `docker.io/odoo:19.0` runs
  non-root, so `RUN chmod` failed with `Operation not permitted` and the build broke.
- **The filestore volume was owned by the service uid, not the image's uid** (ticket
  277 again). Odoo runs as uid 100; the volume had to be chowned through
  `podman unshare` at host uid `subuid_base + 100 - 1` before
  `/var/lib/odoo/sessions` was writable.

## Blockers still standing for the full stack (see GUARDEN-DEPLOY.md)

`build:`/`extends:`/`profiles:` refuse the whole file; a container **cannot reach a
sibling** (285); a consumer gets **one** database and needs three (284); and
`weedr service build` is unimplemented, so image supply is the remaining gap.

## Also found while doing this

- **`weedr service restart` is not implemented** — only `stop` and `start` exist,
  so a restart is two commands.
- **The database was initialized by hand** (`odoo -i base --stop-after-init`) through
  a `podman run` carrying the same env and the same secret, because nothing in
  guarden does it. A first deploy of an Odoo service needs an init step.
