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
#     file the app phase could not modify later (the root-then-drop residual
#     class).
#   * **the unit and the record**: the installed unit carries
#     `UserNS=keep-id:uid=10001,gid=<probed gid>` with numbers matching the
#     registry's `owner_uid`/`owner_gid`, a second start leaves the unit
#     byte-identical, an edited record is rendered through instead of
#     re-probed, and a record with the uid removed is probed again.
#   * **uid 0 and the pin, measured on podman 5.7.0**: a container started with
#     the generated line and run as root answers `/proc/self/uid_map`, the
#     running service container answers its init uid/gid and both maps, and the
#     init uid is asserted to BE the probed uid — which here it is by
#     construction: this image's `USER` and the pinned pair are the same
#     number. Who runs is the image's business either way and is asserted
#     where the two differ: an image that names a `USER` runs it (t352:
#     `USER root` under a pin has pid 1 = 0; below, this image pinned at 4242
#     has pid 1 = 10001), an image with no `USER` runs the pinned pair (t351:
#     2000) — and what the pin decides everywhere is where that uid LANDS.
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

# --- the two claims round 3 found still written in the tree ------------------
#
# A sentence describing a failure mode the measured rule does not have (the
# spec's §6.3 clause and this file's own worker message below), and a
# docstring stating an equivalence that holds only as a subset. Prose and
# comments are the one surface no assertion in this family reads, which is how
# both survived a round that had already been told to grep them out — so the
# claim is checked here, on the tree the runner just pushed into the cut, and
# the run prints what matched. The bracketed spellings keep this line out of
# its own match; `-I` keeps a stale `__pycache__` byte-compilation of an
# older docstring from answering for the file beside it.
run grep -rnI -e 'forced on[t]o' -e 'digits are exactl[y]' \
    "$GUARDEN_ROOT/docs" "$GUARDEN_ROOT/src" "$GUARDEN_ROOT/tests"
echo "MEASURE: refuted claims still in the tree: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_exit 1

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
#   * With USER named for the service, keep-id's map is complete: init uid/gid
#     came back 10001/10001 under `keep-id:uid=10001,gid=10001` — the image's
#     own `USER` and the pinned pair are this fixture's same number, and the
#     pin is what puts that pair on the service identity — and the three rows
#     of each map are the ones asserted below — the pinned pair onto the
#     service identity, the ids above it onto the service's subordinate band,
#     the rest carried through.
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
# ADR-0019's two record shapes: this service's units name ONE image, so its
# document keeps the scalar pair and never grows the per-unit table — the map
# is written only when the units disagree about their user, and the other half
# of that claim (a two-image service whose record DOES carry the table) is
# asserted at the bottom of this file.
assert_file_lacks "$record" "owner_units"

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

# What runs here, asserted where it is citable: init IS the probed uid (fact
# 2) and init's gid IS the probed gid (fact 5 — one measured run in eight
# landed files on the first subgid instead, which is the anomaly this gid
# assertion exists to catch) — because init is the image's own `USER` and this
# image's USER and the pinned pair are the same number, so init lands on the
# mapping the line creates. What the pin decides is where that uid LANDS, not
# who starts: a pin does not override `USER`, measured and asserted on the
# root row of the same table in t352 (pid 1 answers 0 under
# `keep-id:uid=3000`).
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u; id -g'
assert_exit 0
init_uid=$(sed -n '1p' "$GUARDEN_STDOUT")
init_gid=$(sed -n '2p' "$GUARDEN_STDOUT")
echo "MEASURE: init uid/gid of the pinned container: $init_uid/$init_gid"
[ "$init_uid" = "10001" ] \
    || _fail "init uid $init_uid under $generated is not the probed uid 10001, and this image's USER is that pair (podman 5.7.0)"
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

