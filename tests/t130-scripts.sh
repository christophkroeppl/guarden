#!/usr/bin/env bash
# The scripts path: a host without cloud-init converges to the same state.
#
# The ticket is explicit that both paths reach one state and that the seam, the
# exit codes and the word `drift` do not change with the path taken. That makes
# the claim checkable without a second machine: converge the host through the
# script, then assert the cloud-init document's sequence and this one agree, and
# assert that a converged host is silent on both.
#
# Nothing here fetches anything. The script runs the phases that are already
# installed; what a fresh box needs *before* it can run them is the rendered
# user-data's `packages:` block, and that is what the cloud-init path is for.

. "$(dirname "$0")/lib.sh"
# `guarden_prefix` rather than `scratch_host`: this file stages a
# `/etc/guarden/guarden.toml`, and that helper is the one that creates the
# directory `stage_config` copies into.
guarden_prefix

# A host that has been through both paths and is converged: btrfs layout, the
# substrate installed, the podlet pin filled and fetched, and the alias measured.
#
# The measured alias is a fixture rather than something this file arranges: the
# probe that writes it runs a throwaway container, and a fake podman starts no
# container, so a host that "measures" one here would be a test arranging its
# own answer. `guarden-measured.toml` is what a host looks like after the probe
# has run for real, which is the state both paths are being compared from.
stage_config guarden-measured.toml
seed "$GUARDEN_FIXTURES/packages" "btrfs-progs" "snapper" "ferm" "fail2ban" \
    "podman" "python3-yaml" "python3-jinja2"
seed "$GUARDEN_FIXTURES/btrfs-subvolumes" "ID 256 gen 42 top level 5 path @" \
    "ID 257 gen 42 top level 5 path @var"
seed "$GUARDEN_FIXTURES/curl-body" "the podlet release bytes"
digest=$(sha256sum "$GUARDEN_FIXTURES/curl-body" | cut -d' ' -f1)

seed "$GUARDEN_PREFIX/etc/guarden/podlet.release" \
    'version = "1.4.0"' \
    'url = "https://example.invalid/podlet"' \
    "sha256 = \"$digest\""

# The scripts path: the phase list, in spec 6.1's order, applied and then
# checked. Read from `soil list` rather than written here, so the order this
# file runs is the order the program says.
run soil list
assert_exit 0
for phase in packages storage sysctl firewall install units; do
    assert_stdout_has "$phase"
done

run soil --apply
assert_exit 0

# What a converged host says afterwards is what matters: no drift, exit 0, and
# nothing on stderr. The word `drift` is the contract (spec 1.2) and a path
# that reported it here would be reporting a path-specific fiction.
run soil --check
assert_exit 0
assert_stderr_empty
assert_stderr_lacks "drift"

# A second run of the scripts path changes nothing at all: no user, no group, no
# directory, no package, no download. A converge that is not idempotent is a
# phase that has to be babysat.
rm -f "$GUARDEN_CALLS"
run soil --apply
assert_exit 0
assert_not_called "useradd"
assert_not_called "groupadd"
assert_not_called "apt-get install"
assert_not_called "curl"

# --- both paths reach one state ---------------------------------------------

# The cloud-init document runs the same phase list, and it is rendered from the
# program rather than written out by hand, so the two cannot disagree about what
# converged state is.
run soil packages --render-user-data "$GUARDEN_FIXTURES/user-data.yaml"
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "soil packages --apply"
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "soil units --check"

for phase in packages storage sysctl firewall install units; do
    assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "soil $phase --apply"
    assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "soil $phase --check"
done

# The document checks what it converged rather than only converging it: a boot
# that applied every phase and never asked is a boot that reported success
# without having looked.
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "--apply;"
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "--check"

# And the runner the ticket names passes that document to the instance, rather
# than one of its own. It renders the same list this file rendered from and
# refuses to boot a committed document that has drifted from it, so the file a
# reviewer reads is the file the machine boots.
run tool golden-vm --print
assert_exit 0
assert_stdout_has "packages storage sysctl firewall install units"
assert_stdout_has "soil units --check"

# `--print` names the committed document, which is the point: the path an
# operator reads in the repository is the path that would be passed.
assert_stdout_has "tools/cloud-init/user-data.yaml"

# And a caller who names their own document gets exactly that one, because
# `--user-data` is an instruction rather than a suggestion.
seed "$GUARDEN_FIXTURES/mine.yaml" '#cloud-config' 'packages: [btrfs-progs]'
tool golden-vm --user-data "$GUARDEN_FIXTURES/mine.yaml" --print
assert_exit 0
assert_stdout_has "$GUARDEN_FIXTURES/mine.yaml"

tool golden-vm --user-data "$GUARDEN_FIXTURES/absent.yaml" --print
assert_exit 1
assert_stderr_has "absent.yaml"