#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil storage --check
assert_output_has "drift" soil storage --check
assert_no_file "$GUARDEN_STATE/soil/storage.done"

assert_exit 0 soil storage --apply
assert_file "$GUARDEN_STATE/soil/storage.done"
assert_call_log_has "snapper"
assert_call_log_has "btrfs subvolume create"

assert_exit 0 soil storage --check
assert_output_has "ok" soil storage --check

assert_call_log_lacks "snapper.*pond-nonprod|pond-nonprod.*snapper"

finish
