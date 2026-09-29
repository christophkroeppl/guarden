#!/usr/bin/env bash
# The fakes in fixtures/bin, one per external tool spec 11 names. A fake
# replaces a tool that would otherwise need root, a kernel, a distribution or a
# network, and its only job is to be indistinguishable at the seam and to
# record that it was called.
#
# The list is the spec's, including the distribution's package tools: a test
# that asserted on a fake that does not exist would be asserting nothing.

. "$(dirname "$0")/lib.sh"

# Identity and users: weedr service add, soil install.
assert_fake useradd
assert_fake usermod
assert_fake userdel
assert_fake loginctl
assert_fake runuser

# Containers: loom's converter, weedr service build.
assert_fake podman
assert_fake podlet

# Units: soil units, furrow and the mutator's calls.
assert_fake systemctl
assert_fake sudo

# Snapshots and storage: weedr service snapshot, weedr pin sync, soil storage.
assert_fake snapper
assert_fake btrfs
assert_fake chattr

# Credentials: weedr secret set and the materialiser.
assert_fake systemd-creds

# The network: soil firewall and soil install's alias probe.
assert_fake ferm
assert_fake iptables
assert_fake ip

# What a poke brings: hose poke.
assert_fake tar
assert_fake git

# soil packages.
assert_fake apt-get
assert_fake apt
assert_fake dpkg

# Every call lands in one log, and the log is a file under the fixture state
# rather than a shell variable, so a test can read it.
assert_called "useradd --version"
assert_called "iptables --version"
assert_file_exists "$GUARDEN_CALLS"

# Arguments are recorded, not swallowed: a fake that logged only the tool's
# name could not tell `weedr port open 8080/tcp` from `weedr port close 8080/tcp`.
fake iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT
assert_called "-p tcp --dport 8080 -j DNAT"

# A call with no arguments is still a call.
fake systemctl
assert_called "systemctl"
