# 266: the runner's machine-facing paths have no test tier

**Blocked by:** nothing. **Blocks:** nothing — this is a gap, not a stop.

## What is now asserted, and what is not

Adversarial review (2026-10-12, on `b38145f`/`9997f6b`) rejected a round of
runner diagnostics partly because nothing in `tests/` drives `tests/lxc.sh` at
all. The answer landed in two halves:

- the **failure-line text** moved to `tests/failure_messages.sh`, a pure
  function (`_failure_message <name> <rc> [status]`), and
  `tests/t10-failure-messages.sh` drives it every way a gate can read it —
  the 124/128+n codes, the confirmed and unconfirmed meanings of 1, and the
  plain codes. That is asserted.
- everything **machine-facing** about the runner is still unasserted: the
  guest wrapper that writes `<name> <rc>` and `exit`s with the suite's code,
  the read-back of that word on rc=1, the `fuser`/lock-file guards, the whole
  cut/push/reset path, and the arithmetic that gives a failing suite its
  machine group. This ticket is that residue.

## Why a suite cannot cover it, and what could

A suite runs **inside** the machine the runner cut, and `lxc` does not exist
there; the runner is a host process. So the machine tier cannot reach the
runner by construction — the split is the reason `_failure_message` is a
separate file in the first place.

Observations that exist so far are manual and recorded, not asserted: on
2026-10-12 the wrapper's `cd … || exit 97` path and its `127` path were run
against the golden by hand (97 writes no status word; 127 writes one), and
`timeout --foreground --signal=KILL N sleep M` was measured to exit 124 on
expiry. Each is one machine short of a test.

Options, none chosen:

1. **A host-tier self-test invoking the runner against a throwaway machine**
   (`tests/lxc.sh` has no such mode; `--self-test` would need a machine and a
   deliberately-failing suite, which is a fake suite in everything but name —
   against this repository's rule).
2. **Extract more of the runner behind pure seams** the way the messages
   were: the suite-name → `machine`-group arithmetic and the ledger writes
   are pure once their inputs are parameters.
3. **Leave it, and keep the manual observations in this ticket** so the next
   agent inherits facts rather than re-deriving them.

Whatever is chosen, the claim to close this ticket is: **a change to the
runner's machine-facing paths goes red somewhere in `tests/` when it is
wrong**, the same standard the runner exists to hold the suites to.
