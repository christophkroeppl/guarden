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

# The machine's own tools, not the stand-ins in fixtures/bin. `lib.sh` puts that
# directory on PATH for the fake tier, and both the assertions below and the
# programs under them have to reach the real `getent`, `dpkg-query`, `systemctl`,
# `snapper`, `sysctl` and `install` -- otherwise this file is asking a fake what
# it had been asked to do, which is the whole thing the rewrite exists to stop.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# The ingress interface is the one the default route leaves by, which is where
# hostprep.ingress_interface looks when guarden.toml names none. It is read
# rather than written down because the rendered rules name it and nothing in the
# design fixes a name.
interface=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')
[ -n "$interface" ] || _fail "the default route names no interface, so there is no ingress"



# The seeded module and registry entry go on exit: a service registry entry
# that outlives the test is a phantom service on every file that runs after
# this one. There is no timer to stop, because guarden has no lockout failsafe.
cleanup() {
    rm -f /usr/lib/guarden/modules/gate/module.toml \
        /var/lib/guarden/registry/traefik-production.toml
}
trap cleanup EXIT

# This file owns the phase's starting state: a fresh distribution has no
# firewall installed (ufw is not installed by guarden). The machine is left in
# the converged state rather than put back.

# **The distribution's own apt timers are off first, and that is a precondition
# rather than tidiness.** On a host with ufw installed, `apt-daily-upgrade.service`
# runs `unattended-upgrade`, whose post-invoke hook answers `/etc/ufw/ufw.conf` by
# running `systemctl enable ufw` — measured on this golden at uptime 27.7 s for the
# service and 30.2 s for the `systemctl enable`, with the symlink created at
# 31.2 s and `ufw.service` started at 31.7 s. Since ufw is no longer installed by
# guarden, this specific race is historical, but the timers are still disabled
# because any packaging timer running on its own schedule is another writer of the
# state this phase converges. `soil packages` turns them off — spec 6.1's
# `packages` item, the same rule and the same "not enabled is enough" answer it
# applies to `snapper-cleanup.timer` — and `t20-packages.sh` is where that converge
# is asserted. This suite drives the firewall phase without the packages phase, so
# it plants the precondition the way `t20-storage.sh` plants the `guarden` group,
# and says so.
for timer in apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer; do
    systemctl disable --now "$timer" >/dev/null 2>&1 || :
done
assert_not_enabled apt-daily.timer
assert_not_enabled apt-daily-upgrade.timer
assert_not_enabled dpkg-db-backup.timer

stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run soil firewall --check
assert_exit 1
# `soil install` does not converge the firewall phase, so at this point nothing
# the phase owns exists yet and every one of its items reports drift. Asserting
# one that is genuinely absent is what proves the check is about this phase.
assert_stderr_has "drift: 10-framework.conf carries the skeleton"

run soil firewall --apply
assert_exit 0
assert_file_exists /etc/guarden/firewall/10-framework.conf
assert_file_exists /etc/guarden/firewall/20-ingress-nat.conf
assert_file_exists /etc/systemd/system/guarden-firewall.service

# 10-framework.conf is the skeleton, and it carries the ingress interface's
# route_localnet because that is the whole requirement for the forwarding to
# work at all.
assert_file_has /etc/guarden/firewall/10-framework.conf \
    "route_localnet is scoped to $interface"
assert_file_has /etc/guarden/firewall/10-framework.conf "/etc/sysctl.d/90-guarden.conf"
assert_file_has /etc/guarden/firewall/10-framework.conf "30-services.conf"

# A host with no edge installed has no ingress: a module that has not been added
# contributes nothing and no publication is invented.
# Counted as rules: the old `^\[ ` probe matched nothing ferm emits, so it passed always.
[ "$(grep -vE '^[[:space:]]*(#|$)' /etc/guarden/firewall/20-ingress-nat.conf | grep -cE '^[[:space:]]+(jump|proto|mod|ip|if|daddr|iif) ' || true)" = 0 ] \
    || _fail "a host with no edge installed renders an ingress rule"

# The three rules, once the gate module is enabled and the edge's publications
# exist. Each publication is read from the registry and never assumed, because
# it is allocated from `ingress.publication_range`: `80/tcp` lands on the
# redirect entrypoint's publication and `443/*` on the TLS one, so the two
# entrypoints have two numbers and only `443/udp` shares `443/tcp`'s.
#
# The module seeded here is the shipped one, in the shape it ships in: an
# ingress entry names the entrypoint it forwards to, because a publication is a
# loopback port a container is already listening on.
seed /usr/lib/guarden/modules/gate/module.toml \
    'name = "gate"' \
    '[[services]]' 'service = "traefik-production"' \
    'ingress = [ "web:80/tcp", "websecure:443/tcp", "websecure:443/udp" ]' 'api = true'
