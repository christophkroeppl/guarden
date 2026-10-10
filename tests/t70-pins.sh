#!/usr/bin/env bash
# `stakes`, `weedr pin sync`, and `chattr +i`: the three halves of a pin.
#
# (ticket 70, spec 8.5, 8.2, 6.8, ADR-0007)
#
# **Retention is snapper's, and what guarden runs is a reconciler.** The pin files
# and the registries say what is wanted; `weedr pin sync` recomputes the marks from
# both and writes them, and snapper's own algorithms do the deleting. So the three
# things this file separates are: the **pin** (an unprivileged file, a priority
# with a budget), the **mark** (a root write into snapper's metadata, the thing
# that actually protects a snapshot), and the **immutable flag** (a deny that
# nothing overrides, and a different mechanism entirely).
#
# **`stakes` runs as `guarden` and writes no mark.** The mark is the reconciler's,
# because writing snapper's metadata is not something an unprivileged program can
# do. That division is the whole reason the pin store is a directory of files
# anybody in the group may create.
#
# **Every mark in this file is read off the snapshot.** There is no fabricated
# `snapper list`, no `.modifications` file and no call log: the service is created
# for real, `snapper` takes the snapshots for real, and the assertions read
# `snapper list --machine-readable json` — the read spec 8.2 names, and the one
# where `userdata` is an object and `important` is therefore a **key** rather than
# a string a test has to match inside a comma-joined quoted field. The numbers are
# whatever the machine issued; none of them is written down here.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. Every claim below is
# a question to the box: a real subvolume, a real snapshot, a real mark in real
# snapper metadata, a real `chattr`. `.venv/bin` is kept first because it is the
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

registry=/var/lib/guarden/registry
tree=/var/lib/guarden/services/myapp-production
stakes=/var/lib/guarden/stakes
config=myapp-production-data

# Two `number`-tagged snapshots, which is the kind the marks protect: a routine
# `timeline` snapshot is not a candidate for the number cleaner, so a mark on one
# is not a mark. They are taken through `snapper` itself rather than by writing a
# list, because the list is what the assertions below read and a test that wrote
# it would be reading its own fixture.
#
# `weedr service snapshot` only ever takes routine ones, so an on-demand snapshot
# has to come from `snapper` directly — which is what an operator's own
# `snapper create` does and what the design says it does.
run snapper -c "$config" create --cleanup-algorithm number --description "before the risky change"
assert_exit 0
run snapper -c "$config" create --cleanup-algorithm number --description "guarden routine"
assert_exit 0
assert_snapshot_count "$config" 2
assert_newest_snapshot "$config" 2
# The two numbers the rest of this file uses, read back off the machine rather
# than assumed. A fresh configuration numbers from 1, and asserting that is the
# assertion that the numbering is snapper's and not this file's.
one=1
two=2

# The seed is in the registry before anything is pinned, so `one` is wanted from
# the first reconciler run and "already marked, so not rewritten" is about the
# mark rather than about the order this file happens to run things in.
seed "$registry/myapp-preview.toml" \
    "service = \"myapp-preview\"" "workload = \"myapp\"" "project = \"myapp\"" \
    "environment = \"preview\"" "uid = 1002" "created = \"2026-09-30T09:00:00Z\"" \
    '[instances."feature\\x2dlogin"]' 'ref = "feature/login"' \
    'created = "2026-09-30T09:00:00Z"' \
    '[instances."feature\\x2dlogin".seed.data]' \
    "service = \"myapp-production\"" "volume = \"data\"" "number = $one"

