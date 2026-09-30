#!/usr/bin/env bash
# The service user: one per service, a subid range the system allocates, and the
# read-back that is the whole point of the rule (ADR-0003, ticket 30 item 6).
#
# `useradd --add-subuids-for-system` succeeding is the tool's word for it;
# `/etc/subuid` holding the range is the fact. An unallocated range is a container
# that starts and then cannot map its own root, which is a long way from the
# cause, so the read-back is a step and not a courtesy.

. "$(dirname "$0")/lib.sh"

# The read-back fails loudly, naming the service. A fixture marker stands in for
# a system where the allocation silently did not happen — and the service is not
# repaired, because the spec's remedy is the operator's and a mutator that
# allocated a second range on the retry would hide the first failure.
guarden_prefix "$GUARDEN_FIXTURES/host-unallocated"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
touch "$GUARDEN_FIXTURES/subid-unallocated"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "myapp-production has no subid range"
assert_stderr_has "could not map its own root"
assert_file_lacks "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-production.toml" "myapp-production"

# Without the marker, the range is there and the service is created.
rm -f "$GUARDEN_FIXTURES/subid-unallocated"
guarden_prefix "$GUARDEN_FIXTURES/host-allocated"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has "$GUARDEN_PREFIX/etc/subuid" "myapp-production:100000:65536"
assert_file_has "$GUARDEN_PREFIX/etc/subgid" "myapp-production:100000:65536"

# A second service gets a **different** range, because one hardcoded range for
# everyone is not a fallback — it maps every container's root to the same host
# uid, and the firewall's uid matching stops meaning what it says.
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_file_has "$GUARDEN_PREFIX/etc/subuid" "myapp-staging:165536:65536"
assert_file_has "$GUARDEN_PREFIX/etc/subgid" "myapp-staging:165536:65536"
assert_file_has "$GUARDEN_PREFIX/etc/passwd" "myapp-production:x:1000:1000"
assert_file_has "$GUARDEN_PREFIX/etc/passwd" "myapp-staging:x:1001:1001"
assert_called "loginctl enable-linger myapp-staging"

# A range two users hold is refused, not silently accepted: this is the check
# that makes "a distinct range per service user" a fact rather than an intention.
guarden_prefix "$GUARDEN_FIXTURES/host3"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
printf '%s\n' 'myapp-production:100000:65536' >"$GUARDEN_PREFIX/etc/subuid"
printf '%s\n' 'myapp-production:100000:65536' >"$GUARDEN_PREFIX/etc/subgid"
printf '%s\n' 'myapp-production:x:1000:1000' >>"$GUARDEN_PREFIX/etc/passwd"
touch "$GUARDEN_FIXTURES/subid-collision"
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 1
assert_stderr_has "share the subid range 100000:65536"
assert_stderr_has "maps its root to the same host uid"

# The fallback path, for shadow-utils older than 4.11: the user is created plain
# and the range written afterwards, and only there does the call log carry the
# range, which is why the read-back matters on both paths.
guarden_prefix "$GUARDEN_FIXTURES/host4"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
touch "$GUARDEN_FIXTURES/shadow-utils-old"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_called "usermod --add-subuids 100000-165535 myapp-production"
assert_called "usermod --add-subgids 100000-165535 myapp-production"
assert_file_has "$GUARDEN_PREFIX/etc/subuid" "myapp-production:100000:65536"

# A group that does not exist is reported and skipped, and no group is ever
# created: the groups a service needs belong to the system and the distribution,
# and a mutator that could create one could hand out a group nobody meant to grant.
guarden_prefix "$GUARDEN_FIXTURES/host5"
stage_config guarden.toml
stage_poke myapp 9f2c1ab
mkdir -p "$GUARDEN_PREFIX/etc/guarden/services/myapp-production"
printf '%s\n' '[groups]' 'add = ["video", "nosuchgroup"]' >"$GUARDEN_PREFIX/etc/guarden/services/myapp-production/overrides.toml"
printf '%s\n' 'video:x:44:' >>"$GUARDEN_PREFIX/etc/group"
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
assert_stderr_has "supplementary group 'nosuchgroup' is not on the host"
assert_called "usermod --append --groups video myapp-production"
assert_not_called "nosuchgroup"
assert_file_lacks "$GUARDEN_PREFIX/etc/group" "nosuchgroup"

# No login shell, and a home inside the service's own tree.
assert_called "--shell /usr/sbin/nologin"
assert_file_has "$GUARDEN_PREFIX/etc/passwd" ":/usr/sbin/nologin"
assert_file_has "$GUARDEN_PREFIX/etc/passwd" "/var/lib/guarden/services/myapp-production/home"
