# 312 — cloud-init path ends `status: error` (undocumented), and vps clone needs git it never installs

Blockers: none. Found 2026-10-19 by the from-scratch acceptance run
(deploy-verify-fresh-boxes.md findings 6 and 7).

## What happens
1. install.sh exits 75 at each of the two staged btrfs reboots, so a correct cloud-init
   run ends `cloud-init status: error` with "REBOOT now, then re-run" as the last lines
   — measured on e2e-fresh-cinit. The recovery is self-describing inside install.sh's
   banner and template.yaml's own header comment, but README and sysadmin tell a
   cloud-init operator NOTHING about expecting red and re-running; the only
   record of the behaviour is a deployment-audit MD in the operator's cwd.
2. Latent: the vps document's runcmd runs provision.sh, which does `git clone`, while
   the rendered packages block lists no git. Not hit (ubuntu:26.04 ships git) — on an
   image without it the whole cloud-init path stops at the clone with no guarden
   diagnostic.

## Measured correction (2026-10-19, on e2e-fresh-cinit)

**The "twice" in this ticket's title is wrong, and the measured truth is worse for the
operator than "red twice" — it is red ONCE and then silently green.**

cloud-init's `runcmd` runs `once-per-instance`, and cloud-init writes that module's
semaphore **before** the module runs, so a run that FAILED still leaves the marker.
Measured on the box the acceptance run left running:

- boot 1 (07:44–07:47): `scripts_user: FAIL` — the runcmd exited 75; the status.json
  written at 07:47:21 was 875 bytes and carried the error, so `cloud-init status` read
  `status: error`.
- boot 2 (07:52): `scripts_user: SUCCESS (previously ran)` — the marker was already
  there, so cloud-init did **not** re-run the runcmd; the status.json written at
  07:52:16 was 496 bytes and was **clean**.
- boots 3 and 4: the same "previously ran", and `cloud-init status` reads `status: done`
  right now, on a host that only converged because an operator ran the installer by
  hand after each reboot.

The whole log holds **one** `runcmd` execution across four boots.

So the operator-facing contract is: **expect `status: error` on the first boot, re-run
the installer BY HAND after each reboot, and ask `soil --check` — not `cloud-init
status` — whether the host is converged.** A green `cloud-init status` is not a
converged host, and that is the trap: the one command an operator would reach for
says the host is fine while it is not.

The scripts path is a different contract and stays 75/75/0: the operator re-runs the
command three times and the third returns 0. The two must not be conflated, and the
documents now say which is which.

## What to build
1: document the cloud-init contract (README cloud-init section + sysadmin fresh-install,
   cross ticket 311): expect red on the first boot, the exact re-run command, and
   `soil --check` as the convergence answer. Ideally also a guarden-side note in the
   provision template header (docs-side first; a code change only if the template's
   own comment proves insufficient for the next reader). 2: add git to the template's
   packages block (or make provision.sh detect-and-fail with a guarden one-liner) —
   pick from the template's pin discipline (packages are pinned there) and red-first
   in the cloud-init template test if one pins the packages list.

## Closed 2026-10-19 (fix/ticket-wave-a)

1. **The contract is documented in all three places**: README's cloud-init section,
   `docs/sysadmin.md`'s fresh-install section, and the `vps` profile's own template
   header — the template is editable and is the document the operator's machine
   boots, so the contract travels with it. `tests/t480-doc-claims.sh` asserts it,
   including the two wrong claims ("red twice", "done only after the third run")
   being **absent**, so the correction cannot be undone by a later edit.
2. **git is in the substrate package list**, one entry per family, and named in
   spec 6.1's package sentence. A distribution package and not a guard in
   `provision.sh`: the package list is where a host's dependencies are stated, and a
   script that refused to run because the host lacked a tool would be a second list
   of the same thing. The rendered `vps` document carries it, which is the assertion
   the suite makes — against the **rendered** document, not against a copy of the
   list.

The doc-assertion mechanism did not exist before this wave: every other suite asserts
on a machine, and the documents had no keeper. `tests/t480-doc-claims.sh` is it, and
`tests/suitecache.py` gained the seam it needed — a suite names the tree it reads
(`# reads: <path>`) so a doc-assertion suite's green is not inherited over an edited
document.
