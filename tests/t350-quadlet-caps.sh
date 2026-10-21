#!/usr/bin/env bash
# A resource cap in a hand-written quadlet unit (ticket 350, spec 4 and spec 6.3).
#
# **One rule, two vocabularies, and only one of them held.** Ticket 272 refused a
# cap on the repository's Compose declaration — `mem_limit:`, `cpus:`,
# `pids_limit:`, `ulimits:`, `deploy.resources.*` — and a repository that ships
# units writes the same statement in quadlet's tables: `[Container] Memory=`,
# `PidsLimit=` or `Ulimit=`, or `[Service] MemoryMax=`, `CPUQuota=`, `TasksMax=`,
# `LimitNOFILE=`. None of those is a key the renderer owns, so each reached the
# generated unit verbatim and really capped the container, with nothing said. The
# refusal is the same rule in the other vocabulary, checked on the repository's
# own unit source with exit `2` before the unit is generated.
#
# **The key list is measured, not remembered** (the ticket's point 3). Ticket
# 272's first list carried `DefaultMemoryLow=`, `DefaultStartupMemoryLow=`,
# `MemoryPressureWatch=` and `DefaultTasksMax=`, none of which is a per-unit
# setting — a refusal of a key that cannot appear refuses nothing while reading
# like a refusal. So every key this suite asserts a refusal for is asked of the
# machine — documented in `podman-systemd.unit(5)`'s `[Container]` table, or in
# `systemd.resource-control(5)`/`systemd.exec(5)` AND accepted in a `[Service]`
# section by `systemd-analyze verify`, which is the machine's own parser. The
# `DefaultTasksMax=` case below is the same oracle saying no, so a green run is
# not a check that cannot fail.
#
# **The admin's drop-in is the other half of the rule.** A cap is the operator's,
# and `/etc/containers/systemd/users/<uid>/<unit>.container.d/` is the only place
# one is granted: `refuse_directives` reads the repository's source and `_dropins`
# merges the admin's file after it, on a copy. The last section asserts a
# drop-in's `[Service] MemoryMax=` still lands in the generated unit, because a
# refusal that caught the drop-in would take away the answer it points at.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged unit source, registry row,
# drop-in and rendered unit is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`.
# The unit source is hand-written quadlet, so no converter is driven and no fetch
# happens; `man` and `systemd-analyze` are the machine's own tools.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: app" "units: .guarden/quadlet/"
unit_source=$project/.guarden/quadlet/web.container

# --- the [Container] caps: quadlet's own table -------------------------------
#
# None of the three is a key the renderer owns, so each landed in the generated
# unit as written: `Memory=` caps the memory, `PidsLimit=` the pids, `Ulimit=`
# the process limits — the same three statements as `mem_limit:`, `pids_limit:`
# and `ulimits:` in the Compose vocabulary.
refuse_container() {
    local key=$1 value=$2
    seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27" "$key=$value"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$key"
    # The container is named too, because the container and the key are the two
    # facts somebody needs to fix it.
    assert_stderr_has "'web'"
    # The owner is named, because "not allowed" is not actionable and the
    # operator's drop-in is where the answer lives.
    assert_stderr_has "drop-in"
    # And the refusal is guarden's: a hand-written unit drives no converter.
    assert_stderr_lacks "podlet"
}

refuse_container Memory 2g
refuse_container PidsLimit 512
refuse_container Ulimit nofile=1024:2048

