# 271 — the cut's apt-lock wait: cloud-init holds it past 300s and the suite is skipped

Blockers: none. Found 2026-10-13, three occurrences in one day.

## What happens

`tests/lxc.sh`'s cut waits for apt's locks before handing a machine to a
suite (the wait after `cloud-init status --wait`, added because cloud-init's
own `package_update` can still hold them). Three times on 2026-10-13 the wait
expired with the lock still held:

```
error: gate-f1x still holds the apt lock after 60 checks spread over at
least 300s, or the wait could not measure it (last answer: held); a suite
that runs `soil packages` now may exit 100
error: cannot cut a clean gate-f1x
```

The runner then skips that suite and counts it in the summary's failures,
which is how a both-orders gate of 65 green suites ends with `EXIT=1` and
"1 failures" on each pass.

## The occurrences

- `gate-f12` (contaminated run, forward): skipped `t90-gitops`
- `gate-f14` (clean run, forward): skipped `t90-gitops`
- `gate-f15` (clean run, reverse): skipped `t70-pins`

Each skipped suite was green when re-run alone, and green in the other
pass — so this has never been a guarden defect. It is the harness's
readiness check being wrong about when a machine is ready.

## Why it is a ticket and not a retry

The wait's own message says it cannot distinguish "the lock is held" from
"the wait could not measure it" (`last answer: held`), and nothing records
*what* held the lock — cloud-init's apt, unattended-upgrades, or the
measurement itself. The fix is either a longer/`-o DPkg::Lock::Timeout`
aware wait, or naming the holder in the failure so the next occurrence is
evidence rather than another re-run.

## What this ticket wants

Capture, at the failure: `fuser -v /var/lib/dpkg/lock-frontend` (or
`lsof`), `systemctl status cloud-init.service apt-daily.service
unattended-upgrades.service`, and `/var/log/cloud-init.log`'s last lines.
Then either widen the wait against what was found or make the failure name
the holder. A second option worth weighing: treat a cut failure as an
*infrastructure* outcome with its own summary line, so a both-orders gate
of green suites cannot exit 1 on it.

## Evidence

- `~/.hermes/cache/scratch/gate-final2.log` lines 153-154 (f14) and
  164-165 (f15); `gate-final.log` for the f12 occurrence.
- The re-runs: `gate-hiccup-runs.log` — both suites green on `dc93c32`.
