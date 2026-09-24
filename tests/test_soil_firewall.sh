#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil firewall --check
assert_output_has "drift" soil firewall --check
assert_no_file "$GUARDEN_STATE/soil/firewall.done"

assert_exit 0 soil firewall --apply
assert_file "$GUARDEN_STATE/soil/firewall.done"
assert_call_log_has "apt-get install -y ferm fail2ban"
assert_call_log_has "ufw disable"
assert_call_log_has "systemctl disable --now ufw"
assert_call_log_has "ferm /etc/ferm/ferm.conf"
assert_call_log_has "systemctl enable --now ferm"
assert_call_log_has "systemctl enable --now fail2ban"
assert_call_log_has "fail2ban-client reload"
assert_file "$GUARDEN_SYSROOT/etc/ferm/ferm.conf"
assert_file "$GUARDEN_SYSROOT/etc/fail2ban/jail.d/guarden.local"

assert_exit 0 soil firewall --check
assert_output_has "ok" soil firewall --check

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil firewall --check
assert_call_log_empty

assert_exit 0 soil firewall --apply
assert_exit 0 soil firewall --check
assert_output_has "ok: firewall" soil firewall --check

finish
