#!/usr/bin/env bash
# Taking a service away, one instance at a time, and the one verb that destroys
# data (ticket 30, spec 5.3).
#
# `remove` reverses all of it and **moves** each state and bulk subvolume aside
# rather than deleting it, so a removal is reversible with `weedr service add` and
# nothing here destroys data. It is refused outright on a gated track, and refused
# while any instance exists, with the instance names named.
#
# Every assertion below asks the machine what it holds: a real user from the real
# passwd database, a real btrfs subvolume, a real snapper configuration. A staged
# `/etc/passwd` cannot be reconciled with a `useradd` that wrote to the real one —
# the mutator reads back the subid range it was promised and finds none — so there
# is no staged host here. `GUARDEN_PREFIX=/` is the only value that is not a
# relocation, and `stage_config` needs the variable to exist at all.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. `lib.sh` puts that
# directory on PATH, and every assertion below asks the machine what it holds: a
# real user gone from the real passwd database, a real btrfs subvolume renamed,
# a real snapper configuration still on the host. The fake `userdel` left the
# entry it had been handed in place with uid 0, so "the user is gone" was a fact
# about a stand-in. `.venv/bin` is kept first because it is the checkout's
# interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

stage_config guarden.toml
stage_poke myapp 9f2c1ab
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0

# assert_stopped_in_manager <user> <unit>: the user manager's own answer rather
# than a record of a call. `inactive`, `failed` and `unknown` all mean the
# container is not running, and an exact comparison is the whole of it — a
# substring test would read "inactive" as "active".
assert_stopped_in_manager() {
    local state
    state=$(systemctl --user --machine "$1@" is-active "$2" 2>/dev/null || true)
    [ "$state" != active ] || _fail "$2 is $state in $1's user manager"
}

# A unit in the service's own home is stopped before the volumes move, because a
# running container writing into a subvolume that is being renamed is a data
# problem and not a cosmetic one. What is asserted afterwards is the outcome: the
# unit is not active. A deleted user answers the same question the same way, so
# this proves the state the mutator left behind and not the order it left it in.
touch /var/lib/guarden/services/myapp-staging/home/.config/containers/systemd/web.container
run weedr service remove myapp-staging
assert_exit 0
assert_stdout_has "removed myapp-staging"
assert_stopped_in_manager myapp-staging web

# The user is gone from all three databases, not merely from the passwd file: a
# `userdel` that left the delegated range behind would hand the next service the
# same block of uids and make the firewall's uid matching ambiguous.
assert_no_passwd myapp-staging
assert_no_subid /etc/subuid myapp-staging
assert_no_subid /etc/subgid myapp-staging

# Moved, not deleted: the volume is a rename, which is what carries its snapshots
# with it and what makes the removal reversible. The thing that moved is still a
# subvolume rather than a copy of one, and it is still the service's data.
assert_file_missing /var/lib/guarden/services/myapp-staging
assert_file_exists /var/lib/guarden/removed/myapp-staging
moved=$(find /var/lib/guarden/removed/myapp-staging -maxdepth 2 -name data)
assert_subvolume "$moved"
assert_file_missing /var/lib/guarden/registry/myapp-staging.toml
assert_file_missing /etc/guarden/services/myapp-staging

# The snapper configurations are soil storage's to remove, not this verb's: they
# are the host's, and soil is the phase that converges every configuration it can
# see. So the configuration is still on the host after the removal, and the
# verb's own tree is gone. It is read by name rather than through `get-config`
# here: the configuration now names a subvolume that has been renamed away, and
# what is under test is that it was not deleted along with it.
assert_file_exists /etc/snapper/configs/myapp-staging-data

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
assert_file_exists /var/lib/guarden/services/myapp-production
assert_file_exists /var/lib/guarden/registry/myapp-production.toml

