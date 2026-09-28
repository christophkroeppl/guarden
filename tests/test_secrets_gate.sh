#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED_HOME="$GUARDEN_STATE/homes/bed-staging-nutristack"
ENV_FILE="$BED_HOME/.env"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"

assert_file "$PROJECT/.env.example"
assert_output_has "EXAMPLE-secret" cat "$PROJECT/.env.example"
assert_output_has "EXAMPLE-DATABASE_URL" cat "$PROJECT/.env.example"
assert_output_has "PORT=3000" cat "$PROJECT/.env.example"
assert_output_has "LOG_LEVEL=info" cat "$PROJECT/.env.example"

assert_file "$ENV_FILE"
db_url=$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE")
app_secret=$(sed -n 's/^APP_SECRET=//p' "$ENV_FILE")
if [ -z "$db_url" ]; then
  echo "assert: DATABASE_URL should be generated non-empty"
  failures=$((failures + 1))
fi
if [ -z "$app_secret" ]; then
  echo "assert: APP_SECRET should be generated non-empty"
  failures=$((failures + 1))
fi
case "$db_url" in EXAMPLE-*|changeme)
  echo "assert: DATABASE_URL should not be placeholder: $db_url"
  failures=$((failures + 1))
esac

: > "$GUARDEN_CALL_LOG"
weedr secret set bed-staging-nutristack APP_SECRET <<< "real-secret-value"
assert_call_log_empty
local_file="$BED_HOME/.env.staging.local"
assert_file "$local_file"
assert_output_has "APP_SECRET=real-secret-value" cat "$local_file"

assert_exit 0 weedr secret set bed-staging-nutristack
assert_output_has "nothing missing: bed-staging-nutristack" weedr secret set bed-staging-nutristack

before_secret=$(sed -n 's/^APP_SECRET=//p' "$ENV_FILE")
assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
after_secret=$(sed -n 's/^APP_SECRET=//p' "$ENV_FILE")
if [ "$before_secret" != "$after_secret" ]; then
  echo "assert: staging secret must stay stable across re-converge"
  failures=$((failures + 1))
fi

assert_exit 0 weedr bed plow nutristack --env preview --from "$PROJECT"
prev_home="$GUARDEN_STATE/homes/bed-preview-nutristack"
assert_file "$prev_home/.env"
prev_secret=$(sed -n 's/^APP_SECRET=//p' "$prev_home/.env")
if [ -z "$prev_secret" ]; then
  echo "assert: preview APP_SECRET should be generated"
  failures=$((failures + 1))
fi
case "$prev_secret" in EXAMPLE-*|changeme)
  echo "assert: preview APP_SECRET should not be placeholder: $prev_secret"
  failures=$((failures + 1))
esac

assert_exit 0 weedr bed plow nutristack --env production --from "$PROJECT"
prod_home="$GUARDEN_STATE/homes/bed-production-nutristack"
assert_file "$prod_home/.env"
prod_secret=$(sed -n 's/^APP_SECRET=//p' "$prod_home/.env" || true)
if [ -n "$prod_secret" ]; then
  echo "assert: production APP_SECRET should be empty (admin sets later), got: $prod_secret"
  failures=$((failures + 1))
fi

assert_exit 0 weedr secret set bed-production-nutristack
assert_output_has "missing: DATABASE_URL" weedr secret set bed-production-nutristack
assert_output_has "missing: APP_SECRET" weedr secret set bed-production-nutristack

mkdir -p "$WORK/project-staging/.guarden"
cp "$PROJECT/compose.yaml" "$WORK/project-staging/compose.yaml"
cp "$PROJECT/.guarden/bed.yaml" "$WORK/project-staging/.guarden/bed.yaml"
cp "$PROJECT/.guarden/.env.schema" "$WORK/project-staging/.guarden/.env.schema"
printf 'APP_SECRET=local-override-value\n' > "$WORK/project-staging/.env.staging.local"
assert_exit 0 weedr bed plow daily-dose --env staging --from "$WORK/project-staging"
dd_home="$GUARDEN_STATE/homes/bed-staging-daily-dose"
dd_file="$dd_home/.env.staging.local"
assert_file "$dd_file"
assert_output_has "APP_SECRET=local-override-value" cat "$dd_file"

finish
