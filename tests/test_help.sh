#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for cmd in soil weedr stakes roots twig pond hose; do
  assert_exit 0 "$cmd" --help
  assert_output_has "usage:" "$cmd" --help
done

finish
