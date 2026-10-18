#!/usr/bin/env bash
# machine: fresh
# The cut's apt-lock wait, where it can be driven (ticket 271).
#
# `tests/aptlock.sh` is the guest half of `_wait_cloud_init`: the runner ships
# those bytes into the machine before the checkout is pushed, and this suite
# runs the same file in the machine — so the probe and the evidence asserted
# here are the bytes a cut runs, not a copy of them. What a suite cannot drive
# is the runner's own loop, which needs `lxc` and does not exist in the guest;
# `tests/t10-failure-messages.sh` pins that half, and the cut that delivered
# this suite is the loop's own observation of the free path.
#
# Every branch is forced rather than waited for: a lock file this suite owns,
# held open by a process it starts, and a path that does not exist. Waiting for
# a real apt holder would be green on whatever the machine happened to be
# doing — and the real locks are answered anyway, at the end, on the machine
# the runner has just measured free.

. "$(dirname "$(readlink -f "$0")")/lib.sh"

aptlock=$GUARDEN_ROOT/tests/aptlock.sh
[ -r "$aptlock" ] \
    || _fail "$aptlock is missing; a cut ships it into the machine before the checkout"

lock=$GUARDEN_FIXTURES/t370-lock
absent=$GUARDEN_FIXTURES/t370-absent
: >"$lock"

# free: the file exists and nothing has it open.
out=$(sh "$aptlock" probe "$lock")
[ "$out" = free ] || _fail "an unheld lock answers free, not [$out]"

# held: a process of this suite's own, with the file open, names itself with
# its pid. That name is what ticket 271 asked the failure line to carry — the
# old wait printed "last answer: held" and could not say who.
sleep 600 3<"$lock" &
holder=$!
trap 'kill "$holder" 2>/dev/null || true' EXIT
sleep 1
out=$(sh "$aptlock" probe "$lock")
case $out in
    held:*) ;;
    *) _fail "a held lock answers held:<who>(<pid>), not [$out]" ;;
esac
echo "$out" | grep -qF "sleep($holder)" \
    || _fail "the probe did not name the holder: expected sleep($holder) in [$out]"

# unmeasured: fuser cannot say. Its exit 1 covers "none accessed" *and* "a fatal
# error", and a path that does not exist is the fatal one — reached here
# without touching any lock the machine needs.
out=$(sh "$aptlock" probe "$absent")
[ "$out" = unmeasured ] || _fail "an unmeasurable lock answers unmeasured, not [$out]"

# A verb that does not exist is rejected input (exit 2), not a probe that
# answers nothing: a typo'd call site would otherwise poll a wordless loop.
rc=0
sh "$aptlock" nonsense >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || _fail "an unknown verb exits $rc, not 2"

# evidence, on apt's own locks — the ticket's three captures, in the ticket's
# order, on the default paths the runner asks about.
out=$(sh "$aptlock" evidence)
echo "$out" | grep -qF 'fuser -v /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock' \
    || _fail "the evidence does not name apt's two locks by default"
echo "$out" | grep -qF 'systemctl status cloud-init.service apt-daily.service unattended-upgrades.service' \
    || _fail "the evidence does not ask systemd for the three usual holders"
echo "$out" | grep -qF 'tail -n 40 /var/log/cloud-init.log' \
    || _fail "the evidence does not reach for cloud-init's own log"
echo "$out" | grep -qF 'Active:' \
    || _fail "systemctl status produced no status at all: [$out]"

# the log's own content: a capture that reported nothing when the file is there
# is the same defect as the old message — it would be an answer that says it
# looked without saying what it saw.
logline=$(tail -n 40 /var/log/cloud-init.log 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1) || true
if [ -n "$logline" ]; then
    echo "$out" | grep -qF -- "$logline" \
        || _fail "the evidence does not carry cloud-init.log's last line [$logline]"
else
    echo "$out" | grep -qF 'absent' \
        || _fail "cloud-init.log has no line to tail and the evidence does not say so"
fi

# evidence, on the lock this suite is holding: `fuser -v` has to carry the
# holder's pid and command, which is what makes the next occurrence a fact
# rather than a re-run.
out=$(sh "$aptlock" evidence "$lock")
echo "$out" | grep -qF "fuser -v $lock" \
    || _fail "the evidence does not report what it asked fuser about: [$out]"
echo "$out" | grep -qE "[[:space:]]$holder([[:space:]]|$)" \
    || _fail "fuser -v does not carry the holder's pid $holder: [$out]"
echo "$out" | grep -qE "[[:space:]]sleep([[:space:]]|$)" \
    || _fail "fuser -v does not carry the holder's command: [$out]"

# and apt's own locks, on the machine the runner has just measured free: the
# word has to be one of the three, `unmeasured` would contradict the green wait
# that delivered this suite, and a held lock still has to carry a name —
# "held:" with nothing after it is the ticket's defect in another form.
out=$(sh "$aptlock" probe)
case $out in
    free|held:?*) ;;
    *) _fail "probe on apt's own locks answers [$out]" ;;
esac
