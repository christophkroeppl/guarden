# 322 — psmisc is not in the cloud-init package list, so the apt-lock wait is unavailable on a minimal image

Blockers: none. Found 2026-10-19 while the drop-in work ran its suites: the
harness refused to cut a clean box with

    error: fuser is not on guarden-run-dropin, so the apt lock wait cannot run;
    install psmisc on the golden, or a suite that calls `soil packages` early
    will lose the lock race

## What happens
`fuser` comes from `psmisc`, and `psmisc` is NOT in the cloud-init package
list — the harness's own comment (tests/lxc.sh:350-355) says so and notes it is
present on the golden only because `ubuntu-standard` pulls it in. On an image
without that metapackage, every suite that needs the apt-lock wait cannot cut,
and the failure names a package nobody installs on a real host.

The harness guard itself is correct and deliberate (it fails closed, with a
named error, rather than entering the race believing it was protected). What is
missing is the PACKAGE — and the consumer of it is **the harness**, not a host:
`fuser` is used by `tests/lxc.sh`'s cut-time wait, `tests/aptlock.sh`'s probe
and evidence, and `tests/lib.sh`'s `apt_waits`, and by nothing under
`src/guarden/`. The product does not wait for apt's locks at all: spec §6.1
says waiting for the lock "is not available, because `apt-get` does not do it",
and the `packages` phase disables the distribution's own timers instead.

## What to build
Add `psmisc` to the package list so the wait is available where it is needed —
in the **harness** role, which is what the only consumer of `fuser` is, and in
the harness's own cut list, which is the document every cut actually boots.
Then keep the guard's message pointing at the right place (it currently says
"install psmisc on the golden" — that advice is only right for a dev image, not
for a host).

## Status: fixed

`psmisc` is in `[harness.debian]`, `[harness.fedora]` and `[harness.arch]` in
`packages/packages.toml`, and in the harness's cut list in `tests/lxc.sh`.

**The role is the harness role, and the repository settles it three ways.**

- **The consumer.** `grep -rn fuser src/ tools/` returns nothing. The three
  places that use it are harness code. A psmisc in the substrate would install
  a tool on every real host that no host-side program calls — which is the
  mirror of the mistake the package list's own header warns about: "keeping
  the role separate is what stops the harness's tools from becoming every
  host's dependency, which is the failure the other direction would cause".
- **The contract.** spec §6.1 enumerates the substrate and does not name
  psmisc, so a substrate placement would contradict the spec.
- **The maintainer's own upstream.** `origin/develop` carries psmisc in the
  three `[harness.*]` lists, from commit `f347fe0`, whose message says "psmisc
  now sits in the harness role for all three families: it is a throwaway-machine
  tool, not a host dependency". That placement was **lost locally** by `84ae393`,
  which resolved `packages.toml` wholesale to the other side of a merge — a
  merge accident and not a decision — and that loss is the hole this ticket
  describes.

**The golden carried it by accident, and the accident is not the claim.**
`ubuntu-standard` *depends* on psmisc and `procps` only *recommends* it
(measured on the golden: `apt-cache depends ubuntu-standard` lists
`Depends: psmisc`; `apt-cache depends procps` lists `Recommends: psmisc`). A
dependency that arrives because an unrelated metapackage pulled it in is a
dependency nobody declared.

**The package list alone did not fix it, and that is the part worth
recording.** The list's harness role reaches the golden-VM render profile, but
a cut boots the harness's own hand-maintained cloud-init heredoc
(`tests/lxc.sh`'s `_user_data`), not the rendered document. So the cut list
needed the package too, and the runner's guard now names
`packages/packages.toml` rather than telling an operator to patch the golden by
hand.

**The guard still fails closed.** It exits 1 rather than warning and
continuing, because a caller cannot see stderr and an exit code at once, and 0
would say the wait succeeded. That is unchanged.

### Acceptance

- [x] `psmisc` is in the harness role for all three families, with the reason.
- [x] The harness's cut list bakes it, so a cut has `fuser` before any suite
      runs.
- [x] The guard's message names the list, not a hand-patch of the golden.
- [x] Red-first: `tests/t322-psmisc.sh` and `tests/t322-psmisc-package-list.sh`
      are RED on the pre-fix tree and GREEN after it.

### Deliberately not changed

- The substrate lists on all three families — no host-side program calls
  `fuser`.
- `docs/spec.md` — §6.1's substrate enumeration is unchanged and still correct.
- `src/guarden/**` — nothing there needs `fuser`.
- The trailing-newline state of `packages/packages.toml` — pre-existing.
