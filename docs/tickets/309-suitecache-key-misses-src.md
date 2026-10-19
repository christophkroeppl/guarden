# 309 — suitecache key omits src/guarden/** so inherited greens can be stale for non-gate runs

Blockers: none. Found 2026-10-18 while auditing an inherited-green scare (the key tree
at tests/suitecache.py:20-35 includes tests/lib.sh, fixtures, packages, tools,
templates, pyproject — but not src/guarden/*.py).

## What happens
`tests/lxc.sh run` without --no-cache inherits a suite's green whenever the KEY tree is
unchanged — so a change to src/guarden/ alone does not invalidate cached greens. The
release gate works around it by mandate (--no-cache is "what a release gate uses"), but
everyday runs can report green over untested code, and the workaround's honesty depends
on every human and agent remembering it (one scare already cost a full investigation).

## What to build
Add src/guarden/** (and modules/**, which render templates) to the cache key tree,
red-first: a cache-key unit test — mutate a src file's bytes, assert the key changes;
mutate docs-only, assert it does not. Check the key's cost (hashing the tree per run)
stays bounded; keep --no-cache semantics untouched.
