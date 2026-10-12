#!/usr/bin/env bash
# A public ingress grant, end to end at the CLI seam (ticket 160, spec 6.2, 7.5).
#
# The subject is the mechanism, and the mechanism is one DNAT and nothing else:
# `weedr port open` writes the admin's grant into the root-owned overrides.toml,
# renders 50-services.conf whole, and the rendered rule translates the public
# port onto a loopback publication the service already holds. **There is no
# POSTROUTING masquerade anywhere in this file**, and every absence below is
# asserted rather than assumed: a masquerade written as
# `-d 127.0.0.1 --dport <pub>` matches no packet in either direction, so a render
# that carried one would be carrying a claim it cannot keep.
#
# What is asserted here is the grant and the file the mutator writes. The reach
# criterion -- a granted public port answering from off the box, which locally
# generated traffic cannot demonstrate because it never traverses PREROUTING --
# is a golden-VM criterion and the ticket says so.
#
# machine: fresh
# A real host, not a staged one. The mutator chowns every file it writes to
# `root:guarden`, so `weedr port open` needs the real gid, and a suite that
# staged `/etc/group` would be asserting a group number the machine's own
# database does not carry. The registry rows below are seeded rather than created
# by an `useradd` because identity is not this file's subject, and the trap
# leaves the machine as it was found.

. "$(dirname "$0")/lib.sh"

export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
overrides=/etc/guarden/services
tree=/var/lib/guarden/services
conf=/etc/guarden/firewall/50-services.conf
ingress=/etc/guarden/firewall/20-ingress-nat.conf

cleanup() {
    rm -rf "$tree/peer-staging" "$tree/relay-staging" \
        "$overrides/peer-staging" "$overrides/relay-staging" \
        "$registry/peer-staging.toml" "$registry/relay-staging.toml" \
        "$conf" "$ingress"
    userdel operator >/dev/null 2>&1 || :
}
trap cleanup EXIT

cleanup
# `host.admin_user` names the uid the whole OUTPUT accept set admits, and a
# converged guarden host carries an account by that name -- `soil install` records
# the invoking user there. The fixture names `operator`, so the account is here.
id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
stage_config guarden-measured.toml

# Count RULES, not the word: the file carries provenance comments that spell DNAT
# out, and a grep that matches prose reports a rule this suite never granted.
dnat_count() {
    grep -c -- 'DNAT to 127\.0\.0\.1:' "$conf" || true
}

# The two services this file grants to. Each row is what `weedr service ingest`
# writes for a manifest carrying those `ports:` entries: the request in manifest
# order, and the publication the mutator allocated for the container behind each
# one. They are seeded because the allocation is `weedr service ingest`'s work
# and nothing here is about it. Both request 8333, so the "one service at a time"
# refusal below is reachable without inventing a port for it.
seed "$registry/peer-staging.toml" \
    'service = "peer-staging"' 'workload = "peer"' 'project = "peer"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-10-03T09:00:00Z"' \
    '[ports]' 'requested = [ 8333 ]' \
    '[publication]' 'node = 20133'
seed "$tree/peer-staging/home/.guarden/service.yml" \
    'project: peer' 'units: .guarden/quadlet/' 'ports:' \
    '  - container: node' '    port: 8333'

seed "$registry/relay-staging.toml" \
    'service = "relay-staging"' 'workload = "relay"' 'project = "relay"' \
    'environment = "staging"' 'uid = 1102' 'created = "2026-10-03T09:00:00Z"' \
    '[ports]' 'requested = [ 8333, 8443 ]' \
    '[publication]' 'core = 20134' 'relay = 20135'
seed "$tree/relay-staging/home/.guarden/service.yml" \
    'project: relay' 'units: .guarden/quadlet/' 'ports:' \
    '  - container: core' '    port: 8333' \
    '  - container: relay' '    port: 8443'

# `weedr port list` first: the reachable surface of the host before anything is
# granted, and the JSON field set spec 1.2 closes at `services` with exactly
# `name`, `requested`, `granted` and `pending` per service. Both services asked
# and neither was granted, which is the state a poke leaves behind.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr port list
assert_exit 0
assert_stdout_has "peer-staging"
assert_stdout_has "8333"

run weedr port list --json
assert_exit 0
assert_stdout_lines 1
assert_json services.0.name '"peer-staging"'
assert_json services.0.requested "[8333]"
assert_json services.0.granted "[]"
assert_json services.0.pending "[8333]"
assert_json services.1.name '"relay-staging"'
assert_json services.1.requested "[8333,8443]"
assert_json services.1.granted "[]"
assert_json services.1.pending "[8333,8443]"
assert_json_missing services.0.uid

# A requested port with no grant is simply not forwarded, and 50-services.conf
# does not exist at all: nothing has been granted, so there is nothing to render.
# The container comes up without the port rather than with it half-working.
assert_file_missing "$conf"

