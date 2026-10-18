#!/usr/bin/env bash
# ADR-0019 end to end: guarden probes the image's declared user at first start,
# renders `UserNS=keep-id:uid=...,gid=...` into the generated unit from that
# probe alone, records it in the registry as `owner_uid`/`owner_gid` — and no
# file is ever chowned. Ticket 277's `Permission denied` is the failure this
# replaces: a non-root image user mapped into the service's subuid band, denied
# on entry, aliased on disk if it ever got through.
#
# Five claims, each where its evidence lands:
#
#   * **the write** (the ADR's headline): a service whose Containerfile sets a
#     NON-ROOT `USER`, deployed through create/ingest, started with no manual
#     chown anywhere in this file — an in-container write succeeds and the file
#     it leaves on the host is owned by the SERVICE uid, while the container
#     still sees itself as the image's uid. Nothing here chowns by construction.
#   * **create and modify, twice over**: a stop, a start, and a second process
#     appending to the first one's file — so a create-only pass cannot hide a
#     file the app phase could not modify later (the root-forced-past-the-pin
#     residual class).
#   * **the unit and the record**: the installed unit carries
#     `UserNS=keep-id:uid=10001,gid=<probed gid>` with numbers matching the
#     registry's `owner_uid`/`owner_gid`, a second start leaves the unit
#     byte-identical, an edited record is rendered through instead of
#     re-probed, and a record with the uid removed is probed again.
#   * **uid 0 and the pin, measured on podman 5.7.0**: a container started with
#     the generated line and run as root answers `/proc/self/uid_map`, the
#     running service container answers its init uid/gid and both maps, and the
#     init uid is asserted to BE the probed uid — keep-id with an explicit
#     uid= forces init to that uid, so there is no root-start phase under a pin
#     and the ADR's root-then-drop class collapses to exactly this.
#   * **the machine's own answers first**: the default map and the podman
#     version are echoed before anything is asserted about guarden, so a run
#     that stops below still carries them.
#
# Real host, real `useradd`, real subuid range, real rootless podman, real
# systemd: `GUARDEN_PREFIX=/`, as `t230-build` and `t50-slice` do.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0
run podman --version
assert_exit 0
echo "MEASURE: $(cat "$GUARDEN_STDOUT")"

# --- the service: a Containerfile that drops to a non-root uid ---------------
#
# The staged tree is written here rather than shipped as a fixture: `fixtures/`
# holds configuration inputs and manifests, and a Containerfile a suite needs
# is staged the way `t230-build` seeds one into a service's home.
staged=/var/lib/guarden/staging/kida/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: kida" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the keep-id probe container" \
    "" \
    "[Container]" \
    "Image=localhost/kid-staging:latest" \
    "Volume=data:/data"
seed "$staged/Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 10001 kiduser" \
    "USER 10001" \
    "CMD [\"sleep\", \"3600\"]"

run weedr service ingest kid-staging --from poke kida@0000001
assert_exit 0
run weedr service build kid-staging
assert_exit 0
assert_stdout_has "localhost/kid-staging:latest"

home=/var/lib/guarden/services/kid-staging/home
unit=$home/.config/containers/systemd/app.container
record=$registry/kid-staging.toml
svc_uid=$(id -u kid-staging)
assert_passwd kid-staging
assert_linger kid-staging
run grep -c "^kid-staging:" /etc/subuid
assert_exit 0
assert_stdout_has "1"

# A rootless podman as the service user reads `/run/user/<uid>`; linger is on
# and the manager comes up on its own, but the first probe is a container run
# and this is the premise it stands on, waited for rather than assumed.
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"

# One shape for "podman as this service user": the suite's own 0700 tree is
# scrubbed out of the environment the way `t50-slice` scrubs it, and USER and
# LOGNAME are named for the service — `runuser`/`setpriv` keep the CALLER's,
# and the caller is root. Measured: with USER=root, podman's keep-id mapping
# reads the subid files keyed by that name, finds none, and produces a map of
# one pair — no gid 0, no gid 5 — which crun refuses to init
# (`ping_group_range`, then `devpts`; containers/crun#1648). A systemd user
# manager names the service for its own units; this mirrors it.
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# capture_as <service> <podman args...>: run podman as the service user and
# hand back what podman printed. `podman_as` — like every `run` in lib.sh —
# captures into the suite's own stdout/stderr files, so a `$(podman_as ...)`
# would capture the harness's silence rather than the tool's answer; this runs
# it and cats both captures back.
capture_as() {
    local service=$1
    shift
    podman_as "$service" "$@"
    cat "$GUARDEN_STDOUT" "$GUARDEN_STDERR"
}

# map_row <file> <container-id>: one row of a uid_map/gid_map with its columns
# normalised, so the assertions below compare numbers and not padding.
map_row() {
    awk -v id="$2" '$1 == id { print $1 " " $2 " " $3 }' "$1"
}

