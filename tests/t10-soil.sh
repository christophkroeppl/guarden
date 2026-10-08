#!/usr/bin/env bash
# soil is the only program with two modes (spec 6.1). Every phase takes
# `--check` and `--apply`, `soil --check` is every phase, and `soil list` names
# them. guarden has no lockout failsafe, so there is no flag that arms one.
#
# This file is the interface, not the converges: that every phase accepts both
# modes and that a phase which exists never rejects its own name. What a phase
# converges is ticket 20's subject and is tested there.

. "$(dirname "$0")/lib.sh"

for phase in packages storage sysctl firewall install units; do
    run soil "$phase" --check
    assert_not_rejected
done

# `packages --apply` is the one exception, and not because its apply is wrong: it
# is the only phase that reaches the network and the only one that can refuse an
# input, the pinned podlet record being a repository input and a third-party
# binary guarden will not fetch unpinned. So its answer depends on a record rather
# than on the host alone, and this file asserts the interface while `t20` and
# `t130` assert what the record says. The other five have nothing to reject.
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

# guarden has no lockout failsafe, so the flag that armed it is gone. It is a
# rejected input wherever it appears -- a silently ignored one would let a
# caller believe a failsafe was in force when nothing of the sort exists.
stage_podlet_release
run soil firewall --apply --deadman
assert_exit 2
assert_one_diagnostic "error:"
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

# --------------------------------------------------------------------------
# the drift line, which is the diagnostic contract and not a converge
# --------------------------------------------------------------------------
#
# **`Item` describes the converged state, so the line has to say which side of it
# the host is on.** A bare `error: drift: the ferm package is installed` reads as
# a claim about the present, and an operator reading it cannot tell whether `ferm`
# is fine and something else is wrong or whether `ferm` is missing and needs
# installing — two opposite actions from one line. The line is one line, prefixed,
# carries the word `drift` the spec names, names the item, and says the fact.
#
# A staged host, because the question is the shape of the line and not what any
# one phase converges: `storage --check` is the phase with the most items and
# none of them reaches the network, apt or podman.
guarden_prefix
stage_config guarden.toml
run soil storage --check
assert_exit 1
# A directory row from spec 2.1's table, and one the applies above cannot have
# converged: those ran against the real machine and this block is staged, so the
# line can only have come from the host the prefix names. The queue's group bits
# are `rwx` rather than `r-x` for the reason ADR-0003 gives — `furrow` enqueues
# into it — so the string names the mode, the owner and the group.
assert_stderr_has "drift: /var/lib/guarden/queue is 0770 root:guarden"
assert_stderr_has "does not hold on this host"

# **Every** drift line carries the fact, not only this one. One drift line with
# the fact and six without it is a diagnostic surface that is right once and
# wrong six times, and a per-item count is the only way that is caught.
total=$(grep -c '^error: drift: ' "$GUARDEN_STDERR" || true)
carrying=$(grep -c 'does not hold on this host$' "$GUARDEN_STDERR" || true)
[ "${total:-0}" -gt 1 ] || _fail "the phase reported ${total:-0} drift lines, so this says nothing"
[ "${total:-0}" = "${carrying:-0}" ] \
    || _fail "$total drift lines and ${carrying:-0} of them say which side of the requirement the host is on"
