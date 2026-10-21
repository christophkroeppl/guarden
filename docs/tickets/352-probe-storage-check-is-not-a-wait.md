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
