# Environments are explicit; beds and ponds carry track-prefixed names

Every bed declares its environment — `production`, `staging`, `preview`, or `fence` — and
`weedr bed plow` requires `--env`; a git manifest must declare it too. There is no
implicit default, so "which track is this" is never a guess. Names carry the track, one
schema for both classes: bed users and homes are `bed-<env>-<name>` — `<name>` is the
project for a project bed, and the workload name otherwise (`traefik` for the fence
bed) — and pond names are `pond-<env>-<name>` (`pond-production-postgres`,
`pond-staging-postgres`): class prefix first, track second.

A project has one bed per environment, each its own user and folder. Preview is one
shared `bed-preview-<project>` per project, with instances nested per ref under the bed
home, capped at three concurrent refs by default (FIFO eviction, overridable). The
`fence` track is the boundary: `bed-fence-traefik` runs Traefik with ports 80/443 and
safe defaults.

Boot ordering follows the track and the dependency chain: the fence track starts first,
then production ponds, then production beds; staging and preview — ponds and beds — start
only after all production services have started, plus a fixed delay. Inside each wave
container dependencies (`After=`, quadlet dependencies) decide the exact order, so a pond
always precedes the beds that consume it. `weedr` writes the ordering as systemd
ordering drop-ins.

Why: an implicit production default turns a forgotten flag into a production deploy, and
one bed per PR multiplies users, homes, and ladders for a single review slot.
Consequences: every command and manifest shows its track, preview eviction is a directory
move inside one bed, and staging pays a fixed delay at boot.