# The refusal that matters most, and it is exit 2: a port no manifest requested
# may not be granted at all. The manifest asks and the admin decides, and neither
# can do the other's job -- and a grant with no request behind it names no
# container, so the renderer would have nothing to translate onto.
run weedr port open peer-staging 9999/tcp
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "9999"
assert_stderr_has "ports:"
assert_stderr_has "container"
assert_file_missing "$overrides/peer-staging/overrides.toml"
assert_file_missing "$conf"

# There is no private/public grant and no bare-port shorthand. A grant is a
# translation to a publication, so there is no bind for "private" to describe,
# and the protocol belongs to the rule.
run weedr port open peer-staging public:8333/tcp
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "private or public grant"

run weedr port open peer-staging private:8333/tcp
assert_exit 2
assert_one_diagnostic "error:"

run weedr port open peer-staging 8333
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "PORT/PROTO"

run weedr port open peer-staging 8333/sctp
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "tcp or udp"

run weedr port open peer-staging nonsense/tcp
assert_exit 2
assert_one_diagnostic "error:"

# The grant. It creates the admin's file where there was none, adds the port to
# `[ports] open`, and prints the diff before installing -- so what changed is
# readable in the terminal that made the change.
run weedr port open peer-staging 8333/tcp
assert_exit 0
assert_stdout_has "50-services.conf"
assert_stdout_has "127.0.0.1:20133"
assert_file_exists "$overrides/peer-staging/overrides.toml"
assert_file_has "$overrides/peer-staging/overrides.toml" 'open = ["8333/tcp"]'

# The grant is a translation and nothing else: one PREROUTING DNAT from the
# ingress interface onto the service's own loopback publication.
assert_file_has "$conf" "table nat"
assert_file_has "$conf" "chain PREROUTING"
assert_file_has "$conf" "DNAT to 127.0.0.1:20133;"

# **The absence of a masquerade is the asserted behaviour.** A nat POSTROUTING
# rule here would match no packet in either direction: the destination is local
# after the DNAT, so the packet is delivered to INPUT and never reaches
# POSTROUTING, and conntrack unwinds the translation on the reply.
# `MASQUERADE` is named bare rather than in iptables' spelling, because ferm
# spells a target `jump MASQUERADE;` and the old spelling (`-j MASQUERADE`)
# matches no output this generator can produce — an absence assertion that cannot
# fail is not an assertion. `SNAT` is spelled as ferm spells a source rewrite
# (`to-source ... jump SNAT`), so it cannot match on an unrelated substring.
assert_file_lacks "$conf" "MASQUERADE"
assert_file_lacks "$conf" "jump SNAT"
assert_file_lacks "$conf" "chain POSTROUTING"
assert_file_lacks "$conf" "to-source"

# Nothing binds a non-loopback address and a grant is never a bind: the only
# destination this file names is 127.0.0.1, and ingress.alias never appears as
# one because pasta translates to loopback before the kernel sees the packet.
assert_file_lacks "$conf" "0.0.0.0"
assert_file_lacks "$conf" "192.0.2.1"
assert_file_lacks "$conf" "jump REDIRECT"

# The rendered INPUT accept is plain, because a forwarded packet has no socket
# and an owner match there would be unreliable: the uid restriction is in OUTPUT,
# which is where the owner match works.
#
# **And it names the PUBLICATION, not the public port** (spec 7.6: "`INPUT`
# accepts the published ports plainly"). PREROUTING DNAT rewrites the destination
# PORT as well as the address, so a packet that dialled 8333 arrives at INPUT
# carrying 20133. An accept on 8333 matches no packet, the framework's INPUT
# falls through to its own drop, and the grant delivers nothing from off the box
# while the file looks healthy. This is the assertion that was wrong, and the
# render was wrong with it.
assert_file_has "$conf" "chain guarden-in"
assert_file_has "$conf" "proto tcp dport 20133 jump ACCEPT;"
guarden_in_body=$(sed -n '/chain guarden-in/,/^}/p' "$conf")
printf '%s' "$guarden_in_body" | grep -q 'dport 8333 ' &&
    _fail "guarden-in accepts the public port 8333; INPUT sees the publication"
# The public port belongs to the nat chain and the publication to this one. The
# absence has to be anchored to the ACCEPT, not to the bare dport: the nat rule
# legitimately reads `dport 8333 jump DNAT to ...` and a substring search on the
# port alone matches it, which is a false failure for a rule that is correct.
assert_file_lacks "$conf" "proto tcp dport 8333 jump ACCEPT;"

# Two mutations in a row cannot install out of order: the render is whole-file
# from the union of every grant, so the first grant is still in the second.
run weedr port open relay-staging 8443/tcp
assert_exit 0
assert_file_has "$conf" "127.0.0.1:20133"
assert_file_has "$conf" "127.0.0.1:20135"
[ "$(dnat_count)" = 2 ] || _fail "50-services.conf carries $(dnat_count) DNAT rules, expected 2"

# A rule two services asked for renders once. Deduplication is a property of the
# set: the render is a pure function of the union, so re-running a grant already
# in force cannot add a second copy of its rule.
run weedr port open peer-staging 8333/tcp
assert_exit 0
assert_stdout_has "already granted"
[ "$(dnat_count)" = 2 ] || _fail "a re-granted port rendered $(dnat_count) DNAT rules, expected 2"

