#!/usr/bin/env bash
# `weedr service list` is the status command, and spec 1.2's field set is **closed**:
# an unknown field is never emitted and never read, and adding one to a program is
# a change to that table and not a compatible addition. So every one of the
# fourteen fields is present, and a field with nothing to say is null or an empty
# collection rather than absent — with the distinction the spec insists on, that
# `gate: null` is not the same as `state: "ready"`.
#
# There is no staged host here, and that is the whole of what this file changed.
# The field set is a claim about what the status command says about *this* box, and
# a staged `/etc/passwd` reconciled with a real `useradd` writing to the real one
# answers nothing: `list` would have reported a uid no account carries, and the
# snapshot counts came from a file a stand-in read rather than from snapper. So
# every number below is the machine's own — the uid the real user database
# allocated, the snapshot a real `snapper create` took, and the dates the real
# `snapper list` rendered.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. `lib.sh` puts that
# directory on PATH, and this file's subject is what the machine holds. The fake
# `useradd` numbered accounts from a counter, the fake `snapper` answered
# `list` out of a file the test wrote, and a staged `proc/sys` cannot be written
# by `sysctl -w` at all — which is how a report claimed an IPv6 warning the box
# had not earned. `.venv/bin` is kept first because it is the checkout's
# interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# `soil install` creates the group and is not this file's phase. It is load-bearing
# rather than tidiness: the registry and every `overrides.toml` are root:guarden
# and the unprivileged programs read them through it, and `users.group_id` refuses
# to write a service without it. Established here so the answer below is about
# `list` and not about whichever suite ran first.
if ! getent group guarden >/dev/null 2>&1; then
    groupadd --system guarden
fi
mkdir -p /etc/guarden
stage_config guarden.toml
stage_poke myapp 9f2c1ab

# The two host invariants the report carries are put where the design says they
# are before anything is reported, because a fresh image ships IPv6 enabled and
# the port threshold at the kernel default: a report carrying both warnings from
# its first line would say nothing about the fields. What the box had is read
# back first and written back at the end, so the machine is left the way this
# file found it.
ipv6_had=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
port_had=$(sysctl -n net.ipv4.ip_unprivileged_port_start)
run sysctl -w net.ipv6.conf.all.disable_ipv6=1
assert_exit 0
run sysctl -w net.ipv4.ip_unprivileged_port_start=1024
assert_exit 0

run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0

# The uid is the one the host's user database holds, read back rather than chosen:
# a number this file picked would be a number no account carries, and the report
# would be right about the field and wrong about the box.
production_uid=$(getent passwd myapp-production | cut -d: -f3)

# A real snapshot and a real mark, because both halves of the counts have to exist
# on the machine for the report to be a reading rather than a fixture. The
# snapshot is what the nightly timer takes, the pin file is what an operator leaves
# behind, and `weedr pin sync` is the root reconciler that turns the file into the
# `important=yes` the report counts. Nothing here writes a value for the program
# to read back, and the number and the dates below are read out of what the real
# `snapper list` rendered rather than written here.
run weedr service snapshot myapp-production
assert_exit 0
run snapper --machine-readable json --config myapp-production-data list
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/myapp-production-data.json"
run python3 "$GUARDEN_ROOT/tests/t30-list-snapshots.py" myapp-production-data \
    <"$GUARDEN_FIXTURES/myapp-production-data.json"
assert_exit 0
number=$(head -n 1 "$GUARDEN_STDOUT")
oldest=$(sed -n 2p "$GUARDEN_STDOUT")
newest=$(tail -n 1 "$GUARDEN_STDOUT")
seed /var/lib/guarden/stakes/"myapp-production:data@$number" "before the risky change"
run weedr pin sync
assert_exit 0
assert_stdout_has "marked myapp-production:data@$number"

run weedr service list --json
assert_exit 0
assert_stdout_lines 1
assert_json services.1.name '"myapp-production"'
assert_json services.1.workload '"myapp"'
assert_json services.1.project '"myapp"'
assert_json services.1.environment '"production"'
assert_json services.1.uid "$production_uid"
assert_json services.1.source '"gitops"'
assert_json services.1.deployed_sha null
assert_json services.1.publication.containers "[]"
assert_json services.1.publication.api null
assert_json services.1.edges "[]"
assert_json services.1.ports '{"requested":[],"granted":[],"pending":[]}'
assert_json services.2.gate null
assert_json services.1.volumes.0.name '"data"'
assert_json services.1.volumes.0.kind '"state"'
assert_json services.1.volumes.0.config '"myapp-production-data"'
assert_json services.1.volumes.0.snapshots.total 1
assert_json services.1.volumes.0.snapshots.marked 1
assert_json services.1.volumes.0.snapshots.oldest "\"$oldest\""
assert_json services.1.volumes.0.snapshots.newest "\"$newest\""
assert_json services.1.volumes.0.snapshots.limits.NUMBER_LIMIT '"2-10"'
assert_json services.1.volumes.0.snapshots.limits.TIMELINE_LIMIT_DAILY '"0-7"'
assert_json services.1.volumes.0.removed null

