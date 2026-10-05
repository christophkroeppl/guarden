#!/usr/bin/env bash
# `weedr service snapshot`: a routine snapshot, and only ever a routine one.
#
# (ticket 70, spec 8.2, 8.3)
#
# **The two kinds of snapshot are distinguished by the tag and nothing else.** A
# routine one is `timeline`-tagged and lives by the ladder; an on-demand one is
# `number`-tagged and is what the marks protect. There is no flag that chooses
# between them, so what is pinned here is that `weedr service snapshot` never
# marks what it takes — a routine snapshot carrying `important=yes` would be
# excluded from the ladder it is supposed to live by, and the only thing that
# would put it back in it is an operator reading a retention report.
#
# The id on stdout is `<service>:<volume>@<number>`, because a configuration's
# name is opaque and a service with two state volumes has a different number in
# each configuration: `myapp-production-data-42` would be ambiguous and is never
# emitted.
#
# **Every number in this file is read back off the machine.** There is no
# fabricated snapshot list and no record of what snapper was asked to do: the
# service is created for real, `snapper` takes the snapshot for real, and the
# assertions read `snapper list --machine-readable json` — which is the read
# spec 8.2 names, and the one where `important` is a key rather than a
# comma-joined quoted field.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. Every claim below is
# a question to the box: a real btrfs subvolume, a real snapper configuration, a
# real snapshot list, a real lock file. `.venv/bin` is kept first because it is
# the checkout's interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
stage_config guarden-measured.toml
stage_poke myapp 9f2c1ab
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0

# The configuration the mutator made, and the one it deliberately did not. A
# bulk volume has no configuration at all, and the file under /etc/snapper is the
# way to ask that of the machine — never a call log, which could only say a
# program had not asked.
assert_snapper_config myapp-production-data NUMBER_CLEANUP yes
assert_no_snapper_config myapp-production-chainstate

# A first snapshot, so the routine one below is the second number and not the
# first. Taken through the verb rather than by calling `snapper` directly, because
# this file is about what the verb does and a hand-placed snapshot would make the
# counts this file goes on to assert ones a test arranged.
run weedr service snapshot myapp-production
assert_exit 0
assert_snapshot_count myapp-production-data 1
assert_newest_snapshot myapp-production-data 1
first=$(python3 "$GUARDEN_ROOT/tests/snapfield.py" myapp-production-data 1 date \
    <"$GUARDEN_FIXTURES/snapper-myapp-production-data.json")

# One snapshot per state volume, taken while the service keeps running. Nothing is
# stopped and no lock is taken, and the volume is snapshotted rather than the tree.
#
# "Nothing is stopped" was `assert_not_called "systemctl --user --machine
# myapp-production@ stop"`. There is no container running for this service, so a
# manager-state assertion would pass vacuously and mean nothing; the state that
# *is* assertable is that no lock was taken, which is below, and that the
# configuration holds exactly one more snapshot than it did, which is here.
run weedr service snapshot myapp-production
assert_exit 0
assert_snapshot_count myapp-production-data 2
assert_newest_snapshot myapp-production-data 2

# The id carries the service, the volume and the number, and the number is the one
# the routine snapshot got. The opaque configuration's own name never appears in
# an id, because a service with two state volumes has a different number in each.
assert_stdout_has "snapshotted myapp-production:data@2"
assert_stdout_lacks "myapp-production-data-2"

# The routine snapshot is `timeline`-tagged, and **nothing marked it**. This is the
# replacement for the pair of assertions that used to read a fabricated
# `.modifications` file and a fabricated CSV list: the tag is read out of
# `snapper list --json` and `important` is read as a key of the same document, so
# both halves are facts about the snapshot rather than about a program's intent.
assert_snapshot_tag myapp-production-data 2 timeline
assert_snapshot_marked myapp-production-data 2 no
assert_snapshot_lacks_userdata myapp-production-data 2 guarden
# The first snapshot is the same, so the property is about the verb and not about
# one lucky number.
assert_snapshot_tag myapp-production-data 1 timeline
assert_snapshot_marked myapp-production-data 1 no

# No lock was taken. A btrfs subvolume snapshot is atomic, so a routine snapshot
# needs none, and the lock file is the state that says so: `soil storage` installs
# cleanup under the same key, and its absence here is the claim.
assert_file_missing /run/guarden/locks/snapshots.lock

# The newest number is recorded in the registry, so an operator can ask what the
# newest one is without reading snapper's list. It is a registry field and not a
# `list --json` one: the closed field set in spec 1.2 has `snapshots` as the
# counts read back from snapper, and a second place for the recorded number would
# be a second answer to the same question.
registry=/var/lib/guarden/registry
assert_file_has "$registry/myapp-production.toml" "snapshots = 2"

