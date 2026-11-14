#!/usr/bin/env bash
# A service-requested firewall rule, end to end at the CLI seam
# (ticket 180, spec 7.7, ADR-0013), and the one accept guarden renders without
# anybody asking: the host's stub resolver (ticket 260, spec 7.6, ADR-0015).
#
# The subject is the four load-bearing rules and the order they hold in. A
# request installs nothing; the grant is a root verb on no sudoers rule; the
# position is guarden's, so a grant lands above the default deny and the deny
# stays the last line of the chain; and the render is a set, so two services
# asking for one line get one rule carrying both names. Each of those is
# asserted here as a fact about the rendered file rather than about a code
# path, because that is where a claim like "the deny is still last" is true.
#
# **The stub resolver's accept is the opposite case and is asserted the same
# way.** It is not a request and not a grant: guarden renders it from the host
# it is running on, so no repository, no `overrides.toml` and no verb can add or
# remove one. What makes it safe to render unconditionally is that it names ONE
# address and ONE port, owner-matched to service uids — and that is asserted, in
# both directions: the accept is above the deny and in force, and a service uid
# still cannot reach anything else on loopback. The negative is the one that
# matters here. Every other rule in this file is somebody's grant; this one is
# the widest thing guarden renders unasked, and a render that widened it to
# `127.0.0.0/8`, to another port, or to another uid would pass every positive
# assertion above and quietly turn the default deny into decoration.
#
# What this file does **not** assert is the honest limit of a grant: that a
# granted rule matching `-o lo` and accepting really does reopen loopback for
# that match. That is a property of the rendered text and is stated in
# SECURITY.md 2.5, docs/sysadmin.md and ADR-0013; re-testing it here would be
# testing iptables.
#
# machine: fresh
# A real host. The mutator chowns every file it writes to `root:guarden`, so
# `weedr firewall open` needs the real gid.

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
overrides=/etc/guarden/services
conf=/etc/guarden/firewall/50-services.conf
ingress=/etc/guarden/firewall/20-ingress-nat.conf

cleanup() {
    rm -rf "$registry/tunnel-staging.toml" "$registry/relay-staging.toml" \
        "$registry/shelf-staging.toml" \
        "$overrides/tunnel-staging" "$overrides/relay-staging" "$conf" "$ingress"
}
trap cleanup EXIT
cleanup

# The `guarden` user too, not just its group: `weedr service ingest` renders a
# service's units AS that user, so the ingest below cannot proceed without it.
id -u guarden >/dev/null 2>&1 ||
    useradd --system --no-create-home --gid guarden --shell /usr/sbin/nologin guarden
# `soil install` is this suite's precondition and not its subject: ingest renders
# a service's units with `loom` out of /usr/lib/guarden/bin, and only `install`
# puts it there.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
assert_file_exists /usr/lib/guarden/bin/loom

# `host.admin_user` names the uid the whole OUTPUT accept set admits, so the
# firewall refuses to render without it. The fixture names `operator`, so the
# account is here.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
stage_config guarden-measured.toml
stage_poke gated 9f2c1ab

# `weedr firewall list` on a host with no request at all: the empty inventory,
# and it is exit 0 rather than a failure, because a host with no request is a
# host in the state the verb asked about.
run weedr firewall list
assert_exit 0
assert_stdout_has "no service asks for a firewall rule"

run weedr firewall list --json
assert_exit 0
assert_stdout_lines 1
assert_json rules "[]"

# --- the request installs nothing -------------------------------------------

