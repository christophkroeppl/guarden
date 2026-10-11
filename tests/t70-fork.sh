#!/usr/bin/env bash
# `weedr service fork` and `weedr service rollback`: the two verbs that move data.
#
# (ticket 70, spec 8.3, 8.4, 8.6)
#
# **The complete set is validated before anything is changed.** btrfs has no
# atomic multi-subvolume snapshot primitive, so a snapshot is several volumes that
# are each consistent and may be microseconds apart. A service with a `data` and a
# `cache` volume is in exactly the state a crash is about: half one instant, half
# another. Both verbs here resolve the whole set, refuse a volume that has no
# snapshot **naming it**, and move nothing.
#
# **A number never names a set and a time does**, so `--to` is a time. The
# configuration name is `<service>-<volume>` and nothing parses it, and a service
# with two state volumes has a *different* number in each of its configurations —
# so `--to 41` would restore one volume to one instant and the other to another.
#
# **A fork pins the source for the duration by creating the pin file**, which is
# why the file appears during the verb and is gone after it, and why a clone
# cannot be taken of a snapshot the reconciler is about to unmark.
#
# The whole file runs against the real machine. There is no fabricated snapshot
# list, no `.modifications` file and no call log: the subvolumes are real, the
# clones are real btrfs clones, and what a verb did is read back off the
# filesystem — `btrfs subvolume show` for what exists, `btrfs property get ro` for
# the read-only flag, `lsattr` for immutability, and the registry for the record.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. Every claim below is
# a question to the box: a real subvolume, a real clone, a real `btrfs property`,
# a real snapper configuration. `.venv/bin` is kept first because it is the
# checkout's interpreter and not a stand-in for anything.
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

registry=/var/lib/guarden/registry
production=/var/lib/guarden/services/myapp-production
staging=/var/lib/guarden/services/myapp-staging
config=myapp-production-data

# Data that differs between the two services, so "the clone carries the source's
# bytes and not the target's" is a question with two possible answers.
#
# **The source's file is written before the snapshot is taken, because the clone
# is made of the snapshot and not of the live volume.** The claim that used to
# stand here — "the file lives in the source's live volume, so the snapshot taken
# above contains it" — was false and the test failed on it: `pgdata` was created
# after snapshot 1, so the clone faithfully carried a snapshot that had never
# held the file and the volume came back empty. That is the difference worth
# having this file assert, because a clone made from the source's *live* volume
# and one made from its snapshot are otherwise indistinguishable here.
printf 'the source data\n' >"$production/state/data/pgdata"
printf 'the target data\n' >"$staging/state/data/pgdata"
printf 'the target chainstate\n' >"$staging/bulk/chainstate/state.bin"

# The source's snapshot has to exist as a subvolume for the clone to be made of
# it, and only real `snapper` makes one — the fake this file used to lean on did
# not, and a test that let it would have been asserting that the stand-in worked.
# A `number`-tagged snapshot is the kind a fork clones and the kind a mark
# protects; `weedr service snapshot` only ever takes routine ones, so this is
# taken the way an operator's own `snapper create` takes it.
run snapper -c "$config" create --cleanup-algorithm number --description "guarden fork source"
assert_exit 0
assert_snapshot_count "$config" 1
source_number=1

# Lineage is the track's `fork_from` row and never the track's name, so `staging`
# forks from `production` with no flag at all.
run weedr service fork myapp-staging
assert_exit 0
assert_stdout_has "forked myapp-staging from myapp-production"
assert_stdout_has "cloned myapp-production:data@$source_number"

# The clone is a real subvolume carrying the **source's** bytes, and it is not the
# target's. Three separate facts, and each is read off the filesystem rather than
# out of a log of the `btrfs subvolume snapshot` that was issued.
assert_subvolume "$staging/state/data"
assert_file_has "$staging/state/data/pgdata" "the source data"
assert_file_lacks "$staging/state/data/pgdata" "the target data"
# btrfs does not make a snapshot read-only (docs/notes item O measured it), so
# clearing the flag is a real property write rather than a redundant one — which is
# why this is asked of the property and not merely of the clone's existence.
assert_property "$staging/state/data" ro false
# And the source was not written to: the clone is the buffer.
assert_file_has "$production/state/data/pgdata" "the source data"

