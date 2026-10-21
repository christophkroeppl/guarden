# 352 — the probe cut's storage state is tested once, behind a readiness gate that does not mean "ready"

## What is wrong

`cmd_provision` ends by proving that a cut from the golden carries the converted
storage state. It does that in two steps (`tests/lxc.sh:962-986`): a loop that
waits for the probe to answer `lxc exec … true`, then a single three-condition
test.

The gate does not mean what the test needs. `true` answers as soon as the guest
agent is up; `soil/state`, the `reboot-required` marker and snapper's
configuration on a freshly cut machine settle *after* that. So the test can run
against a machine that is up but not finished, fail, and report a storage
defect that does not exist.

## Measured, 2026-10-21

The golden was deleted and re-provisioned from scratch (its `/tmp` had been
`tmpfs` — it carried no `@tmp` subvolume, and 13 of 128 suites were red on
every cut). The conversion converged:

```
  storage: a reboot is required (attempt 1)
  storage: a reboot is required (attempt 2)
  storage: the conversion converged
```

and then provision failed with:

```
error: a cut from guarden-golden/base does not carry the converged storage state
```

`provision` exited **1**. The golden was fine. Measured immediately afterwards
— on the golden, and on a cut copied from `guarden-golden/base`:

```
/      btrfs  /@
/var   btrfs  /@var
/tmp   btrfs  /@tmp
state = [done]
no reboot marker: OK
snapper -c root get-config → rc=0     (config 'root' present)
```

All three conditions that the failed test checks pass. Both suites that had
been red came back green on fresh cuts:

```
ok   t130-scripts.sh     1 ran, 0 inherited, 0 failures, 1 machines cut
ok   t20-storage.sh      1 ran, 0 inherited, 0 failures, 1 machines cut
```

So the rebuild succeeded and the runner said it had not.

## Why it matters

A false negative here is expensive and misdirecting. It is the *last* step of a
45-60 minute rebuild, it reports a storage defect in the artifact rather than a
race in the check, and the obvious response — delete the golden and rebuild
again — costs another hour and produces the same result. The comment above the
gate already records this exact confusion happening on an earlier occasion;
the `exec true` gate was the attempted fix, and it does not cover the gap it
was aimed at.

## The fix

Make the condition test *be* the wait, rather than testing once after a weaker
signal — the shape `_reboot` already uses with the boot id. Retry the three
conditions on a bounded loop, and only fail when the budget is exhausted. Keep
the two distinct diagnostics: "the probe never answered" and "the probe
answered and its storage is wrong" are different bugs and should not collapse
into one message.

## Acceptance

1. A rebuild on a golden whose conversion has just converged exits **0**, and
   prints `the probe cut carries the converged state`.
2. The suite proves it is not vacuous: with the probe's `soil/state` forced to
   something other than `done`, provision still fails — the retry must not
   become a wait-for-anything.
3. The "did not come up" path still produces its own message when the probe
   genuinely cannot be exec'd.

## Deliberately not in scope

`snapper -c root create-config -f btrfs /` failed mid-conversion with
`IO Error (subvolume is not a btrfs subvolume)` while `/` was still
`subvolid=5, subvol=/` — the btrfs top level rather than `@`. It recovered on a
later phase, so the ordering is load-bearing and only accidentally correct.
That is a separate question about the conversion's phase order and is not fixed
by making this check patient.

## The fix, measured on the branch

**The condition test is the wait.** `tests/probecut.sh` cuts the probe and asks
`tests/probestate.sh` on a bounded wall clock (`GUARDEN_LXC_PROBE_WAIT`, 180 s
unless a caller names another), and the wait's success is the machine's own
evidence line rather than an exit code. The two failures stay apart: a probe that
never answered read nothing, and a probe that answered with the wrong storage is
the snapshot's finding. It is split the way ticket 271 split the apt-lock wait —
the conditions in a file shipped into the machine with `sh -c`, the host half in a
file that a suite can drive — and `probecut.sh` has a `check` verb that waits on a
machine which already exists, which is what makes the wait measurable without a
rebuild.

