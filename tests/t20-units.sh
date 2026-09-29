#!/usr/bin/env bash
# soil units, and the two modes as a whole.
#
# The recurring jobs are the phase's content: a routine snapshot on a schedule
# and the mark reconciler beside it. Both are the ones that have to be enabled,
# because an installed timer that nothing started is a snapshot policy nobody has
# and a mark nobody writes.

. "$(dirname "$0")/lib.sh"
scratch_host

# A host that has not been converted, so `soil --check` has something to say
# about a phase other than the one this file is about.
seed "$GUARDEN_FIXTURES/btrfs-subvolumes" "ID 256 gen 42 top level 5 path @"

run soil units --check
assert_exit 1
assert_stderr_has "drift: /guarden-snapshot.service is installed"

run soil units --apply
assert_exit 0
assert_file_has "$(host etc/systemd/system/guarden-snapshot.service)" \
    "ExecStart=/usr/lib/guarden/bin/weedr service snapshot --all"
assert_file_has "$(host etc/systemd/system/guarden-pin-sync.service)" \
    "ExecStart=/usr/bin/flock -w 30 /run/guarden/locks/snapshots.lock /usr/lib/guarden/bin/weedr pin sync"
assert_called "systemctl enable --now guarden-snapshot.timer"
assert_called "systemctl enable --now guarden-pin-sync.timer"
assert_called "systemctl enable --now guarden-snapper-cleanup.timer"

# The reconciler is a root action and `stakes` is not: `stakes` runs
# unprivileged and writing snapper's metadata is not something it can do, so the
# marks have to be written by something that can. It is also the phase that
# converges the snapshot ladder, so a box that is not converged is a box whose
# retention is a convention.
assert_file_has "$(host etc/systemd/system/guarden-snapshot.service)" "Requires=snapperd.service"

# A routine snapshot is never marked, and the unit that makes them says so.
assert_file_has "$(host etc/systemd/system/guarden-snapshot.service)" "Type=oneshot"

run soil units --check
assert_exit 0

# The two modes, as the spec states them: `--check` is safe over ssh at any time
# and `soil --check` is every phase.
run soil --check
assert_exit 1
assert_stderr_has "drift:"
assert_stderr_has "btrfs with the @ and @var subvolumes"

# `--check` changed nothing, so the drift it reported is still there.
run soil units --check
assert_exit 0
run soil --check
assert_exit 1
assert_stderr_has "drift: btrfs with the @ and @var subvolumes"

# And every phase converges, after which the whole host checks clean. The pin is
# filled in first, because an unpinned third-party artefact is a rejected input
# and a rejected input stops the run before the phases that follow it -- which is
# the right order for an input, and the reason a host cannot be converged with an
# unfilled pin.
seed "$GUARDEN_FIXTURES/curl-body" "the podlet release bytes"
digest=$(sha256sum "$GUARDEN_FIXTURES/curl-body" | cut -d' ' -f1)
seed "$GUARDEN_HOST/etc/guarden/podlet.release" \
    'version = "1.4.0"' \
    'url = "https://example.invalid/podlet"' \
    "sha256 = \"$digest\""
seed "$GUARDEN_FIXTURES/btrfs-subvolumes" \
    "ID 256 gen 42 top level 5 path @" \
    "ID 257 gen 42 top level 5 path @var"
run soil --apply
assert_stderr_has "ingress.alias is empty"
assert_stderr_has "alias probe 1 of 4"
run soil --check
assert_stderr_has "drift: ingress.alias holds an address the probe measured"

# A second whole-host apply creates nothing: the two program users and the one
# group already exist, every directory is already at its mode, and every package
# is already installed. The alias is the one thing it re-runs, because the probe
# is the only thing that can produce it.
rm -f "$GUARDEN_CALLS"
run soil --apply
assert_not_called "useradd"
assert_not_called "groupadd"
assert_not_called "install -d"
assert_not_called "apt-get"
assert_not_called "create-config"
assert_called "podman run --rm --network"
