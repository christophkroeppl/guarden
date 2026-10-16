# 290 — environment-aware edge targets for `needs:`

Blockers: none. Found 2026-10-16 designing the odoo-btc-bcr staging/production
split. **Today a `needs:` edge is static: it names one provider service, so a
consumer in staging and a consumer in production dial the same database.**

## What happens

```yaml
needs:
  - service: postgres        # logical name
    as: db
    port: 5432
    auth: database
```

`edges.install` records the edge under `edge_key("postgres", 5432, "db")` and
`registry.load("postgres")` resolves the provider by that literal name. There is
no per-environment resolution, so:

```
odoo-btc-bcr-staging   → postgres-production   (staging reads prod data)
odoo-btc-bcr           → postgres-production   (same)
```

The stopgap is a hand-deployed `odoo-btc-bcr-pg-staging`. It works but is manual,
does not scale, and is the kind of fork that rots.

## Why the resolution belongs in the host, not the manifest

The manifest refuses `environment:` and `track:` by name (spec 4, REFUSED_KEYS):
the host decides the environment, and a repository that could name one would be a
second place for it to be wrong. So the logical→concrete mapping cannot live in
the manifest. Options A (an `environment_target:` map on each edge) and C (a
manifest-per-environment `environments:` block) both put environment knowledge in
the repository and are rejected for that reason.

The track table in `/etc/guarden/guarden.toml` is the root-owned, operator-managed
place where environment lives. The mapping goes there.

## What to build

A `[providers]` table in `guarden.toml`, keyed by track, mapping a logical
provider name to the concrete service that serves it in that track:

```toml
[providers.staging]
postgres = "postgres-staging"

[providers.production]
postgres = "postgres-production"
```

`Config.resolve_provider(track, logical)` returns the concrete name, or `logical`
unchanged when there is no mapping — so a manifest that names a full service name
directly keeps working, and a host with no `[providers]` table behaves exactly as
before.

The resolution runs in the mutator and the renderer, at every point a `needs:`
entry is turned into a provider lookup, an edge key, a hostname or a `Wants=`
edge. Both sides resolve identically from the same table, so the key the mutator
writes is the key the renderer reads.

**Status:** ready-for-agent

- [ ] `config.py` parses `[providers.<track>]` (table of string→string) and
      `Config.resolve_provider(track, logical) -> concrete`; identity when unmapped
- [ ] `edges.check` and `edges.install` resolve each edge's provider name against
      the consumer's environment before `registry.load`, and key the edge record
      by the concrete name
- [ ] `render.check_edges` and `render.edge_publications` resolve against
      `context.track.name` / `context.config`, so the lookup key matches the key
      the mutator wrote and the concrete name flows into `AddHost=`, `DB_HOST=`,
      `<AS>_<DB>_HOST` and `Wants=`
- [ ] `edge_publications` returns `(logical, concrete, port)`; `_container_unit`
      uses the concrete name for `AddHost=` and `_environment_file` matches the
      logical name and renders the concrete one
- [ ] spec 3.1 documents `[providers]`; spec 5.3 / 7.3 state the resolution
- [ ] A consumer in staging resolves `postgres` → `postgres-staging`; the same
      manifest in production resolves `postgres` → `postgres-production`; an
      unmapped name is unchanged
