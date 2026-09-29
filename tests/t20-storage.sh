#!/usr/bin/env bash
# soil storage: the layout it verifies, the directories it creates, the
# configurations it converges, and the two it must not touch.
#
# The skip rule is the part worth pinning (spec 8.1). A configuration's name is
# opaque, nothing parses it, and there are exactly three cases: a service's, the
# host's own two, and everything else — which is skipped with a warning naming
# it, because a rule that skipped whatever it did not recognise would silently
# drop a configuration the operator owns.

. "$(dirname "$0")/lib.sh"
scratch_host

# The distribution ships its snapper cleanup timer enabled, and it overlaps the
# reconciler for the same reason guarden replaces it: on its own schedule it is
# the same overlap by another name.
mkdir -p "$GUARDEN_FIXTURES/systemd"
say "$GUARDEN_FIXTURES/systemd/snapper-cleanup.timer.enabled" "enabled"
say "$GUARDEN_FIXTURES/systemd/snapper-cleanup.service.enabled" "enabled"

# A host that has not been converted has no @ and no @var, and soil verifies
# that rather than converting it.
seed "$GUARDEN_FIXTURES/btrfs-subvolumes" "ID 256 gen 42 top level 5 path @"
run soil storage --check
assert_exit 1
assert_stderr_has "drift: btrfs with the @ and @var subvolumes"

# A converted host does, and /boot stays on ext4 so the next boot finds a
# kernel.
seed "$GUARDEN_FIXTURES/btrfs-subvolumes" \
    "ID 256 gen 42 top level 5 path @" \
    "ID 257 gen 42 top level 5 path @var"
run soil storage --apply
assert_exit 0
assert_called "snapper -c root create-config -f btrfs -p /"
assert_called "snapper -c home create-config -f btrfs -p /home"

# Every mode is one spec 2.1 gives, and the two that were wrong there are the
# ones a converge has to get right: `queue/` and `stakes/` are 0770 because
# `furrow` enqueues and `stakes` creates pin files, and 0750's group bits are
# r-x.
assert_called "install -d -m 0750 -o root -g guarden $GUARDEN_HOST/var/lib/guarden"
assert_called "install -d -m 0711 -o root -g root $GUARDEN_HOST/var/lib/guarden/services"
assert_called "install -d -m 0770 -o root -g guarden $GUARDEN_HOST/var/lib/guarden/queue"
assert_called "install -d -m 0770 -o root -g guarden $GUARDEN_HOST/var/lib/guarden/stakes"
assert_called "install -d -m 0755 -o root -g root $GUARDEN_HOST/var/lib/guarden/staging"
assert_called "install -d -m 0750 -o root -g guarden $GUARDEN_HOST/var/lib/guarden/soil"

# /boot sharing the filesystem that becomes btrfs is how a conversion leaves a
# box with no kernel, so it is checked and never silently assumed.
seed "$GUARDEN_FIXTURES/boot-fstype" "btrfs"
run soil storage --check
assert_exit 1
assert_stderr_has "drift: /boot is on ext4"
seed "$GUARDEN_FIXTURES/boot-fstype" "ext4"

# The package hook snapshots root before every transaction, and the conversion's
# state and reboot marker have somewhere to live.
assert_file_has "$(host etc/apt/apt.conf.d/80guarden-snapper)" "DPkg::Pre-Invoke"
assert_file_has "$(host etc/apt/apt.conf.d/80guarden-snapper)" "snapper -c root create"
assert_file_exists "$(host var/lib/guarden/soil)"

# The distribution's packaged cleanup timer is disabled and guarden's own oneshot
# replaces it, because snapper takes no lock that `snapper modify` participates
# in and its cleaner reuses one reference to the snapshot list across all three
# passes: a mark written during a running cleanup is lost silently.
assert_called "systemctl disable --now snapper-cleanup.timer"
assert_called "systemctl disable --now snapper-cleanup.service"
assert_file_has "$(host etc/systemd/system/guarden-snapper-cleanup.service)" \
    "/run/guarden/locks/snapshots.lock"
assert_file_has "$(host etc/systemd/system/guarden-snapper-cleanup.service)" \
    "snapper -c root cleanup number"
assert_file_has "$(host etc/systemd/system/guarden-snapper-cleanup.service)" \
    "snapper -c home cleanup space"

# The canonical set reaches the host's own two configurations, and only the four
# fixed keys: no track owns them, so there is no track to read a default from
# and their ladder is left as the distribution shipped it.
assert_file_has "$GUARDEN_FIXTURES/snapper/root.conf" "EMPTY_PRE_POST_CLEANUP=no"
assert_file_has "$GUARDEN_FIXTURES/snapper/root.conf" "NUMBER_MIN_AGE=3600"
assert_file_has "$GUARDEN_FIXTURES/snapper/root.conf" "NUMBER_LIMIT_IMPORTANT=8-12"
assert_file_has "$GUARDEN_FIXTURES/snapper/root.conf" "TIMELINE_LIMIT_DAILY=0-7"
assert_file_has "$GUARDEN_FIXTURES/snapper/root.conf" "FREE_LIMIT=0.1"
assert_called "snapper -c root modify -f"

# A converged host checks clean, and a second apply changes nothing.
run soil storage --check
assert_exit 0
rm -f "$GUARDEN_CALLS"
run soil storage --apply
assert_exit 0
assert_not_called "modify -f"
assert_not_called "create-config"
assert_not_called "disable"
assert_not_called "install -d"

# A service's configuration gets the full ladder, and the values come from the
# track the *registry* names -- never from parsing the configuration's name,
# which is opaque because both a service name and a volume name may hold a `-`.
seed "$GUARDEN_HOST/var/lib/guarden/registry/myapp-production.toml" \
    'name = "myapp-production"' 'environment = "production"'
seed "$GUARDEN_HOST/etc/snapper/configs/myapp-production-pgdata" "ignored"
seed "$GUARDEN_HOST/etc/guarden/guarden.toml" \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"'
run soil storage --apply
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.conf" \
    "TIMELINE_LIMIT_DAILY=0-7"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.conf" "FREE_LIMIT=0.1"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-production-pgdata.conf" \
    "TIMELINE_LIMIT_WEEKLY=0-4"

# A staging volume keeps no daily snapshots and still keeps twelve in the buckets
# that aged out of it. That is a surprising default, so it is asserted rather
# than left to be discovered.
seed "$GUARDEN_HOST/var/lib/guarden/registry/myapp-staging.toml" \
    'name = "myapp-staging"' 'environment = "staging"'
seed "$GUARDEN_HOST/etc/snapper/configs/myapp-staging-data" "ignored"
run soil storage --apply
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-staging-data.conf" "TIMELINE_LIMIT_DAILY=0-0"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-staging-data.conf" "TIMELINE_LIMIT_MONTHLY=0-6"

# A service's own overrides win over the track, and the ladder's other buckets
# are per-volume for the same reason.
seed "$GUARDEN_HOST/etc/guarden/services/myapp-staging/overrides.toml" \
    '[retention]' 'keep_last = 3' 'free_limit = 0.08' 'quarterly = 1'
run soil storage --apply
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-staging-data.conf" "TIMELINE_LIMIT_DAILY=0-3"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-staging-data.conf" "FREE_LIMIT=0.08"
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-staging-data.conf" "TIMELINE_LIMIT_QUARTERLY=0-1"

# The longest registry entry wins, so `myapp` and `myapp-preview` both being
# services is not ambiguous for `myapp-preview-data`, and an instance's
# configuration -- `<service>-<escaped-ref>-<volume>` -- is matched the same way.
seed "$GUARDEN_HOST/etc/guarden/guarden.toml" \
    '[[environments]]' 'name = "production"' 'keep_last = 7' 'free_limit = 0.10' \
    'kind = "slot"' \
    '[[environments]]' 'name = "preview"' 'keep_last = 1' 'free_limit = 0.20' \
    'kind = "instance"'
seed "$GUARDEN_HOST/var/lib/guarden/registry/myapp-preview.toml" \
    'name = "myapp-preview"' 'environment = "preview"'
seed "$GUARDEN_HOST/etc/snapper/configs/myapp-preview-feature\\x2dx-data" "ignored"
run soil storage --apply
assert_file_has "$GUARDEN_FIXTURES/snapper/myapp-preview-feature\\x2dx-data.conf" \
    "TIMELINE_LIMIT_DAILY=0-1"
assert_file_lacks "$GUARDEN_FIXTURES/snapper/myapp-preview-feature\\x2dx-data.conf" \
    "TIMELINE_LIMIT_DAILY=0-7"

# Anything else is skipped with a warning naming it, and left byte for byte
# alone: a configuration guarden did not create belongs to the operator.
seed "$GUARDEN_FIXTURES/snapper/operator-owned.conf" "EMPTY_PRE_POST_CLEANUP=yes"
seed "$GUARDEN_HOST/etc/snapper/configs/operator-owned" "ignored"
run soil storage --apply
assert_stderr_has "warning: the snapper configuration operator-owned is not guarden's"
assert_file_has "$GUARDEN_FIXTURES/snapper/operator-owned.conf" "EMPTY_PRE_POST_CLEANUP=yes"
assert_not_called "operator-owned modify"

# `soil storage` creates no service volume and never recreates a service's
# configuration: the mutator creates those, and a subvolume here would be one
# more way for a service's data to appear from nowhere.
assert_not_called "btrfs subvolume create"
assert_called "btrfs subvolume list /"