# The field an operator edits by hand holds a NUMBER, and a quoted "4242" in
# the TOML document is a string: read back unconverted it reached the
# renderer's `uid and uid > 0` and raised TypeError — a traceback out of
# `weedr service start` rather than either answer below. Two answers, the pair
# `OwnerUnit.from_document` already gives the per-unit table: a string that IS
# a number is converted and rendered through — the same as the hand edit
# above — and a value that is not a number at all is refused as host state
# that does not hold what guarden wrote (one line, exit 1).
sed -i 's/^owner_uid = 10001$/owner_uid = "4242"/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of a quoted owner_uid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 0
assert_file_has "$unit" "UserNS=keep-id:uid=4242,gid=$kid_gid"
# The value comes back as the NUMBER it was read as: the start writes its own
# record (the gate verdict) from the loaded one, so the conversion is durable
# and what must NOT be here is 10001 — that would be the probe answering again.
assert_file_has "$record" "owner_uid = 4242"
assert_file_lacks "$record" "owner_uid = 10001"

# The read the claim in this file's header needed: this image DECLARES its
# user (10001) while the record pins another pair (4242), so pid 1 says which
# of the two the container runs as. The rule both readings of the measurement
# agree on, and what ADR-0019 now states: an image's explicit `USER` is what
# init runs as under a pin — t352 measures the root spelling the same way
# (pid 1 = 0 under `keep-id:uid=3000`) — while an image with no `USER` line
# runs the pinned pair (t351 measures 2000 under `keep-id:uid=2000`). What is
# true either way is where each uid LANDS.
runtime_pin=/run/user/"$(id -u kid-staging)"
for _ in $(seq 1 30); do
    [ -d "$runtime_pin" ] && break
    sleep 1
done
assert_file_exists "$runtime_pin"
pin_ready=0
for _ in $(seq 1 60); do
    podman_as kid-staging exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        pin_ready=1
        break
    fi
    sleep 2
done
[ "$pin_ready" = 1 ] || _fail "the kid-staging container never became exec-able under the 4242 pin"
# The pin the record rendered, read where it is falsifiable: the RUNNING
# container's own uid_map, with the same `map_row` read the two map assertions
# above make. A row `4242 0 1` is the pinned pair sitting on the service
# identity, and it only exists in a container that was STARTED under the 4242
# line — without it the pid 1 read just below is the container that came up
# under the first pin, and answering 10001 there says nothing about 4242 (it
# is the same-number case this file's own header calls out as proving nothing).
run_in "$home" setpriv --reuid=kid-staging --regid=kid-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kid-staging LOGNAME=kid-staging \
    XDG_RUNTIME_DIR="$runtime_pin" \
    podman exec "$container" cat /proc/self/uid_map
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/uid-map-pin"
echo "MEASURE: uid_map of the container the record pins at 4242: $(tr '\n' '|' <"$GUARDEN_FIXTURES/uid-map-pin")"
[ "$(map_row "$GUARDEN_FIXTURES/uid-map-pin" 4242)" = "4242 0 1" ] \
    || _fail "the running container answers uid_map row [$(map_row "$GUARDEN_FIXTURES/uid-map-pin" 4242)] for 4242 where the record's pin puts that pair on the service identity with [4242 0 1], so the pin is not live in this container and the pid 1 below is not a reading taken under 4242"
podman_as kid-staging exec "$container" sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the image-USER-10001 container pinned at 4242: $(cat "$GUARDEN_STDOUT")"
pid1_pin=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$pid1_pin" = 10001 ] \
    || _fail "pid 1 under keep-id:uid=4242 answers uid $pid1_pin, and this image declares USER 10001 — an explicit USER is what init runs as and the pin decides where that uid lands; 4242 here would mean the pin decides who starts"

sed -i 's/^owner_uid = 4242$/owner_uid = "not-a-number"/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of an unnumbered owner_uid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "kid-staging"
assert_stderr_has "owner_uid"
assert_stdout_lacks "started kid-staging"
# The record is rendered through, so what the rest of this file reads is the
# probe's own pair again.
sed -i 's/^owner_uid = "not-a-number"$/owner_uid = 10001/' "$record"

