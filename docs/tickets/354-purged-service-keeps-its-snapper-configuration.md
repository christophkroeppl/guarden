# 354 — a purged service's snapper configuration survives, and the next suite reusing the name meets it

## What is broken

A suite's `purge` removes the service's tree, `/etc/guarden/services/<name>`, its
creds and its registry entry, and **not** its snapper configuration. The
configuration outlives the tree, under a name another suite reuses.

Measured on 2026-10-21 on one cut from `guarden-golden/base`
(`GUARDEN_LXC_RUNNER=guarden-run-t354a`), pre-change tree at `c92fbc3`, running
`t315-envfile-ref.sh` then `t80-edges.sh` twice:

```
after t315:  envconsumer-preview-feature\x2fx-data  envconsumer-preview-plain-data
             pgprov-envfile-staging-pgdata  root
after t80:   + pgdual-staging-pgdata  pgprov-staging-pgdata
             postgres-production-pgdata  postgres-staging-pgdata
```

`/var/lib/guarden/services`, `/var/lib/guarden/registry` and `/etc/guarden/creds`
were empty at every checkpoint, and **all three runs exited 0**. The leftover is
silent: the suite that creates it has nothing to notice.

## What the next suite meets

Measured in the same guest:

```
snapper -c postgres-staging-pgdata list
IO Error (query default id failed, open failed path:
  /var/lib/guarden/services/postgres-staging/state/pgdata errno:2 (No such file or directory))
-> rc=1

snapper -c postgres-staging-pgdata create-config --fstype=btrfs <dir>
Creating config failed (config already exists).
-> rc=1
```

And on the product's own path, which is worse than a diagnostic:
`snapper.configuration_exists` is a **stat** of `/etc/snapper/configs/<name>`
(`src/guarden/snapper.py:325`), so a leftover *file* means `create-config` is
skipped and `set-config` is run against a configuration snapper does not know.
Measured on a cut whose first `t80` run had left the name behind
(`guarden-run-t354b`, `t80` run 2):

```
error: expected exit 0, got 1
  stderr: error: snapper exited 1: Unknown config.
```

`postgres-staging` is ingested by `tests/t60-gate.sh:86`,
`tests/t100-homepage.sh:166`, `tests/t120-deploy.sh:61` and
`tests/t230-build.sh:90`. `t80-edges.sh` (gate position 114) runs before all of
them under `just test-shared --reverse`, so the failure lands in a suite whose
subject has nothing to do with snapper.

## The decision: the configuration goes first, and the file goes with it

Three measurements, and the order is not a preference in any of them:

1. **With the subvolume gone the verb refuses.** `snapper -c <config>
   delete-config` on a configuration whose tree a purge had already removed:
   `IO Error (query default id failed, open failed path:… errno:2)`, rc=1, and
   the configuration stays. So a tree-first teardown cannot be repaired with the
   verb at all.
2. **The verb stops at the file after a `set-config`.** The product always
   writes the canonical values with `set-config`, and on this snapper (0.10.6,
   ubuntu 26.04) `delete-config` then returns **0**, removes the `.snapshots`
   subtree and the daemon's entry, and **leaves
   `/etc/snapper/configs/<config>`**. Measured four times (`pz-data`, `pc-data`,
   `pd-data`, `pf-data`): file present after `delete-config`, rc=0. Without a
   prior `set-config` the same command removes the file.
3. **Removing the file alone is not enough.** Snapper's daemon keeps naming a
   configuration whose file was removed — `snapper list-configs` still lists it,
   and `create-config` for the name still answers "config already exists"
   (measured on `guarden-run-t354a`; `snapper --no-dbus list-configs` reported
   only `root` and complained `reading config '…' failed`).

So the teardown does both, in this order: **the verb** (which clears the daemon's
knowledge and the read-only `.snapshots` subtree `rm -rf` cannot remove) and then
**the file** (which is what `configuration_exists` reads). Both **before the
tree**, because after it neither works and the leftover is unrepairable.

## The fix

`tests/lib.sh` grows three helpers:

| helper | asks |
|---|---|
| `snapper_configs_of <service>...` | the files in `/etc/snapper/configs` whose `SUBVOLUME` is under one of those service trees, read with `snapper --no-dbus … get-config` (the daemon's `list-configs` named none of seven configurations that existed as files, measured) |
| `remove_snapper_configs <service>...` | the verb, then the file |
| `assert_no_snapper_configs <service>...` | the same question as the promise — the assertion a teardown finishes with, not an assumption |

The four suites that already have a purge call them: `t80-edges.sh`,
`t315-envfile-ref.sh`, `t230-build.sh`, `t317-build-context.sh`. The last two also
stop swallowing a purge that failed (t329's class, left alone there on purpose),
and `t230` additionally purges `postgres-staging`, which it ingests at line 90
and never removed.

## Acceptance, measured

- `t315` → `t80` → `t80` on one cut (`guarden-run-t354d`): **rc=0, 0, 0**, and
  `/etc/snapper/configs` holds `root` after each.
- `t80` → `t315` on one cut — the opposite order — **rc=0, 0**, `root` after each.
- `t80` → `t230` → `t80` → `t230` on one cut (`guarden-run-t354e`), which is the
  pair that shares `postgres-staging`: **rc=0** four times, `root` after each.
- Through the runner on the committed tree, `--no-cache`, runner
  `guarden-run-t354h`: `ok t80-edges.sh`, `ok t315-envfile-ref.sh`,
  `ok t230-build.sh`, `ok t317-build-context.sh`.
- **The assertion is not vacuous**: with `remove_snapper_configs` replaced by `:`
  in the guest, `t80-edges.sh` exited 1 with
  `error: snapper configuration(s) left after the purge: pgdual-staging-pgdata
  pgprov-staging-pgdata postgres-production-pgdata postgres-staging-pgdata` —
  exactly the four its own services created.
- The RED is the pre-change measurement above, taken on the same machine shape.

`guarden-golden` was not provisioned, rebuilt or destroyed; every run used its
own `GUARDEN_LXC_RUNNER`.

## Not in scope, and why

- **`t60-gate.sh`, `t100-homepage.sh`, `t120-deploy.sh` have no teardown at all**
  — not a swallowing one, none. Measured on `guarden-run-t354f`: `t60-gate.sh`
  exited 0 and left `postgres-staging qapp-production qapp-staging
  traefik-production` in `/var/lib/guarden/services`, four registry entries, two
  creds directories and `postgres-staging-pgdata qapp-production-data
  qapp-staging-data` in `/etc/snapper/configs`. Giving three suites a teardown is
  its own change with its own inventory; ticket 355 carries it.
- **The product is not changed.** `weedr service remove` leaves a service's
  snapper configurations to `soil storage` on purpose
  (`tests/t30-remove.sh:102`, asserted on stdout at `:139`), and
  `tests/t20-storage.sh` is where that converge is exercised.
- **A configuration whose subvolume is already gone cannot be made to disappear
  from snapper's view**: the verb refuses (1), and removing the file leaves the
  daemon naming it (3). A machine dirtied by a pre-change run is recut, not
  repaired. No suite can reach that state after this change, because the
  configuration is removed before the tree.
