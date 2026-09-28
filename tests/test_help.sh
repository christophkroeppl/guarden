#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for cmd in soil weedr stakes roots twig pond hose; do
  assert_exit 0 "$cmd" --help
  assert_output_has "usage:" "$cmd" --help
done

assert_output_has "bed plow" weedr --help
assert_output_has "bed remove" weedr --help
assert_output_has "bed list" weedr --help
assert_output_has "pond dig" weedr --help
assert_output_has "pond fill" weedr --help
assert_output_has "pond drain" weedr --help
assert_output_has "pin <snapshot>" stakes --help
assert_output_has "unpin <snapshot>" stakes --help
assert_output_has "query [snapshot]" stakes --help
assert_output_has "list" stakes --help

finish
