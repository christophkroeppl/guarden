# 330 — the service templates are in the repo but never installed: `weedr service create` has nothing to choose from

**RESOLVED (`851920a`, `4d67a2a`, 2026-10-19): the templates now ship with the
program, `soil install` installs them, and `weedr service create --template`
works.** The templates moved from `examples/services/` to
`src/guarden/templates/services/`, so the install phase's existing walk picks
them up and the existing check already compares them recursively — no new item
was needed. `t131-service-templates.sh` asserts both the installed set and the
verb, on a fresh VM:

    MEASURE: the installed template set: postgres vaultwarden
    MEASURE: create --env staging --template postgres: created
    MEASURE: the units it installed: 1
    MEASURE: the template's image reached the service

Blockers: none. Found 2026-10-19 while correcting the manual-fleet deployment
record (`deploy-fresh-manual-fleet.md`), whose commands named verbs that do
not exist — which sent me looking for the real manual path.

## What was measured

**`weedr service create --template X` cannot work on a host, because the
template set is empty.**

`require_template` reads `paths.TEMPLATES / "services"` — that is
`/usr/lib/guarden/templates/services/` on a real host (`service.py:413`).
On a live box (`app-vm`), that directory does not exist:

    $ lxc exec app-vm -- ls -la /usr/lib/guarden/templates/
    80guarden-snapper  cloud-init  convert  dashboard-groups.yml.j2
    dashboard-links.yml.j2  edge-forward-auth.yml.j2  edge-routes.yml.j2  ...

    $ lxc exec app-vm -- ls -la /usr/lib/guarden/templates/services/
    ls: cannot access '...': No such file or directory

**The templates exist — in the wrong place.** The repo carries them at
`src/guarden/templates/services/postgres/` and `src/guarden/templates/services/vaultwarden/`, each a
directory holding one `.container` file.

**And the install phase does not install them.** `_install_templates`
(`hostprep.py:2109-2128`) copies `src/guarden/templates/` — the program's own
templates, the units, the jinja files, the convert script. That tree has no
`services/` subdirectory, and `examples/` is not under it, so the walk never
sees the two service templates.

So the verbs the spec describes are wired to a set that no host has.

## What breaks

- `weedr service create <name> --template postgres` fails with the
  "no such template" refusal, because the installed set is empty.
- `weedr service create <name>` with the template omitted asks the operator
  to choose from a set that is empty — and `_choose_template` refuses
  ("create needs a terminal to answer its prompts" or the empty-set refusal).
- The spec's §5.3 "create a new service from a template" is a capability the
  platform documents and does not have.
- Ticket 328's guided creator, which extends `create`, inherits the same
  emptiness: it would ask the operator to fill in a template that is not
  there.

## What to do

**Install the service templates.** The decision is where they live, and
there are two honest answers:

- **Move them under `src/guarden/templates/services/`** — then the existing
  install walk picks them up with no new code, and the template set is
  installed by the same phase that installs everything else. The cost: the
  templates become part of the program's own template tree, and `examples/`
  loses two entries (or keeps them as pointers).
- **Add a second walk** in the install phase for `src/guarden/templates/services/` into
  `templates/services/`. The cost: two walks to keep agreeing, and the
  examples tree becomes a source of installed state (the spec's §5.1 rule
  that a template is root-owned and installed, not read out of a checkout).

**The first is simpler**, and the spec's own doctrine favours it: a program
that reads a template from the checkout it was installed from is a program
whose behaviour depends on where it was installed from. The templates are
root-owned and installed (`service.py:480-485`), so they belong where the
install phase already installs root-owned templates.

**Whichever is chosen, the install phase needs an item for it** — not a
best-effort copy — so `soil --check` reports the drift when the template set
is missing or stale, the same way it reports every other part of the host's
layout.

## Also worth deciding in the same change

- **The template set should be converged, not merely present.** A template
  the operator edited on the host is a template the install phase overwrites
  — or does not. The spec says a template is root-owned and installed, so
  guarden owns it; but that should be stated rather than implied, because a
  template an operator has edited and a template guarden overwrites are
  different expectations.
- **The two existing templates are minimal.** `src/guarden/templates/services/postgres/`
  is one `.container` with an `Image=` line and a `PublishPort=`, and
  `src/guarden/templates/services/vaultwarden/` likewise. A template that produces a
  service with no manifest cannot `provide:` anything, so nothing can reach
  it — the reason the manual path needed twelve steps. A template that
  carried a manifest would fix that, and the manifest is what ticket 328's
  creator writes.

## Notes

- The corrected deployment record for the manual fleet is in
  `deploy-fresh-manual-fleet.md`; it names the path that actually works
  (`weedr service add --from <tree>`) and says which of the two templates
  exist.
- The discovery came from a documentation defect: the record named
  `weedr service set-image` and `weedr service set-env`, verbs that do not
  exist in the codebase. The services really were deployed, but not by a path
  the document described. A false command in a runbook is a trap for the
  next operator, so the record is corrected rather than left.
