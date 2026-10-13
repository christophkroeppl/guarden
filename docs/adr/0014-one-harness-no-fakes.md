# the VM is the harness, and there are no fakes

Accepted 2026-10-01. Supersedes the two-tier split argued in
`docs/tickets/35-trim-fakes.md` ("fakes for speed, the VM for truth"). That argument was
reasonable when it was written and it is wrong now, for a reason nobody had measured: **the fake
tier was not a second harness. It was shadowing the first one.**

## What was actually true

`tests/lib.sh` put `fixtures/bin` first on `PATH` unconditionally, for every suite, in both
tiers, and `tests/lxc.sh` never removed it. The "golden VM" run therefore executed against the
fakes for every suite that did not itself override `PATH` to reach the real tools — 29 of the 34
suites in the run of 2026-10-01. There was one harness, and it was the fake one, answering
questions in a machine whose name says otherwise.

The eleven failures in that same run are the mirror image of this decision, and they are the
argument:

- `fixtures/bin/loginctl` knew exactly one subcommand, `enable-linger`, and answered
  `show-user` with "unknown command" — a subcommand the real `loginctl` has carried since
  systemd 249. The fake's invented vocabulary had been the answer for three suites. It is worth
  being precise about the direction of that error, because the first reading of it is the
  opposite one: the machine was right and the stand-in was wrong.
- `/var/lib/guarden` is owned `root:root` on the machine, where the fake reported `root:guarden`
  and `t20-storage` had been asserting a group ownership that no run had ever produced.
- `t30-list` expected a `warning: IPv6 has been re-enabled` line the fake never emitted.

Every one of those is a fact about the host that the fake tier had been answering instead of.
The five suites that override `PATH` and drive the real tools — the `t20` host-prep tier — are
almost entirely the green ones. The cost of the split was not a slower suite; it was a suite
whose failures were about the fake rather than about guarden.

## The fakes are also a hazard, twice over

Ticket 35 records the first occasion: `fixtures/bin/git` was first on `PATH` in a live shell and
silently returned empty success, and a stretch of work was thrown away on the belief that the
repository was corrupted. It was not corrupted. The commands were lying, successfully.

The second occasion is one line long. Ticket 60's `runuser` fake was written to genuinely run
its command — correctly, since a fake that swallows the invocation asserts nothing — and it ended
in `exec "$@"` with the caller's `PATH`, on a development machine where `/usr/bin/podman`,
`/usr/sbin/useradd`, `/usr/bin/btrfs` and `/usr/sbin/iptables` are all real. Nothing was damaged
and nothing needed root; but the harness had been one careless edit away from doing the real
machine's work with the real tools, and the only thing that caught it was reading the code. No
test in the suite would have. A fake that can reach the real tool is not a test double.

## The decision

**One harness: a throwaway LXD VM cut from a golden snapshot, with the real tools.**
`just test` is it, it is the harness of record, and there is no second tier.

- `fixtures/` is retired. No fake exists, none is added, and **`fixtures/bin` is never on `PATH`** —
  not in a test run, not in a VM run, not in a developer's shell. The regression test ticket 35
  already asks for is the mechanism: it fails if a fake ever reappears on the ambient `PATH`.
- `tests/lib.sh` loses its `export PATH=...fixtures/bin...`. A suite that passes in the VM has
  been running against real tools, and that is now a checkable property rather than a habit.
- **No test asserts on a call log.** The 51 call-log assertions across seven files go with the
  fakes. Each is rewritten as an assertion about the state the call would have produced: the unit
  exists, the snapshot carries the mark, the rule is in `50-services.conf`, the file was not
  created. Where a call had no effect there is no state to assert, and those assertions are
  dropped rather than ported — "the program did not call `apt-get install`" is a weaker claim
  than "no package was installed", and in the cases where it is not weaker, the honest answer is
  that the seam did not exist.

## What this costs, stated rather than discovered

- **Suite time.** Thirty-four suites, a VM cut each, minutes rather than seconds. That is the
  real cost and it is paid on every run. The recovery is `just test-one <name>` — one file, one
  cut — and not a second model of the host.
- **Some assertions genuinely lose their seam.** An argv that produces no observable state cannot
  be asserted in a harness that observes state. The count is small and the ticket names each one;
  where the claim mattered, it is restated as the effect's absence.
- **A faked clock or a faked random source has no replacement here.** If a future ticket needs
  one, it takes the value as an argument or it does not get it. Making time injectable so a fake
  can be unnecessary is the better shape anyway.

## What does not change

The seam is the command line of every program, and a test still asserts exit codes, diagnostic
lines, files that appeared or vanished, and nothing imported. The parsers are still tested
directly. The VM still answers the claims that need a real machine — a rootless container
reaching a dependency by the measured alias, a forwarded port answering from off the box,
nothing unprivileged binding below 1024, a clone of a live snapshot starting and recovering —
because those were never fakes' to prove, and they are now the only tier that has to.

> **Amended 2026-10-13 (ADR-0018):** the alias in that criterion is no longer measured. It is a
> constant derived from the pinned `[network] pasta_options`, and the probe is deleted — podman
> 5.7 refuses `--network pasta:` as root, which is what `soil install` runs as, and the image was
> external. The criterion reads "a rootless container reaching a dependency **by the pinned
> alias**", and it is the only check that exercises the mapping end to end.

The change makes the tree match what it already claimed to be.