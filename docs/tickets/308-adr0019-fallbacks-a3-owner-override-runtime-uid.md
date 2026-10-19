# 308 — ADR-0019 recorded follow-ups: A3 fallback, owner override, manifest runtime-uid field

Blockers: none (landed as deliberate deferrals during the keep-id implementation).
Carried 2026-10-19 from ADR-0019's Consequences and the fix-round reports.

## What is missing (all three deferred on purpose, none invented early)
1. **A3 subdir-chown fallback**: sanctioned for images whose entrypoint misbehaves
   under keep-id — especially the root-start phase the ADR's measurement kept
   ("a pin decides where a uid lands, not who starts"). Not implemented: the walk
   carve-out (service.py's 0700+chown must skip/alias-aware the declared subdir),
   `.snapshots` skipped (ticket 273's rule), re-chown on rollback/fork (a snapshot
   predating the chown restores the old owner → silent break).
2. **Per-service owner override** (escape hatch for volumes shared by two image uids):
   deferred because overrides.toml's contract is "five tables and nothing else" —
   needs its own spec amendment, not an invented key.
3. **Manifest runtime-uid field** for images with neither USER nor gosu/su-exec
   handoff (the no-self-heal class): declaring the image's runtime uid for MAPPING
   is not changing an in-container uid (operator constraint preserved) — needs spec
   wording + renderer + refusal rules for who may declare it.

## What to build
In this order when a live image needs one: 1 (with the mutation-style test the
store-walk ticket used), then 2 (spec amendment first), then 3. Each red-first.
