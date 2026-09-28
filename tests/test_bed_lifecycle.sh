#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED="bed-staging-nutristack"
BED_HOME="$GUARDEN_STATE/homes/$BED"
UNITS_DIR="$BED_HOME/.config/containers/systemd"
HOSTS="$GUARDEN_STATE/hosts"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
assert_call_log_has "useradd"
assert_call_log_has "loginctl enable-linger"
assert_call_log_has "bed-staging-nutristack"
assert_file "$BED_HOME"
assert_file "$UNITS_DIR"
assert_file "$GUARDEN_STATE/beds/$BED/meta"
assert_output_has "user=bed-staging-nutristack" cat "$GUARDEN_STATE/beds/$BED/meta"
assert_output_has "env=staging" cat "$GUARDEN_STATE/beds/$BED/meta"
assert_output_has "project=nutristack" cat "$GUARDEN_STATE/beds/$BED/meta"
assert_file "$GUARDEN_STATE/subuid"
assert_output_has "bed-staging-nutristack:100000:65536" cat "$GUARDEN_STATE/subuid"
assert_output_has "bed-staging-nutristack:100000:65536" cat "$GUARDEN_STATE/subgid"
assert_file "$PROJECT/.env.example"

assert_file "$GUARDEN_STATE/beds/$BED/compose.yaml"
assert_file "$GUARDEN_STATE/beds/$BED/.guarden/bed.yaml"
assert_file "$GUARDEN_STATE/beds/$BED/.guarden/.env.schema"

assert_file "$HOSTS"
assert_output_has "bed-staging-nutristack.internal" cat "$HOSTS"
assert_output_has "nutristack.internal" cat "$HOSTS"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
count=$(grep -c '^bed-staging-nutristack:' "$GUARDEN_STATE/subuid" || true)
if [ "$count" -ne 1 ]; then
  echo "assert: re-plow must not allocate a second subuid range, got $count"
  failures=$((failures + 1))
fi

assert_exit 2 weedr bed plow nutristack --from "$PROJECT"
assert_output_has "requires <project> and --env" weedr bed plow nutristack --from "$PROJECT"

assert_exit 2 weedr bed plow nutristack --env dev --from "$PROJECT"
assert_output_has "unknown environment: dev" weedr bed plow nutristack --env dev --from "$PROJECT"
assert_output_has "production|staging|preview|fence" weedr bed plow nutristack --env dev --from "$PROJECT"

assert_exit 1 weedr bed start nope --env staging
assert_output_has "no such bed: bed-staging-nope" weedr bed start nope --env staging

assert_exit 2 weedr bed new nutristack --env staging --from "$PROJECT"
assert_output_has "weedr bed plow" weedr bed new nutristack --env staging --from "$PROJECT"

assert_exit 0 weedr bed plow nutristack --env production --from "$PROJECT"
assert_file "$GUARDEN_STATE/homes/bed-production-nutristack"
assert_file "$GUARDEN_STATE/beds/bed-production-nutristack/meta"
assert_output_has "bed-production-nutristack.internal" cat "$HOSTS"

mkdir -p "$WORK/noenv/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/noenv/compose.yaml"
printf 'routes:\n  api: "api.${env}.${domain}"\n' > "$WORK/noenv/.guarden/bed.yaml"
assert_exit 2 weedr bed plow noenv --env staging --from "$WORK/noenv"
assert_output_has "$WORK/noenv/.guarden/bed.yaml" weedr bed plow noenv --env staging --from "$WORK/noenv"
assert_output_has "missing environment" weedr bed plow noenv --env staging --from "$WORK/noenv"
assert_no_file "$GUARDEN_STATE/beds/bed-staging-noenv"

mkdir -p "$WORK/unknownkey/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/unknownkey/compose.yaml"
printf 'environment: staging\nfrobnicate: "https://github.com/example/nutristack"\n' > "$WORK/unknownkey/.guarden/bed.yaml"
assert_exit 2 weedr bed plow unknownkey --env staging --from "$WORK/unknownkey"
assert_output_has "unknown key: frobnicate" weedr bed plow unknownkey --env staging --from "$WORK/unknownkey"
assert_output_has "$WORK/unknownkey/.guarden/bed.yaml" weedr bed plow unknownkey --env staging --from "$WORK/unknownkey"
assert_no_file "$GUARDEN_STATE/beds/bed-staging-unknownkey"

mkdir -p "$WORK/badenv/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/badenv/compose.yaml"
printf 'environment: dev\n' > "$WORK/badenv/.guarden/bed.yaml"
assert_exit 2 weedr bed plow badenv --env staging --from "$WORK/badenv"
assert_output_has "unknown environment: dev" weedr bed plow badenv --env staging --from "$WORK/badenv"

mkdir -p "$WORK/authok/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/authok/compose.yaml"
printf 'environment: fence\nauth: true\nroutes:\n  web: "${env}.${domain}"\nports:\n  - 443/tcp\n' > "$WORK/authok/.guarden/bed.yaml"
assert_exit 0 weedr bed plow traefik --env fence --from "$WORK/authok"
assert_file "$GUARDEN_STATE/beds/bed-fence-traefik/meta"
assert_output_has "bed-fence-traefik.internal" cat "$HOSTS"

mkdir -p "$WORK/nomanifest"
cp "$PROJECT/compose.yaml" "$WORK/nomanifest/compose.yaml"
assert_exit 2 weedr bed plow nomanifest --env staging --from "$WORK/nomanifest"
assert_output_has "$WORK/nomanifest/.guarden/bed.yaml" weedr bed plow nomanifest --env staging --from "$WORK/nomanifest"

assert_exit 2 weedr bed drop "$BED"
assert_output_has "weedr bed remove" weedr bed drop "$BED"

finish
