#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
STAGING_LOCAL="$GUARDEN_STATE/homes/bed-nutristack-staging/.env.staging.local"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 pond up
assert_call_log_has "runuser -u pond"
assert_call_log_has "podman"
assert_call_log_has "pond-prod"
assert_call_log_has "127.0.0.1:5432"
assert_call_log_has "pond-nonprod"
assert_call_log_has "127.0.0.1:5433"
assert_call_log_has "postgres"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr pond mint nutristack-staging
assert_call_log_has "runuser -u pond"
assert_call_log_has "podman"
assert_call_log_has "pond-nonprod"
assert_call_log_has "CREATE DATABASE"
assert_call_log_has "CREATE ROLE"
assert_file "$STAGING_LOCAL"
assert_output_has "DATABASE_URL=postgres://" cat "$STAGING_LOCAL"
assert_output_has "pond.internal" cat "$GUARDEN_STATE/hosts"

assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr pond mint nutristack-production
assert_call_log_has "runuser -u pond"
assert_call_log_has "pond-prod"
assert_call_log_has "CREATE ROLE"
prod_local="$GUARDEN_STATE/homes/bed-nutristack-production/.env.production.local"
assert_file "$prod_local"
assert_output_has "DATABASE_URL=postgres://" cat "$prod_local"

assert_exit 0 weedr bed new nutristack --env preview:feat-1 --from "$PROJECT"
assert_exit 0 weedr pond mint nutristack-preview-feat-1

assert_exit 2 weedr pond drop nutristack-production
assert_file "$GUARDEN_STATE/homes/bed-nutristack-production/.env.production.local"
assert_exit 0 weedr pond drop nutristack-production --yes
assert_call_log_has "DROP DATABASE"

assert_exit 0 weedr pond drop nutristack-preview-feat-1

printf 'CREATE TABLE t (id int);\n' > "$WORK/dump.sql"
assert_exit 0 weedr bed new nutristack --env preview:feat-2 --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr pond restore nutristack-preview-feat-2 --from "$WORK/dump.sql"
assert_call_log_has "runuser -u pond"
assert_call_log_has "REASSIGN OWNED BY"
restore_local="$GUARDEN_STATE/homes/bed-nutristack-preview-feat-2/.env.preview-feat-2.local"
assert_file "$restore_local"
assert_output_has "DATABASE_URL=postgres://" cat "$restore_local"
if grep -qF "$(grep '^DATABASE_URL=' "$STAGING_LOCAL" | cut -d= -f2-)" "$restore_local" 2>/dev/null; then
  echo "assert: restored credential must be freshly minted"
  failures=$((failures + 1))
fi

finish
