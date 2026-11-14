#!/usr/bin/env bash
# The subid range a service user is delegated, on a host whose `/etc/subuid`
# already holds one (ticket 30 item 6, spec 5.3 step 2).
#
# `/etc/subuid` is the fact, and a call to `useradd` is not. This file asks the
# machine the one question that only the machine can answer — a real ingest of a
# real service, and what range the real `useradd`/`usermod` path left in the real
# `/etc/subuid` — and then checks the two claims the file has to satisfy: the
# service has a range, and no other line claims a uid inside it.
#
# **The service name is one nothing else in the suite uses.** A converged service
# converges before its user is looked at, so a second ingest of a name an earlier
# suite already created would assert nothing about allocation at all; a workload
# of its own is what makes the mutator create the user, which is the step that
# allocates.
#
# This file hangs without the fix it is for. `users.free_block` asks whether the
# base fell inside a line already taken rather than whether the candidate
# overlaps one, so a host whose `/etc/subuid` holds a single ordinary range
# answers true of every later candidate too and the walk never advances. There is
# no `timeout` here on purpose: `tests/lxc.sh` already gives every suite a wall
# clock and turns a suite that overruns it into a failure, and reaching around
# that to bound a hang faster would be the harness rewritten to make one test
# pass.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not stand-ins: a real `useradd` against a real
# `/etc/passwd` and a real `/etc/subuid`, because the claim is what the host
# allocated. `.venv/bin` is kept first because it is the checkout's interpreter
# and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
# The real path, not a relocated one: stage_config writes where guarden reads,
# and /etc/guarden is absent on a host where `soil install` has never run.
stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr service ingest subid-probe-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stderr_empty
assert_stdout_has "subid-probe-production"

# The range is delegated, and it is 65536 wide: which start the host hands out is
# the host's arithmetic, so the start is read back rather than pinned.
assert_passwd subid-probe-production
probe_subuid=$(awk -F: '$1 == "subid-probe-production" { print $2 }' /etc/subuid)
probe_subgid=$(awk -F: '$1 == "subid-probe-production" { print $2 }' /etc/subgid)
assert_subid /etc/subuid subid-probe-production "$probe_subuid" 65536
assert_subid /etc/subgid subid-probe-production "$probe_subgid" 65536

# **A distinct range per service is a fact rather than an intention.** The file is
# the machine's own, including every range the image and every earlier service
# left in it, and this is the whole of the claim: the range this service holds is
# one no other line claims a uid of. A wider line covers a narrower one without
# ever repeating a start, so the comparison is on ranges — which is what a
# container's own mapping collides on.
_capture python3 "$GUARDEN_ROOT/tests/t30-subid.py" /etc/subuid subid-probe-production
if [ "$GUARDEN_EXIT" != 0 ]; then
    _fail "the range /etc/subuid delegated to subid-probe-production is not a free one: $(cat "$GUARDEN_STDERR")"
fi