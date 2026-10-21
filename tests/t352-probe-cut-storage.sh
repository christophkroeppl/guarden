#!/usr/bin/env bash
# machine: fresh
# The probe cut's storage conditions, and the wait built on them (ticket 352).
#
# Two halves, and only one of them is executable in a cut:
#
#   tests/probestate.sh  the three conditions, asked on a machine. This file
#                        runs it on this machine: the green answer is this cut's
#                        own storage, and the forced answers are staged on this
#                        machine's real paths.
#   tests/probecut.sh    the cut and the wait. It drives `lxc`, which does not
#                        exist inside a cut, so what is executed here is its
#                        refusal paths and its classification of a machine that
#                        cannot be asked; the loop's own shape is pinned as text.
#                        That boundary is `t10-failure-messages.sh`'s, recorded
#                        for the runner and true here for the same reason.
#
# **The loop was measured on a host, against a real probe cut of
# `guarden-golden/base`**: the green path, a probe whose `soil/state` was forced
# to `migrated`, and a probe that could not be exec'd. A full rebuild was not run
# — it costs 45-60 minutes and destroys the shared golden — so the claim that a
# whole `provision` exits 0 with this check in it is **not** made here; what was
# measured is the check `provision` calls, and the call itself.
#
# machine: fresh because the two forced answers are written to this machine's own
# `/var/lib/guarden/soil/`, and a machine that carries a wrong state file into
# the next suite would be a premise nothing states.

. "$(dirname "$(readlink -f "$0")")/lib.sh"

state=/var/lib/guarden/soil/state
marker=/var/lib/guarden/soil/reboot-required
guest=$GUARDEN_ROOT/tests/probestate.sh
host=$GUARDEN_ROOT/tests/probecut.sh
runner=$GUARDEN_ROOT/tests/lxc.sh

[ -r "$guest" ] || _fail "$guest is not in the machine, so the conditions a cut polls are not the ones asserted here"
[ -f "$host" ] || _fail "$host is not in the machine"
[ -f "$runner" ] || _fail "$runner is not in the machine"

# --- the guest half, on this machine ---------------------------------------
#
# **The green answer is this machine's own.** A cut of a converged golden
# carries the converted storage state — that is the premise every suite rides —
# and the check reads it from the machine instead of being told it.
run_installed sh "$guest"
assert_exit 0
assert_stdout_has 'state=done marker=absent snapper=ok'

# **A state the conversion has not reached is refused, and the line says which
# condition failed.** The other two are left alone and still read `absent` and
# `ok`, so the exit 1 can only be the state: a check that answered `1` for some
# other reason would not carry this line.
cp -p "$state" "$GUARDEN_FIXTURES/state.aside"
printf 'migrated\n' >"$state"
run_installed sh "$guest"
assert_exit 1
assert_stdout_has 'state=migrated marker=absent snapper=ok'

# and put back: the same measurement in the other direction, which is what makes
# the refusal above a fact about the file rather than about the run.
cp -p "$GUARDEN_FIXTURES/state.aside" "$state"
run_installed sh "$guest"
assert_exit 0
assert_stdout_has 'state=done marker=absent snapper=ok'

# **An outstanding reboot is refused on its own.** This is the condition the
# ticket's incident is about: a machine that took `state=done` before its last
# reboot carries the marker, and a check that only looked at the state would
# call it converged.
: >"$marker"
run_installed sh "$guest"
assert_exit 1
assert_stdout_has 'state=done marker=present snapper=ok'
rm -f "$marker"
run_installed sh "$guest"
assert_exit 0

# **No record at all is not a converged one.** A missing state file reads as
# `none` — the word the conversion's own reader uses — and `none` is not `done`,
# so an absent file cannot pass by being empty.
mv "$state" "$GUARDEN_FIXTURES/state.none"
run_installed sh "$guest"
assert_exit 1
assert_stdout_has 'state=none'
mv "$GUARDEN_FIXTURES/state.none" "$state"

# --- the host half: what a machine without `lxc` can still execute ----------
#
# **A machine that cannot be asked is "did not come up" and not "drifted
# storage"**, and that is decided by whether the evidence line came back at all.
# Nothing is shadowed here: `/nonexistent/lxc` fails to exec, so no evidence line
# is ever produced — the same observable a wedged guest agent produces, measured
# 2026-10-21 as "Context ID not set in volatile.vsock_id" for 40+ minutes while
# LXD's own state said RUNNING.
GUARDEN_LXC_PROBE_WAIT=3
export GUARDEN_LXC_PROBE_WAIT
run_installed "$host" check /nonexistent/lxc guarden-golden
assert_exit 1
assert_one_diagnostic 'error:'
assert_stderr_has 'the probe cut did not come up, so its storage state was never read'
assert_stderr_lacks 'does not carry the converged storage state'
unset GUARDEN_LXC_PROBE_WAIT

