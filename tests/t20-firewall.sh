#!/usr/bin/env bash
# soil firewall: the two files it owns, the three rules it forwards, and the
# timer that gets an operator back in.
#
# The masquerade is the part worth pinning. An earlier revision of these
# documents required a `nat POSTROUTING` masquerade on the grounds that without
# it the forwarding delivered nothing; that was false, a rule written as
# `-d 127.0.0.1 --dport <pub> -j MASQUERADE` matches no packet in either
# direction, and the requirement was removed rather than kept as a harmless
# superstition. A render that carried it would be carrying a claim it cannot
# keep.

. "$(dirname "$0")/lib.sh"
scratch_host

# A fresh Ubuntu ships ufw installed and enabled, and two policies on one box is
# one too many -- so the phase has to turn it off rather than route around it.
mkdir -p "$GUARDEN_FIXTURES/systemd"
say "$GUARDEN_FIXTURES/systemd/ufw.service.enabled" "enabled"
say "$GUARDEN_FIXTURES/systemd/ufw.service.active" "active"

run soil firewall --check
assert_exit 1
assert_stderr_has "drift: the distribution's own firewall is disabled"

run soil firewall --apply
assert_exit 0
assert_called "systemctl disable --now ufw.service"
assert_not_called "systemctl start guarden-firewall-deadman.timer"
assert_file_exists "$(host etc/guarden/firewall/10-framework.conf)"
assert_file_exists "$(host etc/guarden/firewall/20-ingress-nat.conf)"
assert_file_exists "$(host etc/systemd/system/guarden-firewall.service)"
assert_file_exists "$(host etc/systemd/system/guarden-firewall-deadman.timer)"

# 10-framework.conf is the skeleton, and it carries the ingress interface's
# route_localnet because that is the whole requirement for the forwarding to
# work at all.
assert_file_has "$(host etc/guarden/firewall/10-framework.conf)" "route_localnet is scoped to eth0"
assert_file_has "$(host etc/guarden/firewall/10-framework.conf)" "/etc/sysctl.d/90-guarden.conf"
assert_file_has "$(host etc/guarden/firewall/10-framework.conf)" "30-services.conf"

# A fresh host has no edge installed, so it has no ingress: a module that has
# not been added contributes nothing and no publication is invented.
assert_no_firewall_rule "$(host etc/guarden/firewall/20-ingress-nat.conf)"

# The three rules, once the gate module is enabled and the edge's publication
# exists. The publication is read from the registry and never assumed, because
# it is allocated from `ingress.publication_range`.
seed "$GUARDEN_HOST/usr/lib/guarden/modules/gate/module.toml" \
    'name = "gate"' \
    '[[services]]' 'service = "traefik-production"' \
    'ingress = [ "80/tcp", "443/tcp", "443/udp" ]' 'api = true'
seed "$GUARDEN_HOST/var/lib/guarden/registry/traefik-production.toml" \
    'name = "traefik-production"' '[publication]' 'port = 20000'
run soil firewall --apply
assert_exit 0
assert_file_has "$(host etc/guarden/firewall/20-ingress-nat.conf)" \
    "[ 'i eth0' 'p tcp' '--dport 80' ] -j DNAT --to-destination 127.0.0.1:20000"
assert_file_has "$(host etc/guarden/firewall/20-ingress-nat.conf)" \
    "[ 'i eth0' 'p tcp' '--dport 443' ] -j DNAT --to-destination 127.0.0.1:20000"

# 443/udp is HTTP/3, and it is a different protocol and a different nat rule:
# three forwarding rules, not two.
assert_file_has "$(host etc/guarden/firewall/20-ingress-nat.conf)" \
    "[ 'i eth0' 'p udp' '--dport 443' ] -j DNAT --to-destination 127.0.0.1:20000"

# No masquerade, in any form a rule could take.
assert_file_lacks "$(host etc/guarden/firewall/20-ingress-nat.conf)" "-j MASQUERADE"
assert_file_lacks "$(host etc/guarden/firewall/20-ingress-nat.conf)" "CHAIN=POSTROUTING"
assert_file_lacks "$(host etc/guarden/firewall/20-ingress-nat.conf)" "--to-source"

# The alias never appears in a firewall rule. Pasta maps the gateway, so a
# connection is addressed to 127.0.0.1 by the time the kernel's packet path sees
# it, and a rule matching the alias would match nothing.
assert_file_lacks "$(host etc/guarden/firewall/20-ingress-nat.conf)" "192.0.2.1"
assert_file_lacks "$(host etc/guarden/firewall/10-framework.conf)" "192.0.2.1"

# The edge's API is a control surface, not ingress: it is restricted to
# `host.admin_user` and never forwarded, so a module's `api = true` contributes
# no rule -- and the three rules above are the only ones in the file.
assert_rule_count "$(host etc/guarden/firewall/20-ingress-nat.conf)" 3

# 30-services.conf is the mutator's, and this phase does not write it.
assert_file_missing "$(host etc/guarden/firewall/30-services.conf)"

# The dead-man timer is armed only by the flag, and it lasts fifteen minutes and
# opens the firewall when it fires: stopping ferm and putting the
# distribution's own firewall back is the only posture that is reliably "you can
# ssh back in".
run soil firewall --apply --deadman
assert_exit 0
assert_called "systemctl start guarden-firewall-deadman.timer"
assert_file_has "$(host etc/systemd/system/guarden-firewall-deadman.timer)" "OnActiveSec=15min"
assert_file_has "$(host etc/systemd/system/guarden-firewall-deadman.service)" \
    "stop guarden-firewall.service"
assert_file_has "$(host etc/systemd/system/guarden-firewall-deadman.service)" \
    "enable --now ufw.service"

# An armed timer is drift for a plain check, because a timer that outlives its
# drill is a surprise rather than a safety net, and nothing about it is the state
# a converge should leave behind.
run soil firewall --check
assert_exit 1
assert_stderr_has "drift: the dead-man timer is not armed"

# And a plain apply disarms it, so it cannot be left armed.
run soil firewall --apply
assert_exit 0
assert_called "systemctl stop guarden-firewall-deadman.timer"
run soil firewall --check
assert_exit 0
