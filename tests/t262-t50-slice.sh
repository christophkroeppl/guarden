#!/usr/bin/env bash
# The deny assertion must not be moved by concurrent loopback traffic
# (ticket 262, the second acceptance criterion).
#
# **WHAT THIS FILE IS FOR.** `tests/t50-slice.sh` measured the loopback deny
# with the DROP rule's PACKET COUNTER, and that counter is host-wide: the
# rule guarden renders is `daddr 127.0.0.0/8 jump DROP;` with no owner
# match, so every uid's loopback traffic that falls past the accepts above it
# lands on that one rule and moves its count. The old suite used two
# different destinations and read the count on both, which did not close the
# race — both halves read the SAME rule and therefore the SAME count.
#
# **So this file reproduces the race, and it is the RED step.** It drives
# concurrent loopback traffic from a uid that is NOT a service uid while the
# counter is read, and it shows what the old comparison does under that
# traffic: it reports that the stub was dropped, when the stub was never
# dropped at all. That is the symptom the ticket records — the same
# assertion read `0->4` on the ticket-240 branch and said "the stub was
# dropped, so the accept is not above the deny".
#
# **What is asserted here is the property, not the reproduction.** The
# properties are read from the RULES — the live chain the kernel enforces —
# and traffic cannot move a rule. The reproduction is printed as the
# measurement that shows the old shape was wrong.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# One service, so there is one service uid and one stub accept to look for.
# The poke is the same shape `t50-slice.sh` uses: a manifest, a route and a
# publication.
stage_poke routed 9f2c1ab
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0
svc_uid=$(id -u routed-staging)
[ -n "$svc_uid" ] || _fail "routed-staging was ingested and has no uid"

run soil firewall --apply
assert_not_rejected
# **The unit is settled before the rules are read.** The firewall reaches the
# kernel through `systemctl reload-or-restart` (`firewall.load_set`), and the
# unit's ExecStop runs `ferm -F`, which blocks while it flushes the chains — so
# a restart spends real time deactivating and an immediate read sees the
# intermediate state rather than the outcome.
wait_settled guarden-firewall.service
assert_active guarden-firewall.service

# **THE RULES, AS ONE SNAPSHOT.** `iptables -S` prints the rules in
# chain-traversal order, so a rule's line number IS its position, and one read
# is one view of the ruleset — every property below is read out of the same
# string, so they cannot disagree about which ruleset they describe.
run iptables-legacy -S guarden-svc
assert_exit 0
ruleset=$(cat "$GUARDEN_STDOUT")
[ -n "$ruleset" ] || _fail "the guarden-svc chain is empty, so there is no ruleset to read"

# The one deny, and the stub's accept for THIS uid, in the kernel's spelling.
deny_line=$(printf '%s\n' "$ruleset" | grep -n -- '-A guarden-svc -d 127.0.0.0/8 -j DROP' | head -1 | cut -d: -f1)
[ -n "$deny_line" ] || _fail "the guarden-svc chain has no DROP on 127.0.0.0/8"
[ "$(printf '%s\n' "$ruleset" | grep -c -- '-A guarden-svc -d 127.0.0.0/8 -j DROP')" = 1 ] \
    || _fail "the loopback deny is not the single rule on 127.0.0.0/8"

stub_line=$(printf '%s\n' "$ruleset" \
    | grep -n -- "-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner $svc_uid -m udp --dport 53 -j ACCEPT" \
    | head -1 | cut -d: -f1)
[ -n "$stub_line" ] \
    || _fail "the stub accept for uid $svc_uid is not in the enforced chain"

# **The properties, and they are about the RULES.** Traffic cannot move a
# rule, so these hold under any amount of concurrent loopback traffic.
[ "$stub_line" -lt "$deny_line" ] \
    || _fail "the stub accept is at line $stub_line and the deny at $deny_line, so the stub is dropped"
[ "$(printf '%s\n' "$ruleset" | grep -- '-j ACCEPT' | grep -c -- '127.0.0.0/8')" = 0 ] \
    || _fail "an accept matches the whole loopback network, so the deny is unreachable"
last_rule=$(printf '%s\n' "$ruleset" | grep -c -- '-A guarden-svc ')
[ "$deny_line" = "$last_rule" ] \
    || _fail "the deny is at line $deny_line and the chain's last rule is at line $last_rule"

echo "MEASURE: RULES deny=$deny_line stub_accept=$stub_line last=$last_rule"

