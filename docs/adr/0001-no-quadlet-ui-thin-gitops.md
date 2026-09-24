# No third-party quadlet UI; use a thin gitops layer and our own bed layout

We evaluated third-party quadlet management UIs and rejected them. The closest candidate was a FastAPI/SQLite web UI that *generates* quadlet units and manages them via `systemctl --user`. Its database is the source of truth, not git. Units are rewritten wholly from the DB; manual edits are flagged as drift and lost on next edit. There is no drop-in support, no cross-user networking (so no shared Postgres), no staging/preview model, and no btrfs/snapshot awareness.

We decided to keep the good idea (one Linux user per deployment slot, user-scope quadlet dir) and replace the rest with:

- `weedr` as the only privileged mutator (CLI, no UI),
- `hose` as an optional gitops reconciler that calls `weedr`,
- `stakes` for pin accounting,
- `roots` for Traefik config accumulation.

Considered: extending a third-party UI (inherit its beta status and an app DB as source of truth), adopting materia (actively maintained quadlet gitops, but a component/manifest concept layer and a single maintainer), adopting quadit (stale, rootless-only). None of them gave us the bed + pond + pin shape we need.
