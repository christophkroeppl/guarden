#!/bin/sh
# tests/probestate.sh — the probe cut's three storage conditions, asked on the
# machine itself (ticket 352).
#
# One line out, always, and the exit status answers the whole question:
#
#   state=<word>   the conversion's own record: `done` once it has converged,
#                  and `none` when there is no record to read — the word the
#                  conversion's own reader (soil-storage-convert) uses, so the
#                  vocabulary here is its, not a second one
#   marker=<word>  `present` while a reboot is still outstanding
#   snapper=ok     `snapper -c root get-config` answers, so the configuration
#                  the apt hook snapshots into exists; `rc=N` when it does not
#
# Exit 0 only when all three hold. The line is printed whichever way they fall,
# because the evidence is what a failure has to name: "the storage is wrong",
# with no answer under it, is the report ticket 352 was filed against.
#
# **Two callers, one file.** `tests/probecut.sh` ships these bytes into the
# machine with `sh -c`, the way the runner ships `tests/aptlock.sh` into a cut,
# and `tests/t352-probe-cut-storage.sh` runs this file directly in a machine. So
# what provision asks about a probe is what a suite asserts, and not a copy.
#
# It reads and touches nothing: no file is created, no configuration modified.
#
# POSIX sh on purpose: `sh -c` in the guest runs whatever the image's /bin/sh
# is, and a suite runs this file the same way.

state_file=/var/lib/guarden/soil/state
marker_file=/var/lib/guarden/soil/reboot-required

state=none
if [ -r "$state_file" ]; then
    recorded=$(cat "$state_file" 2>/dev/null) || recorded=''
    [ -z "$recorded" ] || state=$recorded
fi

marker=present
[ -e "$marker_file" ] || marker=absent

if snapper -c root get-config >/dev/null 2>&1; then
    snapper=ok
else
    snapper=rc=$?
fi

printf 'state=%s marker=%s snapper=%s\n' "$state" "$marker" "$snapper"

[ "$state" = done ] && [ "$marker" = absent ] && [ "$snapper" = ok ]
