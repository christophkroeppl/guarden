#!/usr/bin/env bash
# Root's stub resolver: a DECISION, pinned (ticket 303, spec 7.6).
#
# **This file pins an ABSENCE, and an absence that is not the same as "nothing
# was tested".** The rendered set carries two owner-matched accepts for the
# host's stub resolver, one per protocol, for every uid in the registry — and
# root is not among them, so root's own name resolution on the host path dies
# at the loopback deny. That was never *decided*: it was a side effect of the
# accept set being built from the registry's uids.
#
# ADR-0016 (git history: f92074c^:docs/adr/0016-stub-resolver-under-the-deny.md)
# deferred it by name: "if a verb running as `root` ever needs the stub on the
# host's loopback, it needs an accept naming that uid and that is a separate
# decision rather than something this rule quietly does." This file is that
# separate decision, and the ADR beside it is where the reasoning lives.
#
# **What the decision is, in one sentence: root does NOT get a stub-resolver
# accept, and the denial is pinned here rather than left to a side effect.**
#
# The reasoning, in the shape the decision needs:
#
#   * **Root is already granted the loopback.** `firewall.py` renders
#     `mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;` — root
#     reaches every publication on 127.0.0.1/tcp, because a health check, a
#     smoke test and a diagnostic all run as root (commit 231dd42). So the
#     "root must not use the loopback" answer is not available: root already
#     has the loopback, and the resolver is one destination inside it.
#   * **A resolver accept adds almost nothing to root.** The service accepts
#     exist for uids that run in CONTAINERS, with their own podman store and
#     their own 0700 home. A process that is already root on this host can
#     read /etc/hosts, bind a socket and read any file — every one of which is
#     a more powerful way to learn a name than asking the stub. So the accept
#     is not a widening of root's authority over the host; it is a widening of
#     root's authority over ONE name-resolution path, and the paths it does not
#     widen are the ones that matter.
#   * **What the accept would cost is the rule's own meaning.** The deny is
#     `daddr 127.0.0.0/8 jump DROP;` with NO owner match, and that is what
#     makes it a default deny (spec 7.6). The accepts are the exceptions, and
#     an exception for uid 0 at the resolver is an exception for the whole uid
#     class rather than for one workload — a general exemption, in a rule whose
#     purpose is to deny, for the uid that needs no exemption to read a name.
#   * **The paths guarden itself drives do not need it.** MEASURED below, on a
#     real cut: every name-resolving path guarden runs is either OUTBOUND (the
#     deny does not touch outbound traffic) or runs AS THE SERVICE USER (which
#     the service accepts cover). The claim "root resolves names during
#     installs and image work" is FALSE for guarden's own verbs, and the
#     measurement is in this file rather than in a claim.
#
# **What IS pinned, and why the assertion is not vacuous.** Two things, and
# each of them can fail:
#
#   1. **Root has no `127.0.0.53` accept.** Counted in the rendered file AND
#      read out of the RUNNING ruleset. A render that added uid 0 to the
#      resolver set would render two more rules here and would be caught by
#      the count AND by the ruleset read.
#   2. **The deny still refuses root's resolver query.** Measured on the
#      running ruleset by the DROP rule's own packet counter across one UDP
#      datagram from root to 127.0.0.53:53. This is the negative, and it is
#      what makes the decision a fact about a machine rather than a sentence
#      about a file: the counter moves.
#
# **The second assertion is the one that could not be written before this
# decision, and it is what makes the file worth more than a grep.** Under the
# other answer the counter would NOT move, so the file cannot pass under both
# answers — which is the whole point of the ticket.
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

# --- the decision, part 1: the rendered file carries no uid-0 accept --------

# **The service set is intact.** A render that answered the other way by
# WIDENING the service set rather than by adding uid 0 would satisfy every
# absence assertion below, so the positive half is asserted first: the
# service uid carries its two accepts, exactly two, and nothing else at that
# address carries one.
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $svc_uid daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;"

