#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"
BED="bed-staging-nutristack"
HOSTS="$GUARDEN_STATE/hosts"

assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed stop nutristack --env staging
assert_call_log_has "systemctl --user stop"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed restart nutristack --env staging
assert_call_log_has "systemctl --user stop"
assert_call_log_has "systemctl --user start"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr bed remove nutristack --env staging
assert_call_log_has "systemctl --user stop"
assert_call_log_has "userdel"
assert_no_file "$GUARDEN_STATE/beds/$BED"
assert_no_file "$GUARDEN_STATE/homes/$BED"
if grep -q "bed-staging-nutristack.internal" "$HOSTS" 2>/dev/null; then
  echo "assert: hyphae name should be removed"
  failures=$((failures + 1))
fi
if grep -q " nutristack.internal" "$HOSTS" 2>/dev/null; then
  echo "assert: hyphae alias should be removed"
  failures=$((failures + 1))
fi

assert_exit 0 weedr bed plow nutristack --env production --from "$PROJECT"
assert_exit 2 weedr bed remove nutristack --env production
assert_output_has "refusing to remove production bed" weedr bed remove nutristack --env production
assert_file "$GUARDEN_STATE/beds/bed-production-nutristack"
assert_exit 0 weedr bed remove nutristack --env production --yes
assert_no_file "$GUARDEN_STATE/beds/bed-production-nutristack"
assert_no_file "$GUARDEN_STATE/homes/bed-production-nutristack"
if grep -q "bed-production-nutristack.internal" "$HOSTS" 2>/dev/null; then
  echo "assert: production hyphae name should be removed"
  failures=$((failures + 1))
fi

assert_exit 2 weedr bed drop bed-staging-nutristack
assert_output_has "weedr bed remove" weedr bed drop bed-staging-nutristack

finish
