# 308 — ADR-0019 recorded follow-ups: A3 fallback, owner override, manifest runtime-uid field

Blockers: none (landed as deliberate deferrals during the keep-id implementation).
Carried 2026-10-19 from ADR-0019's Consequences and the fix-round reports.

**Status: item 2 is MERGED (2026-10-22). `overrides.toml` carries an eighth table,
`[ownership] volumes = { "<vol>" = <uid> }`, and it is a grant in exactly the sense the
other seven are (ADR-0021): the manifest names the volume, the admin names the uid, a name
the manifest does not declare is refused, a uid the host does not already have is refused, a
`state` volume is refused, and guarden's own walk applies the owner at the reconcile — never
a chown the container performs. It is HOST-SIDE ownership only: a container cannot act as
the granted uid, so another service's container does not read the volume. The "five tables"
this ticket deferred on was already seven (`[basicauth]`, ADR-0024, landed after it was
written), so `[ownership]` is the eighth and the spec says that.**
— Item 2 was narrowed on 2026-10-22 to host-side ownership: a container cannot act as the
granted uid, so the volume is not shared with another service by this table (ADR-0021).
Items 1 and 3 are NOT decided here; item 3 deserves its own ADR when a live image needs it.

## What is missing (items 1 and 3, both deferred on purpose, none invented early)

- **Item 1 — A3 subdir-chown fallback**: sanctioned for images whose entrypoint misbehaves
  under keep-id — especially the root-start phase the ADR's measurement kept
  ("a pin decides where a uid lands, not who starts"). Not implemented: the walk
  carve-out (service.py's 0700+chown must skip/alias-aware the declared subdir),
  `.snapshots` skipped (ticket 273's rule), re-chown on rollback/fork (a snapshot
  predating the chown restores the old owner → silent break).
- **Item 3 — manifest runtime-uid field** for images with neither USER nor gosu/su-exec
  handoff (the no-self-heal class): declaring the image's runtime uid for MAPPING
  is not changing an in-container uid (operator constraint preserved) — needs spec
  wording + renderer + refusal rules for who may declare it.

## What to build
In this order when a live image needs one: 1 (with the mutation-style test the
store-walk ticket used), then 3. Each red-first. Item 2 is merged (ADR-0021), and its
section of `tests/t277-volume-owner.sh` is the measurement it left behind.
