#!/usr/bin/env bash
# The shared half of every fake in fixtures/bin.
#
# A fake's whole job is to be indistinguishable from the real tool at the seam
# and to record that it was called. It writes nothing to stdout of its own
# unless the tool it stands in for writes there, because a fake that invented
# output would let a program that misparses it pass.
#
# State lives under $GUARDEN_FIXTURES, which the harness sets to a fresh
# directory per test file. Two paths matter:
#
#   $GUARDEN_FIXTURES/calls.log          every call, one line, arguments %q-quoted
#   $GUARDEN_FIXTURES/snapper/<config>  the snapper fake's seeded state
#
# A configuration is the host's, not the test's, so a *prefixed* run — one where
# guarden's own paths are staged — keeps snapper's configurations beside them in
# <prefix>/etc/snapper/configs/, and an unprefixed run keeps them here. Without
# that split two staged hosts in one test file would share a configuration named
# myapp-production-data, and the second create-config would fail for a reason that
# has nothing to do with the program under test.
#
# A model that does not exist is a failure, not a success: an unmodelled
# subcommand exits 2 with a diagnostic. That is what stops a program calling the
# wrong thing from looking like it worked.

set -u

GUARDEN_FAKE_DIR=${GUARDEN_FIXTURES:-${TMPDIR:-/tmp}/guarden-fixtures}
GUARDEN_FAKE_CALLS="$GUARDEN_FAKE_DIR/calls.log"
GUARDEN_FAKE_SNAPPER="$GUARDEN_FAKE_DIR/snapper"

# fake_init: record this invocation, deriving the tool's name from argv[0].
fake_init() {
    fake_name=${0##*/}
    mkdir -p "$GUARDEN_FAKE_DIR"
    {
        printf '%s' "$fake_name"
        for fake_arg in "$@"; do
            printf ' %q' "$fake_arg"
        done
        printf '\n'
    } >>"$GUARDEN_FAKE_CALLS"
}

# fake_early_exit <args...>: --version and --help are answered by every real
# tool, and a fake that rejects them would fail a program that probes for a
# version — which is how the `useradd --add-subuids-for-system` feature path is
# meant to be asked.
fake_early_exit() {
    case "${1:-}" in
        --version|-V)
            fake_out "${0##*/} 0.0.0-guarden-fixture"
            exit 0
            ;;
    esac
}

# fake_die <message>: a model that does not exist is a failure, not a success.
fake_die() {
    printf 'error: %s: %s\n' "${0##*/}" "$*" >&2
    exit 2
}

# fake_out: the call's stdout, which every caller has already emptied.
fake_out() {
    printf '%s\n' "$@"
}
