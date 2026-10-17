#!/usr/bin/env bash
# soil storage: the directories it creates, the configurations it converges, and
# the two it must not touch.
#
# The skip rule is the part worth pinning (spec 8.1). A configuration's name is
# opaque, nothing parses it, and there are exactly three cases: a service's, the
# host's own, and everything else — which is skipped with a warning naming it,
# because a rule that skipped whatever it did not recognise would silently drop a
# configuration the operator owns.
#
# The host's own layout — the `@` and `@var` subvolumes and `/boot` on ext4 — is
# the harness's to build (tests/lxc.sh) and not this file's to stand in for. A
# stand-in for `btrfs subvolume list` proves only that the phase asked the
# question, not that the box has the answer, so those items are asserted by the
# machine's own state instead: a converge that ran on this layout and a `--check`
# that finds nothing left to do can only both be true of a host that has it.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). This file's whole subject is what the machine holds: the
# fake `install` creates a directory and applies the mode but *cannot* set the
# owner, so a converge run under it leaves `/var/lib/guarden` root:root, and the
# mode is already right, which is the combination this suite exists to catch.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/


stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# **The machine's unconverged state is staged here, not inherited.** The golden
# is built by converging `soil storage` — the conversion is what makes its root
# btrfs — so a cut from it arrives with every storage item already holding, and
# an assertion that "a fresh machine has storage drift" would be asserting the
# golden's build history rather than anything this file does. Removing one
# storage-owned file and loosening one storage-owned mode makes the drift this
# run's own, exactly the way `t20-packages.sh` removes the packages its apply
# puts back; without them the mode assertions below would be pre-satisfied at
# cut on a converged golden.
rm -f /etc/apt/apt.conf.d/80guarden-snapper
chmod 0755 /var/lib/guarden/queue
run soil storage --check
assert_exit 1
assert_stderr_has "drift: the package hook snapshots root before every transaction"

run soil storage --apply
assert_exit 0
assert_file_exists /etc/apt/apt.conf.d/80guarden-snapper

# Every mode is one spec 2.1 gives, and the two that were wrong there are the
# ones a converge has to get right: `queue/` and `stakes/` are 0770 because
# `furrow` enqueues and `stakes` creates pin files, and 0750's group bits are
# r-x. The owner is asserted too, which the fast harness could not do and the
# machine can: `root:guarden` on the registry is what makes it readable by the
# unprivileged programs, and `root:root` on `services/` is what keeps a listing
# from leaking a workload.
assert_mode /var/lib/guarden 0751
assert_owner /var/lib/guarden root:guarden
assert_mode /var/lib/guarden/services 0711
assert_owner /var/lib/guarden/services root:root
assert_mode /var/lib/guarden/shared 0751
assert_mode /var/lib/guarden/queue 0770
assert_owner /var/lib/guarden/queue root:guarden
assert_mode /var/lib/guarden/stakes 0770
assert_owner /var/lib/guarden/stakes root:guarden
assert_mode /var/lib/guarden/staging 0755
assert_owner /var/lib/guarden/staging root:root
assert_mode /var/lib/guarden/soil 0750
assert_owner /var/lib/guarden/soil root:guarden

# The package hook snapshots root before every transaction, and the conversion's
# state and reboot marker have somewhere to live.
assert_file_has /etc/apt/apt.conf.d/80guarden-snapper "DPkg::Pre-Invoke"
assert_file_has /etc/apt/apt.conf.d/80guarden-snapper "snapper -c root create"
assert_file_exists /var/lib/guarden/soil

# The pre-mount hook must recover the journal **before** btrfs-convert: a forced
# stop (`lxc stop --force`, a provider's reset button, a power cut) leaves
# needs_recovery set, btrfs-convert refuses with "source filesystem requires
# recovery, run e2fsck first", and systemd-fsck runs AFTER this hook — so without
# the fsck the conversion never succeeds and the state machine retries forever
# on a host whose root stays ext4. Order is the claim: fsck first, convert
# second.
hook="$GUARDEN_ROOT/src/guarden/templates/convert/dracut/99guarden-convert/guarden-convert-hook.sh"
assert_file_has "$hook" "e2fsck -y"
fsck_line=$(grep -n 'e2fsck -y' "$hook" | head -n1 | cut -d: -f1)
convert_line=$(grep -n 'btrfs-convert --uuid' "$hook" | head -n1 | cut -d: -f1)
if [ -z "$fsck_line" ] || [ -z "$convert_line" ] || [ "$fsck_line" -ge "$convert_line" ]; then
    _fail "the conversion hook must fsck the journal before btrfs-convert"
