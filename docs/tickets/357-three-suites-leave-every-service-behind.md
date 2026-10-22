# 357 — three suites have no teardown, so every service they ingest survives the run

## What is measured

On one cut from `guarden-golden/base` (2026-10-21,
`GUARDEN_LXC_RUNNER=guarden-run-t354f`), `tests/t60-gate.sh` exited **0** and
left on the machine:

```
/var/lib/guarden/services:  postgres-staging qapp-production qapp-staging traefik-production
/var/lib/guarden/registry:  postgres-staging.toml qapp-production.toml qapp-staging.toml traefik-production.toml
/etc/guarden/creds:         qapp-production qapp-staging
/etc/snapper/configs:       postgres-staging-pgdata qapp-production-data qapp-staging-data root
```

The suite passed. Nothing in it claims to clean up, so nothing reports that it
did not.

## The three suites

| suite | cleanup it has today | what it ingests |
|---|---|---|
| `t60-gate.sh` | none — no `cleanup`, no `EXIT` trap | `postgres-staging:86`, `qapp-production:91`, `qapp-staging:93`, the `gate-traefik` module |
| `t100-homepage.sh` | `trap 'rm -f "$marker"' EXIT` and nothing else | `postgres-staging:166`, `quadlet-app-staging:176` |
| `t120-deploy.sh` | none — no `cleanup`, no `EXIT` trap | `postgres-staging:61`, `qapp-production:97,170`, `qapp-staging:203`, `qapp-preview/feature/login:256`, `qapp-preview:308` |

## Why it matters

`--shared` and `--reverse` are the pair `AGENTS.md` says must both be green: the
same suites on one machine, in both orders. These three leave the **whole
service** — tree, registry entry, creds, snapper configuration — so whichever of
them runs first reddens the next one that reuses `postgres-staging`, and the
failure names snapper or a passwd entry rather than the leftover.

Ticket 354 removed the snapper half of this from the four suites that already had
a teardown. These three have no teardown to add it to, which is why they are here
and not there.

### Measured, on a clean machine, 2026-10-22

Both orders fail. This is not a leftover from an earlier run: the runner VMs were
deleted and the runs repeated from a fresh cut.

**Forward** (`t60`, `t100`, `t120` selected; the runner ordered them
`t100`, `t120`, `t60`):

```
ok   t100-homepage.sh
ok   t120-deploy.sh
FAIL t60-gate.sh
error: //var/lib/guarden/registry/qapp-production.toml names [gate] and should not
error: failed at line 375: return 1 (exit 1)
3 suites: 3 ran, 0 inherited, 1 failures, 1 machines cut
```

`t120-deploy.sh` runs `furrow deploy qapp-production` (`:97`), which writes a
`[gate]` table and `state = "blocked"` into
`/var/lib/guarden/registry/qapp-production.toml`. `t60-gate.sh:103` asserts that
a service that has never been evaluated has **no** `[gate]` table:

```sh
# **A service with no `[gate]` table has never been evaluated.** That is `null` in
# JSON and it is not the same as `ready`: a verdict nobody took is not a passing
# one. The service was created a moment ago and the gate has not run.
assert_file_lacks "$production" "[gate]"
```

The service is the same name in both suites, so the second one inherits the first
one's verdict. The assertion is right and the leftover is what breaks it.

**Reverse** (same three suites, `--reverse`):

```
FAIL t120-deploy.sh
error: expected exit 0, got 1
  stderr: error: quadlet-app-staging claims the route host 'staging.web', and
  qapp-staging already holds it; a route host is allocated and the allocator
  refuses the second claimant
error: failed at line 177: return 1 (exit 1)
FAIL t100-homepage.sh
3 suites: 3 ran, 0 inherited, 2 failures, 1 machines cut
```

The route host is **allocated globally** and a service left by a previous suite
holds it, so the second claimant is refused. This is ticket 330's subject — a
route's recorded name is `<track host_prefix><label>` and the allocator refuses a
second claimant — reached from the other direction: not a naming question, but a
stale claimant.

## What the work is

One teardown per suite, written from that suite's **own inventory** — every name
it creates, not most of them (t329 and t354 both measured what half an inventory
costs) — finishing with the helper t354 added:

```sh
remove_snapper_configs <service>...      # the verb, then the file, before the tree
assert_no_snapper_configs <service>...    # the promise, asserted
```

The open question is per suite and is the reason this is a ticket rather than a
mechanical edit: **which of the names a suite creates is a later assertion in the
same suite still reading?** `t60-gate.sh` reads `qapp-staging`'s creds at
`:244-245` and hashes one of the blobs at `:265-275`, and it re-ingests
`qapp-staging` at `:262` and `:267` — a purge placed where the names are first
created would delete the subject of an assertion three lines later. The teardown
belongs in an `EXIT` trap for that reason, and each suite's list has to be derived
by reading it.

A second question the measurement raises: **`qapp-production` and `qapp-staging`
are the same names in two different suites.** A teardown that removes the service
removes it for whoever runs next on the machine, which is the point — but it also
means the two suites cannot both be "the first to create `qapp-production`" on a
shared machine unless the first one cleans up. The route-host refusal above is
the same fact seen from the allocator's side.