# The poke's own verb creates the service, records both `firewall:` entries and
# leaves both pending. This is the state a push leaves behind, and it is the
# whole of what a repository can do here.
run weedr service ingest tunnel-staging --from poke gated@9f2c1ab
assert_exit 0
assert_file_exists "$registry/tunnel-staging.toml"
assert_file_has "$registry/tunnel-staging.toml" 'name = "wireguard-peer"'
assert_file_has "$registry/tunnel-staging.toml" 'name = "peer-range"'
assert_file_has "$registry/tunnel-staging.toml" '"-p udp --dport 51820 -j ACCEPT"'
# `chain` is defaulted to guarden's own chain rather than refused as absent.
assert_file_has "$registry/tunnel-staging.toml" 'chain = "guarden-svc"'
# **And the default belongs to the entry that omitted it.** `wireguard-peer`
# writes `chain:` in the manifest and `peer-range` does not, so the assertion
# above is satisfied by either entry alone: a parser that recorded only the
# explicit chain and dropped the omitted one would still pass it. This is the
# entry with no `chain:` key at all, recorded rather than refused, carrying the
# default — which is what §4 means by a key that may be omitted.
# Ordered as the manifest lists them, which is not the order this line assumed:
# `peer-range` is the SECOND entry. Asserting the defaulted chain by finding it
# where it actually is keeps the claim about the default rather than about
# ordering, which nothing in the ticket fixes.
grep -q 'name = "peer-range", chain = "guarden-svc"' "$registry/tunnel-staging.toml" ||
    _fail "the entry that omitted chain: was not recorded with guarden's chain"
# **A request installs nothing, and it grants nothing either.** The registry's
# `granted` mirror is absent after an ingest, because the only thing that writes
# it is `weedr firewall open` and a poke cannot reach that.
assert_file_lacks "$registry/tunnel-staging.toml" "granted = ["
# **No rule was installed, and no firewall grant was recorded.** A request is a
# request: the whole of what the ingest did about the firewall is write those
# registry lines.
#
# `overrides.toml` itself DOES exist by now and that is not the firewall's doing —
# `units.install` seeds `[mounts] allow` from the module's own unit source. What
# must be absent is the `[firewall]` table in it, because a repository cannot
# grant itself a rule.
assert_file_lacks "$overrides/tunnel-staging/overrides.toml" "[firewall]"
assert_file_missing "$conf"

run weedr firewall list
assert_exit 0
assert_stdout_has "wireguard-peer"
assert_stdout_has "-p udp --dport 51820 -j ACCEPT"
assert_stdout_has "pending"
assert_stdout_has "tunnel-staging wireguard-peer"

run weedr firewall list --json
assert_exit 0
assert_stdout_lines 1
assert_json rules.0.rule '"-p udp --dport 51820 -j ACCEPT"'
assert_json rules.0.chain '"guarden-svc"'
assert_json rules.0.file '"/etc/guarden/firewall/50-services.conf"'
assert_json rules.0.granted false
assert_json rules.0.requested_by.0.service '"tunnel-staging"'
assert_json rules.0.requested_by.0.name '"wireguard-peer"'
# One object per rule text, not one per service: the field set is closed and a
# second service asking for the same line does not add a second object.
assert_json_missing rules.0.uid

# --- the grant is refused with no request behind it -------------------------

# The manifest asks and the admin decides, and neither does the other's job. A
# grant with no request behind it is an admin typing firewall text into a file
# nobody will later find the counterpart of, so it is exit `2` naming the entry
# it would have to be.
run weedr firewall open tunnel-staging invented-rule
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "invented-rule"
assert_stderr_has "firewall:"
assert_stderr_has "wireguard-peer"
assert_file_missing "$conf"
assert_file_lacks "$overrides/tunnel-staging/overrides.toml" "[firewall]"

# A service that does not exist has asked for nothing, which is the host and
# not a rejected input.
run weedr firewall open ghost-staging wireguard-peer
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "ghost-staging"

# --- the grant --------------------------------------------------------------

# The verb writes the NAME into the admin's file — never the rule text — then
# renders whole, prints the diff and installs, all under the `firewall` lock.
run weedr firewall open tunnel-staging wireguard-peer
assert_exit 0
assert_stdout_has "50-services.conf"
assert_stdout_has "51820"
assert_file_exists "$overrides/tunnel-staging/overrides.toml"
assert_file_has "$overrides/tunnel-staging/overrides.toml" '[firewall]'
assert_file_has "$overrides/tunnel-staging/overrides.toml" 'allow = ["wireguard-peer"]'
# **The rule text is not in the admin's file.** The rule behind a name lives in
# the manifest that asked for it, and a file an operator reviews stays readable.
assert_file_lacks "$overrides/tunnel-staging/overrides.toml" "51820"
assert_file_has "$registry/tunnel-staging.toml" 'granted = ["wireguard-peer"]'

