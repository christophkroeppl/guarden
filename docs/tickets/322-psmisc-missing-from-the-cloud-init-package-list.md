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
missing is the PACKAGE: a host installed the documented way does not get
`psmisc`, so a host that runs `soil packages` early can lose the apt race — the
exact thing the wait exists for.

## What to build
Add `psmisc` to the cloud-init template's package list (the template's packages
are pinned — respect that discipline and name the pin), so the wait is available
where it is needed. Then the harness guard stays as the honest last line: it
still refuses a box that lacks fuser, because a dev image may still not have
it. Red-first where a template test pins the package list (look for one; the
cloud-init render test) and keep the guard's message pointing at the right
place (it currently says "install psmisc on the golden" — that advice is only
right for a dev image, not for a real host).

Note: the same reasoning applies to the scripts-only path — `install.sh`
installs the same package set, so the two must agree.
