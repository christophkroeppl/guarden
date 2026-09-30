#!/usr/bin/env bash
# `weedr service list` is the status command, and spec 1.2's field set is **closed**:
# an unknown field is never emitted and never read, and adding one to a program is
# a change to that table and not a compatible addition. So every one of the
# fourteen fields is present, and a field with nothing to say is null or an empty
# collection rather than absent — with the distinction the spec insists on, that
# `gate: null` is not the same as `state: "ready"`.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden.toml
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-production --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
run weedr service ingest myapp-preview/feature-login --from poke myapp@9f2c1ab
assert_exit 0

# The volumes' snapshot counts and effective retention come from snapper, read the
# one way the spec pins: `--machine-readable json`, where `userdata` is an object.
printf '%s\n' '41|number|2026-09-28 18:03:11|before the risky change|important=yes' '42|number|2026-09-29 18:03:11|nightly|' >"$GUARDEN_FIXTURES/snapper/myapp-production-data.list"

run weedr service list --json
assert_exit 0
assert_stdout_lines 1
assert_json services.1.name '"myapp-production"'
assert_json services.1.workload '"myapp"'
assert_json services.1.project '"myapp"'
assert_json services.1.environment '"production"'
assert_json services.1.uid 1000
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
assert_json services.1.volumes.0.snapshots.total 2
assert_json services.1.volumes.0.snapshots.marked 1
assert_json services.1.volumes.0.snapshots.oldest '"2026-09-28 18:03:11"'
assert_json services.1.volumes.0.snapshots.newest '"2026-09-29 18:03:11"'
assert_json services.1.volumes.0.snapshots.limits.NUMBER_LIMIT '"2-10"'
assert_json services.1.volumes.0.snapshots.limits.TIMELINE_LIMIT_DAILY '"0-7"'
assert_json services.1.volumes.0.removed null
assert_json services.1.volumes.1.name '"chainstate"'
assert_json services.1.volumes.1.kind '"bulk"'
assert_json services.1.volumes.1.config null
assert_json services.1.volumes.1.snapshots null
assert_json services.1.instances "[]"

# A bulk volume has no configuration, so it has no snapshot counts either, and the
# field is present and null rather than absent.
assert_json_missing services.1.volumes.1.snapshots.total
assert_json services.2.gate null
assert_json services.0.instances.0.ref '"feature-login"'
assert_json services.0.instances.0.seed '{}'
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
assert_stdout_has "myapp-production  workload myapp  project myapp  track production  uid 1000"
assert_stdout_has "myapp-production-data  2 snapshots, 1 marked"
assert_stdout_has "NUMBER_LIMIT 2-10, NUMBER_LIMIT_IMPORTANT 8-12"
assert_stdout_has "instance       feature-login"
assert_stdout_has "gate           not evaluated"
assert_stdout_lacks "IPv6 has been re-enabled"
assert_stdout_lacks "ip_unprivileged_port_start"

# Both invariants, when the box is outside the design.
printf '%s\n' '0' >"$GUARDEN_PREFIX/proc/sys/net/ipv6/conf/all/disable_ipv6"
printf '%s\n' '0' >"$GUARDEN_PREFIX/proc/sys/net/ipv4/ip_unprivileged_port_start"
run weedr service list
assert_exit 0
assert_stdout_has "warning: IPv6 has been re-enabled"
assert_stdout_has "warning: net.ipv4.ip_unprivileged_port_start is 0, not 1024"
run weedr service list --json
assert_exit 0
assert_json services.1.warnings.0 '"warning: IPv6 has been re-enabled; every rule guarden renders is IPv4"'
assert_json services.1.warnings.1 '"warning: net.ipv4.ip_unprivileged_port_start is 0, not 1024, so an unprivileged process may bind a privileged port"'

# A sysctl that cannot be read is said to be unreadable rather than assumed fine.
rm "$GUARDEN_PREFIX/proc/sys/net/ipv6/conf/all/disable_ipv6"
run weedr service list
assert_exit 0
assert_stdout_has "warning: could not read"

# The removed directory is reported, and a volume that has been moved aside says
# where it went — which is how a restore is found without remembering a path.
printf '%s\n' '1' >"$GUARDEN_PREFIX/proc/sys/net/ipv6/conf/all/disable_ipv6"
printf '%s\n' '1024' >"$GUARDEN_PREFIX/proc/sys/net/ipv4/ip_unprivileged_port_start"
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
