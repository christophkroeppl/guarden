#!/usr/bin/env bash
# The canonical value set, as one definition rather than a literal in two places.
#
# `create-config` writes the distribution's template (t10-snapper-fake.sh pins
# that: EMPTY_PRE_POST_CLEANUP=yes and NUMBER_MIN_AGE=0 are what the template
# ships, and a converge is what changes them). So a created configuration is
# never short in practice, and the canonical set is not what a test sees there.
#
# Where it does show is a configuration that exists but carries only what was
# created, before anything has converged it: the read-back answers the effective
# value rather than a hole. That is the fake's `canonical_config`, and these are
# the assertions that keep it alive instead of leaving it unreachable.

. "$(dirname "$0")/lib.sh"

guarden_prefix
mkdir -p /tmp/canonical-subvolume

# Created and not converged: the effective value is the canonical set even though
# the file itself does not carry it.
printf '%s\n' 'SUBVOLUME=/tmp/canonical-subvolume' 'FSTYPE=btrfs' \
    >"$GUARDEN_PREFIX/etc/snapper/configs/not-converged"
seed "$GUARDEN_FIXTURES/snapper/not-converged.created" not-converged
fake snapper -c not-converged get-config
assert_exit 0
assert_stdout_has "EMPTY_PRE_POST_CLEANUP=no"
assert_stdout_has "NUMBER_MIN_AGE=3600"
assert_stdout_has "NUMBER_LIMIT_IMPORTANT=8-12"
assert_stdout_has "FREE_LIMIT=0.10"

# The read-back reports; it does not rewrite. A get-config that persisted the
# canonical set would make a later converge a no-op and the drift undetectable.
assert_file_lacks "$GUARDEN_PREFIX/etc/snapper/configs/not-converged" "EMPTY_PRE_POST_CLEANUP"

# A configuration a test seeded by hand is not "created but not converged", so it
# reads back exactly what the test put in it. This is the distinction the
# `.created` marker exists to make, and getting it wrong would silently replace
# every seeded configuration with the canonical set.
printf '%s\n' 'NUMBER_LIMIT_IMPORTANT=4-6' 'TIMELINE_CLEANUP=no' \
    >"$GUARDEN_PREFIX/etc/snapper/configs/seeded-by-hand"
fake snapper -c seeded-by-hand get-config
assert_exit 0
assert_stdout_has "NUMBER_LIMIT_IMPORTANT=4-6"
assert_stdout_has "TIMELINE_CLEANUP=no"
assert_stdout_lacks "EMPTY_PRE_POST_CLEANUP"

# The two sets are different sets, and the difference is the point: the template
# is the state before a converge, the canonical set is the state after it.
assert_not_called "modify"
