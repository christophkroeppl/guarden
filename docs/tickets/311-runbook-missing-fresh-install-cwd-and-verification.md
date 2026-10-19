# 311 — the operator runbook has no fresh-install section, no cwd, and no way to see a service answer

Blockers: none. Found 2026-10-19 by the from-scratch acceptance run
(deploy-verify-fresh-boxes.md findings 2, 3, 4).

## What happens
- docs/sysadmin.md:281 / examples/README.md:19 give `cp -r examples/services/…` with
  no cwd; it only resolves from the repo root, which on a real host is
  /usr/local/src/guarden — a path the runbook never names.
- The runbook ends at `weedr service start` (docs/sysadmin.md:237-371): grep for
  pg_isready across README/docs/examples = 0 hits, and to prove the postgres example
  answers the operator had to install postgresql-client by hand. No verification
  subsection exists.
- No operator document mentions tools/install.sh: `curl … | sudo bash` lives only in
  the script's own header and exit-75 banner. README.md:57-74 documents the
  phase-by-hand flow; sysadmin.md:33-42 only documents UPDATING an installed host.

## What to build
A fresh-install section in docs/sysadmin.md (canonical curl command, the 75/75/0
three-run contract, pointing at README for the phase-by-hand alternative), an explicit
`cd /usr/local/src/guarden` (or a variable) before the template cp, and a
verification subsection per service example (what to run — pg_isready/psql — and what
a healthy answer looks like; name any client tooling the operator needs). Examples
README cross-referenced. Red-first where doc suites assert (t260 pins the examples).
