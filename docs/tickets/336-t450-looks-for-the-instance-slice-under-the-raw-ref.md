# 336 — the t450 suite looks for the instance's route slice under the RAW ref, and the ref is escaped

Blockers: none. Found 2026-10-20 while verifying ticket 315's change, by running
the `t4*` regression gate on `develop`'s own tree and reading the failure
instead of the summary.

**This is a STALE TEST, not a product defect.** It was confirmed on `develop`
itself, with a tree carrying none of the change under test. The product is
right; the suite is looking in the wrong directory.

## What happens

`tests/t450-basicauth.sh` ingests a preview and asserts that the instance's own
route slice exists:

```
run weedr service ingest prevapp-preview/feature-a --from poke prevapp@9f2c1ab
assert_exit 0
prevescaped=feature-a
prevslice=$GUARDEN_PREFIX/var/lib/guarden/shared/prevapp-preview/instances/$prevescaped/routes.toml
assert_file_exists "$prevslice"
```

and it fails with:

```
error: //var/lib/guarden/shared/prevapp-preview/instances/feature-a/routes.toml did not appear
error: failed at line 254: return 1 (exit 1)
FAIL t450-basicauth.sh
```

**`prevescaped=feature-a` is the bug.** The variable is named "escaped" and
holds the RAW ref. The instance's directory is named by the **escaped** ref
(spec 5.2), and `systemd_escape` escapes the `-`:

```
_systemd_SAFE = set("A-Za-z0-9_.:")     # src/guarden/names.py:149

systemd_escape('feature-a')  ->  'feature\x2da'
systemd_escape('feature/x')  ->  'feature\x2fx'
systemd_escape('feature-x')  ->  'feature\x2dx'
```

So the slice is at `shared/prevapp-preview/instances/feature\x2da/routes.toml`
and the suite looks for `.../feature-a/routes.toml`. **The file is written; the
suite is reading the wrong name.**

**Two other suites get it right, which is what settles it:**

- `tests/t440-instance-start.sh:59` — `escaped='feature\x2fx'`, and
  `slice_a="/var/lib/guarden/shared/routed-preview/instances/$escaped/routes.toml"`.
- `tests/t360-ingress-path.sh:137` — seeds
  `shared/routed-preview/instances/feature\x2dx/routes.toml`.

Both use the escaped form, and t440 is green. The writer in
`src/guarden/units.py:224-245` creates
`service_dir / "instances" / escaped_ref` and writes the slice into it. The
contract is stated in three places and implemented correctly in all of them.

## Why it matters even though it is only a test

**A red suite in the gate is a red gate.** This one fails on `develop` itself,
so every full run reports a failure nobody caused and everybody learns to
ignore. That is how a real failure gets missed: the noise is already there, so
one more red suite is not noticed.

And the failure is *invisible* in the sense that matters: the suite dies on the
`assert_file_exists`, **before** it asserts the two things it was written to
check — that the instance's slice carries `basicauth = true`, and that the
edge's own file for the preview carries the middleware. The suite whose
comment says *"the policy was in the record and in the instance's slice, and
the edge served the preview with no login"* is not currently checking that
the policy is in the instance's slice at all.

## What to build

**Fix the suite, not the product.** The escaped form of the ref is
`feature\x2da` — the `-` is escaped, and that is the whole of the surprise.

Two ways to do it, and the second is better:

- write the literal `prevescaped='feature\x2da'`, or
- **derive it** the way t440 does, so the suite cannot drift from the rule
  again: ask the product for the escaped name, or compute it from the same
  rule the product uses. A suite that hard-codes the escaped form of one ref
  is a suite that will be wrong again the next time the escaping rule moves.

**Whichever you choose, the suite must reach the assertions past the failing
one.** Prove it by breaking the behaviour it guards — remove `basicauth` from
the instance's slice, or make the edge's file omit the middleware — and watch
the suite fail on THAT assertion rather than in its setup.

**Read `docs/spec.md` §5.2 and §6.4 first.** The escaping is normative there,
and the point of the rule is that `feature/x` and `feature-x` can never
collide — a suite that hard-codes the raw name is the shape of bug that rule
exists to prevent.

## Acceptance

- [ ] `t450-basicauth.sh` is green on `develop` with no branch applied, in a
      real machine: `ok   t450-basicauth.sh`.
- [ ] The suite reaches the assertions past the one that fails today: the
      instance's slice carries `basicauth = true`, the edge's file carries
      `basicAuth:` for the preview, and the htpasswd entry exists.
- [ ] The suite derives the escaped ref from the product's rule rather than
      hard-coding it — or, if it hard-codes it, the commit message says why
      that is safe and what would have to change when the rule moves.
- [ ] A **red-first** check: break the behaviour the suite guards and watch
      the suite fail on that assertion, not on the file's existence. A suite
      that dies in its setup asserts nothing.
- [ ] No other suite looks for an instance directory under a RAW ref. Grep
      for `/instances/` across `tests/` and check each one — `t440` and `t360`
      are right; find out whether any other is wrong, and fix it in the same
      change rather than leaving the next one to fail the same way.