fi
assert_file_has \
    "$GUARDEN_ROOT/src/guarden/templates/convert/dracut/99guarden-convert/module-setup.sh" \
    "e2fsck"

# The distribution's packaged cleanup timer is disabled and guarden's own oneshot
# replaces it, because snapper takes no lock that `snapper modify` participates in
# and its cleaner reuses one reference to the snapshot list across all three
# passes: a mark written during a running cleanup is lost silently.
#
# snapper is asserted installed first, because "the distribution's cleaner is not
# enabled" is otherwise true of a box that has no distribution's cleaner at all.
assert_dpkg snapper
assert_not_enabled snapper-cleanup.timer
assert_not_enabled snapper-cleanup.service
assert_file_exists /etc/systemd/system/guarden-snapper-cleanup.timer
assert_file_has /etc/systemd/system/guarden-snapper-cleanup.service \
    "/run/guarden/locks/snapshots.lock"
assert_file_has /etc/systemd/system/guarden-snapper-cleanup.service \
    "snapper -c root cleanup number"
assert_file_has /etc/systemd/system/guarden-snapper-cleanup.service \
    "snapper -c root cleanup space"

# The canonical set reaches the host's own configuration. It reaches everything in
# spec 8.1's table that is not read out of a track, because "every configuration it
# can see" is what the table says and `NUMBER_LIMIT_IMPORTANT`'s floor is one of
# them; what stays as the distribution shipped it is the **two track-derived**
# values, since no row owns `root` and there is nothing to read `keep_last` from.
#
# The daily bucket is the evidence for that absence: it is read out of the template
# `snapper create-config` builds a configuration from rather than written here. A
# literal would be pinning one version of snapper's default to a test that is about
# something else, and the test would then fail on a host that is correct — and a
# converge that derived a daily bucket here would read `keep_last` from no row at all
# and write `0-0`.
assert_snapper_config root EMPTY_PRE_POST_CLEANUP no
assert_snapper_config root NUMBER_MIN_AGE 3600
assert_snapper_config root NUMBER_CLEANUP yes
assert_snapper_config root TIMELINE_CLEANUP yes
assert_snapper_config root TIMELINE_CREATE no
assert_snapper_config root NUMBER_LIMIT_IMPORTANT 8-12
assert_snapper_config root NUMBER_LIMIT 2-10
assert_snapper_config root TIMELINE_LIMIT_HOURLY 0
assert_snapper_config root TIMELINE_LIMIT_WEEKLY 0-4
assert_snapper_config root TIMELINE_LIMIT_MONTHLY 0-6
assert_snapper_config root TIMELINE_LIMIT_QUARTERLY 0-2
assert_snapper_config root TIMELINE_LIMIT_YEARLY 0
# The template snapper builds every new configuration from, asserted to be there
# before it is read: a missing template would otherwise leave the expected value
# empty and fail the next line with a comparison rather than a cause.
assert_file_exists /usr/share/snapper/config-templates/default
distribution_ladder=$(awk -F'"' '/^TIMELINE_LIMIT_DAILY=/ { print $2 }' \
    /usr/share/snapper/config-templates/default)
assert_snapper_config root TIMELINE_LIMIT_DAILY "$distribution_ladder"

# The four fixed keys are converged, not merely created with: the value the
# distribution ships is put back to something else and a converge has to put it
# right, which is the claim "the canonical set reaches the host's own
# configuration" as distinct from "the phase created a configuration".
run snapper -c root set-config EMPTY_PRE_POST_CLEANUP=yes
assert_exit 0
run soil storage --apply
assert_exit 0
assert_snapper_config root EMPTY_PRE_POST_CLEANUP no

# Two of the ladder keys are pinned by perturbation rather than by value,
# because snapper's own template already ships guarden's value for them: a
# value assertion would then prove nothing about the phase, only about the
# distribution. Written back to something else, a converge has to put them
# right, which is the claim the value pins cannot make.
run snapper -c root set-config TIMELINE_LIMIT_QUARTERLY=0-0
assert_exit 0
assert_snapper_config root TIMELINE_LIMIT_QUARTERLY 0-0
run snapper -c root set-config TIMELINE_LIMIT_YEARLY=1
assert_exit 0
assert_snapper_config root TIMELINE_LIMIT_YEARLY 1
run soil storage --apply
assert_exit 0
assert_snapper_config root TIMELINE_LIMIT_QUARTERLY 0-2
assert_snapper_config root TIMELINE_LIMIT_YEARLY 0