# --- position is guarden's --------------------------------------------------

# The granted rule is in the chain, in ferm's own dialect, above the deny.
assert_file_has "$conf" "table nat"
assert_file_has "$conf" "chain guarden-svc"
assert_file_has "$conf" "proto udp dport 51820 jump ACCEPT;"

# **The deny is the last rule of the chain and a grant cannot move it.** The
# grant landed above it, so a grant is always reachable, and the invariant that
# every accept precedes the single deny survives one.
drop_line=$(grep -n -- "jump DROP" "$conf" | tail -1 | cut -d: -f1)
grant_line=$(grep -n -- "dport 51820" "$conf" | tail -1 | cut -d: -f1)
[ "$grant_line" -lt "$drop_line" ] \
    || _fail "the granted rule is at line $grant_line and the deny at $drop_line"
[ "$(grep -c -- "daddr 127.0.0.0/8 jump DROP" "$conf")" = 1 ] \
    || _fail "the loopback deny is not the single last rule"
tail -1 "$conf" | grep -q "^}" || _fail "the chain does not close after the deny"

# The grant is one rule and not a second accept set: nothing else about the
# uid-matched posture changed, and the drop still names no uid.
run grep -- "jump DROP" "$conf"
assert_exit 0
assert_stdout_lacks "uid-owner"
assert_stdout_has "daddr 127.0.0.0/8"

# A grant reaches no other file. The edge's three forwarding rules are soil's
# and 10-framework.conf is the skeleton; each has exactly one writer.
assert_file_lacks "$conf" "POSTROUTING"
assert_file_lacks "$conf" "MASQUERADE"
assert_file_lacks "$conf" "ufw"
assert_file_lacks "$conf" "chain INPUT"

# The second entry is still pending: one grant is one grant.
run weedr firewall list
assert_exit 0
[ "$(grep -c -- 'installed' "$GUARDEN_STDOUT")" = 1 ] \
    || _fail "one granted rule and one pending rule reported as otherwise"
assert_file_has "$conf" "chain guarden-svc"
assert_file_lacks "$conf" "8333"

# Granting a granted name is the requested state already true, and re-granting
# cannot append a second copy: the render is a pure function of a set.
run weedr firewall open tunnel-staging wireguard-peer
assert_exit 0
assert_stdout_has "already granted"
[ "$(grep -v '^[[:space:]]*#' "$conf" | grep -c -- "dport 51820")" = 1 ] \
    || _fail "a re-granted rule rendered more than once"

# The second grant renders its own rule, and the deny is still last.
run weedr firewall open tunnel-staging peer-range
assert_exit 0
assert_file_has "$conf" "saddr 192.0.2.0/24 proto tcp dport 8333 jump ACCEPT;"
drop_line=$(grep -n -- "jump DROP" "$conf" | tail -1 | cut -d: -f1)
grant_line=$(grep -n -- "dport 8333" "$conf" | tail -1 | cut -d: -f1)
[ "$grant_line" -lt "$drop_line" ] \
    || _fail "the second granted rule landed after the deny"

# --- deduplication is by content, the count is by name ----------------------

# A second service whose manifest asks for the SAME line, under its own name.
# Its registry is seeded rather than ingested because the allocation and the
# unit install are not this file's subject.
seed "$registry/relay-staging.toml" \
    'service = "relay-staging"' 'workload = "relay"' 'project = "relay"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-10-04T09:00:00Z"' \
    '[firewall]' \
    'requested = [ { name = "shared-peer", chain = "guarden-svc", rule = "-p udp --dport 51820 -j ACCEPT" } ]'
seed "$overrides/relay-staging/overrides.toml" \
    '[retention]' 'keep_last = 7' '' '[firewall]' 'allow = ["shared-peer"]'

# One rule, carrying both names. A render that reported the same line twice
# would be claiming two rules where there is one.
run weedr firewall open tunnel-staging wireguard-peer
assert_exit 0
[ "$(grep -v '^[[:space:]]*#' "$conf" | grep -c -- "dport 51820")" = 1 ] \
    || _fail "two services asking for one line rendered it twice"

