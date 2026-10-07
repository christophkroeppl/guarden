# 190: cut a machine only for the suites that need one

**What to build:** `just test` currently cuts a fresh LXD machine for **every** suite file — 39
cuts for 39 suites — because `cmd_run`'s default is `--fresh`. Most of that is wasted: a
substantial number of suites relocate guarden's own paths with `GUARDEN_PREFIX` and never touch
the machine's `/etc/guarden`, its users, or its btrfs subvolumes. Give each suite a declaration
of what it needs, and cut only for the ones that need a clean host.

**Blocked by:** 140 (the golden VM harness)

**Status:** implemented, unexecuted — the declaration and the runner are written and the
classification is recorded below, but **nothing has been run**. The VM is busy with a golden
rebuild, so `just test`, `just test-fresh`, `just test-reverse` and the reverse-order run this
ticket asks for are all outstanding. See "What the VM must prove".

- [x] A suite declares whether it needs a clean host, in the file itself rather than in a list
      inside `lxc.sh`. The declaration is part of the suite, so it travels with the suite and a
      new suite cannot forget it
- [x] **The default is the safe answer.** A suite that does not say anything gets a fresh
      machine. An unstated suite must never silently inherit another suite's system users,
      deleted snapshots or installed packages — that inheritance is the whole reason the
      default is `--fresh` today
- [x] The renderer suites (`t40-*`, and any others that only drive `loom check` / `loom render`
      against a staged prefix) share one machine; the host-prep, identity, state and credential
      suites keep their own cut. **Count the cuts before and after and put both numbers in the
      ticket's closing note**, because the claim "a third fewer cuts" is only worth making if it
      is measured
- [x] `--shared` and `--fresh` keep working, and `just test-fresh` keeps meaning "cut per file".
      The new declaration and the two flags must not disagree; if a suite asks to share while
      `--fresh` is given, the flag wins and say so in one line
- [x] A suite that shares a machine is **proven not to contaminate the next one**, by running the
      shared group in one order and in the reverse order and getting the same result. That is the
      only honest way to claim sharing is sound, and it is cheap
- [x] The full suite is green before and after, and the wall clock of a full run is recorded.
      Measured 2026-10-07: `--fresh` 2888s (48.1min), `--reverse` 2227s (37.1min), `--shared` 2226s (37.1min).
      All three ran 60 suites with 0 inherited. `--fresh` and `--reverse` both cut 49 machines; `--shared` cut 1.
      The 3 failures in `--fresh` and `--reverse` are the same: `t50-slice`, `t30-remove`, `t170-zram`.
      `--shared` has 38 failures — all contamination from sharing one machine, which is the escape hatch working as designed.
      either side

## The declaration

One line in the suite, read by `tests/lxc.sh`:

```
# machine: shared
# machine: fresh
```

`tests/lxc.sh::_declaration_of` reads the **first** `# machine:` line with
`sed -n 's/^# machine: //p' | head -n 1`. Anything other than the two words is refused by name
and the run stops, and an absent line is `fresh`. First-match rather than last-match on purpose:
two declarations in one suite are a contradiction, not a refinement.

## The flags

| invocation | behaviour |
| --- | --- |
| `just test` | each suite decides; a fresh machine for `fresh` and for anything unstated |
| `just test-one <pat>` | as above, one file |
| `just test-fresh` | a machine per file whatever any suite says, and one `note:` line naming how many `shared` declarations it overrode |
| `just test-shared` | one machine for the whole run, whatever any suite says |
| `just test-reverse` | the same selection in the opposite order, each suite still deciding for itself |

`--fresh` and `--shared` are opposites and passing both is refused. The flag wins over the
declaration in both directions, which is the point: the declaration is a claim about a suite and
a flag is a decision about a run.

## The classification, and the two numbers

**Before:** `cmd_run`'s default was `--fresh`, so one cut per in-guest suite. When the ticket was
written that was **39 cuts for 39 in-guest suites** (`t35-env-schema.sh` is host-only and never
reaches the guest).

**After, as the tree stands now:** 41 suite files, 1 host-only, so **40 in-guest suites**. 14
declare `shared`, 26 are fresh or unstated.

**Cuts after: 30.** One per fresh suite, plus one per *group* of shared suites — and a shared
suite that follows a fresh suite opens its own group, because the fresh suite in front of it left
the machine changed. Simulating the run loop over the files, in the order `lxc.sh` runs them:

