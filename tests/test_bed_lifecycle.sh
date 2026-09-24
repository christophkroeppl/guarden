#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED_HOME="$GUARDEN_STATE/homes/bed-nutristack-staging"
UNITS_DIR="$BED_HOME/.config/containers/systemd"
HOSTS="$GUARDEN_STATE/hosts"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"
assert_call_log_has "useradd"
assert_call_log_has "loginctl enable-linger"
assert_file "$BED_HOME"
assert_file "$UNITS_DIR"
assert_file "$GUARDEN_STATE/beds/nutristack-staging/meta"
assert_file "$PROJECT/.env.example"

assert_file "$HOSTS"
assert_output_has "bed-nutristack-staging.internal" cat "$HOSTS"
assert_output_has "nutristack.internal" cat "$HOSTS"

assert_exit 2 weedr bed new nutristack --env staging --from "$PROJECT"

assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
assert_call_log_has "useradd"
assert_file "$GUARDEN_STATE/homes/bed-nutristack-production"
assert_file "$GUARDEN_STATE/beds/nutristack-production/meta"

finish