# A bulk volume has no configuration, so it has no snapshot counts either, and the
# field is present and null rather than absent. It is a subvolume on every path
# rather than a plain directory, and nothing snapshots it, which is why there is
# no configuration for `list` to ask snapper about.
assert_json services.1.volumes.1.name '"chainstate"'
assert_json services.1.volumes.1.kind '"bulk"'
assert_json services.1.volumes.1.config null
assert_json services.1.volumes.1.snapshots null
assert_json_missing services.1.volumes.1.snapshots.total
assert_json services.0.instances.0.ref '"feature-login"'
# The instance is forked from the workload's staging service as an internal step
# of the create (spec 5.3 step 12), so its seed names the snapshot it was cloned
# from rather than sitting empty.
assert_json services.0.instances.0.seed.data.service '"myapp-staging"'
assert_json services.0.instances.0.seed.data.volume '"data"'
assert_json services.0.volumes.0.config '"myapp-preview-feature\\x2dlogin-data"'

# The field set is closed, so a field that is not in it is not there. `removed` is
# not: a removed service has no registry entry for an object to hang on, and the
# human report is where the removed directory belongs.
assert_json_missing removed
assert_json_missing services.1.host
assert_json_missing services.1.free_limit

# A gate that has never been evaluated is null, and null is not `ready`.
assert_stdout_lacks '"state":"ready"'

# The human report. It carries the two host invariants, and both are reported and
# corrected by nobody here: `soil sysctl` converges the port threshold, and only
# the operator who changed it can put it back.
run weedr service list
assert_exit 0
assert_stdout_has "myapp-production  workload myapp  project myapp  track production  uid $production_uid"
assert_stdout_has "myapp-production-data  1 snapshots, 1 marked"
assert_stdout_has "NUMBER_LIMIT 2-10, NUMBER_LIMIT_IMPORTANT 8-12"
assert_stdout_has "instance       feature-login"
assert_stdout_has "gate           not evaluated"
assert_stdout_lacks "IPv6 has been re-enabled"
assert_stdout_lacks "ip_unprivileged_port_start"

# Both invariants, when the box is outside the design. These are the machine's own
# knobs, written with `sysctl`, because this harness runs as root on a throwaway
# VM and the file under /proc/sys is the kernel's rather than a test's to overwrite.
# What the box had was read back above and is written back below.
run sysctl -w net.ipv6.conf.all.disable_ipv6=0
assert_exit 0
run sysctl -w net.ipv4.ip_unprivileged_port_start=0
assert_exit 0
run weedr service list
assert_exit 0
assert_stdout_has "warning: IPv6 has been re-enabled"
assert_stdout_has "warning: net.ipv4.ip_unprivileged_port_start is 0, not 1024"
run weedr service list --json
assert_exit 0
assert_json services.1.warnings.0 '"warning: IPv6 has been re-enabled; every rule guarden renders is IPv4"'
assert_json services.1.warnings.1 '"warning: net.ipv4.ip_unprivileged_port_start is 0, not 1024, so an unprivileged process may bind a privileged port"'

# A sysctl that cannot be read is said to be unreadable rather than assumed fine.
# A bind mount of an empty directory over the directory that holds the knob is what
# makes the read fail; the kernel's own /proc/sys entry is never unlinked, and
# `unhide_sysctl` puts the machine's own directory back exactly as it was found.
hide_sysctl /proc/sys/net/ipv6/conf/all/disable_ipv6
run weedr service list
assert_exit 0
assert_stdout_has "warning: could not read"

unhide_sysctl /proc/sys/net/ipv6/conf/all/disable_ipv6
# The knob is the machine's own again, read from the machine: a bind left in place
# would still let `sysctl -w` succeed, writing into the empty directory under it.
run cat /proc/sys/net/ipv6/conf/all/disable_ipv6
assert_exit 0
run sysctl -w "net.ipv6.conf.all.disable_ipv6=$ipv6_had"
assert_exit 0
run sysctl -w "net.ipv4.ip_unprivileged_port_start=$port_had"
assert_exit 0

# The removed directory is reported, and a volume that has been moved aside says
# where it went — which is how a restore is found without remembering a path.
run weedr service remove myapp-staging
assert_exit 0
run weedr service list
assert_exit 0
assert_stdout_has "removed:"
assert_stdout_has "myapp-staging"

# The generated values table: a value guarden minted rather than one a human
# planted, recorded once at minting because after that the two are
# indistinguishable. No key is generated for a gated track, where a missing key is
# a gate failure and generating one would hide it.
run weedr service list --json
assert_exit 0
assert_json_missing services.1.generated