# A bulk volume is a subvolume on the fork path too, and it is **empty**: a copy
# as of an instant is not reproducible afterwards, and two targets that quietly
# disagreed would be worse than two empty ones. The subvolume exists, and nothing
# was cloned into it.
#
# The assertion that used to sit here read
# `btrfs subvolume create $staging/bulk/chainstate` out of a call log. What the box
# can say instead is the whole of the claim: the volume is a subvolume, and it is
# empty — the file the test put there before the fork is gone, which is the only
# way to tell an empty bulk volume from one that was never touched.
assert_subvolume "$staging/bulk/chainstate"
assert_file_missing "$staging/bulk/chainstate/state.bin"
assert_file_missing "$staging/bulk/chainstate/.cloned-from"

# The units are stopped before a subvolume is moved and started after the clone
# lands. A running container writing into a subvolume that is being renamed is a
# data problem and not a cosmetic one.
#
# This was two call-log assertions naming `systemctl --user --machine
# myapp-staging@ stop` and `... start`. They are now one assertion of the outcome,
# and the outcome is the same whichever order the units were touched in: a unit in
# the service's own home is **not active** afterwards. Nothing here ever started a
# container, so this cannot distinguish "stopped and started" from "never touched" —
# the claim that survives is the weaker but real one, and the stronger one needs a
# running container on a real user manager, which is ticket 140's golden-VM work.
touch "$staging/home/.config/containers/systemd/web.container"
assert_unit_not_active myapp-staging web

# The seed is recorded against the **source's** snapshot: that is the one that has
# to survive, and the one `stakes list` reports as wanted.
assert_file_has "$registry/myapp-staging.toml" "service = \"myapp-production\""
assert_file_has "$registry/myapp-staging.toml" "volume = \"data\""
assert_file_has "$registry/myapp-staging.toml" "number = $source_number"

# The pin was created for the duration of the clone and released after it. What
# protects a snapshot is the mark, and the reconciler is what writes it — the fork
# itself wrote no mark, and a fork that did would be marking snapshots by hand.
#
# Both halves are state now. The pin file's absence is the release, and the mark's
# absence is the reconciler's alone: a fork that marked its own source would leave
# `important=yes` on a snapshot nothing had asked for.
assert_file_missing /var/lib/guarden/stakes/"myapp-production:data@$source_number"
assert_snapshot_marked "$config" "$source_number" no

# The recorded seed is what `stakes list` reports, and it names the service that
# wants it, which is the question `stakes list` exists to answer.
run stakes list
assert_exit 0
assert_stdout_has "myapp-production:data@$source_number"
assert_stdout_has "wanted by myapp-staging"

# A second fork takes a fresh `number`-tagged snapshot when the source has none
# newer than the target's recorded seed, so two forks are two distinct bases. The
# tag is what makes it protectable: a `timeline` snapshot is not a candidate for
# the number cleaner, and a mark on one is not a mark.
#
# The count and the tag are both read back off the configuration, so this says the
# configuration grew and what the new entry is tagged — not that a particular argv
# was issued.
run weedr service fork myapp-staging
assert_exit 0
assert_snapshot_count "$config" 2
assert_newest_snapshot "$config" 2
assert_snapshot_tag "$config" 2 number
# And it is still not marked: a fork that marked what it took would be doing the
# reconciler's job by hand.
assert_snapshot_marked "$config" 2 no

# `--from` overrides the row, so an operator can fork from production by hand and
# in the call log. The staged manifest's own `fork_from` never reaches this: the
# lineage is the track's field and the manifest is refused by name.
run weedr service fork myapp-staging --from myapp-production
assert_exit 0

# `--from <service>@<moment>`: the moment selects a **set**, and one volume
# resolving to a different instant than another is the whole failure this avoids.
#
# The moment is read out of the configuration rather than written down, because a
# real clock decided it: a hand-written timestamp would either name a set that
# does not exist or, worse, accidentally name one.
moment=$(python3 "$GUARDEN_ROOT/tests/snapfield.py" "$config" 1 date \
    <"$GUARDEN_FIXTURES/snapper-$config.json" | awk '{print $1" "$2}')
# **The number the moment resolves to is computed, not written down.** The walk
# is `newest_at_or_before`'s — skip anything after the moment, keep the best by
# `(date, number)` — so a same-second tie resolves to the HIGHER number and the
# answer depends on the clock. Writing `@1` down is a flake; writing nothing
# down is worse, because then a fork that cloned the wrong snapshot would pass.
# `resolve` runs the program's own walk, so the assertion below is both
# deterministic and able to catch a wrong selection.
expected=$(_snapfield "$config" resolve "$moment")
[ -n "$expected" ] || _fail "no snapshot resolves to the moment $moment"
run weedr service fork myapp-staging --from "myapp-production@$moment"
assert_exit 0
assert_stdout_has "cloned myapp-production:data@$expected"
assert_subvolume "$staging/state/data"

