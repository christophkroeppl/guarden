#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 0 soil storage --apply

assert_call_log_has "snapper -c home set-config FREE_LIMIT=0.20"
assert_call_log_has "snapper -c root set-config FREE_LIMIT=0.12"
assert_call_log_has "snapper -c pond-production set-config FREE_LIMIT=0.06"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil storage --check
assert_call_log_empty

assert_exit 0 soil storage --apply
assert_call_log_has "snapper -c home set-config FREE_LIMIT=0.20"
assert_call_log_has "snapper -c root set-config FREE_LIMIT=0.12"
assert_call_log_has "snapper -c pond-production set-config FREE_LIMIT=0.06"

finish
