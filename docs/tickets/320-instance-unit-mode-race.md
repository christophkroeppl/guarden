# 320 — a unit file's mode is whichever writer ran last: 0640, then 0700

Blockers: none. Found 2026-10-19 by the two-instance red-first work on
`fix/instance-start-path` (measured: t440's second ingest, then
`…/home/feature\x2fx/.config/containers/systemd/web.container is mode 700,
not 640`).

## What happens

Two writers disagree about every file under `/var/lib/guarden/services/<name>`:

- `units.install` writes quadlet files with `UNIT_MODE = 0o640` as the service
  uid (`units.py:29`, `units.py:145,150`), and `service.create_service`'s
  template copy writes the same mode (`service.py:454`). The suites assert it:
  `t250-verb-split`, `t260-examples` and `t440` all pin `assert_mode … 640`.
- `_make_tree` runs on **every** create and walks the whole tree —
  `for path in [tree, *sorted(tree.rglob("*"))]: conf.set_owner(…);
  os.chmod(path, TREE_MODE)` (`service.py:637,673-674`) — where `TREE_MODE` is
  `0700`, the mode spec §2.1 states for "`/var/lib/guarden/services/<name>`
  and everything under it".

For one service created once, install runs last and 0640 survives. For a
**second instance of the same service** — the case this branch first exercised
— the second create's walk re-modes the FIRST instance's unit files to 0700
without ever reinstalling them, and every later redeploy of instance A flips
them back to 0640. The file's mode depends on which operation ran last, and
`UNIT_MODE` and spec §2.1's row each describe only its own writer.

It is benign for the mechanism (the owner keeps read/write either way, and
podman's generator runs as that same uid — t440 asserts the service user still
reads the declaration), which is why no run has failed on it in production.
It is a defect because two canonical statements disagree, and AGENTS.md's
order of authority requires one of them to change.

## What to build

Decide which mode is the rule — `UNIT_MODE 0640` as a deliberate unit-file
decision, or spec §2.1's `0700` for everything under the tree — then make the
other writer conform (and say so in the spec or an ADR in the same change).
Red-first: t440 already carries both observations — the 0640 pin immediately
after the install that writes it, and readability of the declaration after the
walk that re-modes it.
