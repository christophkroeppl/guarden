#!/usr/bin/env bash
# Creating a service: the registry record, the system user, the home, the
# quadlet directory, and the subvolumes and snapper configurations for the
# declared volumes (ticket 30, spec 4 and 5.3).
#
# The staged tree is never named by an argument. `ingest` takes
# `poke <project>@<sha>` and guarden resolves the pair to the staging directory
# itself; `add` takes a service name and copies that service's own manifest and
# unit source out of its home.
#
# The prefix is `/` and every claim below is a question to the machine: a passwd
# entry, a delegated subid range, a btrfs subvolume, a snapper configuration.
# Nothing here reads a record of what guarden was about to ask the host to do.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). Every claim below is a question to the machine: a
# passwd entry from the real user database, a real `loginctl` on the real
# systemd, a real btrfs subvolume, a real snapper configuration. Under the fakes
# the `useradd` wrote a line with uid 0 and the `loginctl` knew only
# `enable-linger`, so the assertions here were being asked of the stand-ins
# rather than of the box. `.venv/bin` is kept first because it is the checkout's
# interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
# The real path, not a relocated one: stage_config writes where guarden reads,
# and /etc/guarden is absent on a host where `soil install` has never run.
stage_config guarden.toml
stage_poke myapp 9f2c1ab

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "myapp-production"
assert_stderr_empty

# The identity. The block the system delegated is the fact, not the flag that
# was supposed to produce it. Which free block the host offers is the host's
# arithmetic, so the start is read back rather than pinned and the width is the
# one the design allocates (users.SUBUID_SIZE). The tree is `0700` to the service
# user with no carve-out for the home — the `0700` is what every per-consumer
# credential and every uid-matched firewall rule rests on (ADR-0003).
assert_passwd myapp-production
service_uid=$(getent passwd myapp-production | cut -d: -f3)
subuid_start=$(awk -F: '$1 == "myapp-production" { print $2 }' /etc/subuid)
subgid_start=$(awk -F: '$1 == "myapp-production" { print $2 }' /etc/subgid)
assert_subid /etc/subuid myapp-production "$subuid_start" 65536
assert_subid /etc/subgid myapp-production "$subgid_start" 65536
assert_linger myapp-production
assert_file_exists /var/lib/guarden/services/myapp-production
assert_mode /var/lib/guarden/services/myapp-production 700
assert_owner /var/lib/guarden/services/myapp-production "myapp-production:$(id -gn myapp-production)"
assert_mode /var/lib/guarden/services/myapp-production/home 700
assert_file_exists /var/lib/guarden/services/myapp-production/home/.config/containers/systemd

# No config subvolume is ever created, for any track, including a gitops-created
# production service.
assert_file_missing /var/lib/guarden/services/myapp-production/state/config
assert_file_missing /var/lib/guarden/services/myapp-production/bulk/config

# The volumes. `state` is a subvolume with a snapper configuration of its own,
# named <service>-<volume>, and it carries the canonical set; `bulk` is a subvolume
# with none, and it is a subvolume on every path rather than a plain directory.
assert_subvolume /var/lib/guarden/services/myapp-production/state/data
assert_subvolume /var/lib/guarden/services/myapp-production/bulk/chainstate
assert_snapper_config myapp-production-data EMPTY_PRE_POST_CLEANUP no
assert_snapper_config myapp-production-data NUMBER_MIN_AGE 3600
assert_snapper_config myapp-production-data NUMBER_CLEANUP yes
assert_snapper_config myapp-production-data TIMELINE_CLEANUP yes
assert_snapper_config myapp-production-data TIMELINE_CREATE no
assert_snapper_config myapp-production-data TIMELINE_LIMIT_HOURLY 0
assert_snapper_config myapp-production-data TIMELINE_LIMIT_DAILY 0-7
assert_snapper_config myapp-production-data TIMELINE_LIMIT_WEEKLY 0-4
assert_snapper_config myapp-production-data TIMELINE_LIMIT_MONTHLY 0-6
assert_snapper_config myapp-production-data TIMELINE_LIMIT_QUARTERLY 0-2
assert_snapper_config myapp-production-data TIMELINE_LIMIT_YEARLY 0
assert_snapper_config myapp-production-data NUMBER_LIMIT 2-10
assert_snapper_config myapp-production-data NUMBER_LIMIT_IMPORTANT 8-12
assert_snapper_config myapp-production-data FREE_LIMIT 0.1
assert_no_snapper_config myapp-production-chainstate
assert_file_has /var/lib/guarden/registry/myapp-production.toml 'config = "myapp-production-data"'

# The registry record: identity, the two project fields, and the volumes. The
# registry is 0640 root:guarden, and it describes the topology of the box — so
# the uid it records is the one the host's user database holds, not a number a
# test picked.
registry=/var/lib/guarden/registry/myapp-production.toml
assert_mode "$registry" 640
assert_file_has "$registry" 'service = "myapp-production"'
assert_file_has "$registry" 'workload = "myapp"'
assert_file_has "$registry" 'project = "myapp"'
assert_file_has "$registry" 'environment = "production"'
assert_file_has "$registry" 'source = "gitops"'
assert_file_has "$registry" 'kinds = ["db"]'
assert_file_has "$registry" "uid = $service_uid"

# The admin units path is reconciled for the service's own uid, and nothing
# inside it is read or written.
assert_file_exists "/etc/containers/systemd/users/$service_uid"

# A gated service is a poke's whole reason for existing: it is created, it
# builds, and it does not start until an operator has planted its credentials.
# The gate verdict belongs to `weedr service gate`, so the table is absent, and
# absent is not `ready`.
assert_file_lacks "$registry" "[gate]"
assert_file_has "$registry" "[state.data]"

# The manifest is a service's own: a `furrow deploy` with no `--from` renders
# from the copy in the home, because a poke's staging tree is removed once the
# deploy returns.
assert_file_has /var/lib/guarden/services/myapp-production/home/.guarden/service.yml "project: myapp"

# The second ingest of a converged service exits 0, says it converged, and leaves
# the host alone — with the staging tree gone, which is the case a poke leaves
# behind. What it did not do is the claim: the poke's tree is not resurrected to
# satisfy the read, and both subvolumes are still the ones the first ingest made.
rm -rf /var/lib/guarden/staging/myapp
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
assert_stderr_empty
assert_file_missing /var/lib/guarden/staging/myapp/9f2c1ab
assert_subvolume /var/lib/guarden/services/myapp-production/state/data
assert_subvolume /var/lib/guarden/services/myapp-production/bulk/chainstate
assert_file_has "$registry" 'service = "myapp-production"'

# The hash covers every render input, so an edited source re-deploys instead of
# converging. These two re-deploys came from t250-verb-split.sh: they are about
# creating and converging a service, which is this suite's subject, and they are
# two rebuild cycles that suite did not need for its own (the verb surface).
# The poke is staged again because the converged ingest above deliberately took
# the staging tree away.
#
# The edit is an edit of the real compose file rather than a replacement:
# a stub that mounts nothing would earn the render's own refusal about the
# manifest, not a different hash.
stage_poke myapp 9f2c1ab
sed -i 's|nginx:1.27|nginx:1.28|' /var/lib/guarden/staging/myapp/9f2c1ab/compose.yaml
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_lacks "converged"
assert_stdout_has "myapp-production"

# The Containerfile is a build input too (spec 6.3): seeded, it hashes
# differently and the second re-deploy is not converged either.
seed /var/lib/guarden/staging/myapp/9f2c1ab/Containerfile "FROM docker.io/library/nginx:1.28"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stdout_lacks "converged"
assert_stdout_has "myapp-production"