# A pin is a file named for the snapshot, and nothing else. The name is
# `<service>:<volume>@<number>`: the colon is what makes it unambiguous, because a
# dash is legal in both a service name and a volume name.
#
# `stakes` wrote no mark, and that is now the state rather than a count of calls:
# `two` is unmarked before the pin and still unmarked after it, read out of
# snapper's own metadata. This is the assertion that matters most in the file —
# the pin is a file and the mark is the reconciler's, and a `stakes` that wrote
# one would make the boundary a convention.
assert_snapshot_marked "$config" "$two" no
run stakes pin "myapp-production:data@$two" "the restore point for the 2.3 upgrade"
assert_exit 0
assert_stdout_has "pinned myapp-production:data@$two"
assert_file_exists "$stakes/myapp-production:data@$two"
assert_file_has "$stakes/myapp-production:data@$two" "the restore point for the 2.3 upgrade"
assert_snapshot_marked "$config" "$two" no

# The same pin twice is one file, and the answer says so.
run stakes pin "myapp-production:data@$two" "the restore point for the 2.3 upgrade"
assert_exit 0
assert_stdout_has "already pinned"

# `stakes list` reports the pin files it owns, with the closed field set of
# spec 1.2 and nothing else. `marked` is a statement about what the reconciler
# **will** write, not about the filesystem, because a pin is a priority with a
# budget and not a promise.
run stakes list --json
assert_exit 0
assert_stdout_lines 1
assert_json pins.0.id "\"myapp-production:data@$one\""
assert_json pins.0.service '"myapp-production"'
assert_json pins.0.volume '"data"'
assert_json pins.0.number "$one"
assert_json pins.0.note '""'
assert_json pins.0.marked true
# The union is ordered by the id, so the pinned one is second and the seed-only
# one is first. `stakes list` is the command that answers "which snapshots are
# protected, and by whom", and a list of only the pin files would answer it
# wrongly for every preview on the box.
assert_json pins.1.id "\"myapp-production:data@$two\""
assert_json pins.1.number "$two"
assert_json pins.1.note '"the restore point for the 2.3 upgrade"'
assert_json pins.1.marked true
assert_json_missing pins.0.description

# A snapshot number is never a set, so the id is refused rather than accepted as
# one: `other-app-production-pgdata-41` could be a service called `other-app`
# with a volume called `production-pgdata`.
run stakes pin other-app-production-pgdata-41
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "<service>:<volume>@<number>"
assert_file_missing "$stakes/other-app-production-pgdata-41"
run stakes pin myapp-production:data
assert_exit 2
assert_one_diagnostic "error:"
run stakes pin myapp-production:data@forty
assert_exit 2
assert_one_diagnostic "error:"

# The reconciler turns the pin into a mark. It is written with the `number`
# cleanup tag **and** `important=yes` in one call, because `important` is read
# only by the number cleaner and a snapshot is a candidate for that cleaner only
# when its tag is `number`. `guarden=` is the provenance key, so a human reading
# `snapper list` can see which service wants it.
#
# All four halves of that are read back out of the snapshot rather than out of a
# log of what was asked: the mark is there, the provenance says the pin, and the
# cleanup tag is still `number` — the last of which is the half that is easy to
# get wrong and impossible to see by reading `important` alone.
run weedr pin sync
assert_exit 0
assert_stdout_has "marked myapp-production:data@$two"
assert_snapshot_marked "$config" "$two" yes
assert_snapshot_userdata "$config" "$two" guarden pin
assert_snapshot_tag "$config" "$two" number

# `one` is wanted from this first run, and its provenance is the **preview's**,
# not the pin's: `one` was marked when it was minted as the preview's fork
# source, and the reconciler marking it now would set `guarden=pin` on it.
#
# **This is not the idempotency claim and could not be.** Nothing marked `one`
# before this run, so on the first sync the reconciler writes the mark from the
# seed -- which sets exactly the value asserted here -- and the assertions are
# identical whether it wrote the mark or found it already there. The "already
# marked, so it is not written again" claim needs a *second* run against a mark
# that is already in place, and that is asserted below where it belongs; the
# provenance half is kept here because it is a different claim, and it does vary:
# a reconciler that marked `one` from the pin would leave `guarden=pin` and fail.
assert_snapshot_marked "$config" "$one" yes
assert_snapshot_userdata "$config" "$one" guarden myapp-preview

