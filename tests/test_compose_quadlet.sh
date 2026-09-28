#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED_HOME="$GUARDEN_STATE/homes/bed-staging-nutristack"
UNITS_DIR="$BED_HOME/.config/containers/systemd"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"

assert_call_log_has "podlet compose"
assert_file "$UNITS_DIR/data.volume"
assert_no_file "$UNITS_DIR/cache.volume"
assert_file "$UNITS_DIR/api.container"
assert_file "$UNITS_DIR/web.container"

assert_file "$UNITS_DIR/api.container.d/bed.env"
assert_output_has "EnvironmentFile" cat "$UNITS_DIR/api.container.d/bed.env"

mkdir -p "$UNITS_DIR/api.container.d"
echo keep > "$UNITS_DIR/api.container.d/zz-admin.conf"
assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
assert_file "$UNITS_DIR/api.container.d/zz-admin.conf"
assert_file "$UNITS_DIR/api.container.d/bed.env"

mkdir -p "$WORK/qsrc/.guarden/quadlet"
printf 'environment: staging\nroutes:\n  api: "api.${env}.${domain}"\n' > "$WORK/qsrc/.guarden/bed.yaml"
printf '[Container]\nImage=example/worker:latest\n' > "$WORK/qsrc/.guarden/quadlet/worker.container"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed plow quadtest --env staging --from "$WORK/qsrc"
assert_call_log_lacks "podlet"
qunits="$GUARDEN_STATE/homes/bed-staging-quadtest/.config/containers/systemd"
assert_file "$qunits/worker.container"
assert_output_has "Image=example/worker:latest" cat "$qunits/worker.container"
assert_file "$qunits/worker.container.d/bed.env"
assert_output_has "EnvironmentFile" cat "$qunits/worker.container.d/bed.env"
assert_file "$GUARDEN_STATE/beds/bed-staging-quadtest/.guarden/bed.yaml"

finish