# With the operator's marker in place, it is allowed. The marker is the whole of
# the override, and it is root-owned and outside any track's reach.
#
# The verb leaves the marker where the operator put it — spec 5.3 says the
# *operator* removes it, and the file is present only while a poke may drop a
# service in a gated track, so it is a standing statement about the host rather than
# a token for one drop. What this file has to clean up afterwards is therefore its
# own making: the path is captured where the file is created rather than read back at
# exit, so the trap removes the file this test made whatever the name happens to
# resolve to later.
marker=/etc/guarden/allow-gated-drop
touch "$marker"
trap 'rm -f "$marker"' EXIT
run weedr service remove myapp-production
assert_exit 0
assert_stdout_has 'snapper configurations are left for `soil storage`'
# **The verb does not take the marker with it.** spec 5.3: the operator removes the
# marker, and it is *present only if a poke may drop a service in a gated track* —
# so it is a standing statement about this host, not a token for one drop. A verb
# that deleted a root-owned operator's file as a side effect would be doing exactly
# the thing this design refuses everywhere else, and the drop would also be
# un-gated again the moment the next poke needed it.
assert_file_exists "$marker"
# ...and the operator takes it away again, because that is the whole of the
# override: spec 5.3's way to make the drop possible is for an operator to remove
# the marker, so every later block in this file that needs a gated track refused has
# to start from a host where the marker is not there. It is removed here rather than
# at the end so that the state under test is the one the verb is asked about.
rm -f "$marker"

# An instance track: a whole-service removal is refused while instances exist, and
# it names them. One instance at a time is the only way.
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0

# An instance's own tree is a sibling of the service's volumes, never a child: a
# nested subvolume is excluded from its parent's snapshot entirely, so `state/data`
# would snapshot cleanly, nightly, forever, while containing no instance data at
# all and the only symptom would be an empty restore. The configuration the
# mutator created says which of the two it is, by naming the subvolume it is for.
assert_subvolume "/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/state/data"
assert_file_exists "/var/lib/guarden/services/myapp-preview/home/feature\\x2dlogin"
assert_snapper_config 'myapp-preview-feature\x2dlogin-data' SUBVOLUME \
    "/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin/state/data"
assert_file_missing /var/lib/guarden/services/myapp-preview/state/data

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
assert_file_missing "/var/lib/guarden/services/myapp-preview/instances/feature\\x2dlogin"
assert_file_missing "/var/lib/guarden/services/myapp-preview/home/feature\\x2dlogin"
assert_file_exists /var/lib/guarden/services/myapp-preview

# An instance is refused on a slot track: asking for one there is rejected input,
# not a host fact.
run weedr service remove myapp-preview/feature-login
assert_exit 1
assert_stderr_has "has no instance 'feature-login'"

# purge: the only path in guarden that destroys data. It is not on any sudoers
# rule, it is refused for an instance, and it needs a terminal to confirm at.
#
# stdin is redirected from /dev/null rather than left to whatever is running this
# file: `lxc exec` without -T hands the process a terminal, and a test whose
# subject is "refusing to destroy without one" cannot depend on how it was
# invoked. Pinning it here means the refusal is what the program does, rather than
# what the harness happened to be.
run weedr service purge myapp-preview/feature-login </dev/null
assert_exit 2
assert_stderr_has "an instance's volumes are the service's data"
run weedr service purge myapp-preview </dev/null
assert_exit 1
assert_stderr_has "needs a terminal to confirm at"
assert_stdout_has "about to destroy every volume of myapp-preview"
assert_file_exists /var/lib/guarden/services/myapp-preview

# A gated track is refused for the same reason remove is, and it is refused before
# anything is named: the names go to stdout, so a refusal that came after them
# would have told an operator what was about to die for no reason.
#
# A second workload, because the first production service was removed above and
# its snapper configuration is deliberately still on the host — re-creating one
# the mutator would then collide with would be testing the wrong thing.
stage_poke myapp 9f2c1ab
run weedr service ingest store-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service purge store-production </dev/null
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "on the gated track 'production'"
assert_stdout_lacks "about to destroy"
assert_subvolume /var/lib/guarden/services/store-production/state/data