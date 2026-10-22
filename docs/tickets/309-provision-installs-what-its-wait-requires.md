# 309 — `provision` cannot install the package that its own readiness wait requires

**Found by** the adversarial review of ticket 200 (`merge(200)` at `95b5154`), which
was merged without prior review. The review named the ordering; this ticket
records what was measured about it and what it costs.

## What the ordering does

`cmd_provision` installs the golden's package set from the one list
(`packages/packages.toml`, roles `packages` + `golden`). That set includes
`psmisc`, which is what provides `fuser`.

But `cmd_provision` calls `_wait_cloud_init` **before** that install, and
`_wait_cloud_init` refuses to run when `fuser` is absent:

    tests/lxc.sh:797   _wait_cloud_init "$GOLDEN" "$GOLDEN_APT_LOCK_WAIT" || die "cannot wait for cloud-init on $GOLDEN"
    tests/lxc.sh:478       if ! lxc exec ... 'command -v fuser'; then ... return 1   ← unconditional before this fix
    tests/lxc.sh:838   apt-get install -y -qq $golden_packages                       ← 40 lines later

So on an image without `psmisc`, `provision` dies at *"cannot wait for cloud-init
on guarden-golden"* and never reaches the install that would have provided it.
Before ticket 200, cloud-init installed the packages during boot, so the guard
always found `fuser`; ticket 200 moved the install after the wait and inverted
the dependency.

## Measured

`ubuntu:26.04`, the image the harness is configured to use, **ships psmisc**
(`fuser`, `tar`, `sudo` and `python3` all present on a stock instance). So the
failure is latent, not active, on the default configuration — which is why a
full gate cannot see it in either direction: a gate cuts from a golden that
already has the package.

Measured on a machine with `psmisc` removed, calling the extracted function:

| code | `installing=0` (a cut's guard) | `installing=1` (provisioning) |
| --- | --- | --- |
| `develop` @ `148cc3d` | exit 1, full error | **exit 1 — provision dies** |
| this branch | exit 1, full error | **exit 0, one note** |

The guard is what protects every cut from an unmeasurable apt lock, so it must
keep refusing for a cut. It must not refuse for the one caller that is about to
install `fuser`.

## The fix

`_wait_cloud_init` takes a third argument, `installing`, default `0`. When it is
`1` — set only by `cmd_provision`, at both call sites — an absent `fuser`
defers the lock measurement and returns `0` with a note, because the wait that
*can* happen (cloud-init answering) has already happened above it.

The deferral is only sound together with an assertion after the install, so
`cmd_provision` gains one next to the existing `snapper` assertion of the same
shape:

    vm_exec_t "$GOLDEN" 'command -v fuser >/dev/null' \
        || die "$GOLDEN has no fuser after installing its package list; ..."

A cut never reaches that line: its machine comes from the snapshot, and the
snapshot is only taken after it passes.

## Acceptance

- [ ] On a machine with `psmisc` removed, `_wait_cloud_init m 60 1` exits 0 and
      prints the note; `_wait_cloud_init m 60 0` exits 1 with the full error.
      Measured on this branch (table above).
- [ ] `provision` on a fresh instance installs its list and asserts `fuser`
      afterwards — the assertion is the guard the deferral skipped.
- [ ] A cut still refuses on a machine without `fuser`: the guard's message and
      exit 1 are unchanged.
- [ ] `bash -n tests/lxc.sh` clean.

## Note on why the gate did not catch this

The suite gate exercises cuts, and a cut's machine is a copy of a golden that
already satisfies the guard. Provisioning is not a suite. Any future change to
this ordering must be validated by a provisioning run, not by the gate.
