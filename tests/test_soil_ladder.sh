#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 0 soil storage --apply

assert_call_log_has "snapper -c home set-config FREE_LIMIT=0.20"
assert_call_log_has "snapper -c root set-config FREE_LIMIT=0.12"
assert_call_log_lacks "snapper -c pond"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil storage --check
assert_call_log_empty

assert_exit 0 soil storage --apply
assert_call_log_has "snapper -c home set-config FREE_LIMIT=0.20"
assert_call_log_has "snapper -c root set-config FREE_LIMIT=0.12"
assert_call_log_lacks "snapper -c pond"

finish
