#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil btrfs --check
assert_output_has "drift" soil btrfs --check
assert_no_file "$GUARDEN_STATE/soil/btrfs.done"

assert_exit 0 soil btrfs --apply
assert_file "$GUARDEN_STATE/soil/reboot-needed"
assert_file "$GUARDEN_STATE/soil/btrfs.done"

rm -f "$GUARDEN_STATE/soil/reboot-needed"

assert_exit 0 soil btrfs --apply
assert_no_file "$GUARDEN_STATE/soil/reboot-needed"
assert_call_log_has "dracut"
assert_call_log_has "btrfs subvolume create"

assert_exit 0 soil btrfs --check
assert_output_has "ok" soil btrfs --check

assert_exit 0 soil btrfs --apply
assert_output_has "no drift" soil btrfs --apply

finish