# **And uid 0 carries none.** This is the decision, in the rendered file: the
# count of owner-matched accepts at the resolver whose owner is 0 is ZERO.
#
# **The pattern is anchored on the WHOLE rule, not on a fragment.** A
# fragment search for `uid-owner 0` would match a rule about some other
# destination, and the assertion would then be about the wrong thing: the
# file legitimately carries a uid-0 accept — the operator's shell reaching
# every publication on 127.0.0.1/tcp — and that accept must SURVIVE this
# decision. What is absent is the uid-0 accept AT THE RESOLVER, and only an
# anchored pattern can tell those two apart.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner 0 daddr 127\.0\.0\.53 proto (udp|tcp) dport 53 jump ACCEPT;\$" || true)" = 0 ] \
    || _fail "the rendered set carries a uid-0 accept at 127.0.0.53:53, which ticket 303 decides against"

# **The uid-0 accept the design DOES carry is still there.** This is what
# makes the assertion above non-vacuous in the other direction: a render that
# had dropped root's publication access would satisfy the absence assertion
# too, and this one says it did not. The two together say "root's loopback
# access is unchanged, and its resolver access is still refused" — which is
# the decision, and not the absence of a decision.
assert_file_has "$conf" \
    "mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;"

# **And the reply accepts are still there, once each.** They carry no owner
# match at all, so they are not uid-0 accepts and the absence assertion
# cannot be satisfied by removing them — a render that dropped them would
# break every service's resolution, which is the opposite of this decision.
assert_file_has "$conf" "saddr 127.0.0.53 proto udp sport 53 jump ACCEPT;"
assert_file_has "$conf" "saddr 127.0.0.53 proto tcp sport 53 jump ACCEPT;"

# --- the decision, part 2: the RUNNING ruleset ------------------------------

# **The file is what guarden intends and the chain is what the box
# enforces.** The absence is asserted in both, because a render that never
# reached the kernel is a render that says nothing about the machine. One
# snapshot of the live ruleset, and every property read out of it.
run iptables-legacy -S guarden-svc
assert_exit 0
ruleset=$(cat "$GUARDEN_STDOUT")
[ -n "$ruleset" ] || _fail "the guarden-svc chain is empty, so there is no ruleset to read"

# The kernel's own spelling: `-d 127.0.0.53/32 -p udp -m owner --uid-owner 0
# -m udp --dport 53 -j ACCEPT`. The count is of uid-0 accepts AT THE
# RESOLVER, and it is zero.
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner 0 ')" = 0 ] \
    || _fail "the enforced chain carries a uid-0 accept at the stub resolver"

[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p tcp -m owner --uid-owner 0 ')" = 0 ] \
    || _fail "the enforced chain carries a uid-0 tcp accept at the stub resolver"

# The service uid's accept IS in the enforced chain, so the two assertions
# above are about a set that exists rather than about a set that is empty.
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- "-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner $svc_uid ")" = 1 ] \
    || _fail "the service uid's stub accept is not in the enforced chain"

# The uid-0 publication accept IS in the enforced chain too, which is the
# other half of the non-vacuity argument: root still reaches the loopback, and
# what is refused is the resolver and not the loopback.
#
# **The pattern is the KERNEL's spelling, read off `iptables-legacy -S`.** The
# rendered file says `mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump
# ACCEPT;` and the kernel says `-A guarden-svc -d 127.0.0.1/32 -p tcp -m owner
# --uid-owner 0 -j ACCEPT` — the address carries its prefix length, the
# protocol is named, and the module follows the match criteria. A pattern
# written against the rendered file's spelling would not match, and a pattern
# written against a guess would not either.
[ "$(printf '%s\n' "$ruleset" \
    | grep -c -- '-A guarden-svc -d 127.0.0.1/32 -p tcp -m owner --uid-owner 0 -j ACCEPT')" = 1 ] \
    || _fail "root's publication accept is not in the enforced chain"

# --- the decision, part 3: the DENY still refuses root's query --------------

