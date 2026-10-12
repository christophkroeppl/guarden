#!/usr/bin/env bash
# The runner's failure lines, as one function, so they can be asserted.
#
# `tests/lxc.sh` prints one line per failed suite, and that line is the whole
# of what a gate reader gets for a suite that died without saying why: which
# code, and — for the ambiguous ones — which kind of death. Nothing in the
# machine tier can drive the runner (a suite runs inside the machine and the
# runner does not exist there), so the text logic lives here, where a suite
# can read it, and `_failure_message` is pure: name, code and the guest's
# status word in, one diagnostic out. The machine-facing halves — the exec
# that produces the code, the read-back of the guest's status word — stay in
# the runner.
#
# (ticket 266; adversarial review rejected the round that shipped these lines
# with nothing asserting them — their whole value is their text)

# _failure_message <name> <rc> [status]
#
# `status` is the guest's `"<name> <rc>"` word, or empty when the machine did
# not answer. It is read for rc=1 only, where an assertion and a lost
# transport share the code.
_failure_message() {
    local name=$1 rc=$2 status=${3:-}
    local wall=${SUITE_TIMEOUT:-180}
    if [ "$rc" -eq 124 ]; then
        # 124 is `timeout`'s own code for "the wall clock fired" — measured:
        # `timeout --foreground --signal=KILL N sleep M` exits 124 on expiry
        # and passes the child's code through otherwise (1, 143 and 137 all
        # measured). An earlier branch keyed on 137 and printed "exceeded the
        # wall clock" for it, which never fired: 137 is what a signal death
        # looks like, not a timeout.
        printf 'error: %s exceeded %ss; `timeout` reports 124 — the killed client is the runner, the guest may still be running\n' \
            "$name" "$wall" >&2
    elif [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ]; then
        # 128+n is the shell's shape for death by signal n — from the runner's
        # own kill or from inside the machine, where a guest OOM kill arrives
        # as 137 too; the runner cannot tell those apart and does not say which.
        printf 'error: %s exited %s = 128+%s; a suite that dies on a signal reports nothing\n' \
            "$name" "$rc" "$((rc - 128))" >&2
    elif [ "$rc" -eq 1 ]; then
        if [ "$status" = "$name 1" ]; then
            printf 'error: %s exited 1; the suite stopped on an assertion, and its own line is above\n' \
                "$name" >&2
        else
            printf 'error: %s exited 1 and the machine did not confirm the suite ran; ' \
                "$name" >&2
            printf 'the exec itself may have failed (status: %s)\n' "${status:-absent}" >&2
        fi
    else
        # Every other code — 97 from a failed `cd`, 127 from a missing suite
        # file, and so on — is named, with whatever the suite said above it.
        printf 'error: %s exited %s; anything the suite said is above this line\n' \
            "$name" "$rc" >&2
    fi
}
