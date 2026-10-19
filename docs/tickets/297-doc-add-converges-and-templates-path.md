# 297 — two documentation claims contradicted by code (sysadmin add-reconcile, examples README)

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457.

## What happens
1. docs/sysadmin.md:344 says `weedr service add`'s reconcile note "holds for this case
   exactly as it holds for a poke", but `source_hash` is computed only for
   `kind == "poke"` (service.py:224) and `_converged` skips the hash test when it is
   empty (service.py:587): an `add` after an edited routes/ports/compose still answers
   `converged` and installs nothing — the base doc said the OPPOSITE ("it does not
   hold for this case").
2. examples/README.md:8 says the template set is `$GUARDEN_TEMPLATES`, but
   paths.py:115 + service.py:342 resolve `$GUARDEN_TEMPLATES/services` — an operator
   following the README installs one level too high and `create` answers "holds none".

## What to build
Either fix the code to match the docs (add's own hash) or correct the docs to the
code — decide per spec's convergence rules; correct the README path. Red-first where
a test pins the behaviour, doc assertions where they exist.
