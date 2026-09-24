#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED_HOME="$GUARDEN_STATE/homes/bed-nutristack-staging"
UNITS_DIR="$BED_HOME/.config/containers/systemd"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"

assert_call_log_has "podlet compose"
assert_file "$UNITS_DIR/data.volume"
assert_no_file "$UNITS_DIR/cache.volume"
assert_file "$UNITS_DIR/api.container"
assert_file "$UNITS_DIR/web.container"

assert_file "$UNITS_DIR/api.container.d/bed.env"
assert_output_has "EnvironmentFile" cat "$UNITS_DIR/api.container.d/bed.env"

finish
