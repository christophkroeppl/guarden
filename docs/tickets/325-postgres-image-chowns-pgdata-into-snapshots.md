# 325 — a postgres whose data is a guarden state volume cannot start: the image chowns into snapper's .snapshots

Blockers: none. Found 2026-10-19 by the operator's Phase A snapshot-clone testrun
(phase-a-snapshot-clone-testrun.md, finding F1).

**Shipped 2026-10-21 as ADR-0020's contents mount.** The ticket's own proposed
answer is superseded; the "What to build" section below is kept for the record and
marked as such. See "What was built" at the end.

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

**The defect is not postgres-specific.** The triggering behaviour is the
postgres image's entrypoint, but the cause is structural: a `state` volume's
subvolume root carries snapper's root-owned `.snapshots`, the container is
rootless so its `uid 0` cannot chown it, and so **every** image whose
entrypoint runs `chown -R` over its data directory fails against a `state`
volume — `postgres`, `mariadb`, `mysql` and `elasticsearch` among them. The
fix is therefore in the volume layout and not in the postgres template.

## What to build  (SUPERSEDED — see "What was built")

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

## Why the ticket's answer was not the one shipped

The ticket asks for the renderer to **set `PGDATA`**, and it names the symptom's
trigger — the postgres image. Two things are wrong with that as the answer.

**It is the wrong layer.** `PGDATA` is a postgres-shaped value, and the defect
is not postgres-shaped: any image with a `chown -R` entrypoint hits it. A fix
that sets `PGDATA` leaves `mariadb`, `mysql` and `elasticsearch` broken, and
leaves the next image that chowns its data broken. The fix belongs where the
volume is laid out, and it belongs to the state volume as a class.

**It is the wrong shape for the image.** The postgres image's `PGDATA` default
is `/var/lib/postgresql/data` — the path the repository already mounts the
volume at. Setting `PGDATA=/var/lib/postgresql/data/pgdata` moves the data
*below* the volume root and leaves the volume root itself still mounted, so the
image's `chown -R` still walks the root and still reaches `.snapshots`. It
narrows where the data is; it does not remove the subtree from the image's
view.

**The answer ADR-0020 gives is one level the other way.** The volume's *data*
is one level down inside the subvolume — `state/<vol>/data/` — and THAT is what
the container mounts. The container's data path is the payload, the payload's
sibling is `.snapshots`, and the image never sees it. The image's own default
`PGDATA` then lands inside the payload with no value set at all, so **the
image's convention wins and guarden's layout makes room for it** — which is
the principle the ticket's last paragraph states, applied at the layer where it
holds.

## What was built

**ADR-0020's contents mount, in the volume layout and not in a template.**

- A `state` volume's data lives in `state/<vol>/data/`, one level down inside
  the subvolume, and the container mounts that. The subvolume is still the
  volume — it is what snapper snapshots and what the configuration owns.
- A `bulk` volume is mounted from the subvolume itself: it carries no snapper
  configuration and therefore no `.snapshots` subtree to keep out of the way.
- **No `PGDATA` is set by guarden.** The postgres template's explicit
  `PGDATA` is redundant under this layout and is left alone for now; what
  changed is that the mount target is now the payload, so the image's default
  `PGDATA` is correct on its own.
- **An existing volume whose data is at the root is REFUSED, not migrated.**
  Guarden does not move live data down a level: a move renames data under a
  running process, it cannot skip `.snapshots` without a second rule, and it is
  not atomic across a service's several volumes. The mutator refuses with one
  line naming the service, the volume, the payload directory and the work, and
  changes nothing: the volume starts EMPTY and the operator moves the data
  across deliberately — the same rule the spec already states for a newly
  declared volume.

**Verified on the LXD golden VM** by `tests/t325-pgdata-subdir.sh`, which
pulls the real `postgres:17` image, starts a real rootless container against a
real `state` volume, and asserts that the postgres answers `pg_isready` and
that `.snapshots` is byte-identical (owner, mode, inode) across the start. The
same file asserts the refusal, and that the refusal moved nothing.

**The suite was run RED before the fix**, and it failed for the right reason:
the postgres never became ready, with the image's own chown error in the unit's
log.