# A converged host checks clean, and a second apply changes nothing: the same
# answer to the same question is the whole of "idempotent", and it is a stronger
# claim than a run that made no calls.
run soil storage --check
assert_exit 0
run soil storage --apply
assert_exit 0
run soil storage --check
assert_exit 0

# seed_snapper_config <name> [daily]: a configuration as snapper holds one,
# carrying values a converge has to put right.
#
# **A configuration is made by `snapper create-config` and by nothing else.** A
# file written into `/etc/snapper/configs` by hand is not a configuration: snapper
# answers `Unknown config.` for one, and `snapper list-configs` does not list it —
# before a restart of snapperd and after one, which is how the retired stand-in
# could be handed a file and called it a configuration. `create-config` is what
# makes the pair that is a configuration, the subvolume and the `.snapshots`
# subvolume inside it.
#
# So the subvolume here is a real btrfs subvolume on the suite's own scratch, the
# configuration is snapper's own, and the values that disagree with what a converge
# would write go in through `snapper set-config` — the same writer `soil storage`
# uses, so nothing here fabricates a file snapper would have to believe.
#
# Ownership is decided by the **registry** naming the configuration for a state
# volume (spec 8.1's enumeration is `snapper list-configs`, and the owner is the
# service whose registry entry names it), so where the seeded subvolume sits makes
# no difference to who owns the configuration and nothing about it is a service's
# data: these are the phase's own scratch volumes, not under `/services`.
seed_snapper_config() {
    mkdir -p /var/lib/guarden/tests
    run btrfs subvolume create "/var/lib/guarden/tests/seeded-$1"
    assert_exit 0
    run snapper --config "$1" create-config "/var/lib/guarden/tests/seeded-$1"
    assert_exit 0
    run snapper --config "$1" set-config EMPTY_PRE_POST_CLEANUP=yes NUMBER_MIN_AGE=0 \
        "TIMELINE_LIMIT_DAILY=${2:-0-99}" TIMELINE_LIMIT_WEEKLY=0-99 \
        TIMELINE_LIMIT_MONTHLY=0-99 TIMELINE_LIMIT_QUARTERLY=0-99 FREE_LIMIT=0.99
    assert_exit 0
}

# A service's configuration gets the full ladder, and the values come from the
# track the *registry* names -- never from parsing the configuration's name,
# which is opaque because both a service name and a volume name may hold a `-`.
seed /var/lib/guarden/registry/myapp-production.toml \
    'name = "myapp-production"' 'environment = "production"'
seed_snapper_config myapp-production-pgdata
seed /etc/guarden/guarden.toml \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"'
run soil storage --apply
assert_exit 0
assert_snapper_config myapp-production-pgdata EMPTY_PRE_POST_CLEANUP no
assert_snapper_config myapp-production-pgdata NUMBER_MIN_AGE 3600
assert_snapper_config myapp-production-pgdata TIMELINE_LIMIT_DAILY 0-7
assert_snapper_config myapp-production-pgdata FREE_LIMIT 0.1
assert_snapper_config myapp-production-pgdata TIMELINE_LIMIT_WEEKLY 0-4

# A staging volume keeps no daily snapshots and still keeps twelve in the buckets
# that aged out of it. That is a surprising default, so it is asserted rather
# than left to be discovered.
seed /var/lib/guarden/registry/myapp-staging.toml \
    'name = "myapp-staging"' 'environment = "staging"'
# The staging row with its floor as the shipped template spells it: a TOML
# float, and the one state every staging and preview service on a real host is
# in. The value is read through the strict reader the create path uses, and the
# pin below proves the converge writes the create path's spelling.
seed /etc/guarden/guarden.toml \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"' \
    '[[environments]]' 'name = "staging"' 'keep_last = 0' 'free_limit = 0.20' \
    'kind = "slot"'
seed_snapper_config myapp-staging-data
run soil storage --apply
assert_snapper_config myapp-staging-data TIMELINE_LIMIT_DAILY 0-0
assert_snapper_config myapp-staging-data TIMELINE_LIMIT_MONTHLY 0-6
assert_snapper_config myapp-staging-data FREE_LIMIT 0.2

