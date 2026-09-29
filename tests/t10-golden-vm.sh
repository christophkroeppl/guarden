#!/usr/bin/env bash
# The golden-VM runner entry point (ticket 10 item 7). The runner resolves a
# target and a cloud-init user-data and runs the sequence; what the run proves
# is tickets 15, 20 and 140's work, and none of it is claimed here.
#
# The entry point is exercised on its argument handling only, because the run
# itself is minutes long and needs a machine. It is pointed at a throwaway one
# and not at this box: nothing in it may reformat, reconfigure or reboot the
# host the tests are running on.

. "$(dirname "$0")/lib.sh"

assert_file_exists "$GUARDEN_ROOT/tools/golden-vm"
assert_executable "$GUARDEN_ROOT/tools/golden-vm"

tool golden-vm --help
assert_exit 0
assert_stdout_has "--target"

# The user-data is ticket 130's, and until it exists the runner says so and
# names the file rather than booting something.
tool golden-vm --print
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "user-data"
assert_stderr_has "tools/cloud-init/user-data.yaml"

mkdir -p "$GUARDEN_FIXTURES/cloud-init"
printf '%s\n' '#cloud-config' 'packages: [btrfs-progs, snapper]' >"$GUARDEN_FIXTURES/cloud-init/user-data.yaml"

# The plan is the machine's whole run, and it is readable without a machine:
# every soil phase converged, then every phase checked for drift.
tool golden-vm --user-data "$GUARDEN_FIXTURES/cloud-init/user-data.yaml" --print
assert_exit 0
assert_stdout_has "packages storage sysctl firewall install units"
assert_stdout_has "soil packages --apply"
assert_stdout_has "soil units --check"

# With a plan in hand and no target, the runner refuses rather than falling back
# to somewhere it was not pointed.
tool golden-vm --user-data "$GUARDEN_FIXTURES/cloud-init/user-data.yaml"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no target"

tool golden-vm --user-data "$GUARDEN_FIXTURES/cloud-init/user-data.yaml" --target
assert_exit 1
tool golden-vm --user-data "$GUARDEN_FIXTURES/cloud-init/user-data.yaml" --nonsense
assert_exit 1
assert_stderr_has "--nonsense"
tool golden-vm --user-data "$GUARDEN_FIXTURES/absent.yaml" --print
assert_exit 1
assert_stderr_has "absent.yaml"
