#!/usr/bin/env bash
# The producer-into-`grep -q` shape, held out of the helpers and the harness.
#
# `grep -q` exits at its first match. A producer still writing to that pipe takes
# SIGPIPE, and `set -o pipefail` — on in `tests/lib.sh` and in `tests/lxc.sh` —
# turns the pipeline's status into 141 instead of the match. Which way that
# mistakes the answer depends on the caller: a negative assertion reads "absent"
# for text that is there and passes, while a helper whose status IS the answer
# returns 141 and ends the suite with no diagnostic.
#
# **Every case below puts the match early in a payload larger than one pipe
# buffer** (64 KiB on Linux; these are ~1.2 MB). That is the only state in which
# the producer is still writing when the reader exits: a small payload fits the
# buffer, the writer finishes, and the case would pass whether the shape was
# fixed or not.
#
# machine: shared
# it writes under GUARDEN_FIXTURES and drives helpers that read what it wrote;
# it converges nothing, starts no service and needs no `lxc`.

. "$(dirname "$0")/lib.sh"

# A payload whose first line is the match, followed by ~1.2 MB of filler.
_big_payload() {
    printf '%s\n' "$1"
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line " i " of a payload far larger than one pipe buffer" }'
}

BIG_FILE="$GUARDEN_FIXTURES/big-payload"
_big_payload 'needle the first line of a large payload' >"$BIG_FILE"
BIG_TEXT=$(<"$BIG_FILE")
[ "${#BIG_TEXT}" -gt 65536 ] \
    || _fail "the payload is ${#BIG_TEXT} bytes; the case needs more than one pipe buffer (65536)"

# --- text_has: what the suites use instead of the pipe ----------------------
# The match is the first line, so a `printf '%s' "$text" | grep -q` here would
# have the producer killed by SIGPIPE and answer "no match".
text_has "$BIG_TEXT" 'needle the first line' \
    || _fail "text_has missed a needle on the first line of a ${#BIG_TEXT}-byte text"
text_has "$BIG_TEXT" 'a needle that is not there' \
    && _fail "text_has found a needle that is not in the text"

# **"Could not decide" is not "no match".** A grep that dies — by signal or
# otherwise — exits >1, and the pass arm of a negative assertion is exactly 1,
# which is the direction this whole defect class is silent in. The status alone
# does not show it — `|| return 1` answers 1 as well — so this case reads the
# diagnostic, which is what separates "the answer is no" from "there is no
# answer".
rc=0
undecided=$(
    grep() { return 2; }
    text_has "needle" needle 2>&1
) || rc=$?
[ "$rc" -ne 0 ] || _fail "text_has read a grep that exited 2 as 'no match'"
case $undecided in
    *"grep exited 2"*) ;;
    *) _fail "text_has returned $rc on a grep that exited 2 without naming it: $undecided" ;;
esac

# --- the group helpers: capture, and an unreadable list fails ---------------
# `id` is replaced because a real account cannot be given a group list of this
# size; the subject is the helper's pipeline, not `id`.
BIG_GROUPS="root thegroup $(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "filler%d ", i }')"
[ "${#BIG_GROUPS}" -gt 65536 ] \
    || _fail "the group list is ${#BIG_GROUPS} bytes; the case needs more than one pipe buffer (65536)"
REAL_ID=$(command -v id)
id() {
    case " $* " in
        *" -nG "*) printf '%s\n' "$BIG_GROUPS" ;;
        *) "$REAL_ID" "$@" ;;
    esac
}

