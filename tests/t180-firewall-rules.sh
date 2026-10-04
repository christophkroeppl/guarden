#!/usr/bin/env bash
# A service-requested firewall rule, end to end at the CLI seam
# (ticket 180, spec 7.7, ADR-0013).
#
# The subject is the four load-bearing rules and the order they hold in. A
# request installs nothing; the grant is a root verb on no sudoers rule; the
# position is guarden's, so a grant lands above the default deny and the deny
# stays the last line of the chain; and the render is a set, so two services
# asking for one line get one rule carrying both names. Each of those is
# asserted here as a fact about the rendered file rather than about a code
# path, because that is where a claim like "the deny is still last" is true.
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
conf=/etc/guarden/firewall/30-services.conf
ingress=/etc/guarden/firewall/20-ingress-nat.conf

cleanup() {
    rm -rf "$registry/tunnel-staging.toml" "$registry/relay-staging.toml" \
        "$overrides/tunnel-staging" "$overrides/relay-staging" "$conf" "$ingress"
}
trap cleanup EXIT
cleanup

if ! getent group guarden >/dev/null 2>&1; then
    groupadd --system guarden
fi
# The `guarden` user too, not just its group: `weedr service ingest` renders a
# service's units AS that user, so the ingest below cannot proceed without it.
id -u guarden >/dev/null 2>&1 ||
    useradd --system --no-create-home --gid guarden --shell /usr/sbin/nologin guarden
# `soil install` is this suite's precondition and not its subject: ingest renders
# a service's units with `loom` out of /usr/lib/guarden/bin, and only `install`
# puts it there.
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
mkdir -p /etc/guarden
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
assert_file_has "$registry/tunnel-staging.toml" 'requested = [{ name = "peer-range", chain = "guarden-svc"'
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
assert_json rules.0.file '"/etc/guarden/firewall/30-services.conf"'
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
assert_stdout_has "30-services.conf"
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