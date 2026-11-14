#!/usr/bin/env bash
# The service user: one per service, a subid range the system allocates, and the
# read-back that is the whole point of the rule (ADR-0003, ticket 30 item 6).
#
# The range in `/etc/subuid` is the fact, and a call to useradd is not: which free
# block the host hands out is the system's own arithmetic, so what is asserted is
# that a block was delegated, how wide it is, and that two services do not hold
# the same one. A range nobody allocated is a container that starts and then
# cannot map its own root, which is a long way from the cause.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). The whole of this file is the read-back: a range the
# real `useradd` put in the real `/etc/subuid`, a membership the real `usermod`
# set, a linger the real `loginctl` holds. The fake `useradd` numbered every user
# from a counter and the fake `loginctl` knew only `enable-linger`, so under it
# the read-back proved only that the stand-ins agreed with each other.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
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
assert_passwd myapp-production
assert_linger myapp-production
production_subuid=$(awk -F: '$1 == "myapp-production" { print $2 }' /etc/subuid)
production_subgid=$(awk -F: '$1 == "myapp-production" { print $2 }' /etc/subgid)
assert_subid /etc/subuid myapp-production "$production_subuid" 65536
assert_subid /etc/subgid myapp-production "$production_subgid" 65536

# A second service gets a **different** range, because one hardcoded range for
# everyone is not a fallback — it maps every container's root to the same host
# uid, and the moment two services share a directory the ownership is ambiguous
# and the firewall's uid matching stops meaning what it says. This one is created
# with the grant surface an admin wrote, so the two claims are asked of one run:
# `video` is on the host and `nosuchgroup` is nothing's.
seed /etc/guarden/services/myapp-staging/overrides.toml \
    '[groups]' 'add = ["video", "nosuchgroup"]'
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_passwd myapp-staging
assert_linger myapp-staging
staging_subuid=$(awk -F: '$1 == "myapp-staging" { print $2 }' /etc/subuid)
assert_subid /etc/subuid myapp-staging "$staging_subuid" 65536
[ "$staging_subuid" != "$production_subuid" ] \
    || _fail "myapp-staging was delegated myapp-production's range $staging_subuid"

# A group that does not exist is reported and skipped, and no group is ever
# created: the groups a service needs belong to the system and the distribution,
# and a mutator that could create one could hand out a group nobody meant to grant.
assert_group video
assert_supplementary_group myapp-staging video
assert_stderr_has "the supplementary group 'nosuchgroup' is not on the host"
assert_no_supplementary_group myapp-staging nosuchgroup
assert_no_group nosuchgroup

# A range two users hold is refused, not silently accepted: this is the check
# that makes "a distinct range per service user" a fact rather than an intention.
#
# The colliding line is staged rather than provoked, because a real useradd
# allocates around a block that is taken and will not collide on its own: the
# duplicated line is what a hand edit or a migration leaves behind, and it is the
# case the check exists for. The registry entry goes with it — a second ingest of
# an unchanged service converges without reading the range back, so the read-back
# is only reachable while the service is un-recorded.
impostor_range=$(awk -F: '$1 == "myapp-staging" { print $2 ":" $3 }' /etc/subuid)
say /etc/subuid "impostor:$impostor_range"
rm -f /var/lib/guarden/registry/myapp-staging.toml
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 1
assert_stderr_has "share the subid range $impostor_range"
assert_stderr_has "maps its root to the same host uid"
assert_file_missing /var/lib/guarden/registry/myapp-staging.toml

# No login shell, and a home inside the service's own tree.
assert_passwd_field myapp-production 7 /usr/sbin/nologin
assert_passwd_field myapp-production 6 /var/lib/guarden/services/myapp-production/home