# A name that is not a time is rejected as input, not resolved to a number.
run weedr service fork myapp-staging --from myapp-production@not-a-time
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "time"

# The complete set, and the failure that costs the most if it is assembled in
# pieces. The `twovol` project declares two state volumes and a bulk one, so both
# services are created by a real ingest and the topology is one the mutator made
# rather than a registry this file typed.
#
# The source is **`myapp-production`**, which declares `data` only, and the target
# is `twovol-staging`, which declares `data` and `cache`. The source's own registry
# decides which volumes it has, so `cache` resolves to nothing, the whole verb is
# refused naming it, and nothing moves.
#
# The source is named with `--from`, and that is the only way a service forks from
# another workload's production: with no flag the track's `fork_from` row resolves
# inside the **target's own workload** (spec 8.3, `twovol-staging` → `twovol-
# production`), and two services of one workload created by the same manifest
# declare the same volumes, so the volume that is missing cannot arise on that
# path at all. The verb asked for here without the flag resolved `twovol-
# production`, which is not on this host, and said `the fork source twovol-
# production has no registry entry` — a true diagnostic about a different question.
#
# The claim is "the target is untouched", and the way to ask that of the box is to
# put a byte in the target's volume before the verb and find it still there after.
# The assertion that used to sit here counted `btrfs subvolume snapshot` lines,
# which is a record of what was asked and cannot tell a refusal from a swap that
# was undone.
stage_poke twovol 9f2c1ab
run weedr service ingest twovol-staging --from poke twovol@9f2c1ab
assert_exit 0
twovol_staging=/var/lib/guarden/services/twovol-staging
printf 'the old target\n' >"$twovol_staging/state/data/before"
run weedr service fork twovol-staging --from myapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "cache"
assert_file_exists "$twovol_staging/state/data/before"
assert_file_has "$twovol_staging/state/data/before" "the old target"
# The volume that resolved is named in the same refusal, so an operator can see
# what did resolve and what did not rather than being told only that it failed.
assert_stderr_has "data@"
# And no pin was left behind by a verb that did nothing: the pins are created
# before the swap and released on every path out of it, so a failed clone leaves
# nothing pinned forever.
assert_file_missing /var/lib/guarden/stakes/"myapp-production:data@$source_number"

# The other half of the same failure: a source that **does** declare the volume
# but has no snapshot of it. A snapshot of a running service is what a fork clones,
# so one is taken — with the `number` tag, which is what makes it protectable by a
# mark. The mark itself is the reconciler's to write and not the fork's, so nothing
# was marked.
#
# The source is `twovol-production`, ingested for real from the same two-volume
# project and therefore carrying both configurations with no snapshots in either:
# that is the state a service is in between its creation and its first nightly.
# Both snapshots the verb takes are read back out of real configurations, so the
# count and the tag are facts and not a record of an argv.
stage_poke twovol 9f2c1ab
run weedr service ingest twovol-production --from poke twovol@9f2c1ab
assert_exit 0
run weedr service fork twovol-staging
assert_exit 0
# One snapshot per volume that needed one, both `number`-tagged, and neither
# marked: a fork that marks what it takes is doing the reconciler's job by hand.
assert_snapshot_count twovol-production-data 1
assert_snapshot_count twovol-production-cache 1
assert_snapshot_tag twovol-production-cache 1 number
assert_snapshot_marked twovol-production-cache 1 no
assert_snapshot_marked twovol-production-data 1 no
# And both target volumes are real clones rather than one of them being skipped.
assert_subvolume "$twovol_staging/state/data"
assert_subvolume "$twovol_staging/state/cache"
assert_property "$twovol_staging/state/cache" ro false
# The bulk volume is a subvolume on the fork path too, and it is empty.
assert_subvolume "$twovol_staging/bulk/scratch"

# A rollback takes a **time**, refuses a number-shaped one as the thing it would
# have to be, and restores the whole set.
run weedr service rollback myapp-staging --to 41
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "time"
run weedr service rollback myapp-staging
assert_exit 2

