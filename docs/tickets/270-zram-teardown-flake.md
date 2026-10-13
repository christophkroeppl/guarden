# 270 — zram teardown: the device survived a converged teardown once

Blockers: none. Found 2026-10-13 during the pinned-alias verification runs.

## What was observed

`t170-zram.sh`, on commit `db48348` (a fresh cut, `--no-cache`), failed its
first `assert_no_zram` — *"zram0's size is 2038956032, so the device is still
there"* — immediately after the "absent means absent" block's
`soil install --apply`, which asserts the phase takes the device down. The
same suite on the same sha passed on a second fresh cut minutes later. So the
phase's teardown converged at least once and did not at least once, on the
same tree.

## Why it is a ticket and not a retry

The phase exits `0` in both runs, which means `_gone` judged true at the
phase's end in both — the device was gone when `soil install --apply`
returned. The suite's assertion seconds later found a device with the
generator's own size (50% of RAM) back. Something re-created it between the
phase's end and the assertion, or `_gone`'s `present()` read raced the
kernel's release.

`_teardown` (zram.py) unlinks the generator conf before its `daemon-reload`,
and `_tear_down` resets and hot-removes with `_await_reset` bounded at 10 s.
The suite is `fresh`, so nothing else ran on that machine. A bounded wait
that expires silently and a `_gone` that reads `/sys` are the two places a
race could live; neither has been instrumented.

## What this ticket wants

Instrument the teardown path — which step the flake lands in (the await, the
hot-remove's return, or a generator re-run) — and either widen the wait
against the observed timing or make the assertion's subject provably
post-convergence. The next occurrence's evidence should be captured before
the fix: run the suite in a loop on one cut and record `disksize`,
`initstate`, the swap table and `journalctl -u systemd-zram-setup@zram0` at
the failure.

## Evidence

- red: `~/.hermes/cache/scratch/pinned-fix-runs.log` (sha `db48348`, runner
  `q-4`, t170-zram.sh: *"zram0's size is 2038956032"*)
- green: `~/.hermes/cache/scratch/zram-recheck.log` (same sha, runner
  `z-recheck`)