# A cut that cannot happen is refused before any waiting: the source is named and
# the failure is the cut's, not the storage's.
run_installed "$host" cut /nonexistent/lxc guarden-golden/base guarden-probe
assert_exit 1
assert_one_diagnostic 'error:'
assert_stderr_has 'cannot cut a probe from guarden-golden/base'

# and a verb or an argument count that does not exist is rejected input (exit 2),
# not a wait that answers nothing.
run_installed "$host"
assert_exit 2
assert_stderr_has 'usage: probecut.sh'
run_installed "$host" cut /nonexistent/lxc guarden-golden/base
assert_exit 2
run_installed "$host" nonsense /nonexistent/lxc guarden-golden/base guarden-probe
assert_exit 2

# --- the host half: the shape a cut cannot drive ---------------------------
#
# **Presence checks, and nothing more.** An edit that keeps every literal is
# invisible to them; the loop's behaviour is the host measurement named at the
# top of this file. What they are for is the drift the extraction could grow: a
# budget back to a count of polls, an "answered" decided by an exit code, and a
# second copy of the conditions living beside the first.
budget=$(grep -vE '^[[:space:]]*#' "$host" | grep -cF -- 'budget=${GUARDEN_LXC_PROBE_WAIT:-' || true)
[ "$budget" = 1 ] || _fail "the wait no longer takes its wall clock from GUARDEN_LXC_PROBE_WAIT ($budget site(s))"
deadline=$(grep -vE '^[[:space:]]*#' "$host" | grep -cF -- '[ "$SECONDS" -ge "$budget" ]' || true)
[ "$deadline" = 1 ] || _fail "the wait no longer stops at the budget its caller named ($deadline site(s))"
evidence=$(grep -vE '^[[:space:]]*#' "$host" | grep -cF -- 'state=*)' || true)
[ "$evidence" = 1 ] || _fail "the wait no longer recognises the evidence line as the machine's answer ($evidence site(s))"
converged=$(grep -vE '^[[:space:]]*#' "$host" | grep -cF -- '[ "$rc" -eq 0 ] && return 0' || true)
[ "$converged" = 1 ] || _fail "the wait no longer treats a converged answer as its only success ($converged site(s))"
for sig in 'the probe cut carries the converged state' \
    'does not carry the converged storage state' \
    'the probe cut did not come up, so its storage state was never read'; do
    n=$(grep -vE '^[[:space:]]*#' "$host" | grep -cF -- "$sig" || true)
    [ "$n" -ge 1 ] || _fail "the host half lost one of its three lines: $sig"
done

# the runner calls it once, from provision, and the gate it replaced is gone.
assign=$(grep -cE '^PROBE_CUT=\$REPO/tests/probecut\.sh[[:space:]]*$' "$runner" || true)
[ "$assign" = 1 ] || _fail "the runner does not name the probe cut's check in one assignment ($assign site(s))"
calls=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- '"$PROBE_CUT" cut "$LXC" "$GOLDEN/$SNAPSHOT"' || true)
[ "$calls" = 1 ] || _fail "the runner calls the probe cut's check $calls time(s) from provision; once is the set"
gate=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'exec -T "$probe" -- true' || true)
[ "$gate" = 0 ] || _fail "the runner gates the probe on 'exec … true' again, and that gate means the agent is up, not that the machine has finished"

# **One copy of the conditions, and it is the shipped one.** The runner is asked
# about too: the inline three-condition test this ticket replaced lived in it, and
# a copy put back beside the shipped one would let the host's question and the
# machine's answer drift apart with nothing failing.
guest_copies=$(grep -vE '^[[:space:]]*#' "$guest" | grep -cF -- 'snapper -c root get-config' || true)
[ "$guest_copies" = 1 ] || _fail "probestate.sh asks for the root snapper configuration $guest_copies time(s); one condition is the set"
runner_copies=$(grep -vE '^[[:space:]]*#' "$runner" | grep -cF -- 'snapper -c root get-config' || true)
[ "$runner_copies" = 0 ] || _fail "the runner carries its own copy of the probe's snapper condition ($runner_copies site(s)); the three conditions live in tests/probestate.sh"
