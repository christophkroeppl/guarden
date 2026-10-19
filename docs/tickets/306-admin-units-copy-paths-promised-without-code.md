# 306 — spec promises a mutator copy into the admin drop-in path; no code implements it

Blockers: none. Found 2026-10-19 by the drop-in plan review (verified: the copy has no
implementation; ADMIN_UNITS is referenced only at service.py:785/1442 and render.py:957).

## What happens
docs/spec.md:161-163 calls `/etc/containers/systemd/users/<uid>/` (via
`services/<name>/units.d/`) "the admin injection point ... the mutator copies from" —
but no code copies anything from units.d. In the same breath spec's mode table
(spec.md:224, "every row ... an implementer must be able to point at") has no row for
this path, service.py:781-784 claims "and nothing inside it", README.md:568-577 says
"nothing in guarden reads or rewrites it" (already false — render.py:943 reads the
drop-ins), and tickets 30-weedr-identity:119-126 / 40-loom-renderer:92-97 pin both
claims. Six documents, two incompatible stories, one missing implementation.

## What to build
Decide and make every document say it: EITHER implement the units.d → admin-path copy
(mutator, root-side, with the mode-table row and owner/mode stated), OR amend spec to
the read-only-admin-path reality render.py already has. Coordinate with the in-flight
keep-id drop-in work (it WRITES to this path for guarden's own file) — the copy and the
generated drop-in must coexist without either writer touching the other's file.
