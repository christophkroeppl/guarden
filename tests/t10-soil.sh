#!/usr/bin/env bash
# soil is the only program with two modes (spec 6.1). Every phase takes
# `--check` and `--apply`, `soil --check` is every phase, and `soil list` names
# them. `--deadman` is the firewall's alone, because what it arms is a timer
# whose effect is to open the firewall.

. "$(dirname "$0")/lib.sh"

run soil packages --check
assert_exit 1
assert_stderr_has "soil packages --check is not implemented"
run soil packages --apply
assert_exit 1
assert_stderr_has "soil packages --apply is not implemented"
run soil storage --check
assert_exit 1
assert_stderr_has "soil storage --check is not implemented"
run soil sysctl --check
assert_exit 1
assert_stderr_has "soil sysctl --check is not implemented"
run soil firewall --check
assert_exit 1
assert_stderr_has "soil firewall --check is not implemented"
run soil install --apply
assert_exit 1
assert_stderr_has "soil install --apply is not implemented"
run soil units --apply
assert_exit 1
assert_stderr_has "soil units --apply is not implemented"

run soil --check
assert_exit 1
assert_stderr_has "soil --check is not implemented"
run soil --apply
assert_exit 1
assert_stderr_has "soil --apply is not implemented"

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
assert_exit 1
assert_stderr_has "soil firewall --apply is not implemented"
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
