# 262: t50-slice.sh fails silently, and its deny assertion is racy

**Blocked by:** nothing. **Blocks:** nothing today; it makes `just test` red, so it blocks
any release gate that runs the whole suite.

**Status: DONE (2026-10-20) — all three criteria are met, and the way the
second one is met is the substance of this ticket.**

This ticket has been closed twice and opened once, and the history is kept
because the mistake is the subject. The first closure claimed criterion 2 was
met on the strength of a measurement taken on a quiet machine
(`DENY_DROP=0->0`); it was not met, and the closure was wrong. The second
closure was made after the criterion was met properly, with the measurement
that proves it.

- *Criterion 1 — the suite names the command that failed.* **MET.**
  `tests/lib.sh` carries an `ERR` trap that prints
  `error: failed at line <n>: <command> (exit <rc>)`, and
  `tests/t10-failure-messages.sh` asserts the runner's failure text every way a
  gate can read it — `t10-failure-messages.sh: green`.
- *Criterion 2 — the deny assertion cannot be moved by concurrent traffic.*
  **MET.** The defect was real and the fix is in the tree.

  `src/guarden/firewall.py:488` renders `daddr 127.0.0.0/8 jump DROP;` as
  **one rule with no owner match**, in the `guarden-svc` chain. It is a
  **host-wide counter**: any service uid's loopback traffic moves it. So
  neither of the suite's old deny assertions satisfied either half of the
  criterion — `deny_after == deny_before` did not prove the packet it sent
  was the one counted and was not immune to traffic, and
  `other_after > other_before` was unattributable in the other direction.

  The measurement that was taken to close this criterion the first time,
  `STUB_ACCEPT=14->15 DENY_DROP=0->0` and `OTHER_DENY=0->1`, was a **true
  reading of a quiet machine** and was not evidence of soundness. The ticket's
  own history records the same assertion failing under load on the ticket-240
  branch (`0->4` → "the stub was dropped, so the accept is not above the deny"),
  which is the same race in the same place.

  **What replaced it is a fact about the RULES, and traffic cannot move a
  rule.** Three properties, read from **one** snapshot of the live chain — the
  rules the kernel is enforcing, not the file guarden intends:

  1. the single deny on `127.0.0.0/8` exists, and is the chain's **last** rule;
  2. the stub accept **for that service's uid** is rendered **above** that deny;
  3. **no** accept anywhere in the chain matches the whole of `127.0.0.0/8`.

  The stub accept's counter is kept, because that accept names one address,
  one port, owner-matched — so it *is* attributable.

  **The concurrent traffic stays in the suite, so the immunity is measured
  rather than asserted.** Measured in the VM:

  ```
  CONCURRENT_LOOPBACK_TRAFFIC=movable SHARED_DENY=0->1
  OLD_SHAPE_VERDICT='the stub was dropped' BUT_NO_STUB_PACKET_WAS_SENT
  UNDER_CONCURRENT_TRAFFIC deny=9 stub_accept=5 last=9
  ```

  The old shape's wrong verdict is reproduced **deterministically** — the
  count moved by a stranger's one packet, not by anything the suite sent —
  and the rule-based measurement is stable under the same traffic.
- *Criterion 3 — `t50-slice.sh` is green on `develop` with no branch applied.*
  **MET.** `t50-slice.sh: ok`, one machine cut.

The third criterion is the one that was false when this ticket was written: the
suite was red on `develop` itself. It is green now, and the two faults below are
fixed in the tree.

**This ticket is a RECORD now, not a work list** — the work it describes is done,
and the record is kept because the mistake is the subject: a closure that was
wrong on a quiet machine, and then the closure that fixed it, with the
measurement that proves it.

**What to build:** The three things in `## Acceptance` below, in `tests/t50-slice.sh` and
`tests/lib.sh`: the suite must name the command that failed, the deny assertion must prove
the packet it sent is the one counted, and the suite must be green on `develop` with no
branch applied. Read the `## Acceptance` section — it is the work, and it is already
written down.

**What this ticket records:** a defect found while three parallel agents were working
tickets 220, 240 and 261, which could not be diagnosed inside any of them because it is
not any of their bugs. The history is in `## What was found` below; the work is the
`## Acceptance` section, and the two are not the same thing.

## What was found

`tests/t50-slice.sh` is **red on `develop` itself**. Verified by running it in the throwaway
VM from the `develop` worktree with no agent changes applied — it fails identically. Two
agents were spending hours re-running it, each reading the failure as their own regression.

### Fault one — a swallowed newline (fixed, `2f899dd`)

Line 265 read:

```sh
assert_mode /var/lib/guarden/edge/dynamic 2750# **The manager generates it.** ...
```

Bash treats `2750#` as part of the word, so `#` never opens a comment and `assert_mode` was
handed `2750# **The manager generates it.** ...` as its mode argument. Introduced in
`06d79d4` ("test(250): the manager DOES generate the unit"), which swallowed the newline.

### Fault two — a silent death under `set -e`

With fault one fixed, the suite **still fails, printing nothing**. It dies immediately after
the `OTHER_DENY=0->1` echo. `lib.sh` turns on `set -e` so a failed assertion ends the file
where it failed, which is right — but a *bare* command returning nonzero ends it with no
message at all, and the runner then reports `FAIL t50-slice.sh` with no diagnostic anywhere.

**This is the more expensive fault.** A suite that fails loudly costs one run; a suite that
fails silently costs the hours it just cost, because the only visible signal is a `FAIL`
line with nothing under it.

## The red herring, and why it cost what it did

The suite echoes, to stderr, before it fails:

```
STUB=0->1 DENY=0->0
OTHER_DENY=0->1
```

**That line passes all three of its assertions.** `stub 0->1` is the accept taking the
packet; `deny 0->0` is the packet *not* being dropped, which is what that half asserts; and
`OTHER_DENY 0->1` is the deny still refusing a loopback destination other than the stub. It
reads like a failure because `DENY=0->0` looks like "nothing happened", and two agents read
it as the cause and re-ran the suite nine times between them.

If a diagnostic line is going to be mistaken for a failure this easily, it should be on
stdout as a labelled value rather than an unlabelled `DENY=0->0` on stderr, or the assertion
text should be printed next to it.

## A third observation, unresolved

On `develop` the deny counter reads `0->0` and the assertion passes. On the ticket-240
branch at the same line it read `0->4` and failed with:

```
error: the stub was dropped, so the accept is not above the deny
```

One UDP datagram to `127.0.0.53:53` cannot produce four dropped packets. The likely reading
is that the assertion is **racy**: `deny_packets()` sums the counter on a rule that every
loopback packet from that uid touches, so any concurrent traffic from the service user
(systemd-resolved's own retries, a health check) moves it. **This is a hypothesis and was
not tested.** It is recorded here rather than asserted, and it is the first thing to check.

## Acceptance

- The suite names the command that failed. A bare nonzero under `set -e` is either given a
  diagnostic or made explicit, so no future run can fail with an empty stderr.
- The deny assertion either proves the packet it sent is the one counted, or is written so
  that concurrent loopback traffic cannot move the counter under it.
- `t50-slice.sh` is green on `develop` with no branch applied.