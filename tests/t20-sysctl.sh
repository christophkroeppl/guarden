#!/usr/bin/env bash
# soil sysctl: the three rules that are soil's to converge, and the two
# invariants it only reports.
#
# The port threshold is the one an implementer gets wrong, and spec 1.4 and
# §8.1's companion rule in SECURITY.md 2.7 both say why: the predicate is the
# value 1024 and not the distribution's default, because a base image that
# ships 0 satisfies "the default" and grants every unprivileged uid a privileged
# port while passing.

. "$(dirname "$0")/lib.sh"
scratch_host

# A host that ships 0 is the case the check exists for, and it is the invariant
# rather than the baseline that catches it. Every key starts wrong so the
# converge has all four to write.
seed "$GUARDEN_FIXTURES/sysctl.state" \
    "net.ipv4.ip_unprivileged_port_start=0" \
    "net.ipv6.conf.all.disable_ipv6=0" \
    "net.ipv6.conf.default.disable_ipv6=0" \
    "net.ipv4.conf.eth0.route_localnet=0"

# `--check` reports and changes nothing, and names each key by its invariant.
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: net.ipv4.ip_unprivileged_port_start is 1024"
assert_stderr_has "drift: net.ipv6.conf.all.disable_ipv6 is 1"
assert_stderr_has "drift: net.ipv6.conf.default.disable_ipv6 is 1"
assert_stderr_has "drift: net.ipv4.conf.eth0.route_localnet is 1"

# It changed nothing: it read the keys and wrote no file, and it issued no write.
assert_file_missing "$(host etc/sysctl.d/90-guarden.conf)"
assert_not_called "sysctl -w"

# route_localnet is scoped to the ingress interface, which resolves from the
# default route, and never to conf.all.
run soil sysctl --apply
assert_exit 0
assert_file_has "$(host etc/sysctl.d/90-guarden.conf)" "net.ipv4.conf.eth0.route_localnet = 1"
assert_file_lacks "$(host etc/sysctl.d/90-guarden.conf)" "conf.all.route_localnet"
assert_called "sysctl -w net.ipv4.conf.eth0.route_localnet=1"
assert_called "sysctl -w net.ipv4.ip_unprivileged_port_start=1024"
assert_called "sysctl -w net.ipv6.conf.all.disable_ipv6=1"
assert_called "sysctl -w net.ipv6.conf.default.disable_ipv6=1"

# Every firewall rule guarden writes is IPv4 only, because IPv6 is off, and a
# converged host checks clean. `default` is the key that stops a new interface
# coming up with IPv6, so it is not the one that may be left out.
run soil sysctl --check
assert_exit 0

# Raising it back is a tightening, and it converges.
run soil sysctl --apply
assert_exit 0
run soil sysctl --check
assert_exit 0

# An operator who re-enabled IPv6 is reported, and the port threshold soil owns
# is converged: one of the two is corrected and the other is only ever reported
# on the keys soil does not own.
seed "$GUARDEN_FIXTURES/sysctl.state" "net.ipv6.conf.all.disable_ipv6=0"
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: net.ipv6.conf.all.disable_ipv6 is 1"

# The alias is derived from the host's default route and drifts with it, and
# nothing in a firewall rule may match it: pasta has already translated the
# address to 127.0.0.1 by the time the kernel sees the connection.
seed "$(host etc/guarden/guarden.toml)" \
    '[ingress]' 'alias = "198.51.100.1"' 'publication_range = [20000, 32767]'
run soil sysctl --check
assert_exit 1
assert_stderr_has "ingress.alias is the address the default route resolves to (198.51.100.1)"

# The remedy is in the line the operator reads: re-measure with the probe, never
# edit the file by hand. Nothing in the firewall may match the alias, because
# pasta has already translated it to 127.0.0.1.
assert_stderr_has "soil install --apply"

# A different gateway is drift too.
seed "$GUARDEN_FIXTURES/ip-route" "default via 203.0.113.9 dev ens3 proto dhcp"
seed "$(host etc/guarden/guarden.toml)" \
    '[ingress]' 'alias = "198.51.100.1"' 'publication_range = [20000, 32767]'
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift:"

# An empty alias is a warning rather than drift: it is `soil install` that
# measures it, and the edge refuses to start without it.
run soil sysctl --apply
assert_exit 0
seed "$(host etc/guarden/guarden.toml)" '[ingress]' 'alias = ""'
run soil sysctl --check
assert_exit 0
assert_one_diagnostic "warning:"
assert_stderr_has "ingress.alias is empty"

# The persisted file holds only soil's keys, and a key in it that soil does not
# own is a key soil rewrites away.
say "$(host etc/sysctl.d/90-guarden.conf)" "net.ipv4.conf.all.forwarding = 1"
run soil sysctl --check
assert_exit 1
run soil sysctl --apply
assert_file_lacks "$(host etc/sysctl.d/90-guarden.conf)" "forwarding"
