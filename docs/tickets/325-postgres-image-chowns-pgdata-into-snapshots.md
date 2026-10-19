# 325 — a postgres whose data is a guarden state volume cannot start: the image chowns into snapper's .snapshots

Blockers: none. Found 2026-10-19 by the operator's Phase A snapshot-clone testrun
(phase-a-snapshot-clone-testrun.md, finding F1).

## What happens
The postgres image's own entrypoint chowns `$PGDATA` as root, and when `$PGDATA`
is a guarden `state:` volume (a btrfs subvolume with snapper's `.snapshots`
inside it), the chown walks into `.snapshots` — which is read-only — and the
container dies:

    odoo-btc-bcr-pg-production-postgres[251680]: chown: changing ownership of
      '/var/lib/postgresql/data/.snapshots': Operation not permitted

So every postgres service whose data guarden owns a volume for cannot start.
The image also expects `PGDATA` to be a subdirectory it manages, and the
renderer does not set it.

## What to build
The data directory must be a subdirectory of the state volume, not the volume
root: `PGDATA=/var/lib/postgresql/data/pgdata` (or the equivalent the image
documents), with the state volume mounted at the parent. The renderer must
therefore be able to set PGDATA — read spec 3.x and the compose/quadlet
rendering for where an image-specific environment value may come from: a
manifest field, a template, or the image's own convention. The transform step
of Phase A also depends on this (the dump's data dir is the subdir).

Red-first: a postgres service with a `state:` volume starts, and its `.snapshots`
is untouched (the chown never reaches it). This is the same defect class as
the keep-id work's "the image owns its own data" question — the image's
convention wins, and guarden's volume layout has to make room for it.
