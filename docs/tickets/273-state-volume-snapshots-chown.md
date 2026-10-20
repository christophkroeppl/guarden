# 273 — a state volume's `.snapshots` breaks any image that chowns its data dir

Blockers: none (the workaround exists; this records the finding). Found
2026-10-13 deploying the first real service on a converged host.

**Status: DECIDED (2026-10-20, operator) — ADR-0020. The guarden-side answer is
the CONTENTS mount: the container never sees snapper's `.snapshots` subtree at
all. The "make `.snapshots` ownable" answer is REFUSED, and the reason is the
isolation boundary — it would hand the service write access to the marks that
protect its own snapshots. The implementation is the work below; the decision
is ADR-0020, and the fallback if the contents mount is not expressible is the
service-side answer, not the ownable `.snapshots`.**

## What happens

`postgres-production` was created, its state volume made, its snapper
configuration written, and its unit rendered correctly:

```
Volume=/var/lib/guarden/services/postgres-production/state/data:/var/lib/postgresql/data
```

`weedr service start` reported `started`, and `db.service` reached `active`,
then **failed within a second**:

```
postgres-production-db[4591]: find: '/var/lib/postgresql/data/.snapshots': Permission denied
postgres-production-db[4591]: chown: changing ownership of '/var/lib/postgresql/data/.snapshots': Operation not permitted
podman: container died …
db.service: Main process exited, code=exited, status=1/FAILURE
```

## Why

A `state` volume is a btrfs subvolume with a snapper configuration, and snapper
puts its own `.snapshots` directory **inside** the subvolume at
`state/data/.snapshots` — `0750 root:root`, measured on the host. The service's
container is rootless: its `uid 0` is the *service* uid via `/etc/subuid`, so
the container's root **cannot** `chown` a directory owned by the real host root.

The official `postgres` image (and many others — `mariadb`, `mysql`,
`elasticsearch`, and any image whose entrypoint runs `chown -R` over its data
directory) does exactly that on startup, and the `chown` fails on the one entry
it cannot own. The container exits `1`.

This is not a race and not a misconfiguration: **any** image that recursively
chowns its data directory will fail against a `state` volume, because the
volume always carries snapper's root-owned subtree.

## The two answers

- **Service-side (immediate, no guarden change):** point the image at a
  subdirectory of the volume that is *not* the volume root, so the recursive
  chown never sees `.snapshots`. For postgres that is `PGDATA=/var/lib/postgresql/data/pgdata`;
  for others the equivalent. The volume still snapshots — the data lives inside
  it, one level down — and the chown targets only the subdirectory.
- **Guarden-side (the real fix):** a state volume's `.snapshots` should be
  traversable and *ownable* by the service user, or the volume should be mounted
  so the container never sees `.snapshots` at all (a bind of the subvolume's
  contents rather than the subvolume, if that is expressible). The second is
  cleaner — snapper's bookkeeping is not the container's business — but it needs
  a decision, because mounting the subvolume's *contents* changes what a
  snapshot of the volume contains.

## What this blocks

Every `state`-volume service whose image chowns its data directory. On the
planned deployment that is at least `postgres-production`, and the vault's
Postgres-backed service if it uses the stock image. The workaround is per-service
and is recorded in each service's manifest.
