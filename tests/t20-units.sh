#!/usr/bin/env bash
# soil units, and the two modes as a whole.
#
# The recurring jobs are the phase's content: a routine snapshot on a schedule
# and the mark reconciler beside it. Both are the ones that have to be enabled,
# because an installed timer that nothing started is a snapshot policy nobody has
# and a mark nobody writes.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014), and both the assertions below and the programs under them have to
# reach the real `getent`, `dpkg-query`, `systemctl`,
# `snapper`, `sysctl` and `install` -- otherwise this file is asking a fake what
# it had been asked to do, which is the whole thing the rewrite exists to stop.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# This file owns the phase's starting state, because a timer left enabled by
# whichever file ran before it would make the first check below a fact about the
# machine rather than about this run. What the phase converges is the same state,
# and the machine is left in it.
for timer in guarden-snapshot.timer guarden-pin-sync.timer; do
    systemctl disable --now "$timer" >/dev/null 2>&1 || :
done
rm -f /etc/systemd/system/guarden-snapshot.service \
    /etc/systemd/system/guarden-snapshot.timer \
    /etc/systemd/system/guarden-pin-sync.service \
    /etc/systemd/system/guarden-pin-sync.timer
systemctl daemon-reload >/dev/null 2>&1 || :

# The phase enables three timers and installs two of them: the cleanup timer and
# its oneshot belong to `storage`, which is the phase before this one in spec
# 6.1's order, and a timer whose oneshot is absent cannot be started. That phase
# is converged here for what this one depends on rather than stood in for,
# because a missing prerequisite is a prerequisite failure and not a fact about
# this phase; its own drift is t20-storage's subject and is not this file's exit
# code to judge. The group is `install`'s and the same reason applies.
if ! getent group guarden >/dev/null; then
    groupadd --system guarden
fi
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run soil storage --apply
assert_file_exists /etc/systemd/system/guarden-snapper-cleanup.timer
assert_file_exists /etc/systemd/system/guarden-snapper-cleanup.service

run soil units --check
assert_exit 1
assert_stderr_has "drift: /guarden-snapshot.service is installed"

run soil units --apply
assert_exit 0
assert_file_has /etc/systemd/system/guarden-snapshot.service \
    "ExecStart=/usr/lib/guarden/bin/weedr service snapshot --all"
assert_file_has /etc/systemd/system/guarden-pin-sync.service \
    "ExecStart=/usr/lib/guarden/bin/weedr pin sync"
assert_file_lacks /etc/systemd/system/guarden-snapshot.service \
    "ExecStart=/usr/bin/flock"
assert_file_lacks /etc/systemd/system/guarden-pin-sync.service \
    "ExecStart=/usr/bin/flock"

# An installed unit is not an installed behaviour, and this one is the reason:
# the reconciler takes the snapshots lock itself (`reconcile.run` holds
# `conf.lock("snapshots")`), and the `flock(1)` wrapper this used to carry
# opened a second file description on the same key, so every start blocked on
# the wrapper's own hold forever. No suite ever started the service, so the
# files could be perfect while the unit was dead. 124 is `timeout`'s own code —
# the start did not complete, which is the defect, not an environment fact.
run timeout 60 systemctl start guarden-pin-sync.service
if [ "$GUARDEN_EXIT" -eq 124 ]; then
    _fail "guarden-pin-sync.service did not complete in 60s: the snapshots lock is held by a second wrapper"
fi
assert_exit 0

# All three are enabled *and* running, and the two claims are separate: an
# enabled timer that was not started waits for nothing, and a started timer that
# was not enabled does not survive the next boot.
assert_enabled guarden-snapshot.timer
assert_active guarden-snapshot.timer
assert_enabled guarden-pin-sync.timer
assert_active guarden-pin-sync.timer
assert_enabled guarden-snapper-cleanup.timer
assert_active guarden-snapper-cleanup.timer

# The reconciler is a root action and `stakes` is not: `stakes` runs
# unprivileged and writing snapper's metadata is not something it can do, so the
# marks have to be written by something that can. It is also the phase that
# converges the snapshot ladder, so a box that is not converged is a box whose
# retention is a convention.
assert_file_has /etc/systemd/system/guarden-snapshot.service "Requires=snapperd.service"

# A routine snapshot is never marked, and the unit that makes them says so.
assert_file_has /etc/systemd/system/guarden-snapshot.service "Type=oneshot"

run soil units --check
assert_exit 0

# The two modes, as the spec states them: `--check` is safe over ssh at any time
# and `soil --check` is every phase. Which phases drift is the host's business --
# a machine this file has not converged has every package phase item on it -- so
# the claim is that the whole-host check reads the host and finds something to
# say, not what it found.
run soil --check
assert_exit 1
assert_stderr_has "drift:"

# `--check` changed nothing, so the drift it reported is still there.
run soil units --check
assert_exit 0
run soil --check
assert_exit 1
assert_stderr_has "drift:"

# There is deliberately no `soil --apply` here. This file is about the `units`
# phase and drives it directly, so every exit code below is the phase's own
# answer rather than a fact about the five phases before it. The claim the old
# whole-host block was making -- a second apply creates nothing -- is asked of
# this file's own phase instead, where it can be answered.
accounts=$(getent passwd | wc -l)
run soil units --apply
assert_exit 0
[ "$(getent passwd | wc -l)" = "$accounts" ] \
    || _fail "a second apply created an account"
assert_enabled guarden-snapshot.timer
assert_active guarden-pin-sync.timer
run soil units --check
assert_exit 0
