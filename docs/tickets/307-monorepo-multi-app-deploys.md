# 307 — platform support for deploying multiple apps from one monorepo (LAST priority)

Blockers: operator instruction: only when everything else is done. Created 2026-10-19
(the ticket the operator asked for on 2026-10-18: "We may need to make platform changes
to deploy multiple apps from monorepos like supplements in the near future").

## What happens
One repository, several apps: several compose roots / quadlet sets, several services,
one gitops poke. Today a poke stages one tree and an ingest reads one manifest root —
supplements (or ../daily-dose/main as the superseded test case — operator fallback if
supplements proves too complicated) needs N services from one source tree without N
repositories.

## What to build
Design first (spec/ADR — this changes the poke→ingest contract), then: multi-root
staging, per-app manifest selection, service-per-app registration, source_hash
semantics across the shared tree, edges between the N apps (they should use the
sibling/edge machinery, not loopback hacks). Audits to read first:
deployment-audit-supplements.md, deployment-audit-bases-mcp.md in cwd.
PRIORITY: last in the queue, by operator instruction.
