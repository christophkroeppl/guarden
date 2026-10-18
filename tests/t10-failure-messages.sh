#!/usr/bin/env bash
# The runner's failure lines, asserted: `_failure_message` is driven every way
# a gate can read it. The runner itself cannot be driven from here — a suite
# runs inside the machine, where `lxc` does not exist — which is why the text
# lives in tests/failure_messages.sh and why this file can pin it.
#
# (ticket 266; adversarial review rejected the round that shipped these lines
# with nothing asserting them, on the ground that their whole value is their
# text)
#
# machine: shared

. "$(dirname "$0")/lib.sh"
. "$GUARDEN_ROOT/tests/failure_messages.sh"

_line() {
    _failure_message t10-probe "$1" "${2:-}" 2>&1
}

line=$(_line 124)
echo "$line" | grep -qF 'exceeded 180s' || _fail "124 does not name the wall clock: $line"
echo "$line" | grep -qF 'reports 124' || _fail "124 does not carry its code: $line"

line=$(_line 137)
echo "$line" | grep -qF '128+9' || _fail "137 does not read as signal 9: $line"
echo "$line" | grep -qF 'signal' || _fail "137 does not name a signal death: $line"
case "$line" in
    *exceeded*) _fail "137 claims the wall clock: $line" ;;
esac

line=$(_line 143)
echo "$line" | grep -qF '128+15' || _fail "143 does not read as signal 15: $line"

line=$(_line 192)
echo "$line" | grep -qF '128+64' || _fail "192 (SIGRTMAX) does not read as signal 64: $line"

line=$(_line 0)
echo "$line" | grep -qF 'code 0' || _fail "a zero code is not named a runner defect: $line"

line=$(_line 1 "t10-probe 1")
echo "$line" | grep -qF 'stopped on an assertion' \
    || _fail "a confirmed 1 is not named an assertion: $line"

line=$(_line 124 "t10-probe 124")
echo "$line" | grep -qF '124 on its own' \
    || _fail "a self-inflicted 124 is not told from the wall clock: $line"

line=$(_line 124 "other-suite 124")
echo "$line" | grep -qF 'exceeded' \
    || _fail "a stale word turned a wall-clock kill into a self-inflicted 124: $line"

line=$(_line 1 "")
echo "$line" | grep -qF 'did not confirm' \
    || _fail "an unconfirmed 1 is not named as unconfirmed: $line"
echo "$line" | grep -qF 'absent' || _fail "an unconfirmed 1 does not report the status as absent: $line"

line=$(_line 1 "other-suite 1")
echo "$line" | grep -qF 'did not confirm' \
    || _fail "a stale status word is not treated as unconfirmed: $line"

line=$(_line 127)
echo "$line" | grep -qF 'exited 127' || _fail "127 is not named: $line"

line=$(_line 97)
echo "$line" | grep -qF 'exited 97' || _fail "97 is not named: $line"

# **The wall value is plumbing, and it flows.** The runner sets SUITE_TIMEOUT
# from GUARDEN_LXC_SUITE_TIMEOUT and passes it through; pinning the default
# 180 alone would stay green on a runner that never read the variable.
export SUITE_TIMEOUT=456
line=$(_line 124)
echo "$line" | grep -qF 'exceeded 456s' || _fail "a configured wall clock does not reach the line: $line"
unset SUITE_TIMEOUT

# **The runner calls this function twice, every `error:` line in it is one of
# six known, and every bound it runs is the measured shape.** `_push`
# delivers tests/lxc.sh into the machine, so the drift the extraction could
# grow is greppable from here, and each pin spans spellings rather than one of
# them: the count moves on any seventh line naming `error:` in any form (an
# `echo`, a format variable, a continuation line); the six signatures pin
# each line's leading literal over the comment-stripped stream, so a site that
# changed or went away fails — while a reword confined to a continuation
# line's tail beyond that literal is not caught, and the pins catch presence,
# not location: a reword paired with the literal kept elsewhere stays green.
# **The control-flow chain is pinned link by link**: a runner that lost any
# one of these would report a failing suite as a pass, and no text pin above
# can see that — the return, both verdict lines, both success tests, the
# guest's status capture and its re-raise, the host's capture of the exec's
# status, both counter increments and the run's final exit test are pinned by
# exact form, each measured to move on its own mutation and no other. **And
# the boundary of the whole approach, stated so it cannot be mistaken for
# more**: these are presence checks on text — an edit that keeps every literal
# (an `exit 0` inserted just before the exit test) is invisible to a presence
# check; the adjacency pins in this block close the named instances of that
# class, and a residue remains that only executing the runner could close,
# which no in-machine suite can do to a host process. That boundary is ticket
# 266's; what is asserted here is every literal the chain is built from, each
# pinned by its own measured mutation.
# Every pin reads the comment-stripped stream — the timeout assignment anchor
# and the two adjacency pins read the raw file, adjacency being about the
# physical next line, which stripping would destroy — so prose quoting a pin
# cannot break the pin, and a commented-out call cannot satisfy one; a
# trailing `# …` naming a token would still count.
runner=$GUARDEN_ROOT/tests/lxc.sh
[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"
calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c '_failure_message "' || true)
[ "$calls" = 2 ] || _fail "the runner has $calls _failure_message call sites; two is the set (the marker branch and the plain one)"
marker_calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '_failure_message "\$name" "\$rc" "\$marker"[[:space:]]*$' || true)
[ "$marker_calls" = 1 ] || _fail "the marker call is gone, duplicated, or silenced; it must end its line exactly once"
plain_calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '_failure_message "\$name" "\$rc"[[:space:]]*$' || true)
[ "$plain_calls" = 1 ] || _fail "the plain call is gone, duplicated, or silenced; it must end its line exactly once"
sites=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c 'error:' || true)
[ "$sites" = 6 ] || _fail "the runner names 'error:' on $sites non-comment lines; a fixed set of six is the enumeration"
# (ticket 271 split one line into two: a lock that was held and a lock that
# could not be measured were printed as the same failure, and the ticket's
# whole complaint is that the message could not tell them apart.)
for sig in "printf 'error: %s\\n'" "printf 'error: fuser is not on %s, so the apt lock wait cannot run; '" "printf 'error: %s is missing %s, so no check of the wait can come free\\n'" "printf 'error: %s still holds the apt lock after %ss (held by %s; last answer: %s); '" "printf 'error: the apt locks on %s could not be shown free after %ss (last answer: %s); '" "printf 'error: cannot cut a clean %s\\n'"; do
    # `grep -c`, not `grep -q`: a `grep -q` that exits on its first match sends
    # SIGPIPE to the `grep -vE` still writing upstream, and under `pipefail`
    # the pipeline then reads as a failed match — measured here as a race that
    # failed a different signature on each of two identical runs.
    n=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- "$sig" || true)
    [ "$n" -ge 1 ] || _fail "the runner lost one of its six known error lines: $sig"
done
kills=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c -- '--foreground --signal=KILL' || true)
[ "$kills" = 6 ] || _fail "the runner carries $kills '--foreground --signal=KILL' uses; six is the measured set (lock-file check, probe poll, cloud-init status, evidence, the suite's marker, the suite itself)"
grep -qE '^SUITE_TIMEOUT=\$\{GUARDEN_LXC_SUITE_TIMEOUT:-' "$runner" \
    || _fail "the runner no longer takes its wall clock from GUARDEN_LXC_SUITE_TIMEOUT"
kill_arg=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '--signal=KILL "$SUITE_TIMEOUT"' || true)
[ "$kill_arg" -ge 1 ] || _fail "the runner no longer feeds SUITE_TIMEOUT into its kill"
# **Ticket 271's half of the wait, pinned the same way as everything above: a
# wall clock instead of a count of checks, both budgets taken from the variables
# that name them, the guest's half of the measurement read from the file a suite
# runs, the evidence printed before the verdict, and the two verdicts kept
# apart.** A wait that had gone back to counting polls — whose wall time nobody
# knew, hence the old "at least 300s" — or that printed an evidence block it
# never named, fails here rather than in the next occurrence.
grep -qE '^APT_LOCK_WAIT=\$\{GUARDEN_LXC_APT_LOCK_WAIT:-' "$runner" \
    || _fail "the runner no longer takes its apt-lock budget from GUARDEN_LXC_APT_LOCK_WAIT"
grep -qE '^CLOUD_INIT_WAIT=\$\{GUARDEN_LXC_CLOUD_INIT_WAIT:-' "$runner" \
    || _fail "the runner no longer bounds cloud-init's status wait from GUARDEN_LXC_CLOUD_INIT_WAIT"
deadline=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '-lt "$APT_LOCK_WAIT"' || true)
[ "$deadline" -ge 1 ] || _fail "the runner's lock wait no longer polls until the APT_LOCK_WAIT clock runs out"
guest=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'tests/aptlock.sh' || true)
[ "$guest" -ge 1 ] || _fail "the runner no longer reads the guest half of the wait from tests/aptlock.sh"
for verb in probe evidence; do
    n=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- "aptlock $verb" || true)
    [ "$n" -ge 1 ] || _fail "the runner no longer asks the guest for 'aptlock $verb'"
done
# `grep -c`, not `grep -q`, for the same SIGPIPE reason the signature loop
# gives: a `grep -q` that exits on its first match can leave the `grep -vE`
# upstream writing into a closed pipe, and under `pipefail` the pipeline then
# reads as a failed match — which is exactly how this pin failed the first time
# it was written (measured: "the runner no longer prints its evidence block
# under a line that names it", on a line the runner carried all along).
note=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- "note: apt lock evidence on %s, waited %ss:" || true)
[ "$note" -ge 1 ] || _fail "the runner no longer prints its evidence block under a line that names it"
returns=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^[[:space:]]*return "\$rc"[[:space:]]*$' || true)
[ "$returns" = 1 ] || _fail "the runner does not return the suite's own code exactly once; a failure could be recorded as a pass"
passes=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE 'line pass "\$name"[[:space:]]*$' || true)
[ "$passes" = 1 ] || _fail "the runner's pass verdict is not recorded exactly once, unsilenced"
fails=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE 'line fail "\$name"[[:space:]]*$' || true)
[ "$fails" = 1 ] || _fail "the runner's fail verdict is not recorded exactly once, unsilenced"
rc_tests=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE 'if \[ "\$rc" -eq 0 \]; then[[:space:]]*$' || true)
[ "$rc_tests" = 2 ] || _fail "the runner's success tests are not the measured pair, unsuffixed; a flipped or escaped verdict reads as the other one"
rc_capture=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'rc=\$?' || true)
[ "$rc_capture" = 1 ] || _fail "the guest wrapper no longer captures the suite's own status"
counters=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE 'failures=\$\(\(failures \+ 1\)\)[[:space:]]*$' || true)
[ "$counters" = 2 ] || _fail "the failure counter no longer increments, unsuffixed, on both failure paths"
exit_rc=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'exit \$rc' || true)
[ "$exit_rc" = 1 ] || _fail "the guest wrapper no longer re-raises the suite's status; a failure would exit 0"
host_cap=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '</dev/null \|\| rc=\$\?[[:space:]]*$' || true)
[ "$host_cap" = 1 ] || _fail "the host no longer captures the exec's status into rc, unsuffixed"
final_test=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '\[ "\$failures" -eq 0 \][[:space:]]*$' || true)
[ "$final_test" = 1 ] || _fail "the run's exit test is gone or suffixed; a failing run could exit green"
call_site=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '_run_suite "\$name" \|\| rc=\$\?[[:space:]]*$' || true)
[ "$call_site" = 1 ] || _fail "the call site no longer captures _run_suite's status; the verdict is decoupled from it"
continue_adj=$(grep -A1 -E 'failures=\$\(\(failures \+ 1\)\)[[:space:]]*$' "$runner" | grep -cE '^[[:space:]]*continue[[:space:]]*$' || true)
[ "$continue_adj" = 1 ] || _fail "the failure path no longer runs straight into its continue; a failed suite would be cached as a hit"
exit_before=$(grep -B1 -E '\[ "\$failures" -eq 0 \][[:space:]]*$' "$runner" | grep -cE '^[[:space:]]*exit' || true)
[ "$exit_before" = 0 ] || _fail "an exit sits immediately before the run's exit test; a failing run would exit green"
ledger_pass=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'pass\t%s' || true)
[ "$ledger_pass" = 1 ] || _fail "the ledger's pass arm is not the measured literal"
ledger_fail=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'fail\t%s' || true)
[ "$ledger_fail" = 2 ] || _fail "the ledger's fail arm is not the measured literal"
dispatch=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'run) shift; cmd_run "$@" ;;' || true)
[ "$dispatch" = 1 ] || _fail "the run verb's dispatch arm is gone; the run's status could not propagate"
cd_guard=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'exit 97' || true)
[ "$cd_guard" = 1 ] || _fail "the wrapper's cd guard is gone; a missing repo would exit as a pass"
