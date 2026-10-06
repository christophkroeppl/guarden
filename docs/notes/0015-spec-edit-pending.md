# ADR-0015's spec edit, held for integration — agent A owns `docs/spec.md`

**This is a conflict, recorded rather than raced.** Agent A was given ownership of
`docs/spec.md` to correct the loopback-deny claim in§7.6/7.7; ADR-0015 needs the same
file for a different paragraph. Two agents editing one file is one worktree, so this
edit waits for A to land and is applied on top.

## The paragraph, and what it must say

`docs/spec.md` around line 1196, in the packages section:

> It also fetches **one** artefact from outside a distribution repository: the pinned
> `podlet` release, whose version and SHA256 are recorded in this repository and
> verified on install. That is the only exception to "distribution packages only", it is
> deliberate, and it is the only third-party binary.

**Three claims there are now false**, and `spec.md` is the authority, so leaving them
would make the spec disagree with the ADR that supersedes them.

The replacement, in the spec's own voice:

> It also fetches **pinned artefacts** from outside a distribution repository, and each
> one is an exception to "distribution packages only" that is deliberate: a **url** and
> **two SHA256s** — the artefact's, verified before anything is unpacked out of it, and
> the program's, re-read on every `--check` because the artefact is not kept. Today that
> is `podlet` and, with ADR-0015, the tunnel's `cloudflared`. **A vendor repository is
> never one of these**: its contents move under the pin, so the version in force would be
> the vendor's to decide rather than recorded here. `soil packages --check` asserts the
> version in force.

## Why it waits rather than landing now

- Agent A is editing `docs/spec.md` right now in `ticket-260-stub-resolver`. Applying an
  edit to the same file in `develop` while A works from a common base guarantees one of
  the two is lost, and a silent loss is the failure mode worth avoiding.
- The two edits are in **different sections** (§7.6/7.7 firewall, versus the packages
  section around §6), so there is no content conflict — only a file conflict. Applying it
  after A lands is a clean forward merge with nothing to reconcile.
- `AGENTS.md` and `CONTEXT.md` are already changed and carry no conflict, which is why
  the ADR can be committed now and only this paragraph waits.

## Also already changed, no conflict

- **`AGENTS.md`** — "There is exactly one fetch … it is the only third-party binary"
  replaced with the pinned-artefact rule and the no-vendor-repository prohibition.
- **`CONTEXT.md`** — the `edge` entry no longer says "the one service that terminates
  public traffic". It says the edge is the **only door** (the kernel forwards public
  ports to it) and that a tunnel terminates traffic too and is **not a door**, because it
  dials out, is reached by nobody, binds no port, and no forwarding rule names it.

Those two are the glossary and the working notes, which is where "one canonical
statement per rule" starts. The spec paragraph is the same rule restated, and it lands
with the ADR's implementation rather than before it.
