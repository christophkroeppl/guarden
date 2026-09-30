#!/usr/bin/env bash
# The fast harness: seconds, fakes only, and the one seam.
#
# Every tests/t*.sh runs in its own process with its own fixture state, so one
# test's call log is never another test's evidence. A failing file aborts there
# and is reported here with what it last said.
#
# New tests are new files under tests/ matching t*.sh. Do not add to this
# script's logic; add a file.

set -uo pipefail

root=$(dirname "$(dirname "$(readlink -f "$0")")")
status=0

for test_file in "$root"/tests/t[0-9]*.sh; do
    [ -f "$test_file" ] || continue
    name=${test_file##*/}
    state=$(mktemp -d)
    if GUARDEN_ROOT="$root" GUARDEN_FIXTURES="$state" "$test_file"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        status=1
    fi
    rm -rf "$state"
done

exit "$status"
