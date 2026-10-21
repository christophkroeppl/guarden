#!/bin/sh
# tests/aptlock.sh — the guest half of a cut's apt-lock wait (ticket 271).
#
# Two callers, one file, and that is the point of the file: the runner ships
# these bytes into the machine with `sh -c "$(cat …)" aptlock probe`, because
# `_wait_cloud_init` runs *before* the checkout is pushed into the cut, and
# `tests/t370-apt-lock-wait.sh` runs this file directly in the machine. What the
# suite asserts about the measurement is therefore the measurement a cut runs,
# not a copy of it. The runner reads the file once, at load, the way it reads
# `failure_messages.sh`.
#
# Verbs, each taking the lock files to ask about (default: apt's two):
#
#   probe      one word, with no spaces in it, on stdout:
#                free                 nothing has the locks open
#                held:<who>(<pid>),…  something does, named the way the runner's
#                                     failure line prints it
#                unmeasured           fuser could not say, so nothing was learned
#
#   evidence   ticket 271's capture, in its order: `fuser -v` on the locks, the
#              `systemctl status` of the cloud-init services this image has and
#              of apt-daily.service and unattended-upgrades.service, and the
#              tail of /var/log/cloud-init.log.
#
# `fuser`'s exit code alone is not the answer — its own man page says non-zero
# means "none of the specified files is accessed **or a fatal error**", and 1
# covers both "free" and "could not measure". The stderr text tells the two
# apart, which is why the word is printed here and why the runner never reads
# the code: this is the ambiguity ticket 271's failure message was stuck with.
#
# POSIX sh on purpose: `sh -c` in the guest runs whatever the image's /bin/sh
# is, and a suite runs this file the same way.

set -u

verb=${1:-}
if [ "$#" -gt 0 ]; then
    shift
fi
if [ "$#" -gt 0 ]; then
    locks=$*
else
    locks="/var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock"
fi

# The classification the runner polls for. `fuser` is asked twice when it
# answers 0: once for the verdict (its stderr) and once for the pids (its
# stdout), because the two answers come out of different streams and the word
# has to carry both.
probe() {
    err=$(fuser $locks 2>&1 >/dev/null)
    rc=$?
    case $rc in
        0)
            who=''
            for pid in $(fuser $locks 2>/dev/null); do
                comm=$(cat "/proc/$pid/comm" 2>/dev/null) || comm='?'
                who="${who:+$who,}$comm($pid)"
            done
            printf 'held:%s' "$who"
            ;;
        1)
            if [ -n "$err" ]; then
                printf 'unmeasured'
            else
                printf 'free'
            fi
            ;;
        *)
            printf 'unmeasured'
            ;;
    esac
}

# Best effort, and it always exits 0: this output is what a failed cut prints,
# and a capture that stopped on its own first line would report less than the
# thing it was taken to explain.
#
# Three things about the capture are decisions, not conveniences.
#
# **The cloud-init services are the ones the image has, asked for by asking
# systemd.** Every image this harness runs has cloud-init, and no two
# generations agree on the unit names: ubuntu 26.04 ships cloud-init-local,
# cloud-init-main and cloud-init-network and has no cloud-init.service at all,
# so ticket 271's fixed name printed "Unit cloud-init.service could not be
# found" — an absence that reads as a fact about cloud-init rather than about
# the name the capture invented. `list-unit-files` is the image's own answer,
# and asking about the units it names cannot produce that line.
#
# **A lock nobody holds is said out loud.** `fuser -v` prints nothing at all
# for a file no process has open, so a command line with no output under it
# reads as a measurement that failed instead of as the state that is actually
# free. `held by: nobody` is what the reader gets instead.
#
# **The log line is emitted even when the file is absent**, for the same
# reason: the evidence says what it looked for and what it found, in both
# directions.
evidence() {
    printf 'fuser -v %s\n' "$locks"
    holders=$(fuser -v $locks 2>&1)
    if [ -n "$holders" ]; then
        printf '%s\n' "$holders"
    else
        printf 'held by: nobody\n'
    fi
    cloud=$(systemctl list-unit-files --no-legend --plain 'cloud-init*.service' 2>/dev/null \
        | awk '{print $1}' | tr '\n' ' ')
    cloud=${cloud% }
    units="${cloud:+$cloud }apt-daily.service unattended-upgrades.service"
    printf 'systemctl status %s\n' "$units"
    systemctl status --no-pager $units 2>&1
    printf 'tail -n 40 /var/log/cloud-init.log\n'
    if [ -r /var/log/cloud-init.log ]; then
        tail -n 40 /var/log/cloud-init.log
    else
        printf 'absent\n'
    fi
    return 0
}

case $verb in
    probe) probe ;;
    evidence) evidence ;;
    *)
        printf 'usage: aptlock {probe|evidence} [lock ...]\n' >&2
        exit 2
        ;;
esac