# **This is the assertion that could not be written under the other answer.**
#
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

# **Root sends one datagram to the stub.** `nc -u -w1` writes a two-byte
# header to a UDP socket; the stub does not answer a malformed query, and it
# does not have to: what is under test is whether the PACKET was refused by
# the deny, and the deny's counter answers that whether or not a reply came
# back.
run nc -u -w1 127.0.0.53 53 || true

after=$(deny_packets)
printf 'MEASURE: ROOT_RESOLVER_DENY_COUNTER=%s->%s\n' "$before" "$after" >&2

# **The counter MOVED, so the deny refused root's resolver query.** Under the
# other answer — root holding a stub accept — this counter would NOT move, and
# this file would fail. That is what makes the assertion able to tell the two
# decisions apart, which is the whole of what ticket 303 asked for.
[ "$after" != "$before" ] \
    || _fail "root's datagram to 127.0.0.53:53 was not refused by the loopback deny: root appears to hold a stub accept"

# **The service uid's query is a DIFFERENT answer, and it is the whole point
# of the service accepts.** The same datagram from the service uid does NOT
# meet the deny: the accept above it takes the packet. So the decision is not
# "root and the services are the same" — it is "the services are named and
# root is not", which is what the accept set has always said.
#
# **The measurement is the COUNTER and not the exit code of a resolver
# query.** A `getent hosts <name>` answers "the name did not resolve" for at
# least three different reasons — the deny refused the query, the stub
# refused the query, and the host has no working upstream at all — and the
# exit code cannot tell them apart. The deny's own packet counter is
# unambiguous: it moves when the deny took the packet and not otherwise.
svc_home=/var/lib/guarden/services/shelf-staging/home
run_in "$svc_home" setpriv --reuid=shelf-staging --regid=shelf-staging \
    --clear-groups env -u OLDPWD HOME="$svc_home" PWD="$svc_home" \
    sh -c "printf '\x00\x00' | nc -u -w1 127.0.0.53 53" || true

after_service=$(deny_packets)
printf 'MEASURE: SERVICE_RESOLVER_DENY_COUNTER=%s->%s\n' "$after" "$after_service" >&2
[ "$after_service" = "$after" ] \
    || _fail "the service uid's resolver query met the deny, so the accepts are not above it"

# --- the assertion is not vacuous: it FAILS under the other answer -----------

# **A test that would pass under both answers proves nothing, and ticket 303
# says so by name.** Every assertion above states the DECISION — root is not in
# the resolver's accept set, and the deny refuses root's query — and the way to
# show an assertion is not vacuous is to change the behaviour and watch it fail.
#
# **So this file changes the behaviour, on the running host, and asserts that
# its own assertions go RED.** The other answer is implemented by hand: the
# uid-0 resolver accept is added to the INSTALLED set, above the deny, exactly
# as the renderer would have written it, and the firewall is reloaded. Then the
# two measurements are repeated:
#
#   * root's datagram to the resolver must NOT move the deny's counter — it is
#     ACCEPTED now, and this is what the file asserted it was NOT;
#   * the enforced chain must now CARRY a uid-0 accept at the resolver.
#
# **Both must fail, and they are asserted to fail** — a demonstration that the
# mutation did not take would leave the whole non-vacuity claim unproven. The
# installed set is restored and reloaded afterwards, so the host is left as it
# was found and the file's own closing assertions still hold.
#
# **This mutates the INSTALLED set and not the rendered one.** The rendered
# file is what guarden intends and the installed set is what the box enforces;
# the demonstration is about the box, and editing the rendered file would leave
# the file and the kernel disagreeing for the rest of the run.
backup="$GUARDEN_FIXTURES/50-services.conf.bak"
cp "$conf" "$backup"
cleanup_restore() {
    cp "$backup" "$conf" 2>/dev/null || true
    systemctl restart guarden-firewall.service >/dev/null 2>&1 || true
}
trap cleanup_restore EXIT

