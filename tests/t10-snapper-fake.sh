#!/usr/bin/env bash
# The snapper fake answers, and it answers the way snapper does.
#
# This is the fake that matters most, because a snapper fake that only knew the
# human table would let a CSV parser pass its tests — and reading snapper is
# where guarden's two pinned rules live (spec 8.2, AGENTS.md): snapshot state is
# read with `list --machine-readable json`, because JSON renders a snapshot's
# `userdata` as an object and `important` is a key, while CSV renders the whole
# map as one comma-joined quoted field; and the effective configuration is read
# with `get-config`, never by parsing /etc/snapper/configs/.
#
# So the fake models all three renderings from one seed, and the difference
# between them has to be visible from a test or it is not modelled at all.

. "$(dirname "$0")/lib.sh"

mkdir -p "$GUARDEN_FIXTURES/snapper"
printf '%s\n' '41|number|2026-09-28 18:03:11|before the risky change|important=yes, guarden=myapp-production' >"$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.list"

# json: userdata is an object, so `important` is a key and a lookup needs no
# string matching.
fake snapper -c myapp-production-pgdata list --machine-readable json
assert_exit 0
assert_stdout_has '"number":41'
assert_stdout_has '"cleanup":"number"'
assert_stdout_has '"userdata":{"important":"yes","guarden":"myapp-production"}'
assert_called "snapper -c myapp-production-pgdata list --machine-readable json"

# csv: the same snapshot, and the same map, as one comma-joined quoted field.
# This is the rendering guarden does not read, and a fake that answered it with
# JSON would hide the reason the rule exists.
fake snapper -c myapp-production-pgdata list --machine-readable csv
assert_exit 0
assert_stdout_has '"important=yes, guarden=myapp-production"'
assert_stdout_lacks '"important"'

# The human table carries no userdata at all.
fake snapper -c myapp-production-pgdata list
assert_exit 0
assert_stdout_has "before the risky change"
assert_stdout_lacks "important=yes"

# An unseeded configuration has no snapshots, and says so as an empty JSON array
# rather than inventing one.
fake snapper -c myapp-production-notseeded list --machine-readable json
assert_exit 0
assert_stdout_has "[]"

# A configuration that does not exist is an error, and that is the whole reason
# soil asks rather than statting /etc/snapper/configs/<name>.
fake snapper -c not-a-configuration get-config
assert_exit 1
assert_stderr_has "no configuration for not-a-configuration"

# create-config writes the distribution's own default template, which is the
# state before soil converges anything, and creates no snapshot.
fake snapper -c myapp-production-fresh create-config -f btrfs -p /
assert_exit 0
fake snapper -c myapp-production-fresh get-config
assert_exit 0
assert_stdout_has "EMPTY_PRE_POST_CLEANUP=yes"
assert_stdout_has "NUMBER_MIN_AGE=0"
assert_stdout_has "TIMELINE_LIMIT_DAILY=0-7"
assert_stdout_has "NUMBER_LIMIT_IMPORTANT=8-12"
fake snapper -c myapp-production-fresh list --machine-readable json
assert_stdout_has "[]"

# get-config answers for a key as well as for the whole configuration.
fake snapper -c myapp-production-pgdata get-config NUMBER_LIMIT_IMPORTANT
assert_exit 0
assert_stdout_has "NUMBER_LIMIT_IMPORTANT=8-12"
fake snapper -c myapp-production-pgdata get-config NOT_A_KEY
assert_exit 1

# modify -f merges into what is there rather than replacing it, which is how a
# converged set leaves every other value alone.
printf '%s\n' 'NUMBER_LIMIT_IMPORTANT=4-6' 'A_KEY_SOIL_DOES_NOT_OWN=kept' >"$GUARDEN_FIXTURES/merge.conf"
fake snapper -c myapp-production-pgdata modify -f "$GUARDEN_FIXTURES/merge.conf"
assert_exit 0
fake snapper -c myapp-production-pgdata get-config
assert_stdout_has "NUMBER_LIMIT_IMPORTANT=4-6"
assert_stdout_has "A_KEY_SOIL_DOES_NOT_OWN=kept"
assert_stdout_has "TIMELINE_LIMIT_DAILY=0-7"

# modify records the userdata it was given, because a pin test that does not
# inspect the mark tests nothing: it is the mark, not the pin file, that makes a
# snapshot a candidate's way of being spared.
fake snapper -c myapp-production-pgdata modify --cleanup-algorithm number --userdata 'important=yes, guarden=myapp-production' 41
assert_exit 0
assert_file_exists "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.modifications"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.modifications" '41|number|important=yes, guarden=myapp-production'
assert_called 'modify --cleanup-algorithm number --userdata'

# A cleanup tag other than `number` is a different mechanism, and the fake
# records which one it was given rather than assuming.
fake snapper -c myapp-production-pgdata modify --cleanup-algorithm timeline --userdata 'important=no' 42
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.modifications" '42|timeline|important=no'

# A model that does not exist is a failure, not a success: a fake that exited 0
# for `snapper cleanuop` would let a program shelling out wrongly look correct.
fake snapper -c myapp-production-pgdata cleanuop number
assert_exit 2
assert_one_diagnostic "error:"
fake snapper -c myapp-production-pgdata modify --userdata 'important=yes' 41
assert_exit 2
fake snapper -c myapp-production-pgdata list --machine-readable yaml
assert_exit 2