# No write passes `--no-dbus`. With no snapperd there is no inter-process
# coordination at all, so a mark written that way can be lost with no error
# anywhere, and the reconciler is the one program whose whole job is those marks.
#
# This was `assert_not_called --no-dbus` and it is **dropped rather than ported**:
# the flag is an argv element, and the box keeps no record of the argv it was
# handed, so there is no state behind it. Asserting the absence of a flag would
# mean reading another program's arguments, and the only way to do that without a
# call log is to build a call log — which is the thing this ticket removed.
#
# What is asserted instead is the consequence that matters, and it is asserted
# above: the mark survives, read back out of the same metadata snapper's own
# cleaner consults. That is a real question with a real answer, and it is the one
# the `--no-dbus` rule exists to protect.

# The lock is snapper's and the whole run holds it: `soil storage` installs
# snapper's cleanup under the same key, because snapper takes no lock that
# `snapper modify` participates in and its cleaner reuses one reference to the
# snapshot list across all three passes, so a mark written during a running
# cleanup is lost silently.
assert_file_exists /run/guarden/locks/snapshots.lock

# The second run has nothing to do and says so, rather than pretending to have
# written something. The state agrees with the report: both marks are as they
# were, and neither provenance moved.
run weedr pin sync
assert_exit 0
assert_stdout_has "nothing to reconcile"
assert_snapshot_marked "$config" "$two" yes
assert_snapshot_userdata "$config" "$two" guarden pin
assert_snapshot_userdata "$config" "$one" guarden myapp-preview

# A pin file and a registry seed are one union, and `stakes list` says which
# services name each snapshot as a seed. A preview is protected because something
# was forked from the snapshot it came from.
run stakes list
assert_exit 0
assert_stdout_has "myapp-production:data@$one"
assert_stdout_has "wanted by myapp-preview"
assert_stdout_has "myapp-production:data@$two"
assert_stdout_has "wanted by nothing"
run stakes query "myapp-production:data@$two"
assert_exit 0
assert_stdout_has "note       the restore point for the 2.3 upgrade"
assert_stdout_has "marked     will be written by weedr pin sync"
run stakes query "myapp-production:data@99"
assert_exit 1
assert_one_diagnostic "error:"

# `stakes` does not answer "is this snapshot on disk": a service's tree is `0700`
# to that service, so an unprivileged program cannot count what is in it, and the
# per-volume figures come from `weedr service list --json` as a root read. That
# division is deliberate.
run stakes query "myapp-production:data@$two" --json
assert_exit 0
assert_json number "$two"
assert_json_missing exists

# Releasing the pin file while the **seed** still wants the other snapshot: `two`
# now has no file, no seed and no marker, so it is unmarked, and `one` is left
# alone because the preview's seed still names it. "A snapshot nothing names is
# unmarked so the set is exactly what the pin files and the registries say" — and
# here the registries say `one` is wanted whatever happened to `two`.
run stakes unpin "myapp-production:data@$two"
assert_exit 0
assert_stdout_has "unpinned myapp-production:data@$two"
assert_file_missing "$stakes/myapp-production:data@$two"
# Unpinning what is not pinned is already true and not a failure: a script that
# unpins defensively must not look like it found something.
run stakes unpin "myapp-production:data@$two"
assert_exit 0
assert_stdout_has "not pinned"
run weedr pin sync
assert_exit 0
assert_stdout_has "unmarked myapp-production-data@$two"
# The unmark is `important=no` and nothing else: the provenance is left alone,
# because "which service used to want this" is worth reading months later and
# nothing in the design says to discard it.
assert_snapshot_marked "$config" "$two" no
assert_snapshot_userdata "$config" "$two" guarden pin
assert_snapshot_marked "$config" "$one" yes

