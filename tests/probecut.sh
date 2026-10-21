#!/usr/bin/env bash
# tests/probecut.sh — cut a probe machine from the snapshot a golden is about to
# serve, and wait for its storage to be the converged one (ticket 352).
#
# This is `cmd_provision`'s last step, and the only check that reads the
# artifact from a machine that reboots from it: the builder's own session sees
# its page cache, and on 2026-10-12 a golden's snapshot was found to carry the
# state before its final apply, visible only to a cut.
#
# **The condition test is the wait.** Measured 2026-10-21: provision died with
# "a cut from guarden-golden/base does not carry the converged storage state" on
# a golden whose conversion had just converged, and the cut's storage was
# perfect when it was measured seconds later. The gate in front of the test was
# `lxc exec … true`, which answers as soon as the guest agent is up — while
# `soil/state`, the reboot marker and snapper's configuration settle *after*
# that. So the three questions are asked on a bounded loop and the loop is the
# wait: the same shape `_reboot` uses with the boot id, for the same reason.
#
# **Two failures, kept apart, because they want different answers.** A probe
# that never answered says nothing about the snapshot — nothing was read — and
# the machine is left in place to look at. A probe that answered and whose
# storage is not converged is the snapshot's own finding. Collapsing the two is
# how the 2026-10-21 failure sent its reader to rebuild a golden that was fine.
#
# **`answered` is decided by the evidence line, not by an exit status.** `lxc
# exec` returns the command's status, so a check that only read the code could
# not tell "the machine said its state is `migrated`" from "the agent did not
# answer" — and `tests/probestate.sh` always prints its line, whichever way the
# conditions fall, which is what makes the line the test.
#
# Verbs:
#   cut <lxc> <source> <probe>   delete a stale <probe>, cut it from <source>
#                                (an instance or `<instance>/<snapshot>`), wait,
#                                and delete it again on success. On failure the
#                                probe is left running: it is the machine under
#                                suspicion.
#   check <lxc> <instance>       wait on a machine that already exists, which is
#                                what makes the wait measurable without a rebuild.
#
# The conditions themselves are `tests/probestate.sh`, shipped to the machine
# with `sh -c` the way the runner ships `tests/aptlock.sh`: the bytes asked for
# are the bytes a suite runs in a machine.
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")

usage() {
    printf 'usage: %s {cut|check} <lxc> <source-or-instance> [probe]\n' "${0##*/}" >&2
    exit 2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# **The budget is a wall clock, not a count of attempts.** A count of polls is a
# wait whose length nobody can state without knowing how fast each poll was —
# the lesson ticket 271 paid for in `_wait_cloud_init`. It is overridable
# because a bound is a policy, and a caller that wants a shorter one (a suite, or
# an operator asking whether a machine answers at all) should not have to wait
# out somebody else's number.
budget=${GUARDEN_LXC_PROBE_WAIT:-180}
poll=3

verb=${1:-}
if [ "$#" -gt 0 ]; then
    shift
fi

case $verb in
    cut)
        [ "$#" -eq 3 ] || usage
        lxc=$1 source=$2 probe=$3
        ;;
    check)
        [ "$#" -eq 2 ] || usage
        lxc=$1 instance=$2
        ;;
    *) usage ;;
esac

[ -r "$here/probestate.sh" ] \
    || die "$here/probestate.sh is missing, so there is no condition to wait on"
state_script=$(<"$here/probestate.sh")

# The last evidence line seen, and the last one already printed: an answer that
# changes is news, the same answer every three seconds is not.
evidence=''
printed=''

# _wait <instance>: the conditions, retried until they hold or the budget is
# spent. One of:
#   0  the machine answered and its storage is the converged one
#   1  the machine answered and its storage is not; `evidence` is the last answer
#   2  the machine never answered, so nothing was read
_wait() {
    local instance=$1 out rc
    while :; do
        rc=0
        # **The poll itself is bounded, so a wedged `lxc exec` cannot hold the
        # loop past a single pass.** Without this the budget below is consulted
        # only after the exec returns, and a guest agent that stops answering
        # while LXD still reports RUNNING makes this loop hang rather than
        # expire — measured 2026-10-21 as `Context ID not set in
        # volatile.vsock_id` for 40+ minutes. A 124 from `timeout` leaves `out`
        # empty, so it falls through the `*)` case and is retried like any other
        # unmeasured pass, which is exactly what it is.
        #
        # **`--foreground` is as load-bearing here as it is in
        # `_wait_cloud_init`** (tests/lxc.sh:516-524): without it `timeout` puts
        # the child in a new process group, `lxc exec`'s session does not survive
        # that, and the client waits on a session nobody will close — so the
        # bound would reintroduce the wedge it is here to cap.
        out=$(timeout --foreground --signal=KILL 20 "$lxc" exec -T "$instance" \
            -- sh -c "$state_script" 2>/dev/null) || rc=$?
        case $out in
            state=*)
                evidence=$out
                [ "$rc" -eq 0 ] && return 0
                if [ "$out" != "$printed" ]; then
                    printf '  storage: the probe answered %s (%ss of %ss)\n' \
                        "$out" "$SECONDS" "$budget"
                    printed=$out
                fi
                ;;
            *) : ;;   # no evidence line came back, so nothing was read
        esac
        if [ "$SECONDS" -ge "$budget" ]; then
            [ -n "$evidence" ] && return 1
            return 2
        fi
        sleep "$poll"
    done
}

# fail_wait <status> <what>: the two failures, kept apart and each one line.
fail_wait() {
    case $1 in
        1)
            die "a cut from $2 does not carry the converged storage state after ${SECONDS}s (last answer: $evidence)"
            ;;
        *)
            die "the probe cut did not come up, so its storage state was never read (waited ${SECONDS}s on $2)"
            ;;
    esac
}

case $verb in
    cut)
        "$lxc" delete "$probe" --force >/dev/null 2>&1 || true
        "$lxc" copy "$source" "$probe" >/dev/null 2>&1 \
            || die "cannot cut a probe from $source"
        "$lxc" start "$probe" >/dev/null 2>&1 || die "the probe cut did not start"
        # **The budget's clock starts at the wait**, not at the script: the copy
        # and the start are the cut's cost and not the machine's settling time,
        # and a wall clock that counted them would report a budget it did not
        # spend on waiting.
        SECONDS=0
        rc=0
        _wait "$probe" || rc=$?
        [ "$rc" -eq 0 ] || fail_wait "$rc" "$source"
        "$lxc" delete "$probe" --force >/dev/null 2>&1 || true
        printf '  the probe cut carries the converged state\n'
        ;;
    check)
        SECONDS=0
        rc=0
        _wait "$instance" || rc=$?
        [ "$rc" -eq 0 ] || fail_wait "$rc" "$instance"
        ;;
esac
