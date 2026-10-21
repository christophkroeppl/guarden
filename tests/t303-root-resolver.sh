#!/usr/bin/env bash
# Root and the stub resolver: root gets an accept, and the test pins that it
# does (ticket 303, spec 7.6, ADR-0023).
#
# **The subject is a DECISION, and the decision is that root DOES get a
# stub-resolver accept.** Every render emits two owner-matched
# `127.0.0.53:53` accepts per uid — udp and tcp — above the global
# `daddr 127.0.0.0/8 jump DROP`. Root's uid is in that set. Before this ticket
# it was not, and the exclusion was a side effect of the accept set being built
# from the registry's service uids: root is not a service uid, so root's
# absence was never asked about.
#
# **Why the answer is yes, in the shape the answer needs.** The reasoning lives
# in `docs/adr/0023-root-stub-resolver-accept.md`; what is measured here is the
# thing the reasoning rests on.
#
#   * **Every name lookup on the host goes to the stub.** `/etc/resolv.conf`
#     names `127.0.0.53`, so a lookup is a loopback packet BEFORE any outbound
#     packet exists. The deny is on `127.0.0.0/8`, so it is the *lookup* that
#     dies, not the traffic that follows it. **This is the fact that decided
#     the question**, and it was measured on a converged host:
#
#         BEFORE the firewall converges   root getent exit=0   apt-get update exit=0
#         AFTER  the deny is in force     root getent exit=2   deny counter 0->8
#                                         root curl exit=6
#                                         apt-get update: "Temporary failure
#                                           resolving archive.ubuntu.com" (exit 0)
#         WITH a uid-0 resolver accept   root getent exit=0   deny counter 0->0
#
#     The service uid's lookup is unaffected throughout — it has its own accept
#     above the deny — so the difference is root's and not the box's.
#   * **The refusal is invisible where it costs the most.** `apt-get update`
#     still exits 0 while every mirror fails to resolve, so a host whose
#     package index silently stopped refreshing reads as a host with an
#     unreachable mirror. A rule whose failure mode is a wrong answer is worse
#     than one whose failure mode is an error.
#   * **Root already holds a broader exemption on the same chain.** The
#     operator's shell reaches every publication —
#     `mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;` — so
#     uid 0 is not outside the loopback deny, it is inside it with a named
#     exception. The resolver accept adds one address and one port to a uid
#     that already holds every TCP port on `127.0.0.1`.
#
# **What the test asserts, and why it cannot be satisfied by the other
# answer.** Under the other answer — root refused — the render would carry no
# uid-0 accept at the resolver, and the deny's counter would MOVE across a
# root datagram to the stub. Both of those are asserted here, and both are
# the opposite of what the other answer produces.
#
# Real host, real uid, real ferm, real kernel counters:
# `GUARDEN_PREFIX=/`, as `t180-firewall-rules` and `t441-template-dns` do.
# What is asserted is state — a file, a ruleset, a counter — and never a
# record of what a program said it was about to do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

conf=/etc/guarden/firewall/50-services.conf

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# A service, so the set has a service uid in it and the resolver accepts exist
# at all. `shelf` is the plainest fixture in the tree — one route, no
# credential — so what is under test is the uid and nothing else.
stage_poke shelf 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0
svc_uid=$(getent passwd shelf-staging | cut -d: -f3)
[ -n "$svc_uid" ] || _fail "shelf-staging has no uid, so the resolver accept set is empty"

# **The policy is in force before anything is asserted about it.** The
# counters below are read off a ruleset that has to exist, and `load_set` only
# warns rather than failing when the unit is absent — so without this the
# measurement would be of a chain that was never loaded.
run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
assert_active guarden-firewall.service

# --- the decision, part 1: the rendered file carries root's accepts ---------

# **Root's two accepts, in the renderer's own dialect.** The same address, the
# same port and the same two protocols the service set carries — a service uid
# carries two accepts for the resolver and so does root.
assert_file_has "$conf" \
    "mod owner uid-owner 0 daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner 0 daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"