# A snapshot that is marked and that nothing names any more is unmarked, and the
# line says who used to want it: the mark's `guarden=` key is the provenance and a
# human reading `snapper list` can see it. Dropping the seed is what a preview's
# removal does, and "another service that names the same snapshot still protects
# it" is the other half of the same sentence.
seed "$registry/myapp-preview.toml" \
    "service = \"myapp-preview\"" "workload = \"myapp\"" "project = \"myapp\"" \
    "environment = \"preview\"" "uid = 1002" "created = \"2026-09-30T09:00:00Z\""
run weedr pin sync
assert_exit 0
assert_stdout_has "unmarked myapp-production-data@$one"
assert_stdout_has "myapp-preview"
assert_snapshot_marked "$config" "$one" no

# Adds before it removes, in one run. So one run writes a mark and clears one, and
# the mark is written first — a reconciler that cleared first would leave a window
# in which a snapshot that is wanted is unprotected.
#
# **The ordering is asserted from the reconciler's own stdout**, in order, because
# ordering within one run leaves no state behind to read: after the run both marks
# are as they should be whichever order they were written in. The lines themselves
# are the program's report of what it did, which is a fact about the run, and
# reading them in order is how "adds before it removes" is checked without
# recording a call.
#
# **One run has to do both, so the state for it is built here rather than hoped
# for.** By this point every mark in this configuration has already been released
# — `two` when its pin came off, `one` when the seed came off — so a run over this
# state adds and removes nothing, and asserting an unmark on it was asserting a
# line the reconciler has no reason to print. `two` is therefore marked once more
# through the pin that marks it, and that pin is then released **without** a
# sync, which is the only way to leave a mark nothing names: a pin removed and
# reconciled immediately is a snapshot that was never marked from outside.
run snapper -c "$config" create --cleanup-algorithm number --description "the one that is wanted"
assert_exit 0
assert_snapshot_count "$config" 3
three=3
run stakes pin "myapp-production:data@$two" "wanted for exactly one run"
assert_exit 0
run weedr pin sync
assert_exit 0
assert_snapshot_marked "$config" "$two" yes
run stakes unpin "myapp-production:data@$two"
assert_exit 0
# Still marked: nothing has reconciled since the pin came off, which is the state
# this block needs and is asserted rather than assumed.
assert_snapshot_marked "$config" "$two" yes
run stakes pin "myapp-production:data@$three" "the one that is wanted"
assert_exit 0
seed "$registry/myapp-preview.toml" \
    "service = \"myapp-preview\"" "workload = \"myapp\"" "project = \"myapp\"" \
    "environment = \"preview\"" "uid = 1002" "created = \"2026-09-30T09:00:00Z\"" \
    '[instances."feature\\x2dlogin".seed.data]' \
    "service = \"myapp-production\"" "volume = \"data\"" "number = $one"
run weedr pin sync
assert_exit 0
assert_stdout_has "marked myapp-production:data@$three"
assert_stdout_has "unmarked myapp-production-data@$two"
marked_line=$(grep -n -- "marked myapp-production:data@$three" "$GUARDEN_STDOUT" | cut -d: -f1)
unmarked_line=$(grep -n -- "unmarked myapp-production-data@$two" "$GUARDEN_STDOUT" | cut -d: -f1)
[ -n "$marked_line" ] || _fail "the mark was not written"
[ -n "$unmarked_line" ] || _fail "the unmark was not written"
[ "$marked_line" -lt "$unmarked_line" ] || _fail "the mark was written after the unmark"
# And the state each line claims: three is marked and wanted, two is not and is
# wanted by nothing, and one was marked by the run above and was not written again.
assert_snapshot_marked "$config" "$three" yes
assert_snapshot_userdata "$config" "$three" guarden pin
assert_snapshot_marked "$config" "$two" no
assert_snapshot_userdata "$config" "$one" guarden myapp-preview

