#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil sysctl --check
assert_output_has "drift" soil sysctl --check
assert_no_file "$GUARDEN_STATE/soil/sysctl.done"

assert_exit 0 soil sysctl --apply
assert_file "$GUARDEN_STATE/soil/sysctl.done"
assert_call_log_has "sysctl -w net.ipv4.ip_unprivileged_port_start=0"
assert_file "$GUARDEN_SYSROOT/etc/sysctl.d/99-guarden.conf"

assert_exit 0 soil sysctl --check
assert_output_has "ok" soil sysctl --check

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil sysctl --check
assert_call_log_empty

assert_exit 0 soil sysctl --apply
assert_exit 0 soil sysctl --check
assert_output_has "ok: sysctl" soil sysctl --check

finish