# **And the service set is UNCHANGED.** The service uid's accepts are still
# there, and they are still exactly two — a render that answered this decision
# by widening the service set rather than by adding root would satisfy the
# assertions above, and this one says it did not.
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner $svc_uid daddr 127\.0\.0\.53 proto (udp|tcp) dport 53 jump ACCEPT;\$" || true)" = 2 ] \
    || _fail "the service uid's resolver accepts are not exactly two rules at 127.0.0.53 port 53"

# **The address is the one address and the port is the one port.** An accept
# widened to the loopback network would be the deny itself, and one widened to
# another port would open more than the resolver. Both halves are counted on
# their own, because one of them does not imply the other.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE 'jump ACCEPT;.*127\.0\.0\.0/8' || true)" = 0 ] \
    || _fail "an accept matches the whole loopback network, which is the deny itself"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+daddr 127\.0\.0\.53 proto (udp|tcp) dport [0-9]+ jump ACCEPT;\$" || true)" = 0 ] \
    || _fail "a resolver accept carries no owner match, so any uid could use it"

# **Root's publication accept is unchanged too** — the decision adds root's
# resolver access and does not touch what root already had.
assert_file_has "$conf" \
    "mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;"

# **And the reply accepts are still there, once each.** They carry no owner
# match at all, so they are not root's accepts and their presence is a
# separate fact: a render that dropped them would break every service's
# resolution.
assert_file_has "$conf" "saddr 127.0.0.53 proto udp sport 53 jump ACCEPT;"
assert_file_has "$conf" "saddr 127.0.0.53 proto tcp sport 53 jump ACCEPT;"

# --- the decision, part 2: the ENFORCED ruleset ----------------------------

# **The file is what guarden intends and the chain is what the box enforces.**
# One snapshot of the live ruleset, and every property read out of it.
run iptables-legacy -S guarden-svc
assert_exit 0
ruleset=$(cat "$GUARDEN_STDOUT")
[ -n "$ruleset" ] || _fail "the guarden-svc chain is empty, so there is no ruleset to read"

# The kernel's own spelling: `-d 127.0.0.53/32 -p udp -m owner --uid-owner 0
# -m udp --dport 53 -j ACCEPT`. The pattern is the kernel's, read off
# `iptables-legacy -S`: the address carries its prefix length, the protocol is
# named and the module follows the match criteria.
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner 0 -m udp --dport 53 -j ACCEPT')" = 1 ] \
    || _fail "the enforced chain has no uid-0 accept at the stub resolver for udp"
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p tcp -m owner --uid-owner 0 -m tcp --dport 53 -j ACCEPT')" = 1 ] \
    || _fail "the enforced chain has no uid-0 accept at the stub resolver for tcp"

# The service uid's accepts are in the enforced chain too, and unchanged: the
# decision added root and did not move anything else.
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- "-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner $svc_uid -m udp --dport 53 -j ACCEPT")" = 1 ] \
    || _fail "the service uid's stub accept is not in the enforced chain"
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.1/32 -p tcp -m owner --uid-owner 0 -j ACCEPT')" = 1 ] \
    || _fail "root's publication accept is not in the enforced chain"

# --- the decision, part 3: the DENY no longer refuses root's query ----------

# `iptables -nvx -L` prints `pkts bytes target prot opt in out source
# destination`, so the DROP rule's counter is the first field and its
# destination is `127.0.0.0/8`. One function, so the readings cannot differ in
# how they were taken.
deny_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $NF ~ /^127\.0\.0\.0\/8/ {print $1; exit}'
}

# **The stub is actually listening**, or a counter that stays put proves
# nothing: a packet to a port nothing holds is refused for being unanswered
# rather than by the rule under test. `ss` prints the address with its scope
# as `127.0.0.53%lo:53`.
run ss -lun
assert_exit 0
assert_stdout_has "127.0.0.53%lo:53"