# --- the [Service] caps: systemd's resource controls ------------------------
#
# `_service_keys` writes the track's `CPUWeight=`/`IOWeight=` and then the
# source's own `[Service]` keys beside them, so every key below reached the
# generated scope. The rows are the values the machine parses for each key; the
# loop below re-asks the machine whether the key is a `[Service]` setting at all.
SERVICE_CAP_ROWS=(
    "CPUQuota=50%"
    "CPUQuotaPeriodSec=100ms"
    "AllowedCPUs=0"
    "StartupAllowedCPUs=0"
    "AllowedMemoryNodes=0"
    "StartupAllowedMemoryNodes=0"
    "IODeviceWeight=/dev/null 100"
    "IODeviceLatencyTargetSec=/dev/null 10ms"
    "IOReadBandwidthMax=/dev/null 1M"
    "IOWriteBandwidthMax=/dev/null 1M"
    "IOReadIOPSMax=/dev/null 100"
    "IOWriteIOPSMax=/dev/null 100"
    "MemoryMin=1M"
    "MemoryLow=1M"
    "StartupMemoryLow=1M"
    "MemoryHigh=2M"
    "StartupMemoryHigh=2M"
    "MemoryMax=3M"
    "StartupMemoryMax=3M"
    "MemorySwapMax=1M"
    "StartupMemorySwapMax=1M"
    "MemoryZSwapMax=1M"
    "StartupMemoryZSwapMax=1M"
    "MemoryZSwapWriteback=no"
    "TasksMax=100"
    "LimitAS=1G"
    "LimitCORE=1G"
    "LimitCPU=100"
    "LimitDATA=1G"
    "LimitFSIZE=1G"
    "LimitLOCKS=100"
    "LimitMEMLOCK=64M"
    "LimitMSGQUEUE=64K"
    "LimitNICE=10"
    "LimitNOFILE=1024"
    "LimitNPROC=100"
    "LimitRSS=1G"
    "LimitRTPRIO=10"
    "LimitRTTIME=1000"
    "LimitSIGPENDING=100"
    "LimitSTACK=8M"
)

# The weights that survive, and the one OOM key. `CPUWeight=` and `IOWeight=`
# are deliberately absent from every list here: `_service_keys` overwrites them
# with the track's weight, so a source's value never reaches the unit — the
# exemption the ticket says to keep, asserted as bytes below.
SERVICE_WEIGHT_ROWS=( "StartupCPUWeight=5" "StartupIOWeight=5" )
SERVICE_OOM_ROWS=( "OOMScoreAdjust=500" )

refuse_service() {
    local key=$1 value=$2 answer=$3
    seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27" \
        "" "[Service]" "$key=$value"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$key"
    assert_stderr_has "'web'"
    assert_stderr_has "$answer"
    assert_stderr_lacks "podlet"
}

for row in "${SERVICE_CAP_ROWS[@]}"; do
    refuse_service "${row%%=*}" "${row#*=}" "drop-in"
done
# A weight is the track's, so its answer is the other file — a refusal that
# pointed a weight at a drop-in would point at a file that cannot answer it.
for row in "${SERVICE_WEIGHT_ROWS[@]}"; do
    refuse_service "${row%%=*}" "${row#*=}" "guarden.toml"
done
for row in "${SERVICE_OOM_ROWS[@]}"; do
    refuse_service "${row%%=*}" "${row#*=}" "drop-in"
done

# --- the measurement: every key asked of the machine ------------------------
#
# The lists above are only worth what the machine says about them, so each key
# is checked against the pages the ticket names and each `[Service]` key against
# the parser that would read it. `DefaultTasksMax=` is the control: it is not a
# `[Service]` setting, the parser says so, and if the parser said nothing this
# suite would be pinning a list nobody measured.
pages=$GUARDEN_FIXTURES/man-pages
mkdir -p "$pages"
MANWIDTH=200 man -P cat podman-systemd.unit >"$pages/podman-systemd.unit" 2>/dev/null \
    || _fail "podman-systemd.unit(5) is not installed, so the [Container] keys cannot be measured"
MANWIDTH=200 man -P cat systemd.resource-control >"$pages/systemd.resource-control" 2>/dev/null \
    || _fail "systemd.resource-control(5) is not installed, so the [Service] keys cannot be measured"
MANWIDTH=200 man -P cat systemd.exec >"$pages/systemd.exec" 2>/dev/null \
    || _fail "systemd.exec(5) is not installed, so the Limit keys cannot be measured"
sed -n '/^Container units \[Container\]/,/^Pod units \[Pod\]/p' \
    "$pages/podman-systemd.unit" >"$pages/container-section"
cat "$pages/systemd.resource-control" "$pages/systemd.exec" >"$pages/service-pages"

