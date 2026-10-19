# 302 — no suite ever runs `weedr service start` on a created or instanced service

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457.

## What happens
Across all 75 green suites: t250/t260 stop at the registry record, t120's only preview
deploy has no assert_exit (tests/t120-deploy.sh:256 while neighbours do), and nothing
asserts `weedr service start` for a template-created service or for
`<name>/<ref>` — which is exactly why tickets 295 and 296 stayed green.

## What to build
The missing assertions (see 295's test plan): preview start through the real path,
template-service start reaching a firewall render, one suite covering the seam those
two tickets broke.
