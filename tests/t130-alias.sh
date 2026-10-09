#!/usr/bin/env bash
# The one item of `soil install` that comes from a probe rather than from a file,
# and what the phase says when the probe cannot answer.
#
# (ticket 130, spec 6.1, spec 1.2)
#
# `ingress.alias` is the only value in the whole install phase that is measured
# rather than written: the phase runs a container, reads the gateway its default
# route names, and records that address, because pasta maps it and a container
# that cannot reach the host answers every route with a cause-less 502. Every
# other item is a file or a tool, so every other item converges on any machine
# that has the tool.
#
# **A probe that cannot run is a host fact, and it is reported like one.** That is
# the claim here, and it is a claim about the *diagnostic*: `podman` is a
# `packages` item, so a host that has not run that phase has no container runtime
# at all, and `soil install --apply` on such a host exits `1` with two lines — the
# probe naming what it could not do and the item named as drift. What it must not
# do is let the interpreter's exception out: that is also exit `1`, so the exit
# code agrees while stderr carries a stack trace instead of a sentence, which is
# the failure mode no test can assert about and no operator can act on. That is
# not hypothetical — it is what this suite was written for, and the assertions
# below are the regression.
#
# The same suite then proves the other half, which is what the other two ticket-130
# suites now assert and used to borrow this one for: with the alias measured, the
# install phase converges and a `--check` on it is silent. So the exit codes here
# and there are all about the phase rather than about a container image this
# repository does not ship.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
config=/etc/guarden/guarden.toml

# The shipped table with an unmeasured alias, which is the state of a host whose
# probe has never run. It is `fixtures/guarden.toml` rather than the empty-selection
# one because it already records a module: no `--modules` is passed below, so the
# selection is not an item, and the alias is the only fact in dispute.
stage_config guarden.toml
assert_file_has "$config" 'alias = ""'

# The probe runs and cannot answer. Whichever of the two ways that happens on a
# given machine — no container runtime installed, or a runtime with no probe image
# to run — the answer is the same shape: a line naming the probe and a line naming
# the item as drift, and no interpreter between them.
run soil install --apply
assert_exit 1
assert_stderr_has "alias probe"
assert_stderr_has "drift: ingress.alias holds an address the probe measured"
# **And the line names the cause.** The shape above is not enough on its own, and
# this is the assertion that says so: the probe used to answer "the container's
# default route names no gateway" for *every* failure, so a host with no `podman`
# was told about its route -- a cause this machine does not have, since it has a
# default route and the probe never reached reading one. A line naming the wrong
# cause sends the operator to the wrong remedy, which is the same defect as a
# stack trace in a different costume. Whichever of the two causes this machine
# has, the answer must not be this one.
assert_stderr_lacks "names no gateway"
# And the alias is still unmeasured afterwards. A failed probe that recorded an
# address would be worse than one that recorded nothing: the edge would start with
# a gateway that does not reach this host, and it answers every route with a 502
# that names no cause.
assert_file_has "$config" 'alias = ""'

# The same answer without running anything, which is what `--check` is for: the
# item is drift, and it is the only item, because every other one converged in the
# apply above.
run soil install --check
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "drift: ingress.alias holds an address the probe measured"

# And the other half. With the alias measured — the value `soil install` writes
# when the probe has run, and the only thing the edge refuses to start without —
# the phase converges, and a `--check` on the converged host is silent. This is
# what "exit 0 is done or already true" looks like (spec 1.2), and it is the
# precondition t130-modules.sh and t130-scripts.sh state for themselves.
stage_config guarden-measured.toml
run soil install --apply
assert_exit 0
assert_stderr_empty
run soil install --check
assert_exit 0
assert_stderr_empty
assert_file_has "$config" 'alias = "192.0.2.1"'