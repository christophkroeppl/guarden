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

line=$(_line 1 "t10-probe 1")
echo "$line" | grep -qF 'stopped on an assertion' \
    || _fail "a confirmed 1 is not named an assertion: $line"

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
