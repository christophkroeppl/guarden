# Environments are explicit; beds and ponds carry track-prefixed names

Every bed declares its environment — `production`, `staging`, `preview`, or `fence` — and
`weedr bed plow` requires `--env`; a git manifest must declare it too. There is no
implicit default, so "which track is this" is never a guess. Names carry the track: bed
users and homes are `bed-<env>-<project>`, ponds take prefix-style names
(`production-postgres`).

A project has one bed per environment, each its own user and folder. Preview is one
shared `bed-preview-<project>` per project, with instances nested per ref under the bed
home, capped at three concurrent refs by default (FIFO eviction, overridable). The
`fence` track is the boundary: `bed-fence-traefik` runs Traefik with ports 80/443 and
safe defaults.

Boot ordering follows the track: production services start first; staging and preview
start only after all production services have started, plus a fixed delay, written by
`weedr` as systemd ordering drop-ins.

Why: an implicit production default turns a forgotten flag into a production deploy, and
one bed per PR multiplies users, homes, and ladders for a single review slot.
Consequences: every command and manifest shows its track, preview eviction is a directory
move inside one bed, and staging pays a fixed delay at boot.