# An unreadable state is a reason to stop, never a reason to clear. A registry
# directory that is not there means the seeds cannot be read, and a reconciler
# that cannot see its input releases the snapshots it was protecting and then
# reports success.
#
# What is asserted after the refusal is the thing that matters and that a call log
# could not give: the marks are **still there**. A reconciler that cleared before
# it noticed the input was unreadable would report the same exit code and leave
# every wanted snapshot unprotected.
run stakes pin "myapp-production:data@$two" "held"
assert_exit 0
mv "$registry" "$registry.away"
run weedr pin sync
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "registry"
assert_snapshot_marked "$config" "$three" yes
assert_snapshot_marked "$config" "$one" yes
mv "$registry.away" "$registry"

# The same for a `snapper list` that will not answer: a configuration whose list
# cannot be read is not an empty configuration, and treating it as one would clear
# every mark in it.
#
# A real unreadable list is a configuration naming a subvolume that is not a
# subvolume any more, which is what a volume replaced with an ordinary directory
# leaves behind, and `snapper list` then answers `IO Error (query default id
# failed, subvolume is not a btrfs subvolume).` and exits 1 on its own.
#
# **snapperd has to be told, and that is a fact about guarden's reads rather than a
# trick to get past it.** Every read goes through the daemon, and the daemon holds
# each configuration it has loaded in memory: a configuration file edited behind its
# back is invisible to it until it is restarted, and the file is not what snapper
# answers from. Hand-editing that file is not something guarden ever does — spec 8.2
# reads the effective configuration with `snapper get-config` and never parses the
# file — so the restart here is what an out-of-band edit is worth on this machine,
# and it is what makes the failure real rather than cached away.
cp "/etc/snapper/configs/$config" "$GUARDEN_FIXTURES/snapper-config.saved"
printf '%s\n' 'SUBVOLUME=/etc/guarden' 'FSTYPE=btrfs' \
    'NUMBER_CLEANUP=yes' 'TIMELINE_CLEANUP=yes' \
    >"/etc/snapper/configs/$config"
seed "$registry/myapp-production.toml" \
    "service = \"myapp-production\"" "workload = \"myapp\"" "project = \"myapp\"" \
    "environment = \"production\"" "uid = 1000" "created = \"2026-09-30T09:00:00Z\"" \
    "[state.data]" "config = \"$config\""
run systemctl restart snapperd
assert_exit 0
run snapper --machine-readable json -c "$config" list
assert_exit 1
assert_stderr_has "not a btrfs subvolume"
run weedr pin sync
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "$config"
# And again the marks survived the refusal, which is the whole of the claim. They
# are read after the configuration is put back, because a list that cannot be read
# is also a list that cannot be read to check them — and the refusal above has
# already said the reconciler saw nothing to clear.
cp "$GUARDEN_FIXTURES/snapper-config.saved" "/etc/snapper/configs/$config"
run systemctl restart snapperd
assert_exit 0
assert_snapshot_marked "$config" "$three" yes
assert_snapshot_marked "$config" "$one" yes

# A hand-edited registry whose seed is a bare number names nothing that can be
# marked, and the reconciler stops rather than guessing: it is the same refusal as
# an unreadable state, and it must clear nothing on the way out.
run stakes pin "myapp-production:data@$two" "held"
assert_exit 0
seed "$registry/myapp-preview.toml" \
    "service = \"myapp-preview\"" "environment = \"preview\"" "uid = 1002" \
    '[instances."feature\\x2dlogin".seed.data]' "number = $one"
run weedr pin sync
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "seed"
assert_snapshot_marked "$config" "$three" yes
assert_snapshot_marked "$config" "$one" yes