# --- every scalar TOML holds in those two keys, answered the same way --------
#
# The reader converts a number it can convert and refuses one it cannot, and
# these are the shapes beside the string case — `owner_uid` first and each
# one's twin on `owner_gid`, because both keys go through ONE reader and a
# future key-specific special case would otherwise be invisible here. Each
# refusal is the start an operator meets: exit 1, one line, naming the service
# and the key (spec 1.2), never a traceback from inside the reader and never a
# truncation with no diagnostic at all.
#
# `inf` comes first because it is the shape that escapes `int()` entirely:
# TOML parses it to float('inf') and `int(inf)` raises OverflowError, which a
# `try` of TypeError and ValueError does not catch — the same traceback class
# the string case was fixed for, one scalar type over.
sed -i 's/^owner_uid = .*/owner_uid = inf/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of an inf owner_uid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "kid-staging"
assert_stderr_has "owner_uid"
assert_stdout_lacks "started kid-staging"
sed -i 's/^owner_uid = .*/owner_uid = 10001/' "$record"

# A legal TOML float: `int(4242.9)` truncates to 4242, which is a wrong pin
# with no diagnostic — the value silently becomes a number nobody wrote.
sed -i 's/^owner_uid = .*/owner_uid = 4242.9/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of a fractional owner_uid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "owner_uid"
assert_stdout_lacks "started kid-staging"
sed -i 's/^owner_uid = .*/owner_uid = 10001/' "$record"

# A boolean is an `int` in Python and not one in TOML: `int(True)` is 1, and a
# pin of 1 is a pair the probe never recorded.
sed -i 's/^owner_uid = .*/owner_uid = true/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of a boolean owner_uid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "owner_uid"
assert_stdout_lacks "started kid-staging"
sed -i 's/^owner_uid = .*/owner_uid = 10001/' "$record"

# The gid's own half of the three cases the uid got above: an unnumbered
# spelling is rendered through verbatim, a quoted number is converted and
# lands in the record as the number it was read as, and a value that is no
# number at all is refused naming the key. The gid goes through the same
# reader, and this is what says so rather than the code's symmetry.
sed -i 's/^owner_gid = .*/owner_gid = 9998/' "$record"
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_gid = 9998"
assert_file_has "$unit" "UserNS=keep-id:uid=10001,gid=9998"

sed -i 's/^owner_gid = .*/owner_gid = "9997"/' "$record"
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_gid = 9997"
assert_file_has "$unit" "UserNS=keep-id:uid=10001,gid=9997"
assert_file_lacks "$record" "owner_gid = \"9997\""

sed -i 's/^owner_gid = .*/owner_gid = not-a-number/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of an unnumbered owner_gid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "owner_gid"
assert_stdout_lacks "started kid-staging"
sed -i 's/^owner_gid = .*/owner_gid = '"$kid_gid"'/' "$record"

sed -i 's/^owner_gid = .*/owner_gid = inf/' "$record"
run weedr service start kid-staging
echo "MEASURE: stderr of an inf owner_gid: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "owner_gid"
assert_stdout_lacks "started kid-staging"
sed -i 's/^owner_gid = .*/owner_gid = '"$kid_gid"'/' "$record"

# Back on the recorded pair, unit and record together: every refusal above
# left the installed unit where it was, and the record is what the next render
# reads.
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$record" "owner_gid = $kid_gid"
assert_file_has "$unit" "UserNS=keep-id:uid=10001,gid=$kid_gid"

# --- create AND modify: a second process after a restart ---------------------
#
# The residual class the review names: an entrypoint that comes up as
# container root and drops later — which a pin does not move, init being the
# image's own USER — would leave root-created files on the subuid band that
# the app phase cannot modify later. So the file is created by one process, the container is
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

# --- two units, two images, two pins (ADR-0019's line is per unit) -----------
#
# The claim above is one image for one service. This is the shape it has to
# survive: a service whose units name TWO images, each declaring its own
# non-root user. ADR-0019 is explicit that "each unit maps its own user onto
# the same service identity" — so the probe asks each distinct unit image, the
# registry records a pair per unit, and the renderer writes each unit's own
# line. One pair for the whole service would put the first image's user on every
# other unit, and init is the image's own `USER` — a pin decides WHERE that uid
# lands, not who starts (measured in t352) — so the units it did not probe
# would keep the subuid-aliased writes ticket 277 opened ADR-0019 to stop,
# while the pin mapped a uid their containers never run as. Silently: nothing
# about the run says the pin named the wrong image. Each container's own uid is
# asserted below, next to the uid_map row that says it landed on the service.
#
# The two images are built as the service user from two Containerfiles in the
# service's own tree: `weedr service build` tags every container from the one
# `Containerfile` the tree carries (spec 6.6), so a second image with a second
# uid is built the same way the first one is — `podman build` as the service,
# into the service's own store, which is the store the probe reads.