# The other answer, in the renderer's own dialect: the two uid-0 accepts at
# the resolver, above the deny, in the same place the service uid's pair sits.
sed -i 's|^    mod owner uid-owner 0 daddr 127.0.0.1 proto tcp jump ACCEPT;$|&\n    mod owner uid-owner 0 daddr 127.0.0.53 proto udp dport 53 jump ACCEPT;\n    mod owner uid-owner 0 daddr 127.0.0.53 proto tcp dport 53 jump ACCEPT;|' \
    "$conf"
[ "$(grep -c 'mod owner uid-owner 0 daddr 127.0.0.53' "$conf" || true)" = 2 ] \
    || _fail "the demonstration did not take: the uid-0 resolver accepts are not in the set"

run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service

# The enforced chain now carries them, and this is the assertion from above,
# which asserted their ABSENCE.
run iptables-legacy -S guarden-svc
assert_exit 0
mutated=$(cat "$GUARDEN_STDOUT")
[ "$(printf '%s\n' "$mutated" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner 0 ')" = 1 ] \
    || _fail "the demonstration did not take: the enforced chain has no uid-0 resolver accept"

# **And root's datagram is now ACCEPTED, so the deny's counter does NOT
# move** — which is exactly what the assertion above required it to do. This
# is the counter-assertion: the measurement is repeated under the other answer
# and the answer is the opposite one.
before_mutated=$(deny_packets)
run nc -u -w1 127.0.0.53 53 || true
after_mutated=$(deny_packets)
printf 'MEASURE: UNDER_THE_OTHER_ANSWER_ROOT_RESOLVER_DENY_COUNTER=%s->%s\n' \
    "$before_mutated" "$after_mutated" >&2
[ "$after_mutated" = "$before_mutated" ] \
    || _fail "the demonstration did not take: root's datagram still met the deny with a uid-0 accept present"

# **And the file's own absence assertion, evaluated against the mutated set,
# is now FALSE.** This is the line that makes the non-vacuity claim checkable
# rather than asserted: the condition asserted above — "the enforced chain
# carries NO uid-0 accept at the resolver" — is evaluated against a host that
# holds the other answer, and it does not hold. The count here is asserted to
# be ONE where the file's own assertion demanded ZERO.
#
# **The shape is the one `t502-service-user-root.sh` uses for its RED
# demonstration**: the mutation is asserted to have taken, and the assertion
# below states the mutated state's answer rather than the original's. A
# demonstration that did not take would leave the whole non-vacuity claim
# unproven, so it fails loudly instead.
[ "$(printf '%s\n' "$mutated" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner 0 ')" = 1 ] \
    || _fail "the file's own absence assertion did not go red under the other answer, so it is vacuous"

# The host is restored, and the restore is VERIFIED rather than assumed: a
# restore that silently failed would leave the box holding the other answer and
# every closing assertion below would be measuring that instead.
cleanup_restore
trap - EXIT
run systemctl restart guarden-firewall.service
assert_exit 0
wait_settled guarden-firewall.service
run iptables-legacy -S guarden-svc
assert_exit 0
restored=$(cat "$GUARDEN_STDOUT")
[ "$(printf '%s\n' "$restored" \
    | grep -c -- '-A guarden-svc -d 127.0.0.53/32 -p udp -m owner --uid-owner 0 ')" = 0 ] \
    || _fail "the restore did not take: the enforced chain still carries a uid-0 resolver accept"

# **And the decision holds again on the restored host**, so the file ends where
# it began: the deny refuses root's query.
before_final=$(deny_packets)
run nc -u -w1 127.0.0.53 53 || true
after_final=$(deny_packets)
printf 'MEASURE: RESTORED_ROOT_RESOLVER_DENY_COUNTER=%s->%s\n' \
    "$before_final" "$after_final" >&2
[ "$after_final" != "$before_final" ] \
    || _fail "after the restore the deny does not refuse root's resolver query"

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
# loopback open.
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
