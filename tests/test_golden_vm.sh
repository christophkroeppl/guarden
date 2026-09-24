#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 0 golden-vm lxd:guarden-golden
assert_output_has "no phases yet" golden-vm lxd:guarden-golden
assert_exit 2 golden-vm

finish