# The seeded row proves the reader; the writer is proved by perturbation, the
# shape the root ladder uses above. `percentage` and `str` differ only on an
# integral float, so no seeded value can tell the two normalisers apart -- the
# value snapper holds is written back to what the old bug produced and a
# converge has to repair it, which is the only thing that runs the writer.
run snapper -c myapp-staging-data set-config FREE_LIMIT=0.20
assert_exit 0
assert_snapper_config myapp-staging-data FREE_LIMIT 0.20
run soil storage --apply
assert_exit 0
assert_snapper_config myapp-staging-data FREE_LIMIT 0.2

# A service's own overrides win over the track, and the ladder's other buckets
# are per-volume for the same reason.
seed /etc/guarden/services/myapp-staging/overrides.toml \
    '[retention]' 'keep_last = 3' 'free_limit = 0.08' 'quarterly = 1'
run soil storage --apply
assert_snapper_config myapp-staging-data TIMELINE_LIMIT_DAILY 0-3
assert_snapper_config myapp-staging-data FREE_LIMIT 0.08
assert_snapper_config myapp-staging-data TIMELINE_LIMIT_QUARTERLY 0-1

# An integral floor is the one value the two normalisers spell differently:
# `percentage(2.0)` is `2`, `str(2.0)` is `2.0`. No track would ship it -- it
# is a free-space floor of 200% -- and that is exactly why it is here: it is
# the only value that can tell the normaliser from a plain string conversion,
# and a mutation from one to the other must not survive the suite.
seed /etc/guarden/services/myapp-staging/overrides.toml \
    '[retention]' 'free_limit = 2.0'
run soil storage --apply
assert_snapper_config myapp-staging-data FREE_LIMIT 2

# The longest registry entry wins, so `myapp-production` and `myapp-preview` both
# being services is not ambiguous for `myapp-preview-data`, and an instance's
# configuration -- `<service>-<escaped-ref>-<volume>` -- is matched the same way.
seed /etc/guarden/guarden.toml \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"' \
    '[[environments]]' 'name = "preview"' 'keep_last = 1' 'free_limit = 0.20' \
    'kind = "instance"'
seed /var/lib/guarden/registry/myapp-preview.toml \
    'name = "myapp-preview"' 'environment = "preview"'
seed_snapper_config 'myapp-preview-feature\x2dx-data' 0-7
run soil storage --apply
assert_snapper_config 'myapp-preview-feature\x2dx-data' TIMELINE_LIMIT_DAILY 0-1
assert_snapper_config 'myapp-preview-feature\x2dx-data' FREE_LIMIT 0.2

# A registry entry naming a track the table no longer holds is the no-row
# branch of the converge, and it has to spell the create path's default:
# `0.10` through the same normaliser, `0.1`. The staging row is gone from the
# table above; this service keeps its own registry entry and no overrides.
seed /var/lib/guarden/registry/myapp-norow.toml \
    'name = "myapp-norow"' 'environment = "staging"'
seed_snapper_config myapp-norow-data
run soil storage --apply
assert_snapper_config myapp-norow-data FREE_LIMIT 0.1

# Anything else is skipped with a warning naming it, and left exactly as it was: a
# configuration guarden did not create belongs to the operator. The value is the
# assertion, read through `snapper get-config` — the read spec 8.2 names, and never
# by parsing snapper's own file — and not the file's existence: a converge that
# rewrote the key and then warned would satisfy anything weaker.
seed_snapper_config operator-owned
run soil storage --apply
assert_stderr_has "warning: the snapper configuration operator-owned is not guarden's"
assert_snapper_config operator-owned EMPTY_PRE_POST_CLEANUP yes
assert_snapper_config operator-owned NUMBER_MIN_AGE 0

# The same rule on the other reader. `soil storage` reads the row through the
# same strict function the create path uses, so a quoted floor is refused with
# the track named and exit 1 rather than converged -- TOML types are distinct
# and a string is not a number. The trailing assertions read volumes and
# configurations rather than the table, so the row staying unreadable is
# fine.
seed /etc/guarden/guarden.toml \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"' \
    '[[environments]]' 'name = "staging"' 'keep_last = 0' 'free_limit = "0.20"' \
    'kind = "slot"'
run soil storage --check
assert_exit 1
assert_stderr_has "free_limit is not a number"

# `soil storage` creates no service volume and never recreates a service's
# configuration: the mutator creates those, and a subvolume here would be one
# more way for a service's data to appear from nowhere. The registries above name
# two services whose volumes do not exist, and this is what says the phase did
# not make them.
assert_no_subvolume /var/lib/guarden/services/myapp-production/state/pgdata
assert_no_subvolume /var/lib/guarden/services/myapp-staging/state/data
assert_no_snapper_config myapp-production-data