#!/usr/bin/env bash
# ticket 302, with ticket 296 behind it: a service created from a template must
# carry the host stub resolver's accepts **before anything of it is started**,
# and the start itself is the step no suite ran for such a service either.
#
# `weedr service create` copies the template's quadlet file and saves the record,
# and until ticket 296 it triggered no firewall render at all — while every
# render emits two owner-matched `127.0.0.53:53` accepts for every uid in the
# registry, above the global `daddr 127.0.0.0/8 jump DROP` (spec 7.6). So the
# uid of a template-created service had no accept, and its first `podman pull`
# on `weedr service start` met the deny.
#
# Real host, real uid, real ferm: `GUARDEN_PREFIX=/`, as `t20-firewall` and
# `t50-route` do. The accept is asserted in the file the mutator writes **and**
# in the ruleset ferm loaded, and in the order spec 7.6 states: accepts first,
# one drop last.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
# The firewall phase is the one that installs `guarden-firewall.service`,
# and it is what loads what the mutator renders: without it the render
# below writes `50-services.conf` and warns that nothing loaded it.
run soil firewall --apply
assert_not_rejected

services=/etc/guarden/firewall/50-services.conf

# The runbook's own install of the example set (docs/sysadmin.md): the set does
# not ship, and a template-created service needs one to be created at all.
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r "$GUARDEN_ROOT/examples/services/vaultwarden" /usr/lib/guarden/templates/services/

# `soil`'s own firewall phase writes 10-framework and 20-ingress and leaves
# 50-services to the mutator (t20-firewall asserts as much), so nothing has
# rendered a uid into it yet.
run weedr service create vwstart --env staging --template vaultwarden
assert_exit 0
assert_stdout_has "created vwstart-staging"
assert_stderr_empty

uid=$(getent passwd vwstart-staging | cut -d: -f3)
[ -n "$uid" ] || _fail "vwstart-staging has no uid, so its accept set cannot be named"

# --- ticket 296: the new uid's stub-resolver accepts, before any start ----------
assert_file_exists "$services"
assert_file_has "$services" "mod owner uid-owner $uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$services" "mod owner uid-owner $uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"

# ...and above the deny, which is the whole of the ordering spec 7.6 states:
# accepts first, then one drop. An accept under it renders and reaches nothing.
accept_line=$(grep -nFm1 "uid-owner $uid daddr 127.0.0.53 proto udp" "$services" | cut -d: -f1)
deny_line=$(grep -nF "daddr 127.0.0.0/8 jump DROP;" "$services" | tail -n 1 | cut -d: -f1)
if [ -z "$accept_line" ] || [ -z "$deny_line" ] || [ "$accept_line" -ge "$deny_line" ]; then
    _fail "the stub-resolver accept for uid $uid (line ${accept_line:-absent}) is not above the loopback deny (line ${deny_line:-absent})"
fi

# The file is what guarden intends; the ruleset is what the box enforces.
# `load_set` inside `firewall.install` raises if ferm did not load it, so this
# is the running half of the same claim.
run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "--uid-owner $uid"
assert_stdout_has "127.0.0.53"

# --- the start itself, on the service that had neither publication nor edge -----
# The template ships no manifest, so the gate has nothing to withhold and the
# unit this start reaches is the template's own copy in the service's quadlet
# directory.
run weedr service start vwstart-staging
assert_exit 0
assert_stdout_has "started vwstart-staging"

rm -rf /usr/lib/guarden/templates/services/vaultwarden
