#!/usr/bin/env bash
# The four things a test asserts on: the exit code, the diagnostic lines, the
# files that appeared or vanished, and the call log. A harness that could only
# check one of them would let a program that says the right thing and does the
# wrong thing pass.
#
# Every assertion here runs against a real invocation through the command line.
# No test imports a program, and none may.

. "$(dirname "$0")/lib.sh"

# 1. the exit code. 0 is done or already true.
run soil list
assert_exit 0
assert_stderr_empty
run weedr service start myapp-production
assert_exit 1

# 2. the diagnostic lines: one line, prefixed, naming the thing it is about,
# and on stderr, with the result on stdout and nothing beside it (spec 1.1).
run weedr service start myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "weedr service start is not implemented"
assert_stdout_empty

# 3. the files that appeared. A fake that models a call models its effect.
mkdir -p "$GUARDEN_FIXTURES/snapper"
fake snapper -c myapp-production-pgdata modify --cleanup-algorithm number --userdata 'important=yes' 41
assert_exit 0
assert_file_exists "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.modifications"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.modifications" '41|number|important=yes'

# ...and the files that did not appear: a rejected call changes nothing.
fake snapper -c myapp-production-rejected modify 41
assert_exit 2
assert_file_missing "$GUARDEN_FIXTURES/snapper/myapp-production-rejected.modifications"

# 4. the call log, with the arguments, not just the tool's name.
fake iptables -t nat -A POSTROUTING -o eth0 -d 127.0.0.1 --dport 20000 -j MASQUERADE
assert_called "iptables -t nat -A POSTROUTING -o eth0 -d 127.0.0.1 --dport 20000 -j MASQUERADE"

# A program whose body a later ticket writes calls nothing at all. A skeleton
# that shelled out would put a line in the call log that a later test would
# read as evidence of something this one never did.
assert_makes_no_calls weedr service list
assert_makes_no_calls weedr service restart myapp-production
assert_makes_no_calls soil --check
assert_makes_no_calls loom render . --service myapp-production --out /tmp/units
assert_makes_no_calls roots sync
assert_makes_no_calls twig sync
assert_makes_no_calls furrow status
assert_makes_no_calls hose poke main 9f2c1ab
assert_makes_no_calls stakes list
