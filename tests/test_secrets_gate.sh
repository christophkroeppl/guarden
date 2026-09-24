#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED_HOME="$GUARDEN_STATE/homes/bed-nutristack-staging"
ENV_FILE="$BED_HOME/.env"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"

assert_file "$PROJECT/.env.example"
assert_output_has "EXAMPLE-secret" cat "$PROJECT/.env.example"
assert_output_has "EXAMPLE-DATABASE_URL" cat "$PROJECT/.env.example"
assert_output_has "PORT=3000" cat "$PROJECT/.env.example"
assert_output_has "LOG_LEVEL=info" cat "$PROJECT/.env.example"

assert_file "$ENV_FILE"
db_url=$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)
app_secret=$(grep '^APP_SECRET=' "$ENV_FILE" | cut -d= -f2-)
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
echo "real-secret-value" | weedr secret set nutristack-staging APP_SECRET
assert_call_log_empty
local_file="$BED_HOME/.env.staging.local"
assert_file "$local_file"
assert_output_has "APP_SECRET=real-secret-value" cat "$local_file"

assert_exit 0 weedr bed new nutristack --env preview:feat-1 --from "$PROJECT"
prev_home="$GUARDEN_STATE/homes/bed-nutristack-preview-feat-1"
assert_file "$prev_home/.env"
prev_secret=$(grep '^APP_SECRET=' "$prev_home/.env" | cut -d= -f2-)
if [ -z "$prev_secret" ]; then
  echo "assert: preview APP_SECRET should be generated"
  failures=$((failures + 1))
fi

assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
prod_home="$GUARDEN_STATE/homes/bed-nutristack-production"
assert_file "$prod_home/.env"
prod_secret=$(grep '^APP_SECRET=' "$prod_home/.env" | cut -d= -f2- || true)
if [ -n "$prod_secret" ]; then
  echo "assert: production APP_SECRET should be empty (admin sets later), got: $prod_secret"
  failures=$((failures + 1))
fi

mkdir -p "$WORK/project-staging"
cp "$PROJECT/compose.yaml" "$WORK/project-staging/"
cp "$PROJECT/bed.yaml" "$WORK/project-staging/"
cp "$PROJECT/.env.schema" "$WORK/project-staging/"
cat > "$WORK/project-staging/.env.staging.local" <<'EOF'
APP_SECRET=local-override-value
EOF
assert_exit 0 weedr bed new daily-dose --env staging --from "$WORK/project-staging"
dd_home="$GUARDEN_STATE/homes/bed-daily-dose-staging"
dd_file="$dd_home/.env.staging.local"
assert_file "$dd_file"
assert_output_has "APP_SECRET=local-override-value" cat "$dd_file"

finish