# The gid the probe has to agree with: read from the image's own passwd the
# way the probe reads it, so the assertions below are pinned to the image's
# declaration rather than to a number this file assumes it made.
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman run --rm --user 0 --entrypoint cat localhost/kid-staging:latest /etc/passwd
assert_exit 0
kid_gid=$(grep ":x:10001:" "$GUARDEN_STDOUT" | cut -d: -f4 || true)
[ -n "$kid_gid" ] || _fail "the image's passwd names no entry for uid 10001 to resolve against"
echo "MEASURE: the image resolves uid 10001 to gid $kid_gid"

# --- the machine's answers, before anything is asserted ----------------------
#
# Premises measured by the earlier runs of this file and kept as comments so a
# run that stops below still carries them:
#
#   * podman 5.7.0+ds2-3build1 (Ubuntu), crun 1.21. The vendored
#     /usr/share/containers/containers.conf sets
#     `default_sysctls = ["net.ipv4.ping_group_range=0 0"]`, which crun can
#     write only when gid 0 is mapped (containers/crun#1648); a keep-id map of
#     one pair has no gid 0 and dies on it, while the default mapping runs.
#   * /etc/subuid and /etc/subgid both hold `kid-staging:231072:65536`; the
#     default map reads them (`0 <svc uid> 1 / 1 231072 65536` — the subuid
#     band ticket 277 measured aliases into), a plain `podman unshare` mounts
#     devpts fine, and `runuser … podman run` needs no XDG_RUNTIME_DIR.
#   * With USER named for the service, keep-id's map is complete and the pin
#     forces init onto it: init uid/gid came back 10001/10001 under
#     `keep-id:uid=10001,gid=10001`, and the three rows of each map are the
#     ones asserted below — the pinned pair onto the service identity, the ids
#     above it onto the service's subordinate band, the rest carried through.
default_map=$(capture_as kid-staging run --rm localhost/kid-staging:latest cat /proc/self/uid_map)
echo "MEASURE: default map: $default_map"
[ -n "$default_map" ] || _fail "podman answered no uid_map for the default namespace"

# --- first start: the write, with no chown anywhere --------------------------

run weedr service start kid-staging
assert_exit 0

container=kid-staging-app
ready=0
for _ in $(seq 1 60); do
    podman_as kid-staging exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container $container never became exec-able"

# The write probe: the image's own uid writes into the service's own volume.
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u > /data/written-by'
assert_exit 0

written=/var/lib/guarden/services/kid-staging/state/data/written-by
assert_file_exists "$written"
inside=$(cat "$written")
[ "$inside" = "10001" ] \
    || _fail "the container reports uid $inside inside; the image's uid 10001 must not change"
owner=$(stat -c %u "$written")
[ "$owner" = "$svc_uid" ] \
    || _fail "the file written inside the container is owned by host uid $owner, not the service uid $svc_uid"

# --- the unit carries the line, and the record carries the numbers -----------

assert_file_exists "$unit"
assert_file_has "$unit" "UserNS=keep-id:uid=10001,gid=$kid_gid"
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$record" "owner_gid = $kid_gid"

# --- the pin, measured: uid 0, the init ids, and both maps -------------------
#
# The line is read out of the installed unit rather than retyped, so what is
# measured is the line the render actually produced.

generated=$(grep -m1 "^UserNS=" "$unit" | cut -d= -f2- || true)
[ -n "$generated" ] || _fail "the unit carries no UserNS= line to measure"
echo "MEASURE: the generated line: $generated"

# (b) The task's own shape: a container STARTED with the generated line and
# run as root, reading /proc/self/uid_map. The row `0 1 10001` is the answer
# for uid 0: under keep-id only the pinned pair sits on the service identity
# (asserted by the ownership above), and container uid 0 sits on the service's
# SUBORDINATE band — first subuid, not the service uid (fact 4 of the review;
# the podman code that lays the rows out is getRootlessKeepIDMapping).
root_map=$(capture_as kid-staging run --rm --userns="$generated" --user 0 \
    localhost/kid-staging:latest cat /proc/self/uid_map)
echo "MEASURE: uid_map of the generated line, run as root: $(printf '%s' "$root_map" | tr '\n' '|')"
printf '%s\n' "$root_map" > "$GUARDEN_FIXTURES/root-map"
[ -s "$GUARDEN_FIXTURES/root-map" ] \
    || _fail "uid 0 under $generated answered no uid_map: $root_map"
[ "$(map_row "$GUARDEN_FIXTURES/root-map" 0)" = "0 1 10001" ] \
    || _fail "uid 0 under $generated maps to [$(map_row "$GUARDEN_FIXTURES/root-map" 0)], expected [0 1 10001]"

# The pin's semantics, asserted where they are citable: keep-id with an
# explicit uid= FORCES init to that uid, overriding anything else, so init IS
# the probed uid (fact 2) and init's gid IS the probed gid (fact 5 — one
# measured run in eight landed files on the first subgid instead, which is the
# anomaly this gid assertion exists to catch).
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u; id -g'
assert_exit 0
init_uid=$(sed -n '1p' "$GUARDEN_STDOUT")
init_gid=$(sed -n '2p' "$GUARDEN_STDOUT")
echo "MEASURE: init uid/gid of the pinned container: $init_uid/$init_gid"
[ "$init_uid" = "10001" ] \
    || _fail "init uid $init_uid under $generated is not the probed uid 10001; the pin must force init (podman 5.7.0)"
