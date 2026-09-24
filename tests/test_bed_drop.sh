#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"

assert_exit 0 weedr bed new nutristack --env staging --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed stop nutristack-staging
assert_call_log_has "systemctl --user stop"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed restart nutristack-staging
assert_call_log_has "systemctl --user stop"
assert_call_log_has "systemctl --user start"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed drop nutristack-staging
assert_call_log_has "systemctl --user stop"
assert_call_log_has "userdel"
assert_no_file "$GUARDEN_STATE/beds/nutristack-staging"
assert_no_file "$GUARDEN_STATE/homes/bed-nutristack-staging"
if grep -q "bed-nutristack-staging.internal" "$GUARDEN_STATE/hosts" 2>/dev/null; then
  echo "assert: hyphae name should be removed"
  failures=$((failures + 1))
fi

assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
assert_exit 2 weedr bed drop nutristack-production
assert_file "$GUARDEN_STATE/beds/nutristack-production"
assert_exit 0 weedr bed drop nutristack-production --yes
assert_no_file "$GUARDEN_STATE/beds/nutristack-production"
assert_no_file "$GUARDEN_STATE/homes/bed-nutristack-production"

finish
