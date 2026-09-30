#!/usr/bin/env bash
# soil is the only program with two modes (spec 6.1). Every phase takes
# `--check` and `--apply`, `soil --check` is every phase, and `soil list` names
# them. `--deadman` is the firewall's alone, because what it arms is a timer
# whose effect is to open the firewall.
#
# This file is the interface, not the converges: that every phase accepts both
# modes and that a phase which exists never rejects its own name. What a phase
# converges is ticket 20's subject and is tested there.

. "$(dirname "$0")/lib.sh"

for phase in packages storage sysctl firewall install units; do
    run soil "$phase" --check
    assert_not_rejected
done

# `packages --apply` is the one exception, and it is exit 2 on purpose: the
# pinned podlet record is a repository input, and an unpinned third-party binary
# is refused rather than fetched. The other five have nothing to reject.
for phase in storage sysctl firewall install units; do
    run soil "$phase" --apply
    assert_not_rejected
done

run soil --check
assert_not_rejected

# `soil list` is the one verb that answers, because naming the phases is the one
# thing about the interface that has to be true before a phase body exists.
run soil list
assert_exit 0
assert_stdout_has "packages"
assert_stdout_has "storage"
assert_stdout_has "sysctl"
assert_stdout_has "firewall"
assert_stdout_has "install"
assert_stdout_has "units"
assert_stdout_lines 6

# The armed-timer form is accepted as written; the same flag anywhere else is a
# rejected input, not a silently ignored one.
run soil firewall --apply --deadman
assert_not_rejected
run soil packages --apply --deadman
assert_exit 2
assert_one_diagnostic "error:"
run soil storage --check --deadman
assert_exit 2
run soil --deadman
assert_exit 2
run soil list --deadman
assert_exit 2

# A phase with no mode is not a phase run: it is an incomplete call.
run soil packages
assert_exit 2
assert_one_diagnostic "error:"
run soil --check --apply
assert_exit 2
run soil nonsense
assert_exit 2
assert_stderr_has "nonsense"