[ "$init_gid" = "$kid_gid" ] \
    || _fail "init gid $init_gid under $generated is not the probed gid $kid_gid"

# Both maps of the running container, row by row: the pinned pair onto the
# service identity (`10001 0 1` in the container's own namespace — the host
# side of that pair is what the ownership assertions above already measured),
# the ids below it, and the rest of the subordinate band carried through.
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" podman exec "$container" cat /proc/self/uid_map
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/uid-map"
echo "MEASURE: uid_map of the pinned container: $(tr '\n' '|' <"$GUARDEN_FIXTURES/uid-map")"
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" podman exec "$container" cat /proc/self/gid_map
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/gid-map"
echo "MEASURE: gid_map of the pinned container: $(tr '\n' '|' <"$GUARDEN_FIXTURES/gid-map")"

[ "$(map_row "$GUARDEN_FIXTURES/uid-map" 0)" = "0 1 10001" ] \
    || _fail "uid_map row for 0 is [$(map_row "$GUARDEN_FIXTURES/uid-map" 0)], expected [0 1 10001]"
[ "$(map_row "$GUARDEN_FIXTURES/uid-map" 10001)" = "10001 0 1" ] \
    || _fail "uid_map row for 10001 is [$(map_row "$GUARDEN_FIXTURES/uid-map" 10001)], expected [10001 0 1]"
[ "$(map_row "$GUARDEN_FIXTURES/uid-map" 10002)" = "10002 10002 55535" ] \
    || _fail "uid_map row for 10002 is [$(map_row "$GUARDEN_FIXTURES/uid-map" 10002)], expected [10002 10002 55535]"
gid_next=$((kid_gid + 1))
gid_rest=$((65536 - kid_gid))
[ "$(map_row "$GUARDEN_FIXTURES/gid-map" 0)" = "0 1 $kid_gid" ] \
    || _fail "gid_map row for 0 is [$(map_row "$GUARDEN_FIXTURES/gid-map" 0)], expected [0 1 $kid_gid]"
[ "$(map_row "$GUARDEN_FIXTURES/gid-map" "$kid_gid")" = "$kid_gid 0 1" ] \
    || _fail "gid_map row for $kid_gid is [$(map_row "$GUARDEN_FIXTURES/gid-map" "$kid_gid")], expected [$kid_gid 0 1]"
[ "$(map_row "$GUARDEN_FIXTURES/gid-map" "$gid_next")" = "$gid_next $gid_next $gid_rest" ] \
    || _fail "gid_map row for $gid_next is [$(map_row "$GUARDEN_FIXTURES/gid-map" "$gid_next")], expected [$gid_next $gid_next $gid_rest]"

# --- a second start is stable, and the record is what renders ----------------

before=$(sha256sum "$unit" | cut -d' ' -f1)
run weedr service start kid-staging
assert_exit 0
after=$(sha256sum "$unit" | cut -d' ' -f1)
[ "$before" = "$after" ] || _fail "a second start rendered a different unit ($before -> $after)"
assert_file_has "$record" "owner_uid = 10001"

# The record, not a probe, is what the renderer answers to: an owner_uid the
# probe never produced is rendered through verbatim, which is only possible if
# the second start did not probe and overwrite it.
sed -i 's/^owner_uid = 10001$/owner_uid = 4242/' "$record"
run weedr service start kid-staging
assert_exit 0
grep -q "^owner_uid = 4242$" "$record" \
    || _fail "a start with a probed uid already in the record probed again and overwrote it"
assert_file_has "$unit" "UserNS=keep-id:uid=4242,gid=$kid_gid"

# A record with no probed uid is the probe's condition, and it holds again:
# the line comes back to the image's own ids.
sed -i '/^owner_uid = /d' "$record"
sed -i '/^owner_gid = /d' "$record"
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$unit" "UserNS=keep-id:uid=10001,gid=$kid_gid"

# --- create AND modify: a second process after a restart ---------------------
#
# The residual class the review names: an entrypoint that forced root past the
# pin would leave root-created files on the subuid band that the app phase
# cannot modify later. So the file is created by one process, the container is
# stopped and started, and a SECOND process appends to it — and the round trip
# must leave both the permission and the owner standing.
run weedr service stop kid-staging
assert_exit 0
run weedr service start kid-staging
assert_exit 0
ready=0
for _ in $(seq 1 60); do
    podman_as kid-staging exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container $container never came back after the restart"
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u >> /data/written-by'
assert_exit 0
second=$(sed -n '2p' "$written")
[ "$second" = "10001" ] \
    || _fail "the second process appended uid $second; the app must modify its own file after a restart"
owner=$(stat -c %u "$written")
[ "$owner" = "$svc_uid" ] \
    || _fail "after the restart the file is owned by host uid $owner, not the service uid $svc_uid"
