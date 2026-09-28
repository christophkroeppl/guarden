#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil storage --check
assert_output_has "drift" soil storage --check
assert_no_file "$GUARDEN_STATE/soil/storage.done"

assert_exit 0 soil storage --apply
assert_file "$GUARDEN_STATE/soil/storage.done"
assert_file "$GUARDEN_SYSROOT/var/lib/guarden"
assert_file "$GUARDEN_SYSROOT/var/lib/guarden/beds"
assert_file "$GUARDEN_SYSROOT/var/lib/roots/dynamic"
assert_no_file "$GUARDEN_SYSROOT/var/lib/pond"
assert_file "$GUARDEN_SYSROOT/etc/apt/apt.conf.d/80snapper"
assert_output_has "DPkg::Pre-Invoke" cat "$GUARDEN_SYSROOT/etc/apt/apt.conf.d/80snapper"
assert_call_log_has "btrfs subvolume create .*var/lib/guarden/beds"
assert_call_log_has "chgrp fence .*var/lib/roots/dynamic"
assert_call_log_has "snapper -c root create-config /"
assert_call_log_has "snapper -c home create-config /home"
assert_call_log_has "snapper -c root set-config FREE_LIMIT=0.12"
assert_call_log_has "snapper -c home set-config FREE_LIMIT=0.20"
assert_call_log_lacks "btrfs subvolume create .*pond"
assert_call_log_lacks "snapper -c pond"

assert_exit 0 soil storage --check
assert_output_has "ok" soil storage --check

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil storage --check
assert_call_log_empty

assert_exit 0 soil storage --apply
assert_exit 0 soil storage --check
assert_output_has "ok: storage" soil storage --check

finish
