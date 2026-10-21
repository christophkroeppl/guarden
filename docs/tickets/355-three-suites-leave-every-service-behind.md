# 355 — three suites have no teardown, so every service they ingest survives the run

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
| `t60-gate.sh` | none — no `cleanup`, no `EXIT` trap | `postgres-staging:86`, `qapp-production:89`, `qapp-staging:91`, the `gate-traefik` module |
| `t100-homepage.sh` | `trap 'rm -f "$marker"' EXIT` and nothing else | `postgres-staging:166` |
| `t120-deploy.sh` | none — no `cleanup`, no `EXIT` trap | `postgres-staging:61` |

## Why it matters

`--shared` and `--reverse` are the pair `AGENTS.md` says must both be green: the
same suites on one machine, in both orders. These three leave the **whole
service** — tree, registry entry, creds, snapper configuration — so whichever of
them runs first reddens the next one that reuses `postgres-staging`, and the
failure names snapper or a passwd entry rather than the leftover.

Ticket 354 removed the snapper half of this from the four suites that already had
a teardown. These three have no teardown to add it to, which is why they are here
and not there.

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

## Acceptance

- `t60` → `t100` → `t120` on one machine, and the same three in the opposite
  order, all green, with `/var/lib/guarden/services`, `/var/lib/guarden/registry`,
  `/etc/guarden/creds` and `/etc/snapper/configs` (but `root`) empty after each.
- Each suite's own run (`tests/lxc.sh run <name> --no-cache`) still green, so no
  suite lost coverage to its teardown.
- `t100-homepage.sh`'s marker removal keeps working: it is the only cleanup the
  file has, and it is not a service.