pair=/var/lib/guarden/staging/kidpair/0000001
mkdir -p "$pair/.guarden/quadlet" "$pair/.guarden/images"
seed "$pair/.guarden/service.yml" \
    "project: kidpair" \
    "units: .guarden/quadlet/"
seed "$pair/.guarden/quadlet/web.container" \
    "[Unit]" \
    "Description=the web half of the two-image service" \
    "" \
    "[Container]" \
    "Image=localhost/kidpair-staging:latest"
seed "$pair/.guarden/quadlet/worker.container" \
    "[Unit]" \
    "Description=the worker half of the two-image service" \
    "" \
    "[Container]" \
    "Image=localhost/kidpair-worker:latest"
seed "$pair/.guarden/images/web.Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 10011 kidweb" \
    "USER kidweb" \
    "CMD [\"sleep\", \"3600\"]"
seed "$pair/.guarden/images/worker.Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 20021 kidworker" \
    "USER kidworker" \
    "CMD [\"sleep\", \"3600\"]"

run weedr service ingest kidpair-staging --from poke kidpair@0000001
assert_exit 0

home_pair=/var/lib/guarden/services/kidpair-staging/home
runtime_pair=/run/user/"$(id -u kidpair-staging)"
for _ in $(seq 1 30); do
    [ -d "$runtime_pair" ] && break
    sleep 1
done
assert_file_exists "$runtime_pair"

podman_as kidpair-staging build --tag localhost/kidpair-staging:latest \
    -f "$home_pair/.guarden/images/web.Containerfile" "$home_pair/.guarden/images"
assert_exit 0
podman_as kidpair-staging build --tag localhost/kidpair-worker:latest \
    -f "$home_pair/.guarden/images/worker.Containerfile" "$home_pair/.guarden/images"
assert_exit 0

# image_gid <service> <image> <uid>: the gid the image's OWN passwd resolves
# that uid to, read by running the image as container root — pinned to the
# image's declaration rather than to a number this file assumes it made, which
# is how the assertions below survive a base image renumbering its groups.
image_gid() {
    podman_as "$1" run --rm --user 0 --entrypoint cat "$2" /etc/passwd
    assert_exit 0
    grep ":x:$3:" "$GUARDEN_STDOUT" | cut -d: -f4
}

web_gid=$(image_gid kidpair-staging localhost/kidpair-staging:latest 10011)
worker_gid=$(image_gid kidpair-staging localhost/kidpair-worker:latest 20021)
[ -n "$web_gid" ] || _fail "the web image resolves uid 10011 to no gid in its own passwd"
[ -n "$worker_gid" ] || _fail "the worker image resolves uid 20021 to no gid in its own passwd"
[ "$web_gid" != "$worker_gid" ] || _fail "both images resolve to gid $web_gid, so this fixture cannot tell two pins apart"

# unit_line <path>: the unit's own rendered line, or `none`. A red that prints
# what the unit actually carries is evidence; a grep that only says the pattern
# is missing is not.
unit_line() {
    grep -m1 '^UserNS=' "$1" || printf 'none\n'
}

run weedr service start kidpair-staging
assert_exit 0

pair_ready=0
for _ in $(seq 1 60); do
    podman_as kidpair-staging exec kidpair-staging-web true
    web_up=$GUARDEN_EXIT
    podman_as kidpair-staging exec kidpair-staging-worker true
    if [ "$web_up" = 0 ] && [ "$GUARDEN_EXIT" = 0 ]; then
        pair_ready=1
        break
    fi
    sleep 2
done
[ "$pair_ready" = 1 ] || _fail "the kidpair containers never became exec-able together"

unit_web=$home_pair/.config/containers/systemd/web.container
unit_worker=$home_pair/.config/containers/systemd/worker.container
record_pair=$registry/kidpair-staging.toml

