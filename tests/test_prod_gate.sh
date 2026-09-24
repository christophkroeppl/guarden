#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start nutristack-staging
assert_call_log_has "systemctl --user start"

assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
assert_exit 1 weedr bed start nutristack-production
assert_output_has "missing: DATABASE_URL" weedr bed start nutristack-production
assert_output_has "missing: APP_SECRET" weedr bed start nutristack-production

prod_home="$GUARDEN_STATE/homes/bed-nutristack-production"
echo "DATABASE_URL=EXAMPLE-database" >> "$prod_home/.env"
echo "APP_SECRET=changeme" >> "$prod_home/.env"
assert_exit 1 weedr bed start nutristack-production
assert_output_has "example value: DATABASE_URL" weedr bed start nutristack-production

echo "real-value" | weedr secret set nutristack-production DATABASE_URL
echo "real-value" | weedr secret set nutristack-production APP_SECRET
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start nutristack-production
assert_call_log_has "systemctl --user start"

assert_exit 0 weedr bed new nutristack --env preview:feat-2 --from "$PROJECT"
assert_exit 0 weedr bed start nutristack-preview-feat-2

mkdir -p "$WORK/project-warn"
cp "$PROJECT/compose.yaml" "$WORK/project-warn/"
cp "$PROJECT/bed.yaml" "$WORK/project-warn/"
cp "$PROJECT/.env.schema" "$WORK/project-warn/"
assert_exit 0 weedr bed new warn-test --env staging --from "$WORK/project-warn"
warn_home="$GUARDEN_STATE/homes/bed-warn-test-staging"
printf 'DATABASE_URL=\nAPP_SECRET=changeme\n' > "$warn_home/.env"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed start warn-test-staging
assert_output_has "missing: DATABASE_URL" weedr bed start warn-test-staging
assert_output_has "example value: APP_SECRET" weedr bed start warn-test-staging
assert_output_has "warning" weedr bed start warn-test-staging

mkdir -p "$WORK/project-override"
cp "$PROJECT/compose.yaml" "$WORK/project-override/"
cp "$PROJECT/bed.yaml" "$WORK/project-override/"
cp "$PROJECT/.env.schema" "$WORK/project-override/"
printf 'APP_SECRET=changeme\n' > "$WORK/project-override/.env.staging.local"
assert_exit 0 weedr bed new override-test --env staging --from "$WORK/project-override"
assert_exit 0 weedr bed start override-test-staging
assert_output_has "example value: APP_SECRET" weedr bed start override-test-staging

finish