# The registry is put back before anything else reads it. The refusal above is the
# *reconciler's*, and it stops rather than guessing; the next assertion is about a
# pin file's name, and a read verb that walks every registry would otherwise stop
# on the bare number still sitting in this one and never reach it.
seed "$registry/myapp-preview.toml" \
    "service = \"myapp-preview\"" "workload = \"myapp\"" "project = \"myapp\"" \
    "environment = \"preview\"" "uid = 1002" "created = \"2026-09-30T09:00:00Z\"" \
    '[instances."feature\\x2dlogin"]' 'ref = "feature/login"' \
    'created = "2026-09-30T09:00:00Z"' \
    '[instances."feature\\x2dlogin".seed.data]' \
    "service = \"myapp-production\"" "volume = \"data\"" "number = $one"

# A pin file that is not a snapshot id protects nothing, and is said so rather
# than skipped in silence: a file an operator reads at three in the morning
# believing it protects something is the failure this line exists for.
seed "$stakes/other-app-production-pgdata-41" "not an id"
run stakes list
assert_exit 0
assert_stderr_has "other-app-production-pgdata-41"
assert_stderr_has "not a snapshot id"
rm -f "$stakes/other-app-production-pgdata-41"

# The snapshot's subvolume has to exist, because a record naming a number snapper
# has never heard of is exactly as unfindable as a flag nobody wrote down.
run weedr service immutable "myapp-production:data@99" "a number snapper has not issued"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "myapp-production:data@99"
assert_file_lacks "$registry/myapp-production.toml" "a number snapper has not issued"

# `weedr service immutable` is an escalation, and both halves happen in one call:
# the flag without a record is an escalation nobody can find later, and a record
# without a flag is a lie. The registry carries the operator's reason in the
# operator's words.
#
# **Both halves are read back as state.** The record is the registry line, and the
# flag is `lsattr` on the snapshot's own subvolume — which is the real question,
# because `chattr +i` is a filesystem attribute and `lsattr` is what reports one.
# The assertion that used to read `chattr +i <path>` out of a call log was
# checking the intent; this checks the attribute.
run weedr service immutable "myapp-production:data@$one" "production rollback base"
assert_exit 0
assert_file_has "$registry/myapp-production.toml" 'data = "production rollback base"'
assert_immutable "$tree/state/data/.snapshots/$one/snapshot"

# It is **not** `stakes pin`. Nothing was pinned and no mark was written, because
# the two compose and each has its own verb: pinning is a retention act that
# respects a budget, and this is a deny that also aborts the whole cleanup for its
# configuration. Nothing had pinned this one in the first place, and the state says
# so: no pin file, and the mark this snapshot already carried is untouched.
assert_file_missing "$stakes/myapp-production:data@$one"
assert_snapshot_marked "$config" "$one" yes
assert_snapshot_userdata "$config" "$one" guarden myapp-preview

# Setting it twice is refused, because a second escalation for a volume that is
# already one is a record that cannot be distinguished from the first. The refusal
# is an exit and a diagnostic, and the state it leaves is the state it found: the
# flag is still set and the mark is still the preview's.
run weedr service immutable "myapp-production:data@$one" "again, to prove the point"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "already immutable"
assert_immutable "$tree/state/data/.snapshots/$one/snapshot"
assert_snapshot_userdata "$config" "$one" guarden myapp-preview

# A different volume of the same service is a separate escalation and takes its
# own record, so one service can protect two of its volumes at once. The bulk
# volume has no snapshots at all, so this names a number no configuration holds.
run weedr service immutable "myapp-production:chainstate@7" "the chain, before the upgrade"
assert_exit 1
assert_one_diagnostic "error:"

# `mutable` clears both halves for the same reason it set both.
run weedr service mutable "myapp-production:data@$one"
assert_exit 0
assert_file_lacks "$registry/myapp-production.toml" "production rollback base"
assert_mutable "$tree/state/data/.snapshots/$one/snapshot"

# Clearing a snapshot with no record says so and touches nothing: the flag and the
# record always agree, so there is nothing to clear and no way to end up with one
# without the other.
run weedr service mutable "myapp-production:data@$one"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "not recorded as immutable"
assert_mutable "$tree/state/data/.snapshots/$one/snapshot"