# Two images, two lines: the claim this fixture exists for. Each unit carries
# the pair of the image IT names, and neither unit carries the other's.
line_web=$(unit_line "$unit_web")
line_worker=$(unit_line "$unit_worker")
[ "$line_web" = "UserNS=keep-id:uid=10011,gid=$web_gid" ] \
    || _fail "the web unit of a two-image service carries $line_web, and its own image's user is keep-id:uid=10011,gid=$web_gid"
[ "$line_worker" = "UserNS=keep-id:uid=20021,gid=$worker_gid" ] \
    || _fail "the worker unit of a two-image service carries $line_worker, and its own image's user is keep-id:uid=20021,gid=$worker_gid — a pin read from another image maps a uid that container never runs as, and that container's own uid would land in the subuid band"
[ "$line_web" != "$line_worker" ] \
    || _fail "both units render $line_web, which cannot be two images' users"

# The record carries both answers, per unit, and the service-level anchor is
# the first unit's pair (the single-image fields this file asserted above).
owner_field() {
    python3 -c '
import sys
import tomllib

record = tomllib.load(open(sys.argv[1], "rb"))
entry = record.get("owner_units", {}).get(sys.argv[2], {})
print(entry.get(sys.argv[3], ""))
' "$1" "$2" "$3"
}
assert_file_has "$record_pair" "owner_uid = 10011"
assert_file_has "$record_pair" "owner_gid = $web_gid"
[ "$(owner_field "$record_pair" web image)" = "localhost/kidpair-staging:latest" ] \
    || _fail "the record's web entry names the image $(owner_field "$record_pair" web image)"
[ "$(owner_field "$record_pair" web uid)" = "10011" ] \
    || _fail "the record's web entry holds uid $(owner_field "$record_pair" web uid)"
[ "$(owner_field "$record_pair" worker uid)" = "20021" ] \
    || _fail "the record's worker entry holds uid $(owner_field "$record_pair" worker uid), and its image declares 20021"
[ "$(owner_field "$record_pair" worker gid)" = "$worker_gid" ] \
    || _fail "the record's worker entry holds gid $(owner_field "$record_pair" worker gid)"

# Each container inits at ITS OWN image's uid — the same mechanism t350
# measures the single-image pin with: `id -u` of the running container, and the
# uid_map row that says the pinned pair sits on the service identity.
pair_init() {
    local container=$1
    run_in "$home_pair" setpriv --reuid=kidpair-staging --regid=kidpair-staging \
        --clear-groups env -u OLDPWD HOME="$home_pair" PWD="$home_pair" \
        USER=kidpair-staging LOGNAME=kidpair-staging \
        XDG_RUNTIME_DIR="$runtime_pair" \
        podman exec "$container" sh -c 'id -u; id -g'
    assert_exit 0
    init_uid=$(sed -n '1p' "$GUARDEN_STDOUT")
    init_gid=$(sed -n '2p' "$GUARDEN_STDOUT")
    run_in "$home_pair" setpriv --reuid=kidpair-staging --regid=kidpair-staging \
        --clear-groups env -u OLDPWD HOME="$home_pair" PWD="$home_pair" \
        USER=kidpair-staging LOGNAME=kidpair-staging \
        XDG_RUNTIME_DIR="$runtime_pair" \
        podman exec "$container" cat /proc/self/uid_map
    assert_exit 0
    cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/uid-map-$container"
    echo "MEASURE: $container init uid/gid $init_uid/$init_gid; uid_map $(tr '\n' '|' <"$GUARDEN_FIXTURES/uid-map-$container")"
}

pair_init kidpair-staging-web
[ "$init_uid" = "10011" ] \
    || _fail "the web container inits as uid $init_uid under $line_web, and its own image's user is 10011 — init is the image's own USER, which is this unit's pinned pair"
[ "$init_gid" = "$web_gid" ] \
    || _fail "the web container inits as gid $init_gid under $line_web, and its own image resolves gid $web_gid"
[ "$(map_row "$GUARDEN_FIXTURES/uid-map-kidpair-staging-web" 10011)" = "10011 0 1" ] \
    || _fail "the web uid_map row for 10011 is [$(map_row "$GUARDEN_FIXTURES/uid-map-kidpair-staging-web" 10011)], expected [10011 0 1]"

