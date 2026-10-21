# A suite runs in a machine; the checkout's own hygiene is a unit test

Ticket 304 carried one ledger line from ticket 266: `tests/t35-env-schema.sh`
was skipped by the VM runner (`HOST_ONLY`) and run by nothing else — no recipe
invoked it, and the justfile mentioned it only in a comment. It was a suite
with no runner: a check that cannot fail, which is the shape this repository
retires elsewhere. The ticket asks where repository-hygiene checks run, not how
this one works.

The decision: **a suite runs in a machine and no allowlist can exempt one; a
claim about the checkout is a unit test, and `just unit` runs it on the
checkout.**

## Status

accepted (2026-10-21) — implemented in `fix/t304-work`.

## What was measured

- **A cut machine cannot answer the question.** `tests/lxc.sh` pushes the
  working tree into the guest, and a linked worktree's `.git` is a *file*
  whose `gitdir:` line names a host path that does not exist there; `git`
  answers 128 for every command. A suite whose subject is the checkout's index
  has no machine that can run it. That is why the allowlist existed, and it is
  the reason the allowlist was the wrong answer: it made the absence quiet
  instead of making the claim findable.
- **The suite's own ignore assertions had stopped measuring the rules.**
  `git check-ignore` does not consider a path that is already in the index, and
  both `.env.schema` and `fixtures/projects/quadlet-app/.guarden/.env.schema`
  are tracked. Measured on the ported assertions before `--no-index` was added:
  deleting `!/.env.schema` from `.gitignore` left both of them **green** — the
  command was answering "this file is tracked", which it would answer whatever
  the patterns said. `check-ignore --no-index` is the flag that makes
  `.gitignore` itself the subject. With it, deleting the negation goes red
  (`the schema is ignored`) and anchoring the unanchored rule at the root goes
  red (`the unanchored negation no longer admits a nested
  .guarden/.env.schema`). Both mutations were run; both are red.

## The decision

1. **A suite is `tests/t[0-9]*.sh`, and every one of them runs in a cut
   machine.** `HOST_ONLY` and `GUARDEN_LXC_HOST_ONLY` are deleted with the
   suite. There is no list that can skip one, so a suite whose subject a
   machine cannot see now fails on the machine rather than disappearing from
   the run, and the reader of a summary can no longer mistake "not selected"
   for "green". Spec §11's sentence *there is no suite that runs outside a
   machine* is enforced by the absence of the mechanism instead of by review.
2. **A claim about the checkout is a unit test** — `tests/test_*.py`, run by
   `just unit` on the checkout. The tier already existed for the manifest and
   registry parsers; this ADR names it and what it may do: it executes no
   guarden program, writes nothing, and drives a command line the way every
   other test does (§11's seam). Reading a file and asking `git` about it is
   not running a program against a host.
3. **`tests/t35-env-schema.sh` is deleted, and its claims live in
   `tests/test_env_schema.py`**: the schema is not ignored (the unanchored
   negation is what admits the fixture repositories' schemas too), it is
   tracked, no declaration line carries a value, no `@sensitive` marker claims
   one, and `varlock` resolves it and is in sync when `varlock` is installed.

## Why not the alternatives

- **Ship `.git` into the cut.** A linked worktree's `.git` is a pointer to a
  host path and does not travel; a copy of the primary repository's metadata
  would put remotes, every other branch and the index inside a machine whose
  whole property is that it carries none, and the cache keys the tree it
  pushes as the tree a suite reads.
- **A `just test-host` recipe that runs the shell suite.** That is a test
  script executed on the development machine, which is the rule the harness
  exists to keep — a development checkout is not a target. `AGENTS.md` states
  the rule against running guarden's programs and host-mutating suites on the
  checkout; the unit tier is neither, and it is not new: `just unit` already
  ran three files that import the parsers directly, and this ADR only states
  the boundary it was already standing behind. A unit test reads the checkout
  and writes nothing.
- **Delete the suite and rule that the claim is not checked.** The
  `.gitignore` negation is the only thing that keeps the schema out of every
  clone, and a pattern that stops firing is silent — the schema resolves
  perfectly and is simply never there. The claim is cheap to keep where it can
  be observed.

## What it costs

- **`just test` says nothing about the schema**, and that is a real gap in what
  a green VM run means: `just unit` is the command that answers, and `just ci`
  runs both. The spec states it where it states the seam.
- **The unit tier gains a test that shells out.** It is still a command-line
  test; it imports nothing from guarden. `varlock` is not a declared
  dependency, so that half is skipped — printed as a skip, not swallowed —
  when the tool is absent, and the checkout assertions run either way.
- **The suite cache still carries the root `.env.schema` in every key** though
  no machine suite reads it. That is the safe direction of an
  over-approximation and it costs one hash; narrowing it would be a change to
  the cache for no claim.

## What this ADR does NOT change

- **No test imports a program's internals**; the manifest and registry
  parsers' exception stands because their failure is invisible from outside.
- **The VM is still the only place a guarden program runs**, and no suite may
  run outside a machine.
- **`tests/lxc.sh` still selects by `tests/t[0-9]*.sh`.** The unit tests are
  not suites, are not cut into a machine, and are not in the runner's
  selection.
