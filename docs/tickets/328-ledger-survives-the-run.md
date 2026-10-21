# 328 — the run ledger does not survive the run

## What is broken

`tests/lxc.sh` keeps its run ledger at a path created with `mktemp -d`
(`tests/lxc.sh:1218`):

```sh
ledger=$(mktemp -d)/ledger
: >"$ledger" || die "cannot write a run ledger"
```

and its own comment (`tests/lxc.sh:1205`) says the ledger is *"the run's own
record of what happened, and the summary is computed from it rather than from
counters that a caller could set to anything."*

On a long run the directory disappears and every subsequent write fails.
Measured in the full gate run on 2026-10-21:

```
tests/lxc.sh: line 1287: /home/rumlyne/.hermes/cache/scratch/tmp.Ox9ykejPZ6/ledger: No such file or directory
```

repeated once per suite, and at the end:

```
error: cannot read the run's ledger /home/rumlyne/.hermes/cache/scratch/tmp.Ox9ykejPZ6/ledger: [Errno 2] No such file or directory
```

The same diagnostic appears in isolated suite runs (`t334-tree-repair.sh`,
`t80-edges.sh`), so it is not specific to one suite.

## Why it matters

The per-suite `ok` / `FAIL` lines are printed as suites finish and survive.
**The aggregate is not trustworthy**: "N suites: X ran, Y inherited, Z
failures" is derived from the ledger, and a run whose ledger vanished cannot
certify anything about itself. Every claim of the form "the gate is green"
rests on this file.

## What was measured

- Nothing in `tests/lxc.sh` removes the directory: there is no `trap` for it
  and no `rm -rf` of it (`grep -n 'trap|rm -rf|rmdir|mktemp' tests/lxc.sh`
  returns only `trap '_teardown_runner' EXIT INT TERM` at `:1126` and the
  `mktemp` at `:1218`).
- `mktemp -d` resolves under `TMPDIR`, which is
  `/home/rumlyne/.hermes/cache/scratch` — a directory the host prunes.
- Other `tmp.*` directories in that scratch root survive, so this is not a
  blanket sweep of the pattern; a specific fresh directory was removed while
  the run was cutting machines.

The exact remover was not identified. That is deliberate: the fix below does
not depend on naming it.

## The fix

Stop keeping the run's verdict in a directory the harness does not own.

1. Put the ledger at a harness-owned path — under the repo's own ignored
   cache directory, or beside the worktree — not under `mktemp -d`.
2. Assert the ledger is still readable **before** computing the summary, and
   fail loudly if it is not. A run that cannot read its own ledger must not
   print a summary, because the summary is the thing that would be believed.

## Acceptance

- A run whose `TMPDIR` is deleted mid-run still reports its verdict, or fails
  with a diagnostic that names the ledger — never a silent zero.
- A test that removes the ledger directory partway through and asserts the
  run fails loudly rather than reporting `0 failures`. It must be RED against
  today's code (which reports `0 failures` from an unreadable ledger) and
  GREEN after.
- `just test` on a clean checkout is unaffected: the ledger path must not be
  something a fresh clone lacks.

## Not in scope

The pruner itself. This ticket makes the harness independent of it.
