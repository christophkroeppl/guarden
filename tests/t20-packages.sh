#!/usr/bin/env bash
# soil packages: the distribution's packages, and the one fetch that is not a
# distribution package.
#
# podlet is that fetch, and it is pinned: a version and a SHA256 recorded in the
# repository and verified on install. There is no "latest" and no unpinned
# fallback, because "one third-party binary, verified" is the whole claim and a
# convenient fetch would make it false.

. "$(dirname "$0")/lib.sh"
scratch_host

# The pin is a shipped template, so it exists on a host `soil install` has run.
run soil install --apply
assert_exit 1

run soil packages --check
assert_exit 1
assert_stderr_has "drift: the btrfs-progs package is installed"
assert_stderr_has "drift: the snapper package is installed"
assert_stderr_has "drift: the ferm package is installed"
assert_stderr_has "drift: the fail2ban package is installed"
assert_stderr_has "drift: the podman package is installed"
assert_stderr_has "drift: the python3-yaml package is installed"
assert_stderr_has "drift: the python3-jinja2 package is installed"
assert_not_called "apt-get"

# The two python packages are the runtime dependencies and the only imports
# outside the standard library, which is what keeps the host installable on a
# distribution nobody has tried yet.
assert_file_has "$(host etc/guarden/podlet.release)" "sha256 ="

# An unfilled pin means the fetch does not happen, and it is exit 2 rather than
# exit 1: the record is a repository input, and a rejected input is 2.
run soil packages --apply
assert_exit 2
assert_stderr_has "the pinned podlet record is incomplete"
assert_not_called "curl"

# With a record filled in and a body that matches it, the artefact installs.
seed "$GUARDEN_FIXTURES/curl-body" "the podlet release bytes"
digest=$(sha256sum "$GUARDEN_FIXTURES/curl-body" | cut -d' ' -f1)
seed "$(host etc/guarden/podlet.release)" \
    'version = "1.4.0"' \
    'url = "https://example.invalid/podlet"' \
    "sha256 = \"$digest\""
run soil packages --apply
assert_exit 0
assert_called "apt-get install -y btrfs-progs"
assert_called "curl --fail --silent --show-error --location"
assert_file_exists "$(host usr/lib/guarden/bin/podlet)"
run soil packages --check
assert_exit 0

# A body that is not the pinned one is refused and the binary is not installed.
rm -f "$(host usr/lib/guarden/bin/podlet)"
seed "$GUARDEN_FIXTURES/curl-body" "some other bytes"
run soil packages --apply
assert_exit 2
assert_stderr_has "the SHA256 does not match"
assert_file_missing "$(host usr/lib/guarden/bin/podlet)"

# A binary that was replaced under the pin is drift, and `--check` re-reads the
# digest rather than trusting that it installed it.
seed "$GUARDEN_FIXTURES/curl-body" "the podlet release bytes"
run soil packages --apply
assert_exit 0
say "$(host usr/lib/guarden/bin/podlet)" "tampered"
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the pinned podlet is installed and its SHA256 verified"

# A pin that is filled in is the only thing that makes the fetch reachable, so
# removing the record puts the fetch back out of reach rather than making it
# unpinned -- and it says which of the two faults it is, because an absent record
# and an unfilled one have different fixes.
rm -f "$GUARDEN_CALLS"
rm -f "$(host etc/guarden/podlet.release)"
run soil packages --apply
assert_exit 2
assert_stderr_has "the pinned podlet record is absent"
assert_stderr_has "soil install"
assert_not_called "curl"
