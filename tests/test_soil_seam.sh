#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHASES="users firewall sysctl btrfs storage root-scripts units"

for phase in $PHASES; do
  assert_exit 1 soil "$phase" --check
  assert_no_file "$GUARDEN_STATE/soil/$phase.done"
done

assert_call_log_empty

for phase in $PHASES; do
  assert_exit 0 soil "$phase" --apply
  assert_file "$GUARDEN_STATE/soil/$phase.done"
  assert_exit 0 soil "$phase" --check
done

assert_call_log_has "useradd"
assert_call_log_has "systemctl"
assert_call_log_has "btrfs"
assert_call_log_has "snapper"
assert_call_log_has "podman"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil users --check
assert_exit 0 soil firewall --check
assert_call_log_empty

rm -f "$GUARDEN_STATE/soil/storage.done"
assert_exit 1 soil storage --check
assert_no_file "$GUARDEN_STATE/soil/storage.done"
assert_call_log_empty

assert_exit 2 soil users
assert_exit 2 soil nosuch --check
assert_exit 2 soil users --nope

finish