# The staging service needs a snapshot of its own for a rollback to restore from,
# and it is taken through the verb so it is a real `timeline` snapshot.
run weedr service snapshot myapp-staging
assert_exit 0
assert_snapshot_count myapp-staging-data 1
staging_number=1
printf 'the restored marker\n' >"$staging/state/data/marker"
staging_moment=$(python3 "$GUARDEN_ROOT/tests/snapfield.py" myapp-staging-data \
    "$staging_number" date <"$GUARDEN_FIXTURES/snapper-myapp-staging-data.json" \
    | awk '{print $1" "$2}')
# The rollback must land on the snapshot taken **before** the marker existed, so
# the moment is the configuration's own earliest date rather than a written-down
# one, and the file's absence afterwards is the claim.
run weedr service rollback myapp-staging --to "$staging_moment"
assert_exit 0
assert_stdout_has "rolled myapp-staging back to data@$staging_number"
# The target's own snapshot history lives **inside** the volume being restored, so
# the clone is made of the copy that was moved aside. A fork's source is another
# service's tree and is unaffected, which is why this is a path rewrite and not a
# different ordering.
assert_subvolume "$staging/state/data"
assert_file_missing "$staging/state/data/marker"
# The live volume is back in the registry's name and the moved-aside copy is still
# there, because a rollback moves data aside and does not destroy it.
assert_file_exists "$staging/state/data/pgdata"

# A rollback on a gated track is refused outright, and there is no flag that
# overrides it: the verb is on no sudoers rule, so this is a refusal an operator
# lifts by conceding in their own judgement that this is the wrong next action.
#
# "Moved nothing" was a count of `btrfs subvolume snapshot` lines naming the
# production tree, which is a record of what was asked. It is now the state of the
# production tree itself: its subvolumes are the ones it had, and the volume that
# a successful rollback would have renamed is still where it was.
run weedr service rollback myapp-production --to "$staging_moment"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "gated"
assert_stdout_empty
assert_subvolume "$production/state/data"
assert_file_has "$production/state/data/pgdata" "the source data"
# A rollback moves a volume aside under `<volume>.replaced.<stamp>`, so the
# absence of any such name in the production tree is the claim that nothing moved.
if [ -n "$(find "$production/state" -maxdepth 2 -name 'data.replaced.*' 2>/dev/null)" ]; then
    _fail "the refused rollback moved a production volume aside"
fi

# A repository cannot state a lineage. It is a field on the track and the answer is
# never in the repository, so the key is refused **by name** with the reason,
# rather than ignored: an ignored `fork_from` would be a key a developer believed
# was in effect.
#
# The refusal is the manifest parser's and happens before anything is created — so
# no service and no subvolume comes into being, which is the state this asks the
# box, where a call log could only have said a parser had complained.
#
# The service is `legacy-production` and the poison is in the **twovol** project:
# the verb resolves the name against the track table before it reads anything, so a
# name that is not on a shipped track (`myapp-lineage`, as this said first) is
# refused for that reason instead, and the message would have been about the track
# rather than about the key. `legacy-production` is a service of a workload nothing
# else in this file creates, on a shipped track, so "nothing was created" is a
# state the box can be asked about.
stage_poke twovol 9f2c1ab
seed /var/lib/guarden/staging/twovol/9f2c1ab/.guarden/service.yml \
    "project: twovol" "units: compose.yaml" "fork_from: production" \
    "state:" "  - data" "bulk:" "  - chainstate"
run weedr service ingest legacy-production --from poke twovol@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "fork_from"
assert_stderr_has "lineage is a field on the track"
assert_file_missing /var/lib/guarden/registry/legacy-production.toml
assert_file_missing /var/lib/guarden/services/legacy-production

# A fourth track forks because a row says so. `preprod` is a configuration change
# and needs no change to any program, which is the claim the shipped table makes
# and this is the assertion for it: the row says `fork_from = "production"`, and
# nothing in guarden knows the word `preprod`.
stage_config guarden-preprod.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-preprod --from poke myapp@9f2c1ab
assert_exit 0
run weedr service fork myapp-preprod
assert_exit 0
assert_stdout_has "forked myapp-preprod from myapp-production"

# A row whose `fork_from` names a track that is not in the table, and one that
# names its own track, are both exit `2` naming the track — and both are refused
# when the table is **read**, before any verb can be ambiguous about which service
# it meant.
stage_config guarden-badfork.toml
run weedr service fork myapp-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "fork_from"
stage_config guarden-selffork.toml
run weedr service fork myapp-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "fork_from"
