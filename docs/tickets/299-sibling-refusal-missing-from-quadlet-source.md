# 299 — the sibling-name refusal never runs for a quadlet unit source

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457
(verified: check_siblings wired only into _compose_source, render.py:348).

## What happens
`check_siblings` is wired only into `_compose_source`; a `.guarden/quadlet/` source
whose unit carries `Environment=DB_HOST=db` beside `db.container` still renders names
that resolve to nothing (loom overwrites AddHost=), while the new spec §7.3 paragraph
states the rule for "a unit source". The refusal exists but only compose reaches it.

## What to build
Wire the check into _quadlet_source (render.py:372) with the same one-line exit-2
refusal, red-first: a quadlet fixture naming a non-edge sibling must be refused from
`loom check` and `loom render` with nothing written (mirror t400's shapes).
