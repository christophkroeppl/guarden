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
  not a name at all can never match a manifest's `needs:` entry, and a value
  that is not a service name resolves to a service that does not exist — so the
  consumer is refused at the render with a name no provider can be connected
  to, and the operator is hunting a line the diagnostic never describes. A
  `[providers.<track>]` for a track the host does not have is the same defect
  one level up.
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

## What the adversarial review found in the change above

A review of the first version of this work returned `NEEDS_IMPROVEMENT` with two
MUST FIX findings, and both were real:

- **The exit codes contradicted the module's own convention.** `config.py`'s
  docstring states the split — a wrong *type* is exit `1`, a well-formed file
  breaking a stated *rule* is exit `2` — and the track table implements it:
  `kind`/`cap`/`fork_from` mistakes raise `GuardenError` with the default code
  (2) and type errors go through `_type_error` (1). The three new refusals all
  used 1, so a name that breaks a rule was reported as a host-state fact. They
  now carry 2.

  A second review then caught the half of this that the first fix left behind:
  the track-not-found case had stayed 1 on the argument that it "is a host fact
  and not a rule the file states", and the spec paragraph written to match said
  the same. That argument is wrong. A `[providers.preprod]` table names a track
  and the file names the tracks, so it is a name in this file that names no
  track — the same shape as a `fork_from` naming no track, which is exit `2`, and
  the two cases now carry one code. The spec and the docstring say so.
- **The spec said the opposite of the code.** It stated that both sides of a row
  are service names and both are validated as such, while the code holds the
  logical name to the pattern alone — and the rationale it gave ("a key that is
  not a service name can never match a manifest's `needs:` entry") was false,
  because the manifest holds that entry to the pattern alone too. A forty-
  character logical provider name is legal in a manifest, and the table that
  maps it must accept it. The section now states the two rules as they are and
  names the exit codes.

The review also raised a **failure mode the refusal introduces**: a host
carrying `[providers.staging]` after `staging` was removed from
`[[environments]]` can no longer load `guarden.toml` at all, so every program
that reads it fails rather than only the ones that wanted the mapping. That is
a deliberate fail-closed choice and the spec says so; it is recorded here
because it is the cost of the rule, not a free strictness.

A second review confirmed both MUST FIXes closed and found that the rule the
first review had refuted had been **moved rather than removed** — it survived
in the function's own docstring, in the test's docstring, and in this ticket,
three copies contradicting the code twenty lines below them. A fourth
paragraph in the spec's `[edge_overrides]` section closed the last gap: that
section stated no name rule at all, so a reader would generalize the
`[providers]` pattern-only rule to the table that takes precedence over it.
The two tables share one key space, the override wins, and the override's
rule is the stricter one — both sides a service name in full. The spec now
says so and says what it costs.

**A third review did not answer.** It was dispatched on the closing commit and
timed out with an empty file — no verdict line and no findings — so it is
recorded as *not run* rather than as an approval. The three questions it was
asked were then settled by reading the tree: the two stale copies are gone and
rewritten (`src/guarden/config.py:453-477` and `tests/t30-parsers.py:413-429`),
the spec's `[edge_overrides]` paragraph states both the rule and the precedence
(`docs/spec.md:517`) and both are true of the code (`edgeresolve.resolve` reads
the override table first, `src/guarden/edgeresolve.py:52-55`), and the test's
expected exit code is named per case against the code path each one exercises
(`tests/t30-parsers.py:493-510` against `src/guarden/config.py:483-512`).

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

**The suites that must not move** — each on its own fresh cut, on the final
tree:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t30-parsers --fresh --no-cache
ok   t30-parsers.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t80-edges --fresh --no-cache
ok   t80-edges.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t40-edges --fresh --no-cache
ok   t40-edges.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t40-render --fresh --no-cache
ok   t40-render.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t20-install --fresh --no-cache
ok   t20-install.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t30-create --fresh --no-cache
ok   t30-create.sh
```

`ruff check src tools/check-deps tests` passes, and the diff adds no comment
lines to the source.

**One run in this series failed and it was not a defect.** A `t80-edges.sh` run
died with exit `129` (SIGHUP) because a foreground run and a background run
shared one runner name — the documented collision, where `_reset` deletes the
instance underneath the other run. Re-run alone on its own runner, the suite
is green, and that is the run quoted above.

## The increment the reviews asked for, and its RED and GREEN

`c6c658c` fixed three of the five places that can name a provider; two were left
on the logical name, and a `[providers.<track>]` for a track the host does not
have was still exit `1`. `4165838` closes both, and the run of `t84` that went
with it found the half of the story that had never been run — ticket 289.

**RED** — `505b110`: the tests, with the source at its pre-fix state.

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290a tests/lxc.sh run t30-parsers --no-cache
error: expected exit 0, got 1
  stderr: error: a table for an unknown track is a rule, so exit 2
error: failed at line 16: return 1 (exit 1)
FAIL t30-parsers.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut

$ GUARDEN_LXC_RUNNER=guarden-run-t290b tests/lxc.sh run t83 --no-cache
error: stderr does not name myapp-staging
error: failed at line 216: return 1 (exit 1)
FAIL t83-provider-diagnostics.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

**The no-allocation assertion is not vacuous.** A suite stops at its first
failure, so that RED never reached the fourth scenario. Reverting only the
`edge_publications` message on the green tree and re-running `t83` fails there:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290m tests/lxc.sh run t83 --no-cache
error: stderr does not name dbprov-staging
error: failed at line 216: return 1 (exit 1)
FAIL t83-provider-diagnostics.sh
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
```

**GREEN, and the suites that must not move** — `31a095b`, the change merged with
`develop` three times as it moved underneath. The last merge brought ticket 318's
basic-auth opt-out, which changes `render.py` in another function, so the
renderer-facing suites were run once more on that tree rather than inherited from
`8d32485`. One run each, on a machine of its own:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t290r tests/lxc.sh run t83 --no-cache
ok   t83-provider-diagnostics.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290v tests/lxc.sh run t40-edges --no-cache
ok   t40-edges.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290w tests/lxc.sh run t84-provider-diagnostics-mutator --no-cache
ok   t84-provider-diagnostics-mutator.sh
$ GUARDEN_LXC_RUNNER=guarden-run-t290x tests/lxc.sh run t80-edges --no-cache
ok   t80-edges.sh
```

`t30-parsers` is the fifth, and it was measured on `14f896a`, an earlier merge:
`git diff 14f896a 31a095b -- src/guarden/config.py` is empty, so the parser suite's
subject did not move between the two trees.

`t40-edges` is on the list because it asserts the self-edge refusal's words, and
it passed with its assertions unchanged: the new wording is a clarification that
still carries the name the operator acts on, not a different answer. `ruff check
src tools/check-deps tests` passes, and no unit assertion moved —
`tests/test_config_providers.py`'s only change is its docstring.

**`t84` is ticket 289's measurement.** Its absent-provider scenario asserted
exit `0` and had never been run: the render the same ingest runs refuses the
edge it recorded, so exit `0` is unreachable and the mutator's warning dies with
the raise. The scenario is gone until 289 decides the ordering, and the suite's
header says so.