# ---------------------------------------------------------------------------
# THE RACE, REPRODUCED
# ---------------------------------------------------------------------------
#
# `guarden` is the account guarden's own programs run as, and it is NOT a
# service uid: nothing above the deny accepts its packets, so they fall
# through to the drop and move the shared count. The destination is the
# discard port and the protocol is UDP — no accept above the deny names them,
# so the traffic is exactly what a stranger's loopback traffic looks like to
# this counter.
flood_pid=""
flood_start() {
    env -C /tmp setpriv --reuid=guarden --regid=guarden --clear-groups \
        env -u OLDPWD HOME=/tmp PWD=/tmp \
        sh -c 'while :; do printf "\x00\x00" | nc -u -w1 127.0.0.1 9; sleep 0.1; done' \
        >/dev/null 2>&1 &
    flood_pid=$!
}
flood_stop() {
    if [ -n "$flood_pid" ]; then
        kill "$flood_pid" 2>/dev/null || true
        wait "$flood_pid" 2>/dev/null || true
        flood_pid=""
    fi
}
trap flood_stop EXIT

shared_count() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $9 == "127.0.0.0/8" {print $1; exit}'
}

# **The witness: the shared count must MOVE.** An immunity claim measured over
# a quiet machine proves nothing, so the traffic is not accepted until the
# count is seen to move.
flood_start
before=$(shared_count)
[ -n "$before" ] || _fail "guarden-svc has no DROP rule on 127.0.0.0/8 to count"
moved=""
for _ in $(seq 1 50); do
    sleep 0.2
    if [ "$(shared_count)" != "$before" ]; then
        moved=yes
        break
    fi
done
[ -n "$moved" ] \
    || _fail "the concurrent loopback traffic moved nothing, so the immunity measured below proves nothing"
echo "MEASURE: CONCURRENT_LOOPBACK_TRAFFIC=movable SHARED_DENY=$before->$(shared_count)"

# **THE OLD ASSERTION, AND IT FAILS.** The old shape compared the count
# before and after sending one datagram to the stub, and said the stub was
# dropped if the count had moved. Under concurrent traffic it moves — so the
# old shape reports a dropped stub that was never dropped. This is the
# reproduction the ticket records, and it is asserted rather than printed:
# the old shape's verdict is wrong, and the count is what makes it wrong.
stub_before=$(shared_count)
sleep 1
stub_after=$(shared_count)
[ "$stub_after" != "$stub_before" ] \
    || _fail "the shared count did not move under concurrent traffic, so the race is not reproduced"
echo "MEASURE: OLD_SHAPE_VERDICT='the stub was dropped' BUT_NO_STUB_PACKET_WAS_SENT"

# **AND THE PROPERTIES HOLD ANYWAY, WITH THE COUNT IN MOTION.** This is the
# point: the properties are about the rules, so the traffic that breaks the
# old comparison cannot break them. Read them again from a fresh snapshot,
# because a re-read is the honest way to say "the ruleset still says this".
ruleset_after=$(iptables-legacy -S guarden-svc 2>/dev/null)
deny_after=$(printf '%s\n' "$ruleset_after" | grep -n -- '-A guarden-svc -d 127.0.0.0/8 -j DROP' | head -1 | cut -d: -f1)
stub_after_line=$(printf '%s\n' "$ruleset_after" \
    | grep -n -- "-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner $svc_uid -m udp --dport 53 -j ACCEPT" \
    | head -1 | cut -d: -f1)
[ -n "$deny_after" ] && [ -n "$stub_after_line" ] \
    || _fail "the enforced chain changed under the concurrent traffic, so the measurement is not of one ruleset"
[ "$stub_after_line" -lt "$deny_after" ] \
    || _fail "the stub accept moved below the deny under concurrent traffic"
[ "$(printf '%s\n' "$ruleset_after" | grep -- '-j ACCEPT' | grep -c -- '127.0.0.0/8')" = 0 ] \
    || _fail "an accept matching the whole loopback network appeared under concurrent traffic"
last_after=$(printf '%s\n' "$ruleset_after" | grep -c -- '-A guarden-svc ')
[ "$deny_after" = "$last_after" ] \
    || _fail "the deny is no longer the last rule of guarden-svc under concurrent traffic"
echo "MEASURE: UNDER_CONCURRENT_TRAFFIC deny=$deny_after stub_accept=$stub_after_line last=$last_after"

flood_stop

# **The traffic is stopped, and the properties still hold.** The claim is
# about a ruleset, so it holds with or without traffic; saying so once the
# traffic is gone is the control for the measurement above.
ruleset_final=$(iptables-legacy -S guarden-svc 2>/dev/null)
deny_final=$(printf '%s\n' "$ruleset_final" | grep -n -- '-A guarden-svc -d 127.0.0.0/8 -j DROP' | head -1 | cut -d: -f1)
stub_final=$(printf '%s\n' "$ruleset_final" \
    | grep -n -- "-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner $svc_uid -m udp --dport 53 -j ACCEPT" \
    | head -1 | cut -d: -f1)
[ "$stub_final" -lt "$deny_final" ] \
    || _fail "the stub accept is not above the deny once the traffic stopped"
echo "MEASURE: TRAFFIC_STOPPED deny=$deny_final stub_accept=$stub_final"
