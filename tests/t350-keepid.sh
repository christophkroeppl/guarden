#!/usr/bin/env bash
# ADR-0019 end to end: guarden probes the image's declared user at first start,
# renders `Userns=keep-id:uid=...,gid=...` into the generated unit from that
# probe alone, records it in the registry as `owner_uid`/`owner_gid` — and no
# file is ever chowned. Ticket 277's `Permission denied` is the failure this
# replaces: a non-root image user mapped into the service's subuid band, denied
# on entry, aliased on disk if it ever got through.
#
# Four claims, each where its evidence lands:
#
#   * **the write** (the ADR's headline): a service whose Containerfile sets a
#     NON-ROOT `USER`, deployed through create/ingest, started with no manual
#     chown anywhere in this file — an in-container write succeeds and the file
#     it leaves on the host is owned by the SERVICE uid, while the container
#     still sees itself as the image's uid. Nothing here chowns by construction,
#     so "no chown ran" is a property of the file rather than an assertion.
#   * **the unit and the record**: the installed unit carries
#     `Userns=keep-id:uid=10001,gid=10001` with numbers matching the registry's
#     `owner_uid`/`owner_gid`, a second start leaves both byte-identical, an
#     edited record is rendered through instead of re-probed (so the record is
#     what the renderer answers to), and a record with the uid removed is
#     probed again.
#   * **uid 0 under the generated line** — the root-then-drop class ADR-0019
#     names unmeasured — is read off `/proc/self/uid_map` in a container
#     started with the generated line and run as root, and the numbers are
#     echoed so the run's output carries the measurement.
#   * **the machine's own answers first**: every map below is podman's, taken
#     before anything is asserted about guarden, so a failing assertion further
#     down still leaves the measurements in the log.
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
# scrubbed out of the environment the way `t50-slice` scrubs it, because
# `OLDPWD` still carrying the suite's tree is what quadlet resolves its own
# unit directory from.
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# --- the machine's answers, before anything is asserted ----------------------
#
# Every line is echoed, so a run that stops at a later assertion still carries
# the numbers. What each one is for:
#
#   * the default map — the subuid band ticket 277 measured aliases into;
#   * uid 0 under `keep-id:uid=10001,gid=10001` — the root-then-drop class,
#     run as root, read off /proc/self/uid_map;
#   * the image's own ids under that line — the container must still BE the
#     image's uid, because changing uid inside the container is forbidden;
#   * how podman resolves a bare numeric `USER` (the probe has to agree with
#     it) and a numeric uid that the image's passwd does carry;
#   * the same line with `uid=0`, which is the shape a root image would get,
#     and a drop to 10001 beneath it.
default_map=$(podman_as run --rm localhost/kid-staging:latest cat /proc/self/uid_map)
echo "MEASURE: default map: $default_map"
[ -n "$default_map" ] || _fail "podman answered no uid_map for the default namespace"

keepid_root_map=$(podman_as run --rm --userns=keep-id:uid=10001,gid=10001 --user 0 \
    localhost/kid-staging:latest cat /proc/self/uid_map 2>&1)
echo "MEASURE: uid 0 under keep-id:uid=10001,gid=10001: $keepid_root_map"

keepid_ids=$(podman_as run --rm --userns=keep-id:uid=10001,gid=10001 \
    localhost/kid-staging:latest sh -c 'id -u; id -g' 2>&1)
echo "MEASURE: ids under keep-id:uid=10001,gid=10001: $keepid_ids"

bare_gid=$(podman_as run --rm --user 10001 localhost/kid-staging:latest id -g 2>&1)
echo "MEASURE: bare numeric --user 10001 resolves gid: $bare_gid"

passwd_gid=$(podman_as run --rm --user 1 localhost/kid-staging:latest id -g 2>&1)
echo "MEASURE: --user 1 (daemon, in the image's passwd) resolves gid: $passwd_gid"

keepid0_map=$(podman_as run --rm --userns=keep-id:uid=0,gid=0 \
    localhost/kid-staging:latest cat /proc/self/uid_map 2>&1)
echo "MEASURE: uid 0 under keep-id:uid=0,gid=0: $keepid0_map"

keepid0_drop=$(podman_as run --rm --userns=keep-id:uid=0,gid=0 --user 10001 \
    localhost/kid-staging:latest id -u 2>&1)
echo "MEASURE: a drop to 10001 under keep-id:uid=0,gid=0: $keepid0_drop"

# The shape `weedr service start` probes with: `runuser`, the service's own
# home as the working directory, and no XDG_RUNTIME_DIR of its own — whether a
# container run works that way is what decides what the probe may assume.
raw_run=$(runuser -u kid-staging -- env -u OLDPWD -C "$home" \
    podman run --rm localhost/kid-staging:latest id -u 2>&1)
echo "MEASURE: runuser podman run without XDG_RUNTIME_DIR: $raw_run"

# --- first start: the write, with no chown anywhere --------------------------

run weedr service start kid-staging
assert_exit 0

container=kid-staging-app
ready=0
for _ in $(seq 1 60); do
    if podman_as kid-staging exec "$container" true >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container $container never became exec-able"

# The write probe: the image's own uid writes into the service's own volume.
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" XDG_RUNTIME_DIR="$runtime" \
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
assert_file_has "$unit" "Userns=keep-id:uid=10001,gid=10001"
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$record" "owner_gid = 10001"

# --- uid 0 under the line guarden generated ---------------------------------
#
# The line is read out of the installed unit rather than retyped, so what is
# measured is the line the render actually produced.

generated=$(grep -m1 "^Userns=" "$unit" | cut -d= -f2-)
[ -n "$generated" ] || _fail "the unit carries no Userns= line to measure"
echo "MEASURE: the generated line: $generated"
root_map=$(podman_as run --rm --userns="$generated" --user 0 \
    localhost/kid-staging:latest cat /proc/self/uid_map 2>&1)
echo "MEASURE: uid 0 under the generated line: $root_map"
[ -n "$root_map" ] || _fail "uid 0 under $generated answered no uid_map"
# It has to BE a map — container id 0 with a host id and a length — and not
# podman's refusal of the run dressed up as one. The host id for uid 0 is the
# number this pins, and it is echoed above for the record.
printf '%s\n' "$root_map" \
    | grep -qE "^[[:space:]]*0[[:space:]]+[0-9]+[[:space:]]+[0-9]+" \
    || _fail "uid 0 under $generated did not answer a uid_map: $root_map"

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
assert_file_has "$unit" "Userns=keep-id:uid=4242,gid=10001"

# A record with no probed uid is the probe's condition, and it holds again:
# the line comes back to the image's own ids.
sed -i '/^owner_uid = /d' "$record"
sed -i '/^owner_gid = /d' "$record"
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$unit" "Userns=keep-id:uid=10001,gid=10001"
