#!/usr/bin/env bash
# ticket 302, with ticket 296 behind it: a service created from a template must
# carry the host stub resolver's accepts **before anything of it is started**,
# and the start itself is the step no suite ran for such a service either.
#
# `weedr service create` copies the template's quadlet file and saves the record,
# and until ticket 296 it triggered no firewall render at all — while every
# render emits two owner-matched `127.0.0.53:53` accepts for every uid in the
# registry, above the global `daddr 127.0.0.0/8 jump DROP` (spec 7.6). So the
# uid of a template-created service had no DNS accept, and its first `podman pull`
# on `weedr service start` met the deny.
#
# This suite runs the harder half of that question in the order the review's
# findings name: the set `50-services.conf` **already exists** when the
# creation happens — a service with a publication rendered it on a host whose
# firewall unit is not installed yet — so the creation's uid has something to be
# missing from, and a later `soil firewall --apply` would load a set without it
# (finding 4: the render predicate asked only whether the unit was installed
# while other verbs write the file unconditionally). Then the host converges and
# a second creation exercises 296's own case — unit installed — landing its
# accept in the running ruleset without another apply. A removal re-renders what
# a creation rendered (finding 6, spec 5.3), and the reply accepts spec 7.6
# carries (finding 8) are asserted in the file and in the loaded set.
#
# Real host, real uid, real ferm: `GUARDEN_PREFIX=/`, as `t20-firewall` and
# `t50-route` do. What is asserted is state — the file the mutator writes and
# the ruleset ferm loaded — and never a record of what a program said it was
# about to do.
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
# `soil firewall --apply` comes LATER here, after the first creation: it is the
# phase that installs `guarden-firewall.service`, and finding 4's subject is a
# creation on a host that holds a rendered set but has not installed the unit.

services=/etc/guarden/firewall/50-services.conf

# The runbook's own install of the example set (docs/sysadmin.md): the set does
# not ship, and a template-created service needs one to be created at all.
install -d -m 0755 /usr/lib/guarden/templates/services
cp -r "$GUARDEN_ROOT/examples/services/vaultwarden" /usr/lib/guarden/templates/services/

stage_poke routed 9f2c1ab

# --- the host's starting state: a set written, and nothing to load it ----------
# A service with a publication reaches the mutator's render whatever the host
# has installed (spec 7.6), and this one writes `50-services.conf` while
# `guarden-firewall.service` is absent — `load_set` says so, and that line is
# the state the creation below joins.
run weedr service ingest routed-preview/feature/x --from poke routed@9f2c1ab
assert_exit 0
assert_stderr_has "nothing has loaded it into the running ruleset"
assert_file_exists "$services"

# --- a creation whose uid must join that existing set --------------------------
# The template ships no manifest, so this service brings only its uid. Before
# the fix `_filter_set` asked only `firewall.unit_installed()` — false here —
# and returned without rendering, so the set the apply below would load had no
# accepts for this uid and its first `podman pull` met the deny.
run weedr service create vwstart --env staging --template vaultwarden
assert_exit 0
assert_stdout_has "created vwstart-staging"

uid=$(getent passwd vwstart-staging | cut -d: -f3)
[ -n "$uid" ] || _fail "vwstart-staging has no uid, so its accept set cannot be named"

assert_file_has "$services" "mod owner uid-owner $uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$services" "mod owner uid-owner $uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"

# The render joined a set that exists on a host whose unit is not installed,
# so it also says that nothing has loaded it — the fact the next phase changes.
assert_stderr_has "nothing has loaded it into the running ruleset"

# ...and above the deny, which is the whole of the ordering spec 7.6 states:
# accepts first, then one drop. An accept under it renders and reaches nothing.
accept_line=$(grep -nFm1 "uid-owner $uid daddr 127.0.0.53 proto udp" "$services" | cut -d: -f1)
deny_line=$(grep -nF "daddr 127.0.0.0/8 jump DROP;" "$services" | tail -n 1 | cut -d: -f1)
if [ -z "$accept_line" ] || [ -z "$deny_line" ] || [ "$accept_line" -ge "$deny_line" ]; then
    _fail "the stub-resolver accept for uid $uid (line ${accept_line:-absent}) is not above the loopback deny (line ${deny_line:-absent})"
fi

# --- the reply accepts spec 7.6 carries (finding 8) -----------------------------
# The reply to a uid's query is sent by systemd-resolved, not by the uid, so
# these two are the accepts with no owner match: source-address matched on
# `127.0.0.53 sport 53`, both protocols, above the same deny (spec 7.6).
assert_file_has "$services" "saddr 127.0.0.53 proto udp sport 53 jump ACCEPT;"
assert_file_has "$services" "saddr 127.0.0.53 proto tcp sport 53 jump ACCEPT;"

# --- the host converges: the unit installs and loads the set it found ----------
run soil firewall --apply
assert_not_rejected

# The file is what guarden intends; the ruleset is what the box enforces.
# `load_set` inside `firewall.install` raises if ferm did not load it, so this
# is the running half of the same claim.
run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "--uid-owner $uid"
assert_stdout_has "127.0.0.53"

# --- ticket 296's own case: a creation while the unit is installed -------------
# This creation renders and reaches `load_set` with the unit installed, so its
# accept appears in the RUNNING ruleset below with no apply in between — the
# seam 296 named, asserted on the running set rather than on the file alone.
run weedr service create vwstart2 --env staging --template vaultwarden
assert_exit 0
assert_stdout_has "created vwstart2-staging"
assert_stderr_empty

uid2=$(getent passwd vwstart2-staging | cut -d: -f3)
[ -n "$uid2" ] || _fail "vwstart2-staging has no uid, so its accept set cannot be named"
assert_file_has "$services" "mod owner uid-owner $uid2 daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"

run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "--uid-owner $uid2"

# --- the start itself, on the service that had neither publication nor edge ----
# The template ships no manifest, so the gate has nothing to withhold and the
# unit this start reaches is the template's own copy in the service's quadlet
# directory.
run weedr service start vwstart-staging
assert_exit 0
assert_stdout_has "started vwstart-staging"

# --- a removal re-renders the set (finding 6, spec 5.3) -------------------------
# Its `overrides.toml` goes with it, every grant it held is released, and the
# firewall is re-rendered (§7.7): the uid is out of the registry, so its
# accepts and the forwarded port must be out of both the file and the running
# ruleset — before the fix `_remove` re-synced only the dashboard and a
# recycled uid inherited this one's accepts.
run weedr service remove vwstart-staging
assert_exit 0
assert_file_lacks "$services" "uid-owner $uid daddr"
run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_lacks "--uid-owner $uid "

rm -rf /usr/lib/guarden/templates/services/vaultwarden