for key in Memory PidsLimit Ulimit; do
    # A key quadlet documents is a key quadlet will emit; one it does not is a
    # refusal that would never fire.
    grep -qE "^   $key=" "$pages/container-section" \
        || _fail "quadlet's [Container] table does not document $key="
done

probe=$GUARDEN_FIXTURES/probe.service
verdict=$GUARDEN_FIXTURES/verify.txt
for row in "${SERVICE_CAP_ROWS[@]}" "${SERVICE_WEIGHT_ROWS[@]}" "${SERVICE_OOM_ROWS[@]}"; do
    key=${row%%=*}
    value=${row#*=}
    grep -qE "(^|[, ])$key=" "$pages/service-pages" \
        || _fail "neither systemd.resource-control(5) nor systemd.exec(5) documents $key="
    seed "$probe" "[Unit]" "Description=probe" "" "[Service]" "ExecStart=/bin/true" \
        "$key=$value"
    systemd-analyze verify "$probe" >"$verdict" 2>&1 || true
    if grep -qF "Unknown key '$key'" "$verdict"; then
        _fail "$key= is not a [Service] setting, so refusing it refuses nothing"
    fi
done

# The control: the same question, asked about a name that only looks like one.
seed "$probe" "[Unit]" "Description=probe" "" "[Service]" "ExecStart=/bin/true" \
    "DefaultTasksMax=100"
systemd-analyze verify "$probe" >"$verdict" 2>&1 || true
grep -qF "Unknown key 'DefaultTasksMax'" "$verdict" \
    || _fail "systemd-analyze did not report DefaultTasksMax as unknown, so the measurement proves nothing"

# --- what is NOT refused -----------------------------------------------------
#
# A refusal list that refused everything would pass every assertion above and
# prove nothing. A unit stating no cap renders, and the track's weight still
# reaches it.
registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/app-production.toml" \
    'service = "app-production"' 'workload = "app"' 'project = "app"' \
    'environment = "production"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"'

out=$GUARDEN_FIXTURES/render
unit=$out/units/web.container
seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "" "[Service]" "Restart=always"
run loom render "$project" --service app-production --out "$out"
assert_exit 0
assert_stderr_empty
assert_file_has "$unit" "Restart=always"
assert_file_has "$unit" "CPUWeight=1000"

# **`[Service] CPUWeight=` is the exemption, and it is the same question.** The
# source's weight is not refused and not carried: `_service_keys` writes the
# track's over it. The bytes are what say so — a refusal here would refuse a key
# that cannot reach the unit, and a pass-through would give the repository a
# priority the track owns.
seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27" \
    "" "[Service]" "CPUWeight=5" "IOWeight=5"
run loom render "$project" --service app-production --out "$out"
assert_exit 0
assert_stderr_empty
assert_file_has "$unit" "CPUWeight=1000"
assert_file_lacks "$unit" "CPUWeight=5"
assert_file_has "$unit" "IOWeight=1000"

# --- the refusal is total ----------------------------------------------------
#
# `loom render` refuses the same declaration and the out directory is never
# created: a refusal that had already written half a unit set would be the
# partial render the lock in spec 3.5 exists to prevent.
seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27" "Memory=2g"
refused=$GUARDEN_FIXTURES/refused-render
run loom render "$project" --service app-production --out "$refused"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "Memory"
assert_file_missing "$refused"

# --- the admin's drop-in still grants a cap ---------------------------------
#
# This is the half that must keep working (ticket 40's acceptance list): the
# drop-in is merged after the source's refusals have run, on a copy, so
# `[Service] MemoryMax=` and `MemoryHigh=` reach the generated scope. A
# repository cannot state a cap and an operator still can, which is the whole of
# the rule.
seed "$unit_source" "[Container]" "Image=docker.io/library/nginx:1.27"
seed "$GUARDEN_PREFIX/etc/containers/systemd/users/1101/web.container.d/90-admin.conf" \
    "[Service]" "MemoryMax=512M" "MemoryHigh=384M"
run loom render "$project" --service app-production --out "$out"
assert_exit 0
assert_stderr_empty
assert_file_has "$unit" "MemoryMax=512M"
assert_file_has "$unit" "MemoryHigh=384M"
