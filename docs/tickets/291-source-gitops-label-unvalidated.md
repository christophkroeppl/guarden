# 291 — `source = "gitops"` is written for a poke no gitops receiver could have accepted

Blockers: none. Found 2026-10-18 on the `guarden-deploy` LXC (read-only
measurement) and in `src/guarden/service.py`.

## What happens

`weedr service ingest --from poke <project>@<sha>` writes the registry's
`source` field from the **shape** of the `--from` argument and from nothing
else:

```python
source=registry.SOURCE_GITOPS if source.kind == "poke" else registry.SOURCE_MANUAL,
```

`src/guarden/service.py:201`. `parse_from` validates neither half of a poke
beyond a `sha` containing `/` or `..` (`service.py:114-136`), `service.py`
imports no `projects` module, and nothing on the ingest path asks whether the
project the poke names is a project this host has registered.

## The measurement, 2026-10-18 (LXC `guarden-deploy`, read-only)

`deployment-audit-manual-images.md` §3.2:

- **11 registry files, all `source = "gitops"`**: `hashtest-staging`,
  `hermes-production`, `odoo-btc-bcr-{,bitcoind-,btcpay-,nbxplorer-}staging`,
  `postgres-production`, `rustfs-production`, `supplements-staging`,
  `umami-production`, `zeroclaw-production`.
- `/etc/guarden/projects.d/` held **five** registered projects: `bases-mcp`,
  `odoo-btc-bcr`, `odoo-btc-bcr-bitcoind`, `odoo-btc-bcr-btcpay`,
  `odoo-btc-bcr-nbxplorer`.
- Therefore **seven records carry `source = "gitops"` while no registered
  project matches them** (`projects.toml` empty, `projects.d/` holds the five
  above): `hashtest`, `supplements`, `hermes-production`,
  `postgres-production`, `rustfs-production`, `umami-production`,
  `zeroclaw-production`.
- The staged trees behind them are hand-made under placeholder shas
  (`deadbeef`, `h1`, `6c41bce`, `bbc4528`), and the timeline closes the case:
  those services were created **2026-10-13/14**, and `--from <path>` only
  arrived **2026-10-16** (`1870406`) — so at the time the *only* way to ingest
  a hand-written tree was `--from poke <project>@<sha>` against a hand-staged
  directory.

`deployment-audit-odoo-btc-bcr.md` asks the same question from the other end
(“`/etc/guarden/projects.d/` — is any project registered at all?”).

## Why it is a lie, not a loose label

`source` is provenance and nothing else — spec 3.4, `docs/spec.md:634`:

```
source  = "manual"  # or "gitops"; recorded, and it changes nothing
```

No branch reads it except `report.py:116` (the `weedr service list` JSON), so
the field's whole job is to be true. And "gitops" has a definition in the spec:
the gitops receiver, spec 6.7, which

- is the only program that validates a project — `hose.py:599` calls
  `projects.get()` and names the registered ones, refusing an unregistered one;
- can only write into `staging/<project>/` because `weedr project grant`
  created that directory when the project was registered (`projects.py:434-447`,
  spec 6.7: “created when the key is installed”).

A poke whose project is registered in neither `projects.toml` nor `projects.d/`
**cannot have come through the receiver**. It is an operator's hand-staged
ingest, and the seven records above are hand ingests wearing the gitops label —
which is exactly what makes a manual ingest and a real CI poke indistinguishable
after the fact for anything reading `source` for drift or lineage.

## What happens if it stays

A reader of the registry cannot tell a CI deploy from a `--from poke` someone
typed at a terminal against a directory they staged by hand; the field reports
"deployed through the gitops receiver" for hosts where the receiver has never
run. The next consumer to trust it (a drift report, a lineage walk) is wrong by
seven records on one box, and the error is invisible because the label looks
authoritative.

## What to build

