# 35: trim the fake set, and stop the fakes escaping the harness

**What to build:** Cut the fixture binaries that earn nothing, and make it
impossible for a fake to shadow a real tool outside a test run. Not a
restructuring of the harness — the seam stays the command line and `tests/run.sh`
still globs `tests/t[0-9]*.sh`. This removes dead weight and a real hazard, and
changes nothing about what a test may assert.

**Blocked by:** 10 (harness and program skeletons), 30 (weedr — identities and
configuration)

**Status:** ready-for-agent

- [ ] **Every remaining fake is referenced by a test.** Four are referenced by
      none today and go: `dpkg-query`, `findmnt`, `getent`, `ss`. A fake no test
      names is a fake that only ever runs by accident, via `PATH`.
- [ ] **The trivial stubs are replaced by one shared call-logger.** Eleven
      binaries are 77 bytes each (`apt`, `chattr`, `dpkg`, `ferm`, `git`,
      `iptables`, `podman`, `runuser`, `sudo`, `systemd-creds`, `tar`) and differ
      only in the name they echo. They collapse to a single logging stub
      parameterised by argv[0], so adding a command is a line in a list rather
      than a file. **A fake that only records that it was called asserts nothing**:
      the call log already shows the invocation, so these cost a file each and
      prove nothing.
- [ ] **`snapper` is brought down in size.** At 14.6 kB it is ~40% of all fixture
      code, and it is the single source of the ticket-20/ticket-30 merge
      collision — two tickets extending one `case` statement, twice. Whatever the
      reduction, the existing `tests/t10-snapper-fake.sh` and
      `tests/t10-snapper-canonical.sh` still pass unchanged.
- [ ] **A fake cannot shadow a real tool outside a test run.** Tonight,
      `fixtures/bin/git` was first on `PATH` in a live shell and silently
      no-opped: `git rev-parse`, `git show-ref` and even `git --version` returned
      empty with exit 0. Any process inheriting that environment is affected,
      including agents. The fake directory is entered on `PATH` by `tests/lib.sh`
      for the duration of a test and removed after, and the tests that assert on
      the call log keep working.
- [ ] A regression test fails if a fake reappears on the ambient `PATH`. It must
      not assert the contents of another repo's environment; it asserts the
      property that matters, which is that the harness is the only thing that
      puts a fake on `PATH`.

## Why this is not "just delete some files"

The temptation, given that ticket 140 moves the real proofs into a throwaway
machine, is to argue the fakes are redundant. They are not, and the ticket
records why so the question does not get re-argued later:

- **The fast suite is 37 seconds. A golden-VM round trip is minutes.** They
  answer different questions, and neither substitutes for the other.
- **Fakes assert the contract**: does `soil storage` write the right keys, exit
  the right code, report drift rather than silently succeeding.
- **The VM asserts reality**: ticket 15's claims A, C, F, G and M — the alias is
  the container's default gateway, the connection arrives with the service uid as
  socket owner, a non-granted uid fails — came back **not run** precisely
  because no fake can demonstrate them. Podman 3.4.4 on the development host
  predates `pasta` by four years; the VM is Ubuntu 26.04 and is not the obstacle.
- **The VM can never be the only test.** Waiting minutes to discover a typo'd
  config key is a bad trade for a 37-second suite that catches it immediately.

So: fakes for speed, the VM for truth, and each is answerable only by its own
tier. This ticket trims what is *dead*, and fixes a hazard, and leaves the split
intact.

## The hazard is the real content of this ticket

Everything above is housekeeping. The `PATH` escape is not. A fixture that can
reach outside its harness is a fixture that will eventually make an agent believe
something false, and it did: for a stretch of work, git commands returned empty
success, every check built on them was meaningless, and the repository was
rebuilt from scratch on the belief that it was corrupted. It was not corrupted.
The commands were lying, and the lie was silent and successful.

That is the same failure this repo already records twice — `ir.module.module`
licence values that pass a linter and refuse to install, and an Odoo test run
that reported `0 failed, 0 error(s) of 0 tests` while exiting 0. A tool that
cannot tell you it did nothing is worse than a tool that fails.

**What to build, concretely:** the four unreferenced fakes deleted, the eleven
stubs collapsed to one parameterised logger, `snapper` reduced with its two
existing test files untouched, `fixtures/bin` scoped to the test run, and one
regression test that fails if a fake is ever again on the ambient `PATH`.

**For the tickets after this one:** anything that adds a new fake adds a line to
the list in the shared logger instead of a new file, and nothing in `fixtures/`
may be relied on outside a test run. The golden-VM tier (130, 140) is unaffected
and remains the only thing that can answer ticket 15's eleven.
