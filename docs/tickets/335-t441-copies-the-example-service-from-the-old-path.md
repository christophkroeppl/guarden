# 335 — the t441 suite copies the example service from a path the templates moved away from

Blockers: none. Found 2026-10-20 while verifying ticket 315's change, by running
the `t4*` regression gate and reading the failures rather than the summary.

## What happens

`tests/t441-template-dns.sh` installs the example service the runbook names:

```
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r "$GUARDEN_ROOT/examples/services/vaultwarden" /usr/lib/guarden/templates/services/
```

and it fails with:

```
error: cp: cannot stat '.../examples/services/vaultwarden': No such file or directory
```

**The templates are not in `examples/` any more.** Commit `851920a` (ticket 330)
moved them to `src/guarden/templates/services/`, and the suite was not moved
with them. The file it wants is there:

```
src/guarden/templates/services/vaultwarden.container
```

**This is a stale test, not a product defect.** The product path — the
templates directory the renderer reads — is correct; the suite is copying from
a path that no longer exists. It is a *test* that is red, and it is red for a
reason that has nothing to do with the behaviour it claims to test.

## Why it matters even though it is only a test

**A red suite in the gate is a red gate.** `just test` runs every suite, and
this one fails on develop itself, so every full run reports a failure that
nobody caused and everybody learns to ignore. That is how a real failure gets
missed: the noise is already there, so one more red suite is not noticed.

And the failure is *invisible* in the sense that matters: the suite dies on
the `cp`, before it asserts anything about DNS or templates. The part it was
written to check is not being checked at all.

## What to build

**Fix the suite, not the product.** One of:

- copy from the path the templates now live in (`$GUARDEN_ROOT/src/guarden/templates/services/...`),
  or
- install the templates the way the product installs them, so the suite does
  not reach into the source tree for a path that is not an installation
  contract.

**Whichever you choose, the suite must assert the thing it was written for.**
A suite that dies in its setup asserts nothing, and the failure it *should*
report — a template-created service that does not meet the loopback DNS deny
— is currently never reached.

**Read `docs/spec.md` §6.6 and §7.7 before you change it.** The suite's own
header says which findings it is guarding; those must still be guarded after
the fix.

## Acceptance

- [ ] `t441-template-dns.sh` is green on `develop` with no branch applied, in a
      real machine: `ok   t441-template-dns.sh`.
- [ ] The suite reaches the assertions it was written for — prove it by
      breaking the behaviour it guards and watching the suite fail on THAT
      assertion, not in its setup.
- [ ] The path it copies from is the one the product installs from, or the
      suite installs the templates the product's way. Say which, in the
      commit message.
- [ ] No other suite copies from `examples/` — grep for it and, if another
      suite does the same thing, fix it in the same change rather than
      leaving the next one to fail the same way.
