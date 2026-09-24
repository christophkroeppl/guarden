#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil users --check
assert_output_has "drift" soil users --check
assert_no_file "$GUARDEN_STATE/soil/users.done"

assert_exit 0 soil users --apply
assert_file "$GUARDEN_STATE/soil/users.done"
assert_call_log_has "groupadd --system edge"
assert_call_log_has "useradd --system --user-group --home-dir /home/pond --shell /usr/sbin/nologin pond"
assert_call_log_has "useradd --system --user-group --home-dir /home/roots --shell /usr/sbin/nologin roots"
assert_call_log_has "useradd --system --user-group --home-dir /home/traefik --shell /usr/sbin/nologin traefik"
assert_call_log_has "useradd --system --user-group --home-dir /home/stakes --shell /usr/sbin/nologin stakes"
assert_call_log_has "useradd --system --user-group --home-dir /home/twig --shell /usr/sbin/nologin twig"
assert_call_log_has "useradd --system --user-group --home-dir /home/hose --shell /usr/sbin/nologin hose"
assert_call_log_has "usermod -aG edge roots"
assert_call_log_has "usermod -aG edge traefik"

assert_exit 0 soil users --check
assert_output_has "ok" soil users --check

: > "$GUARDEN_CALL_LOG"
assert_exit 0 soil users --check
assert_call_log_empty

assert_exit 0 soil users --apply
assert_exit 0 soil users --check
assert_output_has "ok: users" soil users --check

finish
