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
#     exception. The resolver accept adds **a second address and the udp half
#     of a protocol pair** to a uid that already holds every TCP port on
#     `127.0.0.1` — the publication accept is `proto tcp` and `127.0.0.1`, so
#     "one address, one port and one added protocol" would misdescribe it.
#     **And because the deny names no uid, uid 0's accept list is the whole of
#     root's loopback policy**, which is why it is short and enumerated.
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

# **The set is CLOSED: the service uids and root, and nobody else.** The count of
# owner-matched accepts at the resolver, over the whole rendered file, is the
# number of uids in the set times two. `guarden` and `operator` are the two
# uids on a converged guarden host that are neither service uids nor root, and
# they must not be in it — a render that answered this decision by widening the
# set would satisfy every positive assertion above.
#
# **The count is over the WHOLE file and not over one uid's lines**, because a
# closure check that only looks at the uids it knows about is not a closure
# check: it would pass on a set that also carried `guarden`.
#
# **The uid is taken as a FIELD and not as "a number on the line".** A second
# `grep -oE '[0-9]+'` over the matched line harvests every number in it — the
# uid, `127` out of `127.0.0.53`, and `53` out of `dport 53` — so the set it
# reports is `[0 127 53 994]` and the assertion is RED on a correct render.
# `sed` takes the one field after `uid-owner` and nothing else, which is what
# the closure claim is about: WHICH uids hold an accept.
resolver_uids=$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | sed -n 's/^[[:space:]]*mod owner uid-owner \([0-9][0-9]*\) daddr 127\.0\.0\.53 .*/\1/p' \
    | sort -u | tr '\n' ' ')
# **The expected set is sorted the same way the measured one is.** The measured
# set comes out of `sort -u`, so it is in ascending order — and uid 0 sorts
# BEFORE a service uid, not after it. An expected string written in the order
# the rule is *thought about* ("the service uid, and root") is not the order
# `sort` produces, and the comparison would be RED on a correct render for a
# reason that has nothing to do with the claim.
expected_uids=$(printf '%s\n0\n' "$svc_uid" | sort -u | tr '\n' ' ')
[ "$resolver_uids" = "$expected_uids" ] \
    || _fail "the resolver's uid set is [$resolver_uids], expected [$expected_uids]"

for uid in $(getent passwd guarden operator | cut -d: -f3); do
    [ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
        | grep -cE "^[[:space:]]+mod owner uid-owner $uid daddr 127\.0\.0\.53 " || true)" = 0 ] \
        || _fail "uid $uid is neither a service uid nor root, and the resolver accept covers it"
done

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

# **And the round trip completes: root's query is answered and the reply comes
# back.** This is the cost the decision was taken to remove, measured on the
# reply's own path rather than on the exit code of a lookup.
#
# **The measurement is the REPLY accept's counter**, which is a fact about the
# rule and about the traffic in one read: the reply accept is
# `saddr 127.0.0.53 proto {udp,tcp} sport 53` — the source, not the
# destination — so it is the reply's own counter and the query's is not in it.
#
# **The row is found by WHAT THE RULE SAYS and not by a column number.**
# `iptables -nvx -L` prints `pkts bytes target prot opt in out source
# destination` and then the match extension, and the extension for a
# source-port match is spelled `spt:53` while a destination-port match is
# `dpt:53` — so the reply's rows are the ones carrying `spt:53` and the
# query's carry `dpt:53`. **The first attempt at this read the source out of a
# fixed field and got nothing**, because the `in`/`out` columns are what the
# rule carries and they move with the chain. The counter is the first column
# on every row, whatever else the row holds, so the sum is taken from the
# first field of the rows that match the rule's own spelling.
reply_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | grep 'spt:53' \
        | grep '127\.0\.0\.53' \
        | awk '{n += $1} END {print n + 0}'
}
reply_before=$(reply_packets)

# **A well-formed DNS query**, so the stub answers it rather than dropping it:
# a two-byte header (id, flags with RD set), one question, and the question's
# name and type.
#
# **The name is `localhost`, and it is sent as a RAW DNS PACKET rather than
# through a resolver library.** Two reasons, and both are about the
# measurement rather than about the stub:
#
#   * **A raw packet bypasses nss entirely**, so the name in `/etc/hosts` is
#     irrelevant and there is no second path that could answer it. The first
#     attempt used `getent hosts localhost`, which nss answers from
#     `/etc/hosts` — so it measured nothing about the resolver at all.
#   * **`localhost` is answered by the stub itself**, from its own local
#     data, and needs no upstream. A name no upstream can answer — `.invalid`
#     — would send resolved out to the network, and the measurement would
#     then depend on the host's upstream and on the very packet path this
#     ticket is about.
run sh -c "printf '\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x09localhost\x00\x00\x01\x00\x01' | nc -u -w2 127.0.0.53 53" || true

reply_after=$(reply_packets)
printf 'MEASURE: REPLY_ACCEPT_COUNTER=%s->%s\n' "$reply_before" "$reply_after" >&2
[ "$reply_after" -gt "$reply_before" ] \
    || _fail "the stub did not answer root's query: the reply accept's counter did not move"

# **And the deny's counter did not move across the same exchange**, which is
# the same event seen from the other side: a refused query never reaches the
# stub and never produces a reply.
after_reply=$(deny_packets)
[ "$after_reply" = "$after" ] \
    || _fail "root's resolver exchange met the deny, so the accept is not in force"

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