# A member that IS present, early, in a list larger than the pipe buffer. The
# negative assertion is the one that fails silently: it passes on the membership
# it exists to refuse.
rc=0
( assert_no_supplementary_group probe thegroup ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
    || _fail "assert_no_supplementary_group passed on a member present in a ${#BIG_GROUPS}-byte group list"

( assert_supplementary_group probe thegroup ) >/dev/null 2>&1 \
    || _fail "assert_supplementary_group refused a member present in a ${#BIG_GROUPS}-byte group list"

( assert_supplementary_group probe absentgroup ) >/dev/null 2>&1 \
    && _fail "assert_supplementary_group accepted a group the list does not name"

( assert_no_supplementary_group probe absentgroup ) >/dev/null 2>&1 \
    || _fail "assert_no_supplementary_group refused a group the list does not name"

# The list cannot be read: that is a failure, never an absence. Otherwise a host
# where `id` is broken would answer "no supplementary group" for every user.
rc=0
(
    id() { return 2; }
    assert_no_supplementary_group probe thegroup
) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || _fail "assert_no_supplementary_group passed when the group list could not be read"

# **The guard's `return` is load-bearing where `set -e` is off.** A caller that
# runs the helper inside an `if` has errexit disabled for it, and there a `_fail`
# that only prints falls through to the membership test on an empty list — which
# answers "not a member" for a list nobody could read.
if ( id() { return 2; }; assert_no_supplementary_group probe thegroup ) 2>/dev/null; then
    _fail "assert_no_supplementary_group answered with errexit off, for a group list it could not read"
fi

# --- _verbs_of: the status is the function's --------------------------------
# Here the reader that exits early is `head -n 1`, and the cost is a false red:
# the assignment takes 141 and the suite dies on a help output it could read.
# **The filler lines carry a `{…}` block each**, because it is `grep -o`'s
# OUTPUT that has to outrun `head`: one match against a large file would let the
# producer finish before the reader exits, and the case would pass either way.
BIG_HELP=$(
    printf '%s\n' 'program verbs {add,remove,list}'
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line " i " names {filler" i "} in a help far larger than one pipe buffer" }'
)
[ "${#BIG_HELP}" -gt 65536 ] \
    || _fail "the help is ${#BIG_HELP} bytes; the case needs more than one pipe buffer (65536)"
run() {
    printf '%s\n' "$BIG_HELP" >"$GUARDEN_STDOUT"
    GUARDEN_EXIT=0
}
rc=0
verbs=$( _verbs_of myprog ) || rc=$?
[ "$rc" = 0 ] \
    || _fail "_verbs_of exited $rc on a ${#BIG_HELP}-byte help whose first {verb list} block is readable"
[ "$verbs" = "add list remove " ] || _fail "_verbs_of answered [$verbs], expected [add list remove ]"

# --- _has_snapshot: the harness function, extracted and driven --------------
# `tests/lxc.sh` cannot be sourced — it dispatches on `$1` at the bottom, and the
# suite runs where `lxc` does not exist — so the function is lifted out by its
# own boundaries and driven here against a stand-in `lxc`. The pin is therefore
# on the harness's shipped text, not on a copy of it.
SNAP_FN="$GUARDEN_FIXTURES/has-snapshot.sh"
sed -n '/^_has_snapshot() {/,/^}/p' "$GUARDEN_ROOT/tests/lxc.sh" >"$SNAP_FN"
[ -s "$SNAP_FN" ] \
    || _fail "tests/lxc.sh no longer defines _has_snapshot; this pin would be vacuous"
. "$SNAP_FN"

SNAP_LXC="$GUARDEN_FIXTURES/fake-lxc"
cat >"$SNAP_LXC" <<'STUB'
#!/bin/sh
echo "Snapshots:"
echo "| base   | 2026-10-21 12:00:00 |"
awk 'BEGIN { for (i = 0; i < 20000; i++) print "| filler" i " | 2026-10-21 12:00:00 |" }'
STUB
chmod +x "$SNAP_LXC"
listing_bytes=$("$SNAP_LXC" | wc -c)
[ "$listing_bytes" -gt 65536 ] \
    || _fail "the stand-in listing is $listing_bytes bytes; the case needs more than one pipe buffer (65536)"

LXC=$SNAP_LXC
SNAPSHOT=base
_has_snapshot probe \
    || _fail "an existing snapshot read as absent on a $listing_bytes-byte listing; every run would rebuild the golden"

SNAPSHOT=absent
if _has_snapshot probe; then
    _fail "a listing that does not name the snapshot answered present"
fi

echo "MEASURE: every case ran against more than one pipe buffer (65536 B): text ${#BIG_TEXT} B, groups ${#BIG_GROUPS} B, help ${#BIG_HELP} B, snapshot listing $listing_bytes B"