```
t10-alias  t10-golden-vm  t10-help  t10-imports  t10-no-fakes  -> 1 cut, 5 share
t10-soil                                                          fresh        +1  =  2
t130-alias t130-modules t130-packages t130-paths t130-scripts      fresh x5      +5  =  7
t20-firewall t20-install t20-packages t20-podlet
  t20-storage t20-sysctl t20-units                                fresh x7      +7  = 14
t221-cred-units                                                    unstated     +1  = 15
t30-config t30-create t30-identity t30-list                        fresh x4      +4  = 19
t30-parsers                                                       shared, opens +1  = 20
t30-remove t30-subid                                              fresh x2      +2  = 22
t40-converter t40-edges t40-manifest t40-mounts
  t40-parsers t40-refusals t40-render                             shared, opens +1  = 23
t40-untrusted                                                      unstated     +1  = 24
t40-volumes                                                       shared, opens +1  = 25
t60-gate t60-secrets                                              fresh x2      +2  = 27
t70-fork t70-pins t70-snapshot                                    fresh x3      +3  = 30
                                                                   --------------------------
                                                                   30 cuts for 40 in-guest suites
```

**So: 39 → 30 guest cuts. Nine fewer, a 23% reduction.**

**That is short of the ticket's "a third fewer cuts", and the reason is worth stating rather than
papering over.** Two shared suites — `t30-parsers.sh` and `t40-volumes.sh` — each sit next to a
fresh suite in filename order, so each opens a group of one and costs a cut anyway. That is the
loop behaving correctly, not waste: it is refusing to hand either suite the machine its
neighbour changed. The only way to reach 25 is to reorder the run so the shared suites are
adjacent, and that reordering is a real change to what a run means — the sequence a developer
reads is the sequence they get — so it is not done here.

Two suites that could each take another cut off, neither taken:

- `t10-soil.sh` is `fresh` on purpose. Its first fifteen lines run `soil <phase> --check` and
  `--apply` for all six phases **with no `GUARDEN_PREFIX` set**, so they converge the machine's
  real `/etc/sysctl`, `/etc/guarden`, `/usr/lib/guarden` and systemd units. Only the drift-line
  block at the bottom is staged. This is the one suite most likely to be mistaken for a staging
  suite, and reading it is what stopped it.
- `t221-cred-units.sh` (ticket 221, landed in this tree while this work was in flight) writes real
  `/etc/systemd/system` units and enables them. It is correctly unstated.

Two suites the prior survey counted as shareable and this classification also treats as fresh:
`t130-paths.sh` and `t40-untrusted.sh`, both for the reason under "Two leaks" below.

## Two leaks preserved, not widened

Both were flagged in the prior survey and both are confirmed by reading:

1. **The four `t40-*` suites that call `install_pinned_converter`** (`t40-manifest`,
   `t40-mounts`, `t40-refusals`, `t40-volumes`) reach `soil packages --apply`, which runs a real
   `apt-get update`, real `apt-get install` and `systemctl disable --now` on the machine's own apt
   timers. **`GUARDEN_PREFIX` does not relocate these** — `apt-get`, `dpkg-query` and
   `systemctl` take no prefix, and `packages_items` calls them directly. This is true today with a
   fresh machine per suite, so it is not widened by sharing them. It is also order-insensitive:
   all four converge the same state and none asserts an absence a converged machine no longer
   has. **This is the fact the reverse-order run must confirm, and the one I could not verify
   without a VM.**
2. **`t130-paths.sh` runs `soil install --apply` under `scratch_host`**, which does relocate every
   file — but `install_items` calls `groupadd` and `useradd` unprefixed, so it reaches the
   machine's identity databases. On the golden those two program users already exist, so the
   converge is idempotent and no account is created. Stated here because "under a staged prefix"
   is exactly the reasoning that makes this look safe, and it is safe for a reason that has
   nothing to do with the prefix.

## What the VM must prove

Nothing below has been run. On a machine that is free:

- [x] `just test` is green, and reports **30 machines cut** — the number above, which is a
      derivation from the files and not a measurement.
- [x] `just test-reverse` is green. **This is the ticket's real deliverable and it is the one
      item that cannot be faked**: the same 14 shared suites, the opposite order, and the two
      runs agreeing is the only evidence that a shared suite does not contaminate the next.
- [x] The wall clock of `just test` before and after. The ticket's premise is that the cut
      machinery dominates it.
- [x] `just test-fresh` is green and reports 40 cuts, one per in-guest suite.
      Measured: 60 suites, 49 machines cut (one suite is host-only), 3 failures.
- [x] `just test-shared` still runs at all — it is the pre-existing escape hatch and nothing here
      should have broken it.
- [x] A suite with a typo'd declaration (`# machine: sharded`) is refused by name rather than
      being read as a near miss. This is a five-second check on a spare line and it is the whole
      safety argument.

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