run weedr firewall list
assert_exit 0
assert_stdout_has "relay-staging shared-peer"
assert_stdout_has "tunnel-staging wireguard-peer"
[ "$(grep -c -- '51820' "$GUARDEN_STDOUT")" = 1 ] \
    || _fail "the shared rule is listed once per service rather than once"

run weedr firewall list --json
assert_exit 0
# One entry, not two, for one rule text — deduplicated by content.
[ "$(python3 "$GUARDEN_ROOT/tests/jsonfield.py" rules <"$GUARDEN_STDOUT" | grep -c '51820')" = 1 ] \
    || _fail "the JSON lists the shared rule twice or omits one holder"
assert_json rules.0.requested_by.0.service '"relay-staging"'
assert_json rules.0.requested_by.1.service '"tunnel-staging"'

# **Closing one leaves it in force while the other still asks.** The two grants
# are independent and the rule is a reference count by name over one entry.
run weedr firewall close tunnel-staging wireguard-peer
assert_exit 0
assert_file_has "$conf" "dport 51820"
assert_file_lacks "$overrides/tunnel-staging/overrides.toml" "wireguard-peer"
assert_file_has "$overrides/relay-staging/overrides.toml" "shared-peer"
drop_line=$(grep -n -- "jump DROP" "$conf" | tail -1 | cut -d: -f1)
grant_line=$(grep -n -- "dport 51820" "$conf" | tail -1 | cut -d: -f1)
[ "$grant_line" -lt "$drop_line" ] \
    || _fail "a rule one service still asks for landed after the deny"

# The last close takes it, and nothing is orphaned.
run weedr firewall close relay-staging shared-peer
assert_exit 0
assert_file_lacks "$conf" "dport 51820"
assert_file_lacks "$overrides/relay-staging/overrides.toml" "shared-peer"
assert_file_has "$registry/relay-staging.toml" 'requested = [{ name = "shared-peer"'

# A close of something never granted is the requested state already true.
run weedr firewall close tunnel-staging wireguard-peer
assert_exit 0
assert_stdout_has "not granted"

# --- the deny is still the last line after all of it -------------------------

drop_line=$(grep -n -- "jump DROP" "$conf" | tail -1 | cut -d: -f1)
last_accept=$(grep -n -- "jump ACCEPT" "$conf" | tail -1 | cut -d: -f1)
[ "$last_accept" -lt "$drop_line" ] \
    || _fail "an accept landed after the deny"

# --- the stub resolver's accept (ticket 260, spec 7.6, ADR-0015) -----------

# Everything above is somebody's grant. This is the one accept guarden renders
# with nobody asking, and the four things that make that safe are asserted here:
# it is rendered, it is above the deny, it is owner-matched to service uids, and
# a service uid still cannot reach anything else on loopback.
#
# The uid is read from the account the ingest created rather than written down,
# because the rule names the uid the registry allocated: a number typed into
# this test would be satisfied by a render that never read anything.
svc_uid=$(getent passwd tunnel-staging | cut -d: -f3)
[ -n "$svc_uid" ] || _fail "tunnel-staging has no uid, so no rule can name it"
svc_home=/var/lib/guarden/services/tunnel-staging/home

# **The policy is in force before anything is asserted about it.** `soil
# firewall --apply` is what installs `guarden-firewall.service` and the two
# files of soil's own half, and the mutator's `load_set` only warns rather than
# failing when the unit is absent — so without this the counters below are read
# off a ruleset that does not exist and every measurement is vacuous. Starting
# it is the point at which the three files are assembled into one policy.
run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
assert_active guarden-firewall.service

# **Read the deny out of the table that HOLDS it.** ferm invokes `iptables` by
# name, so `update-alternatives` decides which table was written, and on this
# golden `/usr/sbin/iptables` is `iptables-nft` while guarden's rules are in
# `iptables-legacy` — reading through `iptables` looks for a chain that is not
# there, and `iptables-nft` says so explicitly. (ticket 270 owns the fix.)
run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "127.0.0.0/8"
assert_stdout_has "DROP"

