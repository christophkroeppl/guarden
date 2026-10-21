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

- [x] `config.py` parses `[providers.<track>]` (table of string→string) and
      `Config.resolve_provider(track, logical) -> concrete`; identity when unmapped
- [x] `edges.check` and `edges.install` resolve each edge's provider name against
      the consumer's environment before `registry.load`, and key the edge record
      by the concrete name
- [x] `render.check_edges` and `render.edge_publications` resolve against
      `context.track.name` / `context.config`, so the lookup key matches the key
      the mutator wrote and the concrete name flows into `AddHost=`, `DB_HOST=`,
      `<AS>_<DB>_HOST` and `Wants=`
- [x] `edge_publications` returns `(logical, concrete, port)`; `_container_unit`
      uses the concrete name for `AddHost=` and `_environment_file` matches the
      logical name and renders the concrete one
- [x] spec 3.1 documents `[providers]`; spec 5.3 / 7.3 state the resolution
- [x] A consumer in staging resolves `postgres` → `postgres-staging`; the same
      manifest in production resolves `postgres` → `postgres-production`; an
      unmapped name is unchanged

## What was already there, and what was not

The resolution itself landed in `develop` as `7ec3db1` and was never verified
on a machine or closed. What was missing was the tail of it, and the tail is
where the ticket's own checklist pointed:

- **The table validated its values as strings and nothing else.** A key that is
  not a service name can never match a manifest's `needs:` entry, and a value
  that is not one resolves to a service that does not exist — so the consumer is
  refused at the render with a name no provider can be connected to, and the
  operator is hunting a line the diagnostic never describes. A
  `[providers.<track>]` for a track the host does not have is the same defect
  one level up. The override table validates both sides for exactly this
  reason, and this table is the same shape, so it holds the same rule.
- **Spec 3.1 documented the table; spec 5.3 and 7.3 did not state the
  resolution.** §7.3 says the renderer writes `AddHost=<provider-service>` and
  that the name is "the provider's own service name", which is true and
  incomplete: with a logical name in the manifest, the name is the one the
  consumer's track resolves it to, and the section now says so.
- **`tests/test_config_providers.py` was collected by nothing.** It was
  module-level functions with a `__main__` runner, and `just unit` runs
  `unittest discover`, which collects a `TestCase` and nothing else — so the
  five assertions reported "Ran 0 tests" and exited `0`. A green that measured
  nothing.

## The RED and the GREEN, as measured

Both on a real LXD cut, on the tree named, with the same runner.

**RED** — `src/guarden/config.py` reverted to `5566196^`, the tests kept:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290 tests/lxc.sh run t30-parsers --fresh --no-cache
error: expected exit 0, got 1
  stderr: error: an invalid key was accepted
  stderr: error: an invalid value was accepted
  stderr: error: a table for an unknown track was accepted
error: failed at line 16: return 1 (exit 1)
FAIL t30-parsers.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

**GREEN** — the source restored:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290 tests/lxc.sh run t30-parsers --fresh --no-cache
ok   t30-parsers.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

And the suite that owns the behaviour, on the same tree:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290 tests/lxc.sh run t80-edges --fresh --no-cache
ok   t80-edges.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

`tests/t80-edges.sh` is the end-to-end proof of the ticket's own last
acceptance item: one manifest naming `postgres`, deployed into staging and
into production, resolving to `postgres-staging` and `postgres-production` in
the registry key, the `AddHost=`, the `DB_HOST=` and the `Wants=` edge, with
an unmapped name passing through unchanged.

**The unit tests** — `just unit` collects 102 now and 97 before, which is the
five assertions the providers table's file carried and nothing collected
before. The two errors in the run are the `podman`-is-not-installed pair in
`tests/test_creator.py`, and they are identical on `develop`.