# The per-volume figures come from `weedr service list --json` as a **root** read,
# because `stakes` runs as `guarden` and a service's tree is `0700` to that
# service: the counts are snapper's and the limits are read back with
# `snapper get-config`, never parsed out of `/etc/snapper/configs/<name>`.
#
# The limits are the ones the mutator wrote, and they are read back through
# `snapper get-config` — which is the read spec 8.1 names. The ladder values below
# are the canonical set from spec 6.1, so they are the same numbers `t30-create`
# asserts on the same host.
run weedr service list --json
assert_exit 0
assert_json services.0.volumes.0.snapshots.total 2
assert_json services.0.volumes.0.snapshots.marked 0
assert_json services.0.volumes.0.snapshots.oldest "\"$first\""
assert_json services.0.volumes.0.snapshots.limits.NUMBER_LIMIT '"2-10"'
assert_json services.0.volumes.0.snapshots.limits.NUMBER_LIMIT_IMPORTANT '"8-12"'
assert_json services.0.volumes.0.snapshots.limits.TIMELINE_LIMIT_DAILY '"0-7"'
run weedr service list
assert_exit 0
assert_stdout_has "myapp-production-data  2 snapshots, 0 marked"
assert_stdout_has "NUMBER_LIMIT 2-10, NUMBER_LIMIT_IMPORTANT 8-12"

# A bulk volume is snapshotted by nothing, and its configuration is never asked
# about: a bulk volume that quietly appeared would be a volume whose data nothing
# had ever protected. `assert_no_snapper_config` above is that claim; the count
# staying at two across the `--all` run below is it again after more work.
#
# The assertion that used to sit here was
# `assert_not_called "snapper --config myapp-production-chainstate"`, and it is now
# a fact about the filesystem: there is no such configuration for `snapper` to
# list, which is why nothing can have snapshotted it.
assert_no_snapper_config myapp-production-chainstate

# `--all` names the bulk volumes it skipped rather than passing them over in
# silence, which is the whole of its contract, and it reaches the other service.
run weedr service snapshot --all
assert_exit 0
assert_stdout_has "skipped the bulk volume chainstate of myapp-production"
assert_snapshot_count myapp-staging-data 1
assert_snapshot_tag myapp-staging-data 1 timeline
assert_snapshot_marked myapp-staging-data 1 no
# And it reaches **this** service too: `--all` is "every service with a state
# volume" (spec 8.2), which is what makes the nightly timer a snapshot a night
# rather than one the first night and none after. The assertion that stood here
# expected the count to stay at two, and it contradicted the assertion three lines
# above it — the same `--all` cannot have reached `myapp-staging-data` and not
# reached `myapp-production-data`. It read as though `--all` had skipped a bulk
# volume, which is the claim two assertions up: a bulk volume has no snapper
# configuration, so nothing can have snapshotted it. That is now asked of the
# volume itself as well, because a missing configuration is snapper's side of the
# fact and an absent `.snapshots` directory is btrfs's.
assert_snapshot_count myapp-production-data 3
assert_snapshot_tag myapp-production-data 3 timeline
assert_snapshot_marked myapp-production-data 3 no
assert_file_missing /var/lib/guarden/services/myapp-production/bulk/chainstate/.snapshots

# A service or `--all`, and not both: `--all` is every service, so a name beside it
# would be a service the caller has to believe was excluded.
run weedr service snapshot myapp-production --all
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "--all"
run weedr service snapshot
assert_exit 2
assert_one_diagnostic "error:"

# A service with no state volume is named, not passed over. The record is seeded
# because a manifest with no `state:` list would need a second project fixture,
# and what is under test is the verb's report of a topology rather than the
# manifest that produced it.
seed "$registry/chainonly-production.toml" \
    "service = \"chainonly-production\"" "workload = \"chainonly\"" "project = \"chainonly\"" \
    "environment = \"production\"" "uid = 1120" "created = \"2026-09-30T09:00:00Z\"" \
    '[bulk]' 'chainstate = {}'
run weedr service snapshot --all
assert_exit 0
assert_stdout_has "skipped chainonly-production: no state volume"
# And nothing was invented for it: no configuration, so no snapshot.
assert_no_snapper_config chainonly-production-chainstate

# A configuration whose list will not read is not a snapshot, and the verb says so
# rather than recording a number it cannot justify. The list is marked unreadable
# rather than broken, so this is a read failure and not a parse one.
#
# A real unreadable configuration is a configuration whose subvolume is not a
# subvolume any more: `snapper list` then fails on its own, with no stand-in
# involved. The configuration is rewritten in place to name a path that is a plain
# directory, which is exactly the state a volume that was replaced with an
# ordinary directory would leave behind.
mkdir -p /etc/snapper/configs
printf '%s\n' \
    'SUBVOLUME=/etc/guarden' \
    'FSTYPE=btrfs' \
    'NUMBER_CLEANUP=yes' \
    'TIMELINE_CLEANUP=yes' \
    >/etc/snapper/configs/unreadable-staging-data
seed "$registry/unreadable-staging.toml" \
    "service = \"unreadable-staging\"" "workload = \"unreadable\"" "project = \"unreadable\"" \
    "environment = \"staging\"" "uid = 1121" "created = \"2026-09-30T09:00:00Z\"" \
    '[state.data]' 'config = "unreadable-staging-data"'
run weedr service snapshot unreadable-staging
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "unreadable-staging-data"
rm -f /etc/snapper/configs/unreadable-staging-data
rm -f "$registry/unreadable-staging.toml"

# A rejected name is exit 2 and nothing is snapshotted at all: the counts on the
# two real configurations are unchanged. `--all` has run twice since the count of
# three above — once here at line 175 and once for the chain-only service — so the
# unchanged figures are 4 and 2, and asking for the counts as they stood before the
# refusal would pass on a verb that had snapshotted everything.
run weedr service snapshot NOPE
assert_exit 2
assert_one_diagnostic "error:"
assert_stdout_empty
assert_snapshot_count myapp-production-data 4
assert_snapshot_count myapp-staging-data 2
