#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 0 soil firewall --apply --deadman
assert_call_log_has "systemctl daemon-reload"
assert_call_log_has "systemctl start guarden-deadman.timer"
assert_call_log_has "ufw disable"
assert_file "$GUARDEN_STATE/soil/firewall.done"
assert_file "$GUARDEN_SYSROOT/etc/systemd/system/guarden-deadman.timer"
assert_file "$GUARDEN_SYSROOT/etc/systemd/system/guarden-deadman.service"
assert_file "$GUARDEN_SYSROOT/usr/local/lib/guarden/deadman-restore"
assert_output_has "systemctl stop ferm" cat "$GUARDEN_SYSROOT/usr/local/lib/guarden/deadman-restore"
assert_output_has "ufw --force disable" cat "$GUARDEN_SYSROOT/usr/local/lib/guarden/deadman-restore"
assert_exit 0 soil firewall --check

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil firewall --apply --deadman
assert_call_log_has "systemctl start guarden-deadman.timer"

assert_exit 2 soil firewall --check --deadman
assert_exit 2 soil users --apply --deadman
assert_exit 2 soil sysctl --apply --deadman
assert_exit 2 soil firewall --deadman

finish
