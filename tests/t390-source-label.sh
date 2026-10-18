#!/usr/bin/env bash
# Ticket 291: the registry's `source` field is the record of how a service came
# to be — `manual` or `gitops`, "recorded, and it changes nothing" (spec 3.4) —
# and `gitops` names one path: the receiver, spec 6.7, which refuses a project
# this host has never registered (`hose` -> `projects.get`) and can only stage
# into a directory `weedr project grant` created for a registered project.
#
# So a poke-shaped ingest of a project registered nowhere records `manual`, and
# the same shape against a registered project records `gitops`. Both claims are
# asked of the registry file the mutator wrote — the record is the subject, not
# anything the program says about it.
#
# The premise is measured the way the deploy box was: eleven records carrying
# `source = "gitops"` on a host where seven of their projects were registered
# in neither `projects.toml` nor `projects.d/` (2026-10-18, audit §3.2), which
# is this file's first ingest with the answer corrected.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# Nothing is registered on this host, which is the state the seven measured
# records were in: no `projects.toml` at all and an empty `projects.d/`.
run weedr project list
assert_exit 0
assert_stdout_has "no projects"

# A poke whose project names nothing registered. Its tree is staged by hand
# the way the deploy box staged them, and what the registry records is what
# actually happened — a manual ingest in the poke's shape.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has /var/lib/guarden/registry/myapp-production.toml 'source = "manual"'

# Register the project, and the same shape for a second service is what the
# receiver would have produced: this is the claim that must not regress.
run weedr project add myapp --repository https://example.invalid/myapp.git
assert_exit 0
assert_file_exists /etc/guarden/projects.d/myapp.toml

run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has /var/lib/guarden/registry/myapp-staging.toml 'source = "gitops"'

# The label is written once, at creation. Registering the project afterwards
# does not retroactively turn the hand-staged ingest into a gitops deploy, so
# a re-ingest of the first service — converged or not — leaves it `manual`.
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has /var/lib/guarden/registry/myapp-production.toml 'source = "manual"'