pair_init kidpair-staging-worker
[ "$init_uid" = "20021" ] \
    || _fail "the worker container inits as uid $init_uid under $line_worker, and its own image's user is 20021 — two images, two own users: init follows each image's USER and not one pinned pair"
[ "$init_gid" = "$worker_gid" ] \
    || _fail "the worker container inits as gid $init_gid under $line_worker, and its own image resolves gid $worker_gid"
[ "$(map_row "$GUARDEN_FIXTURES/uid-map-kidpair-staging-worker" 20021)" = "20021 0 1" ] \
    || _fail "the worker uid_map row for 20021 is [$(map_row "$GUARDEN_FIXTURES/uid-map-kidpair-staging-worker" 20021)], expected [20021 0 1]"

# A second start leaves both lines alone: the record, not a probe, is what the
# renderer answers to once both pairs are in it.
before_pair=$(sha256sum "$unit_web" "$unit_worker" | sha256sum | cut -d' ' -f1)
run weedr service start kidpair-staging
assert_exit 0
after_pair=$(sha256sum "$unit_web" "$unit_worker" | sha256sum | cut -d' ' -f1)
[ "$before_pair" = "$after_pair" ] \
    || _fail "a second start rendered a different pair of units ($before_pair -> $after_pair)"

# --- a render the record does not answer: no line, not another image's pair ---
#
# `weedr service start` probes what the record does not answer before it
# renders, so the start path never meets this question; `loom render` on its
# own — the deploy path — does, and ADR-0019's rule is that a unit the record
# does not answer renders NO line rather than the pair read from another
# image, with the next start probing it. This service's record answers
# `localhost/kid-staging:latest` (owner_image), so a source naming any other
# reference has no pair to be given. The render reads the SOURCE, so the image
# is changed in a copy of it — the home beside it is the one the rest of this
# file still starts.
changed=$GUARDEN_FIXTURES/changed-image
mkdir -p "$changed/.guarden"
cp -R "$home/.guarden/." "$changed/.guarden/"

# Control: the same source naming its own image renders the recorded pair, so
# the half below fails on the image and on nothing else about the render.
run loom render "$changed" --service kid-staging --out "$changed/out-own"
assert_exit 0
[ "$(unit_line "$changed/out-own/units/app.container")" = "UserNS=keep-id:uid=10001,gid=$kid_gid" ] \
    || _fail "the record's own image renders $(unit_line "$changed/out-own/units/app.container") and the pair it holds is keep-id:uid=10001,gid=$kid_gid"

sed -i 's|^Image=localhost/kid-staging:latest$|Image=localhost/kid-other:latest|' \
    "$changed/.guarden/quadlet/app.container"
run loom render "$changed" --service kid-staging --out "$changed/out-other"
assert_exit 0
[ "$(unit_line "$changed/out-other/units/app.container")" = "none" ] \
    || _fail "a unit naming localhost/kid-other:latest renders $(unit_line "$changed/out-other/units/app.container") from a record whose owner_image is localhost/kid-staging:latest, and a unit the record does not answer renders no line (ADR-0019) — the render alone never probes, so a line here is another image's pin installed until the next start repairs it"

# --- a rebuild under the same tag is a DIFFERENT image -----------------------
#
# `owner_image` records the reference and `weedr service build` re-tags it, so
# a Containerfile that changes USER kept the pair read from the image that no
# longer stands behind that tag: the record answered the unit, no probe ran,
# the container came up as the NEW user under the OLD pin, and that uid's
# writes land in the subuid band (ticket 277) while the record and the
# "an image that changed is the probe's condition again" line both claimed
# otherwise. The image changes in the build, so that is where the answer goes
# away — and the next start is the probe's condition again for real.
printf '%s\n' \
    "RUN addgroup -g 10002 kiduser2" \
    "RUN adduser -D -u 10002 -G kiduser2 kiduser2" \
    "USER 10002" >> "$home/Containerfile"
run weedr service build kid-staging
assert_exit 0
assert_file_lacks "$record" "owner_uid"
assert_file_lacks "$record" "owner_image"
run weedr service start kid-staging
assert_exit 0
assert_file_has "$record" "owner_uid = 10002"
assert_file_has "$unit" "UserNS=keep-id:uid=10002,gid=10002"
assert_file_lacks "$unit" "uid=10001"
