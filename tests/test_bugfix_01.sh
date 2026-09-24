#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/fixtures/projects/nutristack"

assert_exit 0 weedr bed new nutristack --env preview:feat-x --from "$PROJECT"
if grep -q '^snapshot=' "$GUARDEN_STATE/beds/nutristack-preview-feat-x/meta"; then
  echo "assert: meta must lack snapshot= line"
  failures=$((failures + 1))
fi

assert_exit 0 weedr preview drop nutristack --ref feat-x
assert_no_file "$GUARDEN_STATE/beds/nutristack-preview-feat-x"

finish
