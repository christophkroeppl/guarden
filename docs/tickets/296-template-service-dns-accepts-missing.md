# 296 — a template-created service meets the loopback DNS deny on its first pull

Blockers: none. Found 2026-10-19 by an adversarial review of develop 10f7457
(verified: weedr.py:419-421).

## What happens
`_filter_set` returns before `firewall.install` when a record has neither publication
nor edges, and `create_service` (service.py:396-461) triggers no render at all — but
every firewall render emits uid-matched `127.0.0.53:53` accepts for ALL registry uids
(firewall.py:423, rules.py:181-182) above the global `daddr 127.0.0.0/8 jump DROP`
(firewall.py:428). A service created from a template therefore has no DNS accept:
its first `podman pull` on `weedr service start` dies on the deny. The docstring's
"contributes no line to it" claim is false.

## What to build
Make creation/install reach the firewall render for the new uid (or otherwise ensure
the uid-matched stub-resolver accept exists at create time), red-first: create a
template service and assert its uid has the accept above the deny before any start.
