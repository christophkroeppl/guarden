# 295 — instances never receive their render: units.install is never given --instance

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457 (verified
in-tree before filing: service.py:328).

## What happens
`units.install(_render_source(directory), resolved.name)` never passes
`resolved.escaped_ref`, so loom is never given `--instance` (units.py:79-80): the
render lands in the service's shared quadlet dir instead of the instance slot
(units.py:37-41), `units_of(name, escaped_ref)` (service.py:827-831) is empty, and
`weedr service start <name>/<ref>` (weedr.py:724-730) exits 1 — the last step of every
`furrow deploy <svc>/<ref>` (furrow.py:641-642). Because `context.instance` is always
None, render.py:1268 never writes `ref`, so the preview path anchoring merged this week
(roots.py:129-144) never renders on the real pipeline (only furrow's scratch render at
furrow.py:506 passes an instance today).

## What to build
Thread `escaped_ref` through units.install's call site(s), assert the instance path
end to end, and close the sibling gap: tests/t120-deploy.sh:256 has no assert_exit on
its only preview deploy, and NO suite runs `weedr service start <name>/<ref>` — that
gap is why this stayed green across all 75 suites (fold in ticket 264:87's wrong
SHARED slice path: units.py:151-162 writes every slice to SHARED/<service>).
