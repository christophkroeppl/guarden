# 301 — concurrent `add`s from one source can rmtree the tree loom is reading

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457.

## What happens
`_render_source` stages into `render-source/<source service>` and `shutil.rmtree`s it
per run with NO lock (service.py:787), while deploy locks are keyed by TARGET
(`deploy-<service>`, furrow.py:550-561) and `weedr service add` takes no lock at all:
two concurrent `add`s from one source can delete the staging tree mid-read of the
other's loom run.

## What to build
Give the staging area per-invocation isolation (unique staging dir) or a lock keyed on
the source, red-first where a test can drive two concurrent adds (or a deterministic
simulation of the interleaving — no fake tools).
