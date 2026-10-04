#!/usr/bin/env bash
# There is exactly one verb alias in guarden and it is `rm` for `remove`
# (spec 1.3, AGENTS.md). It is not derived from the long form, no other verb has
# one, and a new verb brings none by default — so this file pins the one that
# exists and proves no other help surface shows an alias.
#
# machine: shared
# every call is `--help` or a verb that is not implemented, so nothing here
# reaches the machine's identity databases, its packages or its volumes.
# `weedr project remove myapp` exits 1 from `cli.pending` before any path is
# resolved.

. "$(dirname "$0")/lib.sh"

# The alias is shown beside the long form, in the metavar and in the command
# list, so a reader finds it in either place.
run weedr service --help
assert_exit 0
assert_stdout_has "remove (rm)"
run weedr project --help
assert_exit 0
assert_stdout_has "remove (rm)"

# Both spellings reach the verb, and the usage line names the long form, which
# is what the sudoers grants name and the only form a rule would match.
run weedr service remove myapp-production --help
assert_exit 0
assert_stdout_has "weedr service remove"
run weedr service rm myapp-production --help
assert_exit 0
assert_stdout_has "weedr service remove"

# A diagnostic names the long form whichever the caller typed, so what lands in
# the journal is the form an operator greps for.
run weedr project remove myapp
assert_exit 1
assert_stderr_has "weedr project remove is not implemented"
run weedr project rm myapp
assert_exit 1
assert_stderr_has "weedr project remove is not implemented"

# No other verb has an alias, anywhere: every help surface, at every level.
assert_only_alias_rm soil
assert_only_alias_rm weedr
assert_only_alias_rm weedr service
assert_only_alias_rm weedr secret
assert_only_alias_rm weedr port
assert_only_alias_rm weedr pin
assert_only_alias_rm weedr module
assert_only_alias_rm weedr project
assert_only_alias_rm loom
assert_only_alias_rm roots
assert_only_alias_rm twig
assert_only_alias_rm furrow
assert_only_alias_rm furrow preview
assert_only_alias_rm furrow queue
assert_only_alias_rm hose
assert_only_alias_rm stakes

# And `rm` is not a verb anywhere it is not the alias of. Nothing derived it
# into a position of its own.
run weedr pin rm
assert_exit 2
run weedr service list rm
assert_exit 2
run soil rm
assert_exit 2
run stakes rm
assert_exit 2
