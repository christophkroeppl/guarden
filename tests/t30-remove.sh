#!/usr/bin/env bash
# Taking a service away, one instance at a time, and the one verb that destroys
# data (ticket 30, spec 5.3).
#
# `remove` reverses all of it and **moves** each state and bulk subvolume aside
# rather than deleting it, so a removal is reversible with `weedr service add` and
# nothing here destroys data. It is refused outright on a gated track, and refused
# while any instance exists, with the instance names named.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0

# A unit in the service's own home is stopped before the volumes move, because a
# running container writing into a subvolume that is being renamed is a data
# problem and not a cosmetic one.
touch "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-staging/home/.config/containers/systemd/web.container"

run weedr service remove myapp-staging
assert_exit 0
assert_stdout_has "removed myapp-staging"
assert_called "systemctl --user --machine myapp-staging@ stop web"
assert_called "userdel myapp-staging"

# Moved, not deleted: the volume is a rename, which is what carries its snapshots
# with it and what makes the removal reversible.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-staging"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/removed/myapp-staging"
assert_file_lacks "$GUARDEN_PREFIX/etc/subuid" "myapp-staging"
assert_file_lacks "$GUARDEN_PREFIX/etc/subgid" "myapp-staging"
assert_file_lacks "$GUARDEN_PREFIX/etc/passwd" "myapp-staging"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-staging.toml"
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/services/myapp-staging"

# The snapper configurations are soil storage's to remove, not this verb's: they
# are the host's, and soil is the phase that converges every configuration it can
# see.
assert_called "userdel myapp-staging"

# A gated track is refused, and no flag overrides it: a sudoers rule granting the
# verb cannot tell a flag from any other argument, so the only way to allow it is
# for the operator to remove the root-owned marker.
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service remove myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "on the gated track 'production'"
assert_stderr_has "allow-gated-drop"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml"

# With the operator's marker removed, it is allowed. The marker is the whole of the
# override, and it is root-owned and outside any track's reach.
touch "$GUARDEN_PREFIX/etc/guarden/allow-gated-drop"
run weedr service remove myapp-production
assert_exit 0
assert_stdout_has 'snapper configurations are left for `soil storage`'

# An instance track: a whole-service removal is refused while instances exist, and
# it names them. One instance at a time is the only way.
guarden_prefix "$GUARDEN_FIXTURES/host-instances"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0

# An instance's own tree is a sibling of the service's volumes, never a child: a
# nested subvolume is excluded from its parent's snapshot entirely, so `state/data`
# would snapshot cleanly, nightly, forever, while containing no instance data at
# all and the only symptom would be an empty restore.
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/state/data"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/home/feature\\x2dlogin"
assert_called 'snapper --config myapp-preview-feature\\x2dlogin-data create-config'
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/state/data"

# A ref that names no instance is refused: the host is not in the assumed state.
run weedr service remove myapp-preview/no-such-ref
assert_exit 1
assert_stderr_has "has no instance 'no-such-ref'"

# An instance track's service is not removed whole while an instance exists. The
# one instance is the service's own first ingest, so its removal releases the
# instance's publication and seed and leaves the service and its tree alone.
run weedr service remove myapp-preview
assert_exit 1
assert_stderr_has "still has instances"

run weedr service remove myapp-preview/feature-login
assert_exit 0
assert_stdout_has "removed the instance feature-login"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview/home/feature\\x2dlogin"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview"

# An instance is refused on a slot track: asking for one there is rejected input,
# not a host fact.
run weedr service remove myapp-preview/feature-login
assert_exit 1
assert_stderr_has "has no instance 'feature-login'"

# purge: the only path in guarden that destroys data. It is not on any sudoers
# rule, it is refused for an instance, and it needs a terminal to confirm at —
# which the harness does not have, so the refusal is what is proven.
run weedr service purge myapp-preview/feature-login
assert_exit 2
assert_stderr_has "an instance's volumes are the service's data"
run weedr service purge myapp-preview
assert_exit 1
assert_stderr_has "needs a terminal to confirm at"
assert_stdout_has "about to destroy every volume of myapp-preview"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-preview"

# A gated track is refused for the same reason remove is, and it is refused before
# anything is named: the names go to stdout, so a refusal that came after them
# would have told an operator what was about to die for no reason.
guarden_prefix "$GUARDEN_FIXTURES/host-purge"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service purge myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "on the gated track 'production'"
assert_stdout_lacks "about to destroy"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/state/data"
