#!/usr/bin/env bash
# One package list, with per-family entries, and no second copy that can drift.
#
# The list is data, not code: `packages/packages.toml` names every package a
# guarden host needs, once, per distribution family. `soil packages` reads it,
# and the cloud-init user-data is rendered from it, so a package added to one
# and forgotten in the other is a test failure rather than a box that installs
# three things and converges on a fourth.
#
# This is also where "no PyPI at deploy time" is checked rather than assumed:
# the rendered user-data carries the packages and nothing else, so a program
# cannot smuggle a wheel in through the boot path.

. "$(dirname "$0")/lib.sh"
scratch_host

# --- the list itself --------------------------------------------------------

# Per-family entries are the point, and they are not cosmetic: the same
# dependency has a different name per family, and asking for another family
# answers with that family's names rather than this host's. `python3-yaml` on
# Debian, `python3-pyyaml` on Fedora -- so a single hard-coded list could not
# produce both, which is what "per family" is for.
run soil packages --list --family fedora
assert_exit 0
assert_stdout_has "family   fedora"
assert_stdout_has "python3-pyyaml"
assert_stdout_lacks "python3-yaml"
assert_stdout_has "dnf install -y"
assert_stdout_has "rpm -q"

# A family the list does not carry is a rejected input: the caller named one
# that does not exist, and answering with a family that does would make the
# question unanswerable rather than answered wrongly.
run soil packages --list --family nonsense
assert_exit 2
assert_stderr_has "nonsense"
assert_stderr_has "debian"

# The list itself names a family per entry and each family's own tools.
assert_file_has "$GUARDEN_ROOT/packages/packages.toml" "[families.debian]"
assert_file_has "$GUARDEN_ROOT/packages/packages.toml" "[families.fedora]"
assert_file_has "$GUARDEN_ROOT/packages/packages.toml" "install = "

# `python3-yaml` and `python3-jinja2` are the distribution's, by name, in every
# family -- the whole dependency rule is that there is nothing else to install.
run soil packages --list
assert_exit 0
assert_stdout_has "python3-yaml"
assert_stdout_has "python3-jinja2"

# --- the list and the phase agree -------------------------------------------

# The phase converges exactly the packages the list names, so a package in one
# and not the other is drift the fast harness can see. Seeded as installed, and
# the pinned podlet fetched, so this checks the packages and nothing else.
seed "$GUARDEN_FIXTURES/packages" "btrfs-progs" "snapper" "ferm" "fail2ban" \
    "podman" "python3-yaml" "python3-jinja2"
seed "$GUARDEN_FIXTURES/curl-body" "the podlet release bytes"
digest=$(sha256sum "$GUARDEN_FIXTURES/curl-body" | cut -d' ' -f1)
seed "$(host etc/guarden/podlet.release)" \
    'version = "1.4.0"' \
    'url = "https://example.invalid/podlet"' \
    "sha256 = \"$digest\""

run soil packages --apply
assert_exit 0

run soil packages --check
assert_exit 0

# The install argv is the family's own, from the list, not a hard-coded
# `apt-get`: that is what makes the phase portable and the list the only copy.
# A converged host asks once per package and installs nothing.
assert_not_called "apt-get install"
assert_not_called "dnf install"
assert_called_count 14 "dpkg-query -W"

# A host where the list says a package is absent is drift, and the converge
# installs it with the family's tool named in the list.
seed "$GUARDEN_FIXTURES/packages" "btrfs-progs" "snapper" "ferm" "fail2ban" \
    "podman" "python3-yaml"
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the python3-jinja2 package is installed"
assert_not_called "apt-get install"

run soil packages --apply
assert_exit 0
assert_called "apt-get install -y python3-jinja2"
run soil packages --check
assert_exit 0

# --- the rendered user-data carries the list, and nothing from PyPI ---------

run soil packages --render-user-data "$GUARDEN_FIXTURES/rendered.yaml"
assert_exit 0
assert_file_exists "$GUARDEN_FIXTURES/rendered.yaml"
assert_file_has "$GUARDEN_FIXTURES/rendered.yaml" "#cloud-config"
assert_file_has "$GUARDEN_FIXTURES/rendered.yaml" "- podman"
assert_file_has "$GUARDEN_FIXTURES/rendered.yaml" "- passt"

# The rendered document is the one the golden VM boots, so a package added to
# the list and not rendered is a boot that converges on less than the host needs.
assert_stdout_has "packages storage sysctl firewall install units"

# No wheel, no pip, no venv: the boot path installs distribution packages and
# runs the phases, and that is all it does.
assert_file_lacks "$GUARDEN_FIXTURES/rendered.yaml" "pip install"
assert_file_lacks "$GUARDEN_FIXTURES/rendered.yaml" "python3 -m venv"
assert_file_lacks "$GUARDEN_FIXTURES/rendered.yaml" ".whl"
assert_file_lacks "$GUARDEN_FIXTURES/rendered.yaml" "pypi.org"

# --- an already-converged host reports no drift ------------------------------

# The scripts path on a host without cloud-init converges to the same state, and
# the second run is a no-op: the word `drift` and the exit code are the contract
# whichever path got there.
run soil packages --check
assert_exit 0
assert_stderr_empty