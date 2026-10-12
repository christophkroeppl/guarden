#!/usr/bin/env bash
# soil sysctl: the four rules that are soil's to converge, and the alias it only
# reports.
#
# The port threshold is the one an implementer gets wrong, and spec 1.4 and
# §8.1's companion rule in SECURITY.md 2.7 both say why: the predicate is the
# value 1024 and not the distribution's default, because a base image that
# ships 0 satisfies "the default" and grants every unprivileged uid a privileged
# port while passing.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014), and both the assertions below and the programs under them have to
# reach the real `getent`, `dpkg-query`, `systemctl`,
# `snapper`, `sysctl` and `install` -- otherwise this file is asking a fake what
# it had been asked to do, which is the whole thing the rewrite exists to stop.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# assert_sysctl <key> <value>: the knob itself. A sysctl converge has nothing
# else to mean -- there is no file and no argv -- so the value the kernel holds
# afterwards is the whole of the outcome.
assert_sysctl() {
    local actual
    actual=$(sysctl -n "$1" 2>/dev/null)
    [ "$actual" = "$2" ] || _fail "sysctl $1 is '$actual', not '$2'"
}

# route_localnet is scoped to the ingress interface, and the ingress interface
# resolves from the default route. It is read here rather than written down
# because hostprep.ingress_interface derives it the same way and nothing in the
# design fixes a name: a test that pinned eth0 would be asserting a name.
interface=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')
[ -n "$interface" ] || _fail "the default route names no interface"

# IPv6 is put back the way it was found, whatever this file does to it: a test
# that leaves the machine IPv6-disabled has changed the host for every file that
# runs after it, and the golden is shared.
ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
ipv6_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6)
restore_ipv6() {
    sysctl -q -w "net.ipv6.conf.all.disable_ipv6=$ipv6_all" >/dev/null 2>&1 || :
    sysctl -q -w "net.ipv6.conf.default.disable_ipv6=$ipv6_default" >/dev/null 2>&1 || :
}

# guarden.toml is the operator's file and this file is not the operator, so what
# the alias blocks below replace is put back at the end.
config=/etc/guarden/guarden.toml
config_saved=$GUARDEN_FIXTURES/guarden.toml.before
if [ -f "$config" ]; then
    cp "$config" "$config_saved"
fi
restore_config() {
    if [ -f "$config_saved" ]; then
        cp "$config_saved" "$config"
    else
        rm -f "$config"
    fi
}
trap 'restore_ipv6; restore_config' EXIT

# Every key starts wrong so the converge has all four to write, and the persisted
# file starts absent so that "`--check` writes no file" is about this run rather
# than about whichever file converged it before. The port threshold is put to
# 2048 and not to 0: 0 is the failure this rule exists to stop, a machine left at
# 0 grants every unprivileged uid a privileged port, and 2048 is equally
# unconverged and strictly tightening. The converge puts it back to 1024 below,
# and the last check in this file proves it.
rm -f /etc/sysctl.d/90-guarden.conf
sysctl -q -w net.ipv4.ip_unprivileged_port_start=2048
sysctl -q -w net.ipv6.conf.all.disable_ipv6=0
sysctl -q -w net.ipv6.conf.default.disable_ipv6=0
sysctl -q -w "net.ipv4.conf.$interface.route_localnet=0"

# `--check` reports and changes nothing, and names each key by its invariant.
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: net.ipv4.ip_unprivileged_port_start is 1024"
assert_stderr_has "drift: net.ipv6.conf.all.disable_ipv6 is 1"
assert_stderr_has "drift: net.ipv6.conf.default.disable_ipv6 is 1"
assert_stderr_has "drift: net.ipv4.conf.$interface.route_localnet is 1"

# It changed nothing: it read the keys and wrote no file, and the port threshold
# is still the value the test put there rather than the value the phase wants.
assert_file_missing /etc/sysctl.d/90-guarden.conf
assert_sysctl net.ipv4.ip_unprivileged_port_start 2048

# route_localnet is scoped to the ingress interface, which resolves from the
# default route, and never to conf.all.
run soil sysctl --apply
assert_exit 0
assert_file_has /etc/sysctl.d/90-guarden.conf \
    "net.ipv4.conf.$interface.route_localnet = 1"
assert_file_lacks /etc/sysctl.d/90-guarden.conf "conf.all.route_localnet"
assert_sysctl "net.ipv4.conf.$interface.route_localnet" 1
assert_sysctl net.ipv4.ip_unprivileged_port_start 1024
assert_sysctl net.ipv6.conf.all.disable_ipv6 1
assert_sysctl net.ipv6.conf.default.disable_ipv6 1

# Every firewall rule guarden writes is IPv4 only, because IPv6 is off, and a
# converged host checks clean. `default` is the key that stops a new interface
# coming up with IPv6, so it is not the one that may be left out.
run soil sysctl --check
assert_exit 0

# Raising it further is a tightening, and it converges: 1024 is the value, not
# "whatever is at least as strict".
sysctl -q -w net.ipv4.ip_unprivileged_port_start=2048
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: net.ipv4.ip_unprivileged_port_start is 1024"
run soil sysctl --apply
assert_exit 0
assert_sysctl net.ipv4.ip_unprivileged_port_start 1024

# An operator who re-enabled IPv6 is reported, and the port threshold soil owns
# is converged: one of the two is corrected and the other is only ever reported
# on the keys soil does not own.
sysctl -q -w net.ipv6.conf.all.disable_ipv6=0
run soil sysctl --check
assert_exit 1
assert_stderr_has "drift: net.ipv6.conf.all.disable_ipv6 is 1"
run soil sysctl --apply
assert_exit 0
assert_sysctl net.ipv6.conf.all.disable_ipv6 1

# The alias is derived from the host's default route and drifts with it, and
# nothing in a firewall rule may match it: pasta has already translated the
# address to 127.0.0.1 by the time the kernel sees the connection.
seed "$config" \
    '[ingress]' 'alias = "198.51.100.1"' 'publication_range = [20000, 32767]'
run soil sysctl --check
assert_exit 1
assert_stderr_has "ingress.alias is the address the default route resolves to (198.51.100.1)"

# The remedy is in the line the operator reads: re-measure with the probe, never
# edit the file by hand. Nothing in the firewall may match the alias, because
# pasta has already translated it to 127.0.0.1.
assert_stderr_has "soil install --apply"

# An empty alias is a warning rather than drift: it is `soil install` that
# measures it, and the edge refuses to start without it.
run soil sysctl --apply
assert_exit 0
seed "$config" '[ingress]' 'alias = ""'
run soil sysctl --check
assert_exit 0
# The line count is read with wc: lib.sh's assert_one_diagnostic counts with
# `grep -c`, which prints 0 for no match while exiting 1, so its `|| true` turns
# an empty stderr into a pass.
[ "$(wc -l < "$GUARDEN_FIXTURES/stderr")" = 1 ] \
    || _fail "expected exactly one warning line, got $(wc -l < "$GUARDEN_FIXTURES/stderr")"
assert_stderr_has "ingress.alias is empty"

# The persisted file holds only soil's keys, and a key in it that soil does not
# own is a key soil rewrites away. The rewrite is of the file only: soil converges
# four named knobs and does not run sysctl --system, so `forwarding` never
# reaches the kernel from here.
say /etc/sysctl.d/90-guarden.conf "net.ipv4.conf.all.forwarding = 1"
run soil sysctl --check
assert_exit 1
run soil sysctl --apply
assert_exit 0
assert_file_lacks /etc/sysctl.d/90-guarden.conf "forwarding"