## Acceptance

- `t60` → `t100` → `t120` on one machine, and the same three in the opposite
  order, all green, with `/var/lib/guarden/services`, `/var/lib/guarden/registry`,
  `/etc/guarden/creds` and `/etc/snapper/configs` (but `root`) empty after each.
- Each suite's own run (`tests/lxc.sh run <name> --no-cache`) still green, so no
  suite lost coverage to its teardown.
- `t100-homepage.sh`'s marker removal keeps working: it is the only cleanup the
  file has, and it is not a service.

## What landed, and what each answer costs

One teardown per suite, in an `EXIT` trap, written from that suite's **own
inventory** — every name it creates, and a module's service counts as a name
it creates, because a module installs a service and a service is a tree, a
registry entry, a user and a credential. The trap is the right home for the
reason the ticket gave: `t60` re-ingests `qapp-staging` and hashes its creds
at `:262`–`:275`, so a purge placed where the names are created would delete
the subject of an assertion three lines later.

**The purge mechanism is lifted into `tests/lib.sh` once.** Five suites
carried a local `purge()` — `t80-edges.sh`, `t315-envfile-ref.sh`,
`t230-build.sh`, `t317-build-context.sh` and
`t84-provider-diagnostics-mutator.sh` — and the copies had drifted into three
variants: a full form (`t80`, `t315`), a middle form (`t230`, `t317`) and a
bare removal loop (`t84`). The **full** form is adopted, because the
credential-trigger hold is the fix for the race `t315`'s comment describes.
Each suite keeps its own `cleanup()` and its own inventory list; only the
mechanism is shared, and only the mechanism.

Four defects the first version had, found by an adversarial review and
confirmed by measurement before the fix:

1. **`assert_no_snapper_configs` printed its error and returned 0.** Its two
   `_fail` calls are inside an `if` body and inside a `||` list, so neither
   is the function's last command, and `purge`'s `|| failed=1` was dead code.
   The snapper half of the promise was reported and nothing failed.
2. **`assert_no_service_left` was a machine-wide check inside a per-name
   teardown**, called from a bare pre-run `cleanup`. On a shared machine
   holding a service left by one of the sixty suites that has no teardown at
   all, the three suites died before their own first assertion, naming a
   directory listing rather than the culprit. It takes names now, and the
   pre-run call is `cleanup || true`: it clears and never reports, because a
   leftover that is not this suite's is not this run's failure.
3. **A recursive removal cannot remove a btrfs subvolume**, and it fails
   outright on one carrying a read-only snapshot — the `.snapshots` subtree
   snapper owns, which is inside every `state` volume. The product deletes a
   subvolume with btrfs's own ioctl (`clone.py`, `_remove_clone`), and the
   teardown does the same now, finding the volumes by the layout the tree is
   built in.
4. **`t120`'s queue cleanup named two files by sha** and missed the preview
   instance's request, which is named after the service *and* its escaped ref.

**Measured, on the committed tree, one machine, both orders** (`--shared`,
`--no-cache`, a worktree holding only these three suites):

```
forward:   ok t100-homepage.sh   ok t120-deploy.sh   ok t60-gate.sh
           3 suites: 3 ran, 0 inherited, 0 failures, 1 machines cut
reverse:   ok t60-gate.sh        ok t120-deploy.sh   ok t100-homepage.sh
           3 suites: 3 ran, 0 inherited, 0 failures, 1 machines cut
```

**The assertion is not vacuous.** With the teardown's removal disabled in the
checkout the harness pushes into the cut, the same three suites **fail**, and
they name exactly what survived:

```
error: /var/lib/guarden/services/postgres-staging survived the suite
error: /etc/guarden/creds/qapp-production survived the suite
error: /var/lib/guarden/registry/qapp-staging.toml survived the suite
error: snapper configuration(s) left after the purge: postgres-staging-pgdata
  qapp-production-data qapp-staging-data
FAIL t60-gate.sh
3 suites: 3 ran, 0 inherited, 3 failures, 1 machines cut
```

## Not in scope, and why

- **The other sixty suites still have no teardown.** `t110-previews.sh`,
  `t120-queue.sh`, `t30-create.sh`, `t250-verb-split.sh` and the rest ingest
  services and leave them behind. This ticket is about the three it names,
  and a machine-wide check would make these three fail for a leftover that is
  not theirs — so the check is per name.
- **The `edge` group is left behind.** `weedr module add gate-traefik` creates
  it and nothing removes it. `t20-install.sh` asserts the group is absent,
  and that suite is `fresh`, so it never sees another suite's group; under
  `--shared` it would, and it already fails there for a dozen other reasons.
- **The staged trees are not removed.** `t60`'s `stage_quadlet` and `t120`'s
  `stage_qapp` write the same path, `/var/lib/guarden/staging/qapp/9f2c1ab`,
  and the first one's files survive into the second one's run. The staging
  area is the system's own directory and the poke's tree, not a service's,
  and none of the four directories the acceptance names holds it.
- **The product is not changed.** `weedr service remove` leaves a service's
  snapper configurations to `soil storage` on purpose, and `t20-storage.sh` is
  where that converge is exercised.