# A public port goes to one service at a time, and the holder is named. Both
# services requested 8333, the publication range is shared, and the second grant
# is refused with the service already holding it.
run weedr port open relay-staging 8333/tcp
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "peer-staging"
assert_stderr_has "8333/tcp"
assert_file_lacks "$overrides/relay-staging/overrides.toml" "8333/tcp"
[ "$(dnat_count)" = 2 ] || _fail "a refused grant still changed the rendered set"

# A udp grant of the same number is a different rule and a different nat line,
# so it is allowed: the edge's own file carries 443/tcp and 443/udp for exactly
# this reason.
run weedr port open peer-staging 8333/udp
assert_exit 0
assert_file_has "$conf" "proto udp dport 8333 DNAT to 127.0.0.1:20133;"
[ "$(dnat_count)" = 3 ] || _fail "a udp grant of the same number did not render its own rule"
# The udp grant lands in the filter table too, on the same publication: one
# container, two protocols, two nat lines and two accepts.
assert_file_has "$conf" "proto udp dport 20133 jump ACCEPT;"

# `weedr port list` is the reachable surface of the host in one command, and a
# pending request is sticky: it stays pending until an admin grants it or the
# manifest drops it.
run weedr port list
assert_exit 0
assert_stdout_has "GRANTED"
assert_stdout_has "PENDING"

run weedr port list --json
assert_exit 0
# **`granted` is a set of port NUMBERS, not of grants.** peer-staging holds
# 8333/tcp and 8333/udp and this reads `[8333]`: two grants of one number are
# two rules in the firewall and one port in the reachable surface, and a listing
# naming it twice would report a port the operator granted once.
assert_json services.0.granted "[8333]"
assert_json services.0.pending "[]"
assert_json services.1.granted "[8443]"
assert_json services.1.pending "[8333]"

# Closing removes the forwarding rule and leaves nothing orphaned. The
# publication is not the grant's to release: it belongs to the container, which
# the manifest still names, so it stays in the registry.
run weedr port close peer-staging 8333/udp
assert_exit 0
# Anchored to the udp protocol: 8333/tcp is still granted, and tcp and udp are
# two rules over one port number, so a bare `dport 8333` search would match the
# tcp rule that is required to survive this close.
assert_file_lacks "$conf" "proto udp dport 8333 DNAT to 127.0.0.1:20133"
assert_file_lacks "$conf" "proto udp dport 20133 jump ACCEPT;"

run weedr port close peer-staging 8333/tcp
assert_exit 0
assert_file_lacks "$overrides/peer-staging/overrides.toml" "8333"
assert_file_has "$registry/peer-staging.toml" "node = 20133"
# relay-staging never holds 8333/tcp: its request was refused at the grant above,
# where two services asking for one number is one rule and the holder is named.
# This close is asserted through the service's own override file and the
# registry's node line below.

# A close of something that was never granted is the requested state already
# true: exit 0, and a line saying so rather than a failure.
run weedr port close peer-staging 8333/tcp
assert_exit 0
assert_stdout_has "not granted"

# `50-services.conf` is disjoint from `20-ingress-nat.conf`: the edge's three
# forwarding rules are soil's, and a grant cannot reach that file or the
# publication behind them.
seed "$ingress" \
    'table nat' 'chain PREROUTING {' '' \
    "    if eth0 proto tcp dport 443 DNAT to 127.0.0.1:20007;"
run weedr port open relay-staging 8443/tcp
assert_exit 0
assert_file_lacks "$conf" "dport 443"
assert_file_lacks "$ingress" "dport 8443"
assert_file_lacks "$ingress" "guarden-in"
assert_file_lacks "$conf" "20007"

# A grant reaches none of the structural guarantees. SSH is in 00-ssh.conf, a
# root-owned seed-once file outside the services file entirely, and INPUT is
# soil's skeleton: a grant renders nothing into either, so no manifest can move
# the SSH accept or disable a failsafe. There is no failsafe to disable --
# guarden has none -- but nothing here may claim one, either.
# **The SSH accept is not observable here, and the assertion says so rather than
# pretending otherwise.** 00-ssh.conf is written by `soil firewall`, which this
# suite never runs — measured in a VM: the file does not exist, so asserting on it
# failed. What IS observable is the half that matters for a grant: the services
# file carries no INPUT chain of its own, because a grant is a DNAT and the INPUT
# set is soil's skeleton in 10-framework.conf. A grant that moved the SSH accept
# or wrote a policy would have to write one of these lines, and none appears.
assert_file_lacks "$conf" "chain INPUT"
assert_file_lacks "$conf" "policy"

# A service that does not exist has nothing to grant, and that is the host not
# being in the assumed state rather than a rejected input.
run weedr port open ghost-staging 8333/tcp
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "ghost-staging"

# The grant is the admin's file and the admin's act: nothing was written inside
# the service's own tree, which is 0700 to the service and holds no firewall.
assert_file_missing "$tree/peer-staging/50-services.conf"
assert_file_missing "$tree/relay-staging/50-services.conf"