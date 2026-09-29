#!/usr/bin/env bash
# Creating a service: the registry record, the system user, the home, the
# quadlet directory, and the subvolumes and snapper configurations for the
# declared volumes (ticket 30, spec 4 and 5.3).
#
# The staged tree is never named by an argument. `ingest` takes
# `poke <project>@<sha>` and guarden resolves the pair to the staging directory
# itself; `add` takes a service name and copies that service's own manifest and
# unit source out of its home.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden.toml
stage_poke myapp 9f2c1ab

run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"
assert_stderr_empty

# The identity. `useradd --system --add-subuids-for-system` is the range the
# system allocates, and the tree is `0700` to the service user with no carve-out
# for the home — the `0700` is what every per-consumer credential and every
# uid-matched firewall rule rests on (ADR-0003).
assert_called "useradd --system --no-create-home --home-dir"
assert_called "--shell /usr/sbin/nologin"
assert_called "--add-subuids-for-system myapp-production"
assert_called "loginctl enable-linger myapp-production"
assert_file_has "$GUARDEN_PREFIX/etc/subuid" "myapp-production:100000:65536"
assert_file_has "$GUARDEN_PREFIX/etc/subgid" "myapp-production:100000:65536"
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production"
assert_mode "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production" 700
assert_mode "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/home" 700
assert_file_exists "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/home/.config/containers/systemd"

# No config subvolume is ever created, for any track, including a gitops-created
# production service.
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/state/config"
assert_file_missing "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/bulk/config"

# The volumes. `state` is a subvolume with a snapper configuration of its own,
# named <service>-<volume>; `bulk` is a subvolume with none, and it is a subvolume
# on every path rather than a plain directory.
assert_called "btrfs subvolume create $GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/state/data"
assert_called "btrfs subvolume create $GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/bulk/chainstate"
assert_called "snapper --config myapp-production-data create-config"
assert_called "set-config EMPTY_PRE_POST_CLEANUP=no"
assert_called "set-config NUMBER_MIN_AGE=3600"
assert_called "set-config NUMBER_CLEANUP=yes"
assert_called "set-config TIMELINE_CLEANUP=yes"
assert_called "set-config TIMELINE_LIMIT_DAILY=0-7"
assert_called "set-config TIMELINE_LIMIT_WEEKLY=0-4"
assert_called "set-config TIMELINE_LIMIT_MONTHLY=0-6"
assert_called "set-config TIMELINE_LIMIT_QUARTERLY=0-2"
assert_called "set-config NUMBER_LIMIT=2-10"
assert_called "set-config NUMBER_LIMIT_IMPORTANT=8-12"
assert_called "set-config FREE_LIMIT=0.1"
assert_not_called "snapper --config myapp-production-chainstate create-config"
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" "config = \"myapp-production-data\""

# The registry record: identity, the two project fields, and the volumes. The
# registry is 0640 root:guarden, and it describes the topology of the box.
assert_mode "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 640
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'service = "myapp-production"'
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'workload = "myapp"'
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'project = "myapp"'
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'environment = "production"'
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'source = "gitops"'
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" 'kinds = ["db"]'

# The admin units path is reconciled, and nothing inside it is read or written.
assert_file_exists "$GUARDEN_PREFIX/etc/containers/systemd/users/1000"

# A gated service is a poke's whole reason for existing: it is created, it
# builds, and it does not start until an operator has planted its credentials.
# The gate verdict belongs to `weedr service gate`, so the table is absent, and
# absent is not `ready`.
assert_file_lacks "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" "[gate]"
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" "[state.data]"

# The manifest is a service's own: a `furrow deploy` with no `--from` renders
# from the copy in the home, because a poke's staging tree is removed once the
# deploy returns.
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/services/myapp-production/home/.guarden/service.yml" "project: myapp"

# The second ingest of a converged service exits 0, says it converged, and makes
# no call at all — with the staging tree gone, which is the case a poke leaves
# behind.
rm -rf "$GUARDEN_PREFIX/var/lib/guarden/staging/myapp"
assert_makes_no_calls weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
assert_stderr_empty
