# 190: cut a machine only for the suites that need one

**What to build:** `just test` currently cuts a fresh LXD machine for **every** suite file — 39
cuts for 39 suites — because `cmd_run`'s default is `--fresh`. Most of that is wasted: a
substantial number of suites relocate guarden's own paths with `GUARDEN_PREFIX` and never touch
the machine's `/etc/guarden`, its users, or its btrfs subvolumes. Give each suite a declaration
of what it needs, and cut only for the ones that need a clean host.

**Blocked by:** 140 (the golden VM harness)

**Status:** ready-for-agent

- [ ] A suite declares whether it needs a clean host, in the file itself rather than in a list
      inside `lxc.sh`. The declaration is part of the suite, so it travels with the suite and a
      new suite cannot forget it
- [ ] **The default is the safe answer.** A suite that does not say anything gets a fresh
      machine. An unstated suite must never silently inherit another suite's system users,
      deleted snapshots or installed packages — that inheritance is the whole reason the
      default is `--fresh` today
- [ ] The renderer suites (`t40-*`, and any others that only drive `loom check` / `loom render`
      against a staged prefix) share one machine; the host-prep, identity, state and credential
      suites keep their own cut. **Count the cuts before and after and put both numbers in the
      ticket's closing note**, because the claim "a third fewer cuts" is only worth making if it
      is measured
- [ ] `--shared` and `--fresh` keep working, and `just test-fresh` keeps meaning "cut per file".
      The new declaration and the two flags must not disagree; if a suite asks to share while
      `--fresh` is given, the flag wins and say so in one line
- [ ] A suite that shares a machine is **proven not to contaminate the next one**, by running the
      shared group in one order and in the reverse order and getting the same result. That is the
      only honest way to claim sharing is sound, and it is cheap
- [ ] The full suite is green before and after, and the wall clock of a full run is recorded
      either side

## Why this is first

It is the cheapest of the three and it needs no golden rebuild. Measured on 2026-10-01, a cut
machine's cloud-init holds apt's locks from 12.5 s to 23.5 s of uptime, and waiting for that took
a full run from about 30 minutes to about 55 — so the cut machinery dominates the clock and the
per-suite cut is the cheapest thing to remove.

## What this ticket does not do

- It does not make a cut cheaper. Ticket 200 does that, and it is the bigger win
- It does not cache results, so an unchanged suite still runs. That is ticket 210
- It does not weaken any suite's claims. A suite that shares a machine must assert exactly what
  it asserted when it had one to itself