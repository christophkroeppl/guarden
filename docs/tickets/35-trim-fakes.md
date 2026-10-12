# 35: delete the fakes, and the fake tier with them

**What to build:** Remove `fixtures/` and `tests/run.sh`, take `fixtures/bin` off `PATH` in
`tests/lib.sh`, and rewrite every call-log assertion as an assertion about state. One harness
remains: the throwaway LXD VM with the real tools (ADR-0014).

**Blocked by:** 10 (harness and program skeletons), 30 (weedr — identities and configuration)

**Status:** ready-for-agent

- [ ] **`fixtures/` is deleted**, every binary in it with it. Nothing outside a test referenced
      them and the remaining test files reach the real tools
- [ ] **`tests/lib.sh` no longer puts `fixtures/bin` on `PATH`.** This is the load-bearing line of
      the ticket: it was exported unconditionally for every suite in both tiers, and the LXD
      runner never removed it, so the "real machine" tier was executing against the fakes in 29
      of the 34 suites of the 2026-10-01 run. A suite that passes in the VM must now be a suite
      that ran against real tools, and that is checkable rather than assumed
- [ ] **`tests/run.sh` is deleted** and the `test-fakes` recipe with it, so there is no command
      that runs a suite outside a machine
- [ ] **Every call-log assertion is rewritten as a state assertion, or dropped.** 51 of them
      across seven files (`t70-pins`, `t70-fork`, `t70-snapshot`, `t130-packages`,
      `t40-untrusted`, `t130-scripts`, `t130-modules`). "The unit exists", "the snapshot carries
      the mark", "the rule is in `50-services.conf`", "the file was not created". Where a call
      left no state, the assertion is **dropped rather than ported** — `assert_not_called
      "apt-get install"` becomes "no package was installed", and where that is not the same
      claim, the seam was never there and the honest answer is to say so in the ticket rather
      than to invent a probe
- [ ] **A regression test fails if a fake ever reappears on the ambient `PATH`.** It asserts the
      property that matters — the harness is the only thing that could put one there, and now it
      puts nothing there — and it does not assert the contents of another process's environment
- [ ] **A suite that needed a staged host gets a real one.** `guarden_prefix` and `scratch_host`
      stay for the tests that set up a tree, and a test that genuinely needs root says so rather
      than pretending a prefix is equivalent
- [ ] `just test` is green, and `just test-one <file>` is how a suite is run while working on it

## Why the fakes go, when the previous version of this ticket argued they should stay

The earlier version of this ticket argued for the split on two grounds: the fast suite is 37
seconds and a VM round trip is minutes, and fakes assert the contract while the VM asserts
reality. Both were true and neither survives what happened next, which is recorded here so the
question does not get re-argued a third time.

**The fast tier was not a second harness. It was shadowing the one true harness.**
`tests/lib.sh` exported `PATH="$GUARDEN_ROOT/fixtures/bin:$PATH"` unconditionally, `tests/lxc.sh`
never removed it, and so every suite that did not itself override `PATH` ran against the fakes
*inside the VM*. Twenty-nine of thirty-four. The tree had one harness, and it was answering in a
machine whose name says otherwise.

**The eleven failures of that run were all facts about the fake, and none was a fact about
guarden.** `fixtures/bin/loginctl` knew one subcommand and answered `show-user` with "unknown
command", a subcommand the real `loginctl` has carried since systemd 249. `/var/lib/guarden` is
owned `root:root` on the machine where the fake reported `root:guarden`, and a suite had been
asserting a group ownership no run had ever produced. A drift line the fake never emitted was
expected. Meanwhile the five suites that override `PATH` and drive the real tools are the green
ones: the cost of the split was paid by the tier that was supposed to be the evidence.

**A fake that can reach the real tool is not a test double.** Ticket 35's own first half recorded
the `git` incident — `fixtures/bin/git` first on `PATH` in a live shell, empty success, and a
stretch of work thrown away on the belief that the repository was corrupted. The second occasion
was ticket 60's `runuser` fake, written to genuinely run its command, ending in `exec "$@"` with
the caller's `PATH` on a machine with real `podman`, `useradd`, `btrfs` and `iptables` in
`/usr/bin` and `/usr/sbin`. Nothing needed root and nothing was damaged. No test in the suite
would have caught it; a person reading the code did.

**What this costs, honestly.** Thirty-four suites at one VM cut each is minutes, not seconds, and
that is paid on every run. Some assertions genuinely lose their seam: an argv that produces no
observable state cannot be asserted by a harness that observes state, and the count is small
enough to name. The recovery for the first cost is `just test-one <file>`, not a second model of
the host. The second cost is a real loss and is not papered over.

**For the tickets after this one:** there is no fake to add, and wanting one is the signal to
assert state instead. If a future claim needs a controlled clock, a controlled random source or a
controlled network, the value is taken as an argument or the claim waits — a dependency injected
so a fake is unnecessary is the better shape anyway (ADR-0014).
