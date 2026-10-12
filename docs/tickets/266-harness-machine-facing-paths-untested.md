# 266: the runner's machine-facing paths have no test tier

**Blocked by:** nothing. **Blocks:** nothing — this is a gap, not a stop.

## What is now asserted, and what is not

Adversarial review (2026-10-12, on `b38145f`/`9997f6b`) rejected a round of
runner diagnostics partly because nothing in `tests/` drives `tests/lxc.sh` at
all. The answer landed in two halves:

- the **failure-line text** moved to `tests/failure_messages.sh`, a pure
  function (`_failure_message <name> <rc> [status]`), and
  `tests/t10-failure-messages.sh` drives it every way a gate can read it —
  the 124/128+n codes, the confirmed and unconfirmed meanings of 1, the plain
  codes, and the wall value flowing through from `SUITE_TIMEOUT` rather than
  the default alone; a self-inflicted 124 and a code 0 are driven too. The
  suite also greps the pushed runner source for one `_failure_message` call
  site and no inline failure printf (a word-based drift net, not a proof), so
  the extraction cannot silently drift back. That is asserted.
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

Observations that exist are manual and recorded, not asserted:

- **`free` end-to-end.** gate-v10 (63/63, 52 cuts) ran `b38145f` — the word
  loop *without* the poll bound and *without* the lock-file guard — so it is
  evidence that the guest's `free` word is produced and honoured on every cut
  of a full gate, and evidence for nothing else. The round-3 review was right
  to say so; the earlier commit cited it for code gate-v10 did not run. The
  same loop carried t180-firewall-rules run alone beforehand.
- **The poll bound and the guard** were observed end-to-end on the post-fix
  validation runs from `t-runfix` on 2026-10-12 (all `--no-cache`):
  the t10 area — 7 suites over 2 machines — the t90 area (2 over 2) and the
  probe (1 over 1): 10 suites, 5 cuts, all green, zero `error:` lines. A bound
  that wedged would exhaust the wait and fail every cut, and a `--foreground`
  regression would show the same; the round-3 review caught that the earlier
  record cited gate-v10, which ran none of this code.
- **The rc=1 confirmed path, end to end.** A deliberately-failing probe suite
  ran twice from `t-runfix` — once on `4bb91e7`, once after the round-3
  fixes (removed after each; it is not in the tree). Both runs: the guest
  wrote `<name> 1`, the read-back returned it, and the runner printed
  `error: t999-probe-fail.sh exited 1; the suite stopped on an assertion, and
  its own line is above`, under the suite's own two lines. That is the only
  exercise of the branch on a real machine, and a run is not a test.
- **The hand measurements**: `cd … || exit 97` writes no status word and a
  missing suite file exits 127 with one; `timeout --foreground --signal=KILL
  N sleep M` exits 124 on expiry and passes the child's code through
  otherwise (1, 143 and 137 measured).

## The pin block's boundary, measured

`tests/t10-failure-messages.sh` pins the runner's failure text and control
flow by presence: seventeen pinned literals plus two adjacency pins, each
measured to move on its own mutation and no other. Round 12 of the adversarial
review measured the boundary of that approach — edits that keep every literal
(a `|| true` suffix where nothing is end-anchored, a line added after a
capture, an early `return 0`, an `exit 0` inserted before the exit test) and
still make a failing suite read as a pass. The suffix class is closed by the
end-anchors added in response, the named in-place sites are pinned, and the
two adjacency pins close the named instances of the added-statement class; a
residue remains — an edit that keeps every literal and every adjacency — that
no presence check can close, because presence cannot see structure. Closing
it needs executing the runner, which no in-machine suite can do to a host
process, which is why this ticket exists. Option 1 below is that closure; the
deliberately-failing probe it would use has already run twice by hand and
printed exactly the contract the block asserts, including the "stopped on an
assertion" line.

## Accepted residual

The round-3 review walked the spoof surface: a suite — or a leaked background
child — can rewrite `/tmp/guarden-suite-status`, which can turn a real
assertion into "did not confirm". That is mislabeling only: the verdict and
the ledger use `rc` (`return "$rc"`), never the marker, so no spoof reaches a
false pass. Accepted as mislabeling under adversarial input; a nonce the
read-back checked would buy nothing the ledger does not already hold.

The round-4 review walked the other direction: a timed-out suite's guest keeps
running (the 124 line now says so), and its wrapper may write `<name> <rc>`
after the runner has moved on — the next suite's wrapper deletes the file
before it starts, and the marker feeds only the text, so a late word mislabels
at worst and never reaches the return code, the ledger or the cache. Same
acceptance, same reason.

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