**The honest label, not a refusal — spec 3.4 forces it.** The spec defines
`source` as "recorded, and it changes nothing", so its contract is truthfulness
of the record; it gives `weedr service ingest` no project-registration step
(spec 5.3's ordered list of thirteen steps has none), and it places the
`projects.toml` check twice elsewhere: on `hose` (spec 6.7) and on
`furrow deploy` (spec 6.6: “`<project>` is checked against the project's
`projects.toml` entry” — a promise `furrow._poke` does not keep either, which
is a separate ticket and not this one). Adding a refusal at ingest would give
the label behavioral force the spec denies the field, would add a precondition
the spec's step list does not carry, and would fail every hand-run poke-shaped
ingest the spec permits (spec 6.6: “a hand-run `furrow deploy` names a project
and a sha” — the operator form is the same two-argument form, deliberately).

So the label is decided where the record is written:

- poke whose project **is** registered → `gitops` (unchanged; the receiver is
  the path that shape took, and registered-project pokes keep their label);
- poke whose project is **not** registered → `manual`;
- every non-poke source → `manual` (unchanged).

The label is written once, at record creation, and later ingests do not rewrite
it — same as today.

**Status:** done — merged as `35384f6` ("fix(service): record gitops only for a
poke of a registered project", merged into `develop` as `1a4e614`), and
completed by `b938385` ("fix(291): the label never decides whether the deploy
happens").

- [x] `service.create` writes `SOURCE_GITOPS` only when `source.kind == "poke"`
      **and** the poke's project is registered in `projects.toml` or
      `projects.d/`; otherwise `SOURCE_MANUAL`
- [x] Red first: `tests/t390-source-label.sh` (new suite, t390–t399) ingests a
      poke-shaped tree whose project is registered nowhere and asserts the
      registry says `source = "manual"` — red before the change, green after
- [x] The same suite registers the project and ingests a second service from
      the same poke shape, asserting `source = "gitops"`, so the registered
      path is covered and cannot regress
- [x] `tests/t30-create.sh` and `tests/t30-list.sh` register `myapp` before
      their pokes: their existing `source = "gitops"` claims are true only for
      a registered project, and the premise is what changes, not the claim
- [x] Nothing else reads `record.source` (`report.py:116` only), so no other
      behaviour moves

## What the merged fix left behind, and what closed it

The label was read where the record's own field was built — at
`registry.Registry(...)`, which is **after** `users.ensure()` (the system
user), `_make_tree()` (the home and the tree) and `_copy_source()` (the
copied source). `projects.load()` raises out of a malformed `projects.toml`
or a malformed file under `projects.d/`, so a broken root-owned configuration
**failed the ingest** and left a system user, a `0700` home, a copied tree and
an overrides file on the box with no registry entry naming any of them.

That gave the label a veto it must not have. spec 3.4 says `source` is
"recorded, and it changes nothing", and spec 5.3's thirteen ordered steps
contain no projects step — so a provenance field was deciding whether a
deploy succeeds, which is the one thing this ticket's own decision refused to
do. The ticket's decision — *the honest label, not a refusal* — was right
about the label and silent about the read.

Three changes close it, and each is that decision made whole:

- **The read is TOTAL.** A configuration that cannot be read records
  `manual` — the direction that never claims a receiver path that may not have
  run — and the fault is reported as a `warning:` naming the file. The
  tolerance is the label's alone: `hose` (spec 6.7) and `weedr project list`
  still refuse on a broken projects configuration, because **there** the
  configuration is an input and not a record.
- **The read is BEFORE the identity.** The label is computed after the
  converged return and before `users.ensure()`, so a service that does not
  exist yet is never half-created by a broken configuration. A converged
  service never reads it at all: the label is written once, at creation, and a
  later ingest does not rewrite it.
- **The warning SURVIVES.** `outcome.warnings = users.reconcile_groups(...)`
  assigned the list outright and discarded anything raised before it, so a
  label warning was lost on the way out and the operator saw a deploy succeed
  with no word about the configuration that was broken. It joins now.

## The RED, verbatim, before the fix

The source reverted to the merged 291 fix (`35384f6`'s `service.py`) and the
new test kept:

```
$ GUARDEN_LXC_RUNNER=guarden-run-t291 timeout 1800 tests/lxc.sh run t390-source-label --no-cache
sha: 461c1fcaf823c4db7d20ab489984fe3697b50a9c (SOURCE REVERTED to the merged 291 fix, the new test kept)
error: expected exit 0, got 1
  stderr: error: /etc/guarden/projects.toml is not valid TOML: Expected '=' after a key in a key/value pair (at line 1, column 6)
error: failed at line 75: return 1 (exit 1)
FAIL t390-source-label.sh
error: t390-source-label.sh exited 1; the suite stopped on an assertion, and its own line is above
1 suites: 1 ran, 0 inherited, 1 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

**The diagnostic names the DEFECT and not a neighbour.** The suite asserted
the exit code first, and the stderr line it reports is the ingest's own
refusal on the broken configuration — not a missing file, and not a later
assertion.

## The GREEN, verbatim, with the fix

```
$ GUARDEN_LXC_RUNNER=guarden-run-t291 timeout 1800 tests/lxc.sh run t390-source-label --no-cache
sha: b938385c85839027861779292d57f6392fb92489
ok   t390-source-label.sh
1 suites: 1 ran, 0 inherited, 0 failures, 1 machines cut
note: --no-cache: all 1 suites ran and every result was recorded
```

### The suites that had to stay green

The fix touches the label and the warnings list, and three other suites pin
both: `t30-create.sh` pins `source = "gitops"` for a registered project,
`t30-list.sh` pins the same field in the `weedr service list` JSON, and
`t30-identity.sh` pins the supplementary-group warning that the `+=` change
moved.

```
$ GUARDEN_LXC_RUNNER=guarden-run-t291 timeout 1800 tests/lxc.sh run t30- --no-cache
sha: b938385c85839027861779292d57f6392fb92489
ok   t30-config.sh
ok   t30-create.sh
ok   t30-identity.sh
ok   t30-list.sh
ok   t30-parsers.sh
ok   t30-remove.sh
ok   t30-subid.sh
7 suites: 7 ran, 0 inherited, 0 failures, 7 machines cut
note: --no-cache: all 7 suites ran and every result was recorded
```

## What was deliberately NOT changed

- **The refusal.** The ingest still does not refuse a poke whose project is
  registered nowhere. That is the ticket's decision and this change does not
  revisit it.
- **`hose` and `furrow`.** `hose` refuses an unregistered project
  (`projects.get`, spec 6.7) and `furrow` checks the granted project. Those
  are **inputs**, not records, and their refusal is correct. The label's
  tolerance does not extend to them, and the suite asserts that it does not.
- **The label's direction.** A configuration that cannot be read records
  `manual`, not `gitops`. The fallback is the direction that never claims a
  receiver path that may not have run, and the fault is reported besides.
- **The order of the other thirteen steps.** A malformed projects file is
  the one failure this closes; the partial-state window that the other
  steps share (`volumes.create_state()`, `edges.install()`) is a separate
  question and is not this ticket's.

