# Optional shared ponds, soft recommendation against per-bed state services

A **pond** is a named shared-state instance — Postgres first, others later — named on the
bed schema with the class prefix swapped: `pond-<env>-<name>` (`pond-production-postgres`,
`pond-staging-postgres`). Ponds are optional: host prep creates none. `weedr pond dig
<name>` creates one — including its own Linux user `pond-<env>-<name>` (linger on,
subuid/subgid, its own quadlet dir, its own data directory), exactly like a bed, so
ponds are separated from each other by a real user boundary — and `weedr pond fill
<bed>` provisions a database and role for a bed, `weedr pond drain <bed>` takes them
away.

Why: N state containers mean N backups, N credential sets to restore, and N ladders where
a snapshot can go wrong. The `pond-production-*` and `pond-staging-*` ponds are the
reference use-case our tests exercise, not something host prep assumes.

Consequences: a pond that owns its subvolume owns its ladder, configured alongside the
subvolume — the default, not a requirement. `weedr` mints one role and one password per
bed and reassigns ownership on restore; restoring a dump brings data, never secrets.
Draining production data is manual only (`weedr pond drain`, with confirmation); preview
databases drain automatically.

The recommendation is soft: prefer a shared pond, but a self-contained bed — a bitcoin
node, say — may own its own service or DB container, subvolume, ladder, and state.
`weedr bed plow --pond <name>` connects a bed's hyphae to a pond.
