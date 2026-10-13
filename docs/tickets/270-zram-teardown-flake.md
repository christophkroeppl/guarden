# 270 — zram teardown: the device came back at the vendor's default size

**Resolved 2026-10-13.** Root cause found, fixed, and verified on a real machine.

## The defect

`soil install --apply` with the `[zram]` table removed took the device down and
then **deleted** `/etc/systemd/zram-generator.conf`. But the package ships
`/usr/lib/systemd/zram-generator.conf`, which enables `[zram0]` at **50% of RAM
or 4GiB, whichever is less**:

```
$ cat /usr/lib/systemd/zram-generator.conf
# * size: 50% of available RAM or 4GiB, whichever is less
[zram0]
```

The generator reads that vendor file whenever the `/etc` file is absent. So the
delete did not take the device away — it **reverted the host to the
distribution's default device**, and the `daemon-reload` at the end of
`_teardown` regenerated `dev-zram0.swap`, which `swap.target` then activated.

That is the flake exactly: the device came back at `2038956032` bytes, which is
`min(3889 MiB / 2, 4096 MiB)` — **50% of that VM's usable RAM**, the vendor
default, not guarden's 25%.

Measured on a cut (probe 3):

```
no /etc config       → units: dev-zram0.swap … ; disksize = 2038956032  (the flake's number)
guarden teardown     → rm /etc conf + daemon-reload → units STILL generated, device re-created
/etc config with     → units: (none); swap.target does nothing; device stays absent
  NO [zram0] section
```

## The fix

`_teardown` **writes a sectionless config** instead of deleting the file
(`zram.teardown_conf()`). An `/etc` file with no `[zram0]` shadows the vendor
section, so the generator produces no unit and the device cannot come back.
`_gone()` now checks the file holds that neutralizing content rather than that
the file is absent. A second, smaller hardening: `_reset_device()` retries
`zramctl --reset` while the kernel still holds the device (a reset right after
`swapoff` can fail `Device or resource busy`), bounded at 5 s with one `error:`
at the end if it truly will not reset.

## Verification

- `zram-verify.log`: after the fix, `disksize=absent` at +0/+2/+5/+10 s, units
  0, swap 0, and **an explicit `swap.target` start leaves the device absent**
  (that start is what re-created it before); a second setup/teardown cycle is
  idempotent.
- `t170-zram.sh` green (`zram-suite-runs2.log`), and the suite's own assertions
  now pin the neutralizing file rather than a missing one.

## Why the ticket said "the phase exits 0 in both runs"

It did not, necessarily: `assert_not_rejected` accepts exit **0 or 1**, so the
suite never distinguished a converged teardown from a drift-reported one. The
premise was an assumption, and the real evidence was the size — which matched
the vendor default, not guarden's.
