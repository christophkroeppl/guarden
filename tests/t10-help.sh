#!/usr/bin/env bash
# Every program exists, and its --help lists the verbs the spec lists and
# nothing else. The verb sets below are the interface blocks of spec 6.1-6.8,
# copied here deliberately: a parser that drifts from the contract is invisible
# from anywhere but this file, and copying the list is the only way a test can
# hold it.
#
# machine: shared
# two help surfaces, one file read, and two rejections that happen in the
# parser before any host state is consulted. Nothing here creates an
# identity, a volume or a package.

. "$(dirname "$0")/lib.sh"

assert_verbs soil packages storage sysctl firewall install units list
assert_verbs weedr service secret port pin module project firewall
assert_verbs loom render check
assert_verbs roots sync
assert_verbs twig sync
assert_verbs furrow deploy preview queue status
assert_verbs hose poke drop check
assert_verbs stakes pin unpin list query

assert_subcommands weedr service ingest add remove purge gate start stop restart list status snapshot fork rollback build immutable mutable
assert_subcommands weedr secret set list materialise
assert_subcommands weedr port list open close
assert_subcommands weedr pin sync
assert_subcommands weedr module list add remove
assert_subcommands weedr project list add remove keys grant revoke
assert_subcommands furrow preview drop
assert_subcommands furrow queue list show

run soil --help
assert_exit 0
run weedr --help
assert_exit 0
run loom --help
assert_exit 0
run roots --help
assert_exit 0
run twig --help
assert_exit 0
run furrow --help
assert_exit 0
run hose --help
assert_exit 0
run stakes --help
assert_exit 0

# Each program is a console script, not a shell entry point (AGENTS.md), and
# the eight names are the whole list.
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'soil = "guarden.soil:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'weedr = "guarden.weedr:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'loom = "guarden.loom:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'roots = "guarden.roots:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'twig = "guarden.twig:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'furrow = "guarden.furrow:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'hose = "guarden.hose:main"'
assert_file_has "$GUARDEN_ROOT/pyproject.toml" 'stakes = "guarden.stakes:main"'

# A verb with no body is not a success, and it says so in one line naming the
# verb. A test that could not tell the two apart would be worth nothing.
# `start` is not the verb here any more: ticket 60 gave it a body, because the
# gate it re-evaluates is the reason a start is a mutator verb.
run weedr service build myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "weedr service build is not implemented"
assert_stdout_empty

# A rejected input is exit 2, and names the thing it is about.
run weedr service add myapp-production
assert_exit 2
assert_stderr_has "--from"
assert_stdout_empty

# `hose` has no project argument at all: an invocation carrying one is exit 2,
# because a client-supplied --project would beat the forced command's.
#
# The exit code and the diagnostic are the claim, and they are the whole of it.
# The assertion that used to sit here — that the rejected call reached no tool —
# was a call-log assertion, and **it was dropped rather than ported**: nothing on
# the box records which programs a rejected `hose` invocation reached, and
# "a program did not call X" is not a fact about a machine. The parser refuses
# the argument before it resolves any path, so there is no state to read back,
# and inventing a probe to preserve the claim would be a stand-in of the other
# kind.
run hose poke main 9f2c1ab --project other
assert_exit 2
assert_stderr_has "--project"