# **It is rendered, on both protocols.** systemd-resolved's stub listens on udp
# and tcp 53, and udp is the protocol a pull actually uses; a render carrying
# only one would leave the host path broken in the way the ticket found it.
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"

# **The exact address, and the exact port.** Both halves of "narrow" are
# load-bearing rather than one of them implying the other, so each is counted on
# its own. A render that widened this to the loopback network — the thing being
# denied — or to another port on the resolver would pass every positive
# assertion above.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE 'jump ACCEPT;.*127\.0\.0\.0/8' || true)" = 0 ] \
    || _fail "an accept matches the whole loopback network, which is the deny itself"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner $svc_uid daddr 127\.0\.0\.53 proto (udp|tcp) dport 53 jump ACCEPT;\$" || true)" = 2 ] \
    || _fail "the resolver accepts are not exactly two rules at 127.0.0.53 port 53"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+daddr 127\.0\.0\.53 proto (udp|tcp) dport [0-9]+ jump ACCEPT;\$" || true)" = 0 ] \
    || _fail "a resolver accept carries no owner match, so any uid could use it"

# **Above the deny, and the deny is still last.** Position is guarden's for
# these accepts as it is for the granted rules above: an accept below the single
# deny matches no packet while still appearing in the file.
drop_line=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump DROP;' | tail -1 | cut -d: -f1)
[ -n "$drop_line" ] || _fail "the loopback deny is not in the rendered set at all"
resolver_line=$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -n "daddr 127.0.0.53" | tail -1 | cut -d: -f1)
[ "$resolver_line" -lt "$drop_line" ] \
    || _fail "the resolver accept is at line $resolver_line and the deny at $drop_line"
last_accept=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump ACCEPT;' | tail -1 | cut -d: -f1)
[ "$last_accept" -lt "$drop_line" ] \
    || _fail "an accept landed after the deny, at line $last_accept"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -c 'daddr 127.0.0.0/8 jump DROP;')" = 1 ] \
    || _fail "the loopback deny is not the single last rule"

# **Owner-matched to service uids, and to no one else.** The deny itself names no
# uid — that is what makes it a default deny — so a uid outside the accept set is
# refused `127.0.0.53` exactly as it is refused every publication. `guarden` and
# `operator` are the two uids on a converged guarden host that are not service
# uids and are not meant to reach the stub this way: images are pulled as the
# service user, which is the path this accept exists for.
#
# **Root is not in this list, and that is deliberate** (ADR-0023): root holds the
# resolver's accepts too, because every name lookup on the host goes through the
# stub and the deny was breaking root's own tooling. So the two uids checked
# here are the ones that are neither service uids nor root — the set of uids the
# resolver's accepts are for, less root.
for uid in $(getent passwd guarden operator | cut -d: -f3); do
    [ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
        | grep -cE "^[[:space:]]+mod owner uid-owner $uid daddr 127\.0\.0\.53 " || true)" = 0 ] \
        || _fail "uid $uid is not a service uid and the resolver accept covers it"
done

# A second service, and the resolver's accepts are per uid rather than written
# out once. `shelf` is the plainest fixture in the tree — a compose service with
# one route and no credential — so the ingest below is about the uid and nothing
# else.
stage_poke shelf 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0
shelf_uid=$(getent passwd shelf-staging | cut -d: -f3)
[ -n "$shelf_uid" ] || _fail "shelf-staging was ingested and has no uid"
assert_file_has "$conf" \
    "mod owner uid-owner $shelf_uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $shelf_uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner $svc_uid daddr 127\.0\.0\.53 " || true)" = 2 ] \
    || _fail "a second service changed the first service's resolver accepts"

# A grant cannot reach the resolver either. This rule is rendered from the host
# rather than asked for, so it is in the set whatever any manifest says and no
# `overrides.toml` holds its address.
assert_file_lacks "$overrides/tunnel-staging/overrides.toml" "127.0.0.53"

# --- the deny still works: the negative that matters -----------------------

# Everything above read a file. This measures the running kernel ruleset, which
# is the only way the claim "the deny does not touch the rest of loopback" can be
# true or false — and it is the claim the whole ticket rests on, because the
# defect was never a spelling in the render.
svc_send() {
    run_in "$svc_home" setpriv --reuid=tunnel-staging --regid=tunnel-staging \
        --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
        sh -c "printf '\x00\x00' | nc -u -w1 $1 $2" || true
}