before=$(deny_packets)
[ -n "$before" ] || _fail "guarden-svc has no DROP rule on 127.0.0.0/8 to measure"

# **Root sends one datagram to the stub.** `nc -u` sends what it reads on
# stdin, and **stdin has to carry the bytes**: with no input `nc` reads EOF
# immediately and sends nothing at all, so the counter would not move and the
# measurement would be of a packet that was never sent. The pipe is INSIDE a
# shell, so the bytes reach `nc` rather than the suite's own stdin — the shape
# `t180-firewall-rules.sh` and `t502-service-user-root.sh` use.
run sh -c "printf '\x00\x00' | nc -u -w1 127.0.0.53 53" || true

after=$(deny_packets)
printf 'MEASURE: ROOT_RESOLVER_DENY_COUNTER=%s->%s\n' "$before" "$after" >&2

# **The counter did NOT move, so root's query was ACCEPTED above the deny.**
# Under the other answer the counter moves, and this file fails. That is what
# makes the assertion able to tell the two answers apart, which is the whole
# of what ticket 303 asked for.
[ "$after" = "$before" ] \
    || _fail "root's datagram to 127.0.0.53:53 met the deny: root does not hold a stub accept"

# **And root's name resolution works**, which is the cost the decision was
# taken to remove. `getent hosts` asks the resolver for a name; on a host where
# the deny refuses root's query it answers nothing and exits non-zero.
#
# **The measurement is the EXIT CODE and not the answer.** A `getent` that
# found nothing would print nothing and exit 2, and so would a `getent` whose
# query was refused — but the exit code of a lookup that was REFUSED is what
# the deny changes, and the two are told apart by the counter above, which
# moved under the other answer and does not move here. The name is one the
# host can answer: the loopback itself.
run getent hosts localhost
assert_exit 0

# **The service uid's query is a different path and the same answer**, which
# is what makes the service accepts and root's accept one rule rather than
# two: the same destination, the same port, two owners.
svc_home=/var/lib/guarden/services/shelf-staging/home
before_svc=$(deny_packets)
run_in "$svc_home" setpriv --reuid=shelf-staging --regid=shelf-staging \
    --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
    sh -c "printf '\x00\x00' | nc -u -w1 127.0.0.53 53" || true
after_svc=$(deny_packets)
printf 'MEASURE: SERVICE_RESOLVER_DENY_COUNTER=%s->%s\n' "$before_svc" "$after_svc" >&2
[ "$after_svc" = "$before_svc" ] \
    || _fail "the service uid's resolver query met the deny, so the accepts are not above it"

# --- what the decision does NOT change --------------------------------------

# **The deny is still the last rule of the chain.** Everything above depends
# on the deny being reachable, and the accepts are the exceptions above it.
drop_line=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump DROP;' | tail -1 | cut -d: -f1)
last_accept=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -n 'jump ACCEPT;' | tail -1 | cut -d: -f1)
[ -n "$drop_line" ] || _fail "the loopback deny is not in the rendered set at all"
[ "$last_accept" -lt "$drop_line" ] \
    || _fail "an accept landed after the deny, at line $last_accept"

# **The deny is still ONE rule on the whole network, carrying no owner
# match.** A deny that named the uids it applies to would not be a default
# deny, and one that matched a narrower destination would leave the rest of
# loopback open. **Root's accept is an accept and not a narrowing of the
# deny**: the deny still matches every uid.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -c 'daddr 127.0.0.0/8 jump DROP;')" = 1 ] \
    || _fail "the loopback deny is not the single last rule"
run grep -- "jump DROP" "$conf"
assert_exit 0
assert_stdout_lacks "uid-owner"

# **And the resolver's accept reaches no other file.** `10-framework.conf` and
# `20-ingress-nat.conf` are soil's and each of the three files has exactly
# one writer, so a resolver accept in any of them would be a second writer.
assert_file_lacks /etc/guarden/firewall/10-framework.conf "127.0.0.53"
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "127.0.0.53"

echo "t303-root-resolver: ok"
