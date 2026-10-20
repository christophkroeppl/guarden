# 336 — the instance's own routes slice is read but never written, so a preview's basic auth never reaches the edge

Blockers: none. Found 2026-10-20 while verifying ticket 315's change, by running
the `t4*` regression gate on `develop`'s own tree and reading the failure
instead of the summary.

**This is a PRODUCT defect, not a stale test.** It was confirmed on `develop`
itself, with a tree carrying none of the change under test.

## What happens

`tests/t450-basicauth.sh` ingests a preview and asserts that the instance's own
route slice exists:

```
run weedr service ingest prevapp-preview/feature-a --from poke prevapp@9f2c1ab
assert_exit 0
prevreg=$GUARDEN_PREFIX/var/lib/guarden/registry/prevapp-preview.toml
assert_file_has "$prevreg" "basicauth = true"
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

**The file is never written.** Three places in the tree describe it and none of
them creates it:

- `src/guarden/render.py:1140` — `plan.add("shared/routes.toml", ...)`. That is
  the **service's** slice. There is no `plan.add` for the instance's, and no
  other writer anywhere in `src/guarden/`.
- `src/guarden/roots.py:123` — the READER walks
  `shared/<service>/instances/<escaped-ref>/routes.toml` looking for the
  `basicauth` flag, and `roots.py:84` walks it for the routes.
- `src/guarden/templates/shared-routes.toml.j2:3` — the template's own comment
  says the slice is read from
  `/var/lib/guarden/shared/<service>/instances/<escaped-ref>/routes.toml`
  (spec 2 and 6.4).

**So the contract is stated twice and implemented zero times.** The reader and
the template agree on the path; only the writer is missing.

## Why it matters

**A preview serves without a login.** The basic-auth policy is a SERVICE's, and
a preview is an instance of one service — so the preview's routes must carry
the same middleware the service's own do. The suite's own comment says exactly
this, and names the failure that was found before:

> the policy was in the record and in the instance's slice, and the edge served
> the preview with no login.

The record carries the flag (`assert_file_has "$prevreg" "basicauth = true"`
passes), so the flag reaches the edge's own file — but the ROUTES for the
instance never do, because the instance's slice is never written. The edge
routes the preview and applies no middleware to it.

**The preview track in that fixture carries `expose = "edge"`** — the posture
where the middleware is the only thing between the internet and a developer's
branch. A preview reachable from the edge with no basic auth is an
**authentication bypass on an internet-facing preview**, and the suite that
would have caught it has been red on `develop` ever since.

## What to build

**Write the instance's slice.** The renderer must emit, for an instance,
`shared/<service>/instances/<escaped-ref>/routes.toml` — the instance's routes
and the instance's `basicauth` flag — beside the service's own
`shared/<service>/routes.toml`.

The things to get right, and each of them is a place this could be wrong:

- **The ref is the ESCAPED one.** The directory is named by the escaped ref
  (spec 5.2), and the reader walks the directories it finds, so the writer and
  the reader must agree on the name. A ref containing `/` is the case that
  catches it.
- **The service's own slice is not a substitute.** On an instance track the
  service's `routes.toml` is never written (the suite's comment says so), so
  the instance's slice is the ONLY place the instance's routes live.
- **The instance's routes are the INSTANCE's.** The route target is the
  instance's own publication, not the service's — spec 6.4 and 7.4.
- **The flag travels.** `basicauth = true` must be in the instance's slice,
  because that is the only file the reader consults for an instance.

**Read `docs/spec.md` §2, §6.4 and §7.4 first.** The path and the escaping
are normative there, and this repository has been refuted on both before.

## Acceptance

- [ ] `t450-basicauth.sh` is green on `develop` with no branch applied, in a
      real machine, and it reaches the assertions past the one that fails
      today — the edge's own file carrying `basicAuth:` for the preview.
- [ ] A **red-first** test: the new behaviour fails before the fix, with the
      failure naming the missing file. Write the test first and show it red.
- [ ] An instance whose ref contains `/` writes its slice under the ESCAPED
      name, and the edge's file carries that instance's routes. A ref with a
      slash is the case that a suite that only uses `feature-a` will not
      catch, so the test must use one.
- [ ] The service's own slice and the instance's slice coexist on a host that
      has both a service and an instance, and neither is written twice.
- [ ] `roots sync` renders the instance's routes into the edge's file, and the
      edge serves the preview WITH the middleware.