**The race, caught on the same golden.** A probe cut from `guarden-golden/base`
and polled by the new check:

```
$ tests/probecut.sh cut /snap/bin/lxc guarden-golden/base guarden-probe-t352-g
  storage: the probe answered state=done marker=absent snapper=rc=1 (69s of 180s)
  the probe cut carries the converged state
```

At 69 s the machine answered `lxc exec` — the old gate's whole signal — with
snapper's configuration not yet readable, and it was converged by the next poll.
The old code read that 69-second answer as "ready", tested once, and reported the
storage: the failure this ticket describes, reproduced on the artifact the ticket
says it was not a defect of.

**`provision`, whole, on a copy of the golden.** `lxc copy guarden-golden
guarden-golden-t352chk`, its `base` snapshot deleted, then provision on it:

```
$ GUARDEN_LXC_GOLDEN=guarden-golden-t352chk tests/lxc.sh provision
converting the golden root to btrfs (this reboots it twice)...
  storage: the conversion converged
  the probe cut carries the converged state
provisioned guarden-golden-t352chk on pool guarden-btrfs (snapshot base)
```

exit 0. **A full rebuild was not run, and acceptance item 1 is not claimed as
one.** `guarden-golden` is the shared artifact and a rebuild costs 45-60 minutes
for every other agent on the box, so what ran is provision's whole tail on a
machine that was already converged — the cut and the check included. The phases
only a rebuild has before that point (the `lxc init` from the image, cloud-init's
first boot, the conversion's own reboots) are outside this measurement.

**Not vacuous: a snapshot whose `soil/state` is `migrated`.** A cut was broken
with `printf 'migrated\n' > /var/lib/guarden/soil/state`, stopped, snapshotted as
`broken`, and the same verb was asked to verify a probe cut from it:

```
$ GUARDEN_LXC_PROBE_WAIT=110 tests/probecut.sh cut /snap/bin/lxc guarden-probe-t352-b/broken guarden-probe-t352-d
  storage: the probe answered state=migrated marker=absent snapper=rc=1 (69s of 110s)
  storage: the probe answered state=migrated marker=absent snapper=ok (73s of 110s)
error: a cut from guarden-probe-t352-b/broken does not carry the converged storage state after 112s (last answer: state=migrated marker=absent snapper=ok)
```

exit 1, and only after the whole budget: the retry does not become a
wait-for-anything.

**"Did not come up" from machines that genuinely could not be exec'd.** A stopped
instance:

```
$ GUARDEN_LXC_PROBE_WAIT=6 tests/probecut.sh check /snap/bin/lxc guarden-golden
error: the probe cut did not come up, so its storage state was never read (waited 8s on guarden-golden)
```

and, unplanned, the wedged-agent class `tests/lxc.sh` already records: one cut
answered `Error: LXD VM agent is not currently running` while LXD's own state said
RUNNING, and the check said

```
error: the probe cut did not come up, so its storage state was never read (waited 122s on guarden-probe-t352-b/broken)
```

after which a power cycle had the agent up in 33 s and the same snapshot answered
`state=migrated marker=absent snapper=ok`. Nothing was read, so nothing was
claimed about the snapshot — which is the distinction this ticket asked for.

**The suite.** `tests/t352-probe-cut-storage.sh` runs the shipped conditions on
its own machine — green, then `migrated`, then a present reboot marker, then no
record at all — and pins the host half's shape, which a cut cannot execute:

```
$ just test-one t352-probe-cut-storage
ok   t352-probe-cut-storage.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
```

The suites that pin `tests/lxc.sh`'s own text were re-run because this change
edits it: `t10-` (8 suites, `t10-failure-messages` and `t10-run-ledger` among
them), `t210`, `t211`, `t322-psmisc` and `t15-cutlist` — all green.

The conversion's phase order was not touched, and the `snapper -c root
create-config` finding under "Deliberately not in scope" stands as it was.