# **The stub is actually listening**, or a counter that stays put proves nothing:
# a packet to a port nothing holds is refused for being unanswered rather than
# by the rule under test, and this suite would then be measuring the wrong thing.
# `ss` prints the address with its scope as `127.0.0.53%lo:53`, so the port is
# matched rather than the bare address-and-port pair a filter would guess.
run ss -lun
assert_exit 0
assert_stdout_has "127.0.0.53%lo:53"

# `iptables -nvx -L` prints `pkts bytes target prot opt in out source destination`,
# so the DROP rule's counter is the first field and its destination is
# `127.0.0.0/8`. One function, so the readings cannot differ in how they were
# taken.
deny_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $NF ~ /^127\.0\.0\.0\/8/ {print $1; exit}'
}

# **The negative, and it is the important one here.** A service uid sending to
# `127.0.0.1` — the address every publication lives on, and the address the
# resolver's exemption names as itself — is dropped by this very rule.
# `127.0.0.53` is exempted; `127.0.0.1` is not, and neither is any port other than
# 53 on the exempted address. A counter that does not move here is the accept
# widened into the loopback network, which is every positive assertion above
# failing to notice.
before=$(deny_packets)
[ -n "$before" ] || _fail "guarden-svc has no DROP rule on 127.0.0.0/8 to measure"
svc_send 127.0.0.1 53
after_other=$(deny_packets)
[ "$after_other" != "$before" ] \
    || _fail "a service uid reached 127.0.0.1:53; the deny does not hold on the rest of loopback"

# The same address on a port the stub does not listen on, so "one address" and
# "one port" are both load-bearing rather than one implying the other.
svc_send 127.0.0.53 22
after_port=$(deny_packets)
[ "$after_port" != "$after_other" ] \
    || _fail "a service uid reached 127.0.0.53:22; the accept is not limited to port 53"

# **And the positive, read off the same counter.** The accept is above the deny,
# so a service uid's datagram to `127.0.0.53:53` must NOT move the deny's packet
# count. A counter that moves here is exactly the defect ADR-0015 was written
# for, reproduced rather than fixed: `podman pull` as this uid cannot resolve a
# name, and no first deploy of a new workload can complete.
svc_send 127.0.0.53 53
after_resolver=$(deny_packets)
printf 'RESOLVER_DENY_COUNTER=%s\n' "$after_resolver" >&2
[ "$after_resolver" = "$after_port" ] \
    || _fail "a service uid's datagram to 127.0.0.53:53 was dropped by the deny: the accept is not in force"

# A uid that is not a service uid is refused even at the resolver, because the
# deny names no uid and the accept names this one. `guarden` is the account the
# unprivileged programs run as, so this is the shape of any future verb's
# refusal rather than a hypothetical.
run_in /tmp setpriv --reuid=guarden --regid=guarden --clear-groups \
    env -u OLDPWD sh -c "printf '\x00\x00' | nc -u -w1 127.0.0.53 53" || true
after_other_uid=$(deny_packets)
[ "$after_other_uid" != "$after_resolver" ] \
    || _fail "uid guarden reached 127.0.0.53:53, so the accept is not owner-matched"

# The deny is last, once more, with the resolver accepts and two services on the
# box — the invariant every one of the above depends on.
drop_line=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump DROP;' | tail -1 | cut -d: -f1)
last_accept=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump ACCEPT;' | tail -1 | cut -d: -f1)
[ "$last_accept" -lt "$drop_line" ] \
    || _fail "an accept landed after the deny once the resolver accepts were in"

# The resolver's rule reaches no other file. `10-framework.conf` and
# `20-ingress-nat.conf` are soil's and each of the three files has exactly one
# writer, so a resolver accept in any of them would be a second writer.
assert_file_lacks "$conf" "chain INPUT"
assert_file_lacks "$ingress" "127.0.0.53"
assert_file_lacks /etc/guarden/firewall/10-framework.conf "127.0.0.53"