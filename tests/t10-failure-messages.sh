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
# five known, and every bound it runs is the measured shape.** `_push`
# delivers tests/lxc.sh into the machine, so the drift the extraction could
# grow is greppable from here, and each pin spans spellings rather than one of
# them: the count moves on any sixth line naming `error:` in any form (an
# `echo`, a format variable, a continuation line); the five signatures pin
# each line's leading literal over the comment-stripped stream, so a site that
# changed or went away fails — while a reword confined to a continuation
# line's tail beyond that literal is not caught, and the pins catch presence,
# not location: a reword paired with the literal kept elsewhere stays green.
# **The control-flow layer is pinned as well**: a runner that returned the
# wrong code or recorded the wrong verdict would report a failing suite as a
# pass, and no text pin above can see that — so the return, both verdict
# lines, both success tests, the guest's status capture and both counter
# increments are pinned by exact form.
# Every pin reads the comment-stripped stream — the timeout assignment anchor
# alone reads the raw file, and its `^` and column-0 literal are what no
# comment line can satisfy (a col-0 payload line elsewhere could, though;
# nothing does today) — so prose quoting a pin cannot break the pin, and a
# commented-out call cannot satisfy one; a trailing `# …` naming a token
# would still count.
runner=$GUARDEN_ROOT/tests/lxc.sh
[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"
calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c '_failure_message "' || true)
[ "$calls" = 2 ] || _fail "the runner has $calls _failure_message call sites; two is the set (the marker branch and the plain one)"
marker_calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '_failure_message "\$name" "\$rc" "\$marker"[[:space:]]*$' || true)
[ "$marker_calls" = 1 ] || _fail "the marker call is gone, duplicated, or silenced; it must end its line exactly once"
plain_calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '_failure_message "\$name" "\$rc"[[:space:]]*$' || true)
[ "$plain_calls" = 1 ] || _fail "the plain call is gone, duplicated, or silenced; it must end its line exactly once"
sites=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c 'error:' || true)
[ "$sites" = 5 ] || _fail "the runner names 'error:' on $sites non-comment lines; a fixed set of five is the enumeration"
for sig in "printf 'error: %s\\n'" "printf 'error: fuser is not on %s, so the apt lock wait cannot run; '" "printf 'error: %s is missing %s, so no check of the wait can come free\\n'" "printf 'error: %s still holds the apt lock after 60 checks spread over at least '" "printf 'error: cannot cut a clean %s\\n'"; do
    # `grep -c`, not `grep -q`: a `grep -q` that exits on its first match sends
    # SIGPIPE to the `grep -vE` still writing upstream, and under `pipefail`
    # the pipeline then reads as a failed match — measured here as a race that
    # failed a different signature on each of two identical runs.
    n=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- "$sig" || true)
    [ "$n" -ge 1 ] || _fail "the runner lost one of its five known error lines: $sig"
done
kills=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c -- '--foreground --signal=KILL' || true)
[ "$kills" = 4 ] || _fail "the runner carries $kills '--foreground --signal=KILL' uses; four is the measured set"
grep -qE '^SUITE_TIMEOUT=\$\{GUARDEN_LXC_SUITE_TIMEOUT:-' "$runner" \
    || _fail "the runner no longer takes its wall clock from GUARDEN_LXC_SUITE_TIMEOUT"
kill_arg=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '--signal=KILL "$SUITE_TIMEOUT"' || true)
[ "$kill_arg" -ge 1 ] || _fail "the runner no longer feeds SUITE_TIMEOUT into its kill"
returns=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cE '^[[:space:]]*return "\$rc"[[:space:]]*$' || true)
[ "$returns" = 1 ] || _fail "the runner does not return the suite's own code exactly once; a failure could be recorded as a pass"
passes=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c 'line pass "' || true)
[ "$passes" = 1 ] || _fail "the runner's pass verdict is not recorded exactly once"
fails=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c 'line fail "' || true)
[ "$fails" = 1 ] || _fail "the runner's fail verdict is not recorded exactly once"
rc_tests=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '[ "$rc" -eq 0 ]' || true)
[ "$rc_tests" = 2 ] || _fail "the runner's success tests are not the measured pair; a flipped verdict reads as the other one"
rc_capture=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'rc=\$?' || true)
[ "$rc_capture" = 1 ] || _fail "the guest wrapper no longer captures the suite's own status"
counters=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'failures=$((failures + 1))' || true)
[ "$counters" = 2 ] || _fail "the failure counter no longer increments on both failure paths"
