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

# **The runner calls this function, its error lines are a closed set, and every
# bound it runs is the measured shape.** `_push` delivers tests/lxc.sh into the
# machine, so the drift the extraction could grow is greppable from here.
# Three pins, each spanning spellings rather than one of them: the count of
# non-comment lines naming `error:` (five — four guards and the cut message,
# so an `echo`, a format variable or a reworded line all move it), the count of
# `--foreground --signal=KILL` uses (four — the three bounds and the suite
# exec; round 3 rejected exactly the absence of this on two of them), and the
# configured wall clock reaching the runner through its own assignment.
runner=$GUARDEN_ROOT/tests/lxc.sh
[ -f "$runner" ] || _fail "the runner source is not in the machine at $runner"
grep -q '_failure_message "' "$runner" || _fail "the runner has no _failure_message call site"
sites=$(grep -vE '^[[:space:]]*#' "$runner" | grep -c 'error:' || true)
[ "$sites" = 5 ] || _fail "the runner names 'error:' on $sites non-comment lines; a fixed set of five is the enumeration"
kills=$(grep -c -- '--foreground --signal=KILL' "$runner" || true)
[ "$kills" = 4 ] || _fail "the runner carries $kills '--foreground --signal=KILL' uses; four is the measured set"
grep -qE '^SUITE_TIMEOUT=\$\{GUARDEN_LXC_SUITE_TIMEOUT:-' "$runner" \
    || _fail "the runner no longer takes its wall clock from GUARDEN_LXC_SUITE_TIMEOUT"
grep -qF -- '--signal=KILL "$SUITE_TIMEOUT"' "$runner" || _fail "the runner no longer feeds SUITE_TIMEOUT into its kill"
if grep -qE "printf ['\"]error: %s[^'\"]*(exited|exceeded|died|killed|signal|128\+|wall clock)" "$runner"; then
    _fail "a runner error line reads as a suite failure; the extraction has drifted"
fi
