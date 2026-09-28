#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start nutristack --env staging
assert_call_log_has "systemctl --user start"

assert_exit 0 weedr bed plow nutristack --env production --from "$PROJECT"
assert_exit 1 weedr bed start nutristack --env production
assert_output_has "missing: DATABASE_URL" weedr bed start nutristack --env production
assert_output_has "missing: APP_SECRET" weedr bed start nutristack --env production
assert_output_has "refusing to start bed" weedr bed start nutristack --env production

prod_home="$GUARDEN_STATE/homes/bed-production-nutristack"
printf 'DATABASE_URL=EXAMPLE-database\nAPP_SECRET=changeme\n' >> "$prod_home/.env"
assert_exit 1 weedr bed start nutristack --env production
assert_output_has "example value: DATABASE_URL" weedr bed start nutristack --env production

weedr secret set bed-production-nutristack DATABASE_URL <<< "real-value"
weedr secret set bed-production-nutristack APP_SECRET <<< "real-value"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start nutristack --env production
assert_call_log_has "systemctl --user start"

assert_exit 0 weedr bed plow nutristack --env preview --from "$PROJECT"
assert_exit 0 weedr bed start nutristack --env preview

mkdir -p "$WORK/gatestop/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/gatestop/compose.yaml"
cp "$PROJECT/.guarden/bed.yaml" "$WORK/gatestop/.guarden/bed.yaml"
cp "$PROJECT/.guarden/.env.schema" "$WORK/gatestop/.guarden/.env.schema"
assert_exit 0 weedr bed plow gatestop --env production --from "$WORK/gatestop"

: > "$GUARDEN_CALL_LOG"
assert_exit 1 weedr bed restart gatestop --env production
assert_output_has "missing: DATABASE_URL" weedr bed restart gatestop --env production
assert_call_log_lacks "systemctl --user stop"
assert_call_log_lacks "systemctl --user start"

: > "$GUARDEN_CALL_LOG"
assert_exit 1 weedr bed start gatestop --env production
assert_call_log_lacks "systemctl --user stop"

: > "$GUARDEN_CALL_LOG"
assert_exit 1 weedr redeploy gatestop --env production --from "$WORK/gatestop" --yes
assert_output_has "missing: DATABASE_URL" weedr redeploy gatestop --env production --from "$WORK/gatestop" --yes
assert_call_log_lacks "systemctl --user stop"
assert_call_log_lacks "podlet"

assert_exit 0 weedr bed plow fencetest --env fence --from "$WORK/gatestop"
assert_exit 1 weedr bed start fencetest --env fence
assert_output_has "missing: DATABASE_URL" weedr bed start fencetest --env fence
assert_output_has "refusing to start bed" weedr bed start fencetest --env fence

mkdir -p "$WORK/project-warn/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/project-warn/compose.yaml"
cp "$PROJECT/.guarden/bed.yaml" "$WORK/project-warn/.guarden/bed.yaml"
cp "$PROJECT/.guarden/.env.schema" "$WORK/project-warn/.guarden/.env.schema"
assert_exit 0 weedr bed plow warn-test --env staging --from "$WORK/project-warn"
warn_home="$GUARDEN_STATE/homes/bed-staging-warn-test"
printf 'DATABASE_URL=\nAPP_SECRET=changeme\n' > "$warn_home/.env"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start warn-test --env staging
assert_output_has "missing: DATABASE_URL" weedr bed start warn-test --env staging
assert_output_has "example value: APP_SECRET" weedr bed start warn-test --env staging
assert_output_has "warning" weedr bed start warn-test --env staging
assert_call_log_has "systemctl --user start"

mkdir -p "$WORK/project-override/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/project-override/compose.yaml"
cp "$PROJECT/.guarden/bed.yaml" "$WORK/project-override/.guarden/bed.yaml"
cp "$PROJECT/.guarden/.env.schema" "$WORK/project-override/.guarden/.env.schema"
printf 'APP_SECRET=changeme\n' > "$WORK/project-override/.env.staging.local"
assert_exit 0 weedr bed plow override-test --env staging --from "$WORK/project-override"
assert_exit 0 weedr bed start override-test --env staging
assert_output_has "example value: APP_SECRET" weedr bed start override-test --env staging

finish
