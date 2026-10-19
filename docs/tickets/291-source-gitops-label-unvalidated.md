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

**Status:** ready-for-agent

- [ ] `service.create` writes `SOURCE_GITOPS` only when `source.kind == "poke"`
      **and** the poke's project is registered in `projects.toml` or
      `projects.d/`; otherwise `SOURCE_MANUAL`
- [ ] Red first: `tests/t390-source-label.sh` (new suite, t390–t399) ingests a
      poke-shaped tree whose project is registered nowhere and asserts the
      registry says `source = "manual"` — red before the change, green after
- [ ] The same suite registers the project and ingests a second service from
      the same poke shape, asserting `source = "gitops"`, so the registered
      path is covered and cannot regress
- [ ] `tests/t30-create.sh` and `tests/t30-list.sh` register `myapp` before
      their pokes: their existing `source = "gitops"` claims are true only for
      a registered project, and the premise is what changes, not the claim
- [ ] Nothing else reads `record.source` (`report.py:116` only), so no other
      behaviour moves
