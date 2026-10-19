# 312 — cloud-init path ends `status: error` twice by design (undocumented), and vps clone needs git it never installs

Blockers: none. Found 2026-10-19 by the from-scratch acceptance run
(deploy-verify-fresh-boxes.md findings 6 and 7).

## What happens
1. install.sh exits 75 at each of the two staged btrfs reboots, so a correct cloud-init
   run ends `cloud-init status: error` with "REBOOT now, then re-run" as the last lines
   — measured on e2e-fresh-cinit. The recovery is self-describing inside install.sh's
   banner and template.yaml's own header comment, but README and sysadmin tell a
   cloud-init operator NOTHING about expecting red and re-running twice; the only
   record of the two-cycle behaviour is a deployment-audit MD in the operator's cwd.
2. Latent: the vps document's runcmd runs provision.sh, which does `git clone`, while
   the rendered packages block lists no git. Not hit (ubuntu:26.04 ships git) — on an
   image without it the whole cloud-init path stops at the clone with no guarden
   diagnostic.

## What to build
1: document the two-cycle contract (README cloud-init section + sysadmin fresh-install,
   cross ticket 311): expect red twice, the exact re-run command, `cloud-init status`
   returning `done` only after run 3. Ideally also a guarden-side note in the
   provision template header (docs-side first; a code change only if the template's
   own comment proves insufficient for the next reader). 2: add git to the template's
   packages block (or make provision.sh detect-and-fail with a guarden one-liner) —
   pick from the template's pin discipline (packages are pinned there) and red-first
   in the cloud-init template test if one pins the packages list.