seed /var/lib/guarden/registry/traefik-production.toml \
    'service = "traefik-production"' '[publication]' 'web = 20000' \
    'websecure = 20001' 'api = 20002'
run soil firewall --apply
assert_exit 0
assert_file_has /etc/guarden/firewall/20-ingress-nat.conf \
    "if $interface proto tcp dport 80 DNAT to 127.0.0.1:20000"
assert_file_has /etc/guarden/firewall/20-ingress-nat.conf \
    "if $interface proto tcp dport 443 DNAT to 127.0.0.1:20001"

# 443/udp is HTTP/3, and it is a different protocol and a different nat rule:
# three forwarding rules, not two. It is served from the same TLS entrypoint, so
# it lands on that entrypoint's publication.
assert_file_has /etc/guarden/firewall/20-ingress-nat.conf \
    "if $interface proto udp dport 443 DNAT to 127.0.0.1:20001"

# Bare target words: the `-j` spelling ferm never emits asserted nothing.
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "MASQUERADE"
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "POSTROUTING"
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "REDIRECT"
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "SNAT"
# `jump DNAT to` is a ferm parse error that takes the whole firewall down.
assert_file_lacks /etc/guarden/firewall/20-ingress-nat.conf "jump DNAT"

# Every rule lands on the host's loopback and nowhere else, which is the alias
# claim stated as a fact about the file: pasta maps the gateway, so a connection
# is addressed to 127.0.0.1 by the time the kernel's packet path sees it, and a
# rule matching the alias would match nothing. Asking it of the rendered rules
# rather than of one recorded address is what makes it hold on a host whose
assert_file_lacks /etc/guarden/firewall/10-framework.conf "DNAT"
[ "$(grep -vE '^[[:space:]]*(#|$)' /etc/guarden/firewall/20-ingress-nat.conf \
    | grep -cE '^[[:space:]]+if .* DNAT to 127\.0\.0\.1:[0-9]+;$' || true)" = 3 ] \
    || _fail "a rule in 20-ingress-nat.conf translates somewhere other than the three loopback publications"

# The edge's API is a control surface, not ingress: it is restricted to
# `host.admin_user` and never forwarded, so a module's `api = true` contributes
# no rule -- and the three rules above are the only ones in the file.
assert_rule_count /etc/guarden/firewall/20-ingress-nat.conf 3

# 30-services.conf is the mutator's, and this phase does not write it.
assert_file_missing /etc/guarden/firewall/30-services.conf

# There is no lockout failsafe and no timer. SSH access is guaranteed
# structurally instead: 00-ssh.conf is root-owned and seed-once, its accept is
# the first rule of its own chain, and `soil firewall --apply` refuses to load
# any ruleset in which that is not true (t150-ssh-accept.sh). So there is
# nothing to arm, nothing to disarm, and no timer left running by a failure.
assert_file_missing /etc/systemd/system/guarden-firewall-deadman.timer
assert_file_missing /etc/systemd/system/guarden-firewall-deadman.service
assert_file_lacks /etc/systemd/system/guarden-firewall.service "Conflicts=ufw"

# A plain apply converges the firewall and leaves it up. This is the assertion
# that used to fail: the old failsafe's timer Required a unit whose only action
# was `systemctl stop guarden-firewall.service`, and that unit's ExecStop runs
# `ferm -F` -- so disarming the timer opened the firewall and every plain
# converge left the box with no rules. The unit is settled before it is read:
# its ExecStop blocks on `ferm -F`, so a restart spends real time deactivating
# and an immediate read sees the intermediate state rather than the outcome.
wait_settled guarden-firewall.service
assert_active guarden-firewall.service
run sh -c "iptables -S guarden-in"
assert_exit 0

# The service is stoppable, and stopping it tears guarden's own chains down
# rather than merely going inactive -- that is what `ferm -F` is for -- and
# starting it again puts them back.
run systemctl stop guarden-firewall.service
wait_settled guarden-firewall.service
assert_inactive guarden-firewall.service
run sh -c "iptables -S guarden-in"
assert_exit 1
run sh -c "iptables -S guarden-svc"
assert_exit 1
run systemctl start guarden-firewall.service
wait_settled guarden-firewall.service
assert_active guarden-firewall.service
run sh -c "iptables -S guarden-in"
assert_exit 0

run soil firewall --check
assert_exit 0

# The machine is left converged: the phase's own files in place, the firewall
# running, and no timer to disarm because there is none.
