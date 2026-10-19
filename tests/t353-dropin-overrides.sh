#!/usr/bin/env bash
# The three-file drop-in model for the keep-id pin (ADR-0019).
#
# The model is three files with three writers, and this suite is what says the
# model is the model:
#
#   * the BASE unit, in the service's own quadlet directory, carries **no
#     `UserNS=` line at all** — the pin is not in it, so a regeneration of the
#     unit cannot disturb the pin and the unit cannot carry the line twice.
#   * `50-guarden-keepid.conf`, in the ROOT-OWNED drop-in directory
#     `/etc/containers/systemd/users/<uid>/<unit>.container.d/`, carries the
#     `UserNS=keep-id:uid=…,gid=…` line. **Guarden writes this file and
#     nothing else in that directory.**
#   * `90-admin.conf`, in the same directory, is the HUMAN's own file. Guarden
#     never writes it and never deletes it, and — because drop-ins merge in
#     alphabetical order and the last value of a scalar key wins — a
#     `UserNS=` line in it **overrides** guarden's pin.
#
# The claims, each where its evidence lands:
#
#   * **the base unit carries no line** — asserted on the file itself, and the
#     absence is asserted rather than the presence of something else.
#   * **the pin is in the drop-in, and the drop-in is where the generator
#     reads it** — the generated unit is read for the `--userns` flag, which
#     is the one thing that decides what the container runs under. A drop-in
#     in the system path IS picked up for a base unit in the home (measured:
#     probe-quadlet-dropins.md row 8), and this asserts it end to end on the
#     machine rather than quoting the probe.
#   * **the admin's file wins** — a `90-admin.conf` carrying a different
#     `UserNS=` is the effective one, and the container's own uid_map says so.
#   * **guarden never writes or deletes `90-admin.conf`** — a second render
#     leaves it byte-identical, and a removal of the service leaves it alone.
#   * **a second start leaves everything alone** — the base unit, the
#     drop-in and the admin's file are all byte-identical after it, which is
#     the churn claim: the re-render trigger reads the drop-in, not the base
#     unit.
#
# Real host, real rootless podman: `GUARDEN_PREFIX=/`, as t350 does.

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

# --- the service: an image that declares a non-root user --------------------

staged=/var/lib/guarden/staging/dropin/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: dropin" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the drop-in model subject" \
    "" \
    "[Container]" \
    "Image=localhost/dropin-staging:latest" \
    "Volume=data:/data"
seed "$staged/Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 10001 dropuser" \
    "USER 10001" \
    "CMD [\"sleep\", \"3600\"]"

run weedr service ingest dropin-staging --from poke dropin@0000001
assert_exit 0
run weedr service build dropin-staging
assert_exit 0

home=/var/lib/guarden/services/dropin-staging/home
unit=$home/.config/containers/systemd/app.container
record=$registry/dropin-staging.toml
svc_uid=$(id -u dropin-staging)
dropin_dir=/etc/containers/systemd/users/"$svc_uid"/app.container.d
guarden_dropin=$dropin_dir/50-guarden-keepid.conf
admin_dropin=$dropin_dir/90-admin.conf

# The gid the image's own passwd resolves uid 10001 to — read the way the
# probe reads it, so the assertions are pinned to the image's declaration and
# not to a number this file assumes.
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"
run_in "$home" setpriv --reuid=dropin-staging --regid=dropin-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=dropin-staging LOGNAME=dropin-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman run --rm --user 0 --entrypoint cat localhost/dropin-staging:latest /etc/passwd
assert_exit 0
drop_gid=$(grep ":x:10001:" "$GUARDEN_STDOUT" | cut -d: -f4 || true)
[ -n "$drop_gid" ] || _fail "the image's passwd names no entry for uid 10001 to resolve against"
echo "MEASURE: the image resolves uid 10001 to gid $drop_gid"

# --- the first start: the pin lands in the drop-in, not in the base unit ----

run weedr service start dropin-staging
assert_exit 0

assert_file_exists "$unit"
assert_file_exists "$guarden_dropin"

# **The base unit carries NO `UserNS=` line.** Not "not this one" — no line at
# all, in any spelling: the whole point of the model is that the base unit
# and the drop-in are two different files with two different writers, and a
# base unit that carried the line would carry it twice over once the
# generator merged the drop-in in.
run grep -c "^UserNS=" "$unit"
echo "MEASURE: UserNS= lines in the base unit: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = 0 ] \
    || _fail "the base unit carries $(cat "$GUARDEN_STDOUT") UserNS= line(s) and must carry none: the pin lives in $guarden_dropin, and a base unit that carried it too would have two writers for one key"
assert_file_lacks "$unit" "UserNS="
assert_file_lacks "$unit" "Userns="

# The drop-in carries exactly the line, and the line is the one the record
# holds.
assert_file_has "$guarden_dropin" "UserNS=keep-id:uid=10001,gid=$drop_gid"
assert_file_has "$record" "owner_uid = 10001"
assert_file_has "$record" "owner_gid = $drop_gid"

# The drop-in's mode and owner: the generator reads this path as the SERVICE
# user, and a root-owned `0600` file there yields no generated unit at all
# (measured: probe-quadlet-dropins.md row 10). So it is root-owned and
# world-readable, and the directory that holds it is traversable.
assert_mode "$guarden_dropin" 644
assert_owner "$guarden_dropin" "root:root"
assert_mode "$dropin_dir" 755
assert_mode "/etc/containers/systemd/users" 755

# The generated unit is the thing that decides what the container runs under:
# the `--userns` flag in `ExecStart` is the effective mapping, and the
# `[X-Container]` section is inert (measured: probe-quadlet-dropins.md row 3).
# So the flag is what this suite counts, and the base unit's own `UserNS=`
# line is not what it reads.
generated=/run/user/"$svc_uid"/systemd/generator/app.service
assert_file_exists "$generated"
run grep -c -- "--userns" "$generated"
echo "MEASURE: --userns flags in the generated unit: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = 1 ] \
    || _fail "the generated unit carries $(cat "$GUARDEN_STDOUT") --userns flag(s) and must carry exactly one: the drop-in is the only file that carries a line, and a second one would be a second mapping in force"
run grep -o -- "--userns keep-id:uid=10001,gid=$drop_gid" "$generated"
assert_exit 0
echo "MEASURE: the generated flag: $(cat "$GUARDEN_STDOUT")"

# --- the container actually runs under the pin ------------------------------

container=dropin-staging-app
ready=0
for _ in $(seq 1 60); do
    run_in "$home" setpriv --reuid=dropin-staging --regid=dropin-staging --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER=dropin-staging LOGNAME=dropin-staging \
        XDG_RUNTIME_DIR="$runtime" podman exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container $container never became exec-able"

# The pair on the service identity is the proof that the pin was in force:
# `10001 0 1` in the container's own uid_map is the pinned pair sitting on
# the service's uid, and it exists only in a container started under the pin.
run_in "$home" setpriv --reuid=dropin-staging --regid=dropin-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=dropin-staging LOGNAME=dropin-staging \
    XDG_RUNTIME_DIR="$runtime" podman exec "$container" cat /proc/self/uid_map
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/uid-map"
echo "MEASURE: uid_map of the pinned container: $(tr '\n' '|' <"$GUARDEN_FIXTURES/uid-map")"
pin_row=$(awk '$1 == 10001 { print $1 " " $2 " " $3 }' "$GUARDEN_FIXTURES/uid-map")
[ "$pin_row" = "10001 0 1" ] \
    || _fail "the container's uid_map row for 10001 is [$pin_row] and must be [10001 0 1]: that row is the pinned pair on the service identity, and without it the container is not running under the pin the drop-in declares"

# --- a second start leaves everything alone ---------------------------------
#
# The churn claim: the re-render trigger reads the DROP-IN, not the base
# unit. A trigger that read the base unit would reinstall the units on every
# start (the base unit holds no line, so the answer would always be "no
# line"), and an admin whose `90-admin.conf` says something different would
# be in a fight with guarden for ever. So all three files are byte-identical
# after a second start.

before_unit=$(sha256sum "$unit" | cut -d' ' -f1)
before_guarden=$(sha256sum "$guarden_dropin" | cut -d' ' -f1)
run weedr service start dropin-staging
assert_exit 0
after_unit=$(sha256sum "$unit" | cut -d' ' -f1)
after_guarden=$(sha256sum "$guarden_dropin" | cut -d' ' -f1)
[ "$before_unit" = "$after_unit" ] \
    || _fail "a second start rendered a different base unit ($before_unit -> $after_unit)"
[ "$before_guarden" = "$after_guarden" ] \
    || _fail "a second start rewrote the keep-id drop-in ($before_guarden -> $after_guarden)"

# --- the admin's own file: guarden never writes it --------------------------
#
# The admin's file is the human's. It is written here by hand, exactly as an
# operator would write it, and the claim is that guarden does not touch it:
# a second render leaves it byte-identical.

seed "$admin_dropin" \
    "[Container]" \
    "UserNS=keep-id:uid=2002,gid=2002"
before_admin=$(sha256sum "$admin_dropin" | cut -d' ' -f1)
run weedr service start dropin-staging
assert_exit 0
after_admin=$(sha256sum "$admin_dropin" | cut -d' ' -f1)
[ "$before_admin" = "$after_admin" ] \
    || _fail "a second start rewrote the admin's own drop-in ($before_admin -> $after_admin): that file is the human's and guarden never writes it"
assert_file_has "$admin_dropin" "UserNS=keep-id:uid=2002,gid=2002"
# ... and the file guarden owns still holds guarden's own line, unchanged.
assert_file_has "$guarden_dropin" "UserNS=keep-id:uid=10001,gid=$drop_gid"

# --- the admin's file WINS: the alphabetical order is the whole mechanism ----
#
# `50-` merges before `90-`, and the last value of a scalar key is the
# effective one. So the admin's `UserNS=` is the mapping in force — and the
# proof is the container's own uid_map, not the file's contents.

# The manager has to re-read the units for the change to take effect: a
# drop-in is read by the generator, and the generator runs at daemon-reload.
run systemctl --user --machine "dropin-staging@" daemon-reload
assert_exit 0
run weedr service stop dropin-staging
assert_exit 0
run weedr service start dropin-staging
assert_exit 0

# The generated unit now carries the ADMIN's line, not guarden's: the merged
# file has both, and the flag is the last one.
run grep -c -- "--userns" "$generated"
echo "MEASURE: --userns flags in the generated unit with an admin override: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = 1 ] \
    || _fail "the generated unit carries $(cat "$GUARDEN_STDOUT") --userns flag(s) with the admin's file beside guarden's and must carry exactly one: the two files merge, and the last one is the flag that runs"
run grep -o -- "--userns keep-id:uid=2002,gid=2002" "$generated"
assert_exit 0
echo "MEASURE: the generated flag with the admin's override: $(cat "$GUARDEN_STDOUT")"

# And the container runs under the ADMIN's pair: `2002 0 1` in the uid_map is
# the admin's pair on the service identity, and `10001 0 1` is absent because
# guarden's pin is not the mapping in force.
ready=0
for _ in $(seq 1 60); do
    run_in "$home" setpriv --reuid=dropin-staging --regid=dropin-staging --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER=dropin-staging LOGNAME=dropin-staging \
        XDG_RUNTIME_DIR="$runtime" podman exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container never came back under the admin's override"
run_in "$home" setpriv --reuid=dropin-staging --regid=dropin-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=dropin-staging LOGNAME=dropin-staging \
    XDG_RUNTIME_DIR="$runtime" podman exec "$container" cat /proc/self/uid_map
assert_exit 0
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/uid-map-admin"
echo "MEASURE: uid_map under the admin's override: $(tr '\n' '|' <"$GUARDEN_FIXTURES/uid-map-admin")"
admin_row=$(awk '$1 == 2002 { print $1 " " $2 " " $3 }' "$GUARDEN_FIXTURES/uid-map-admin")
guarden_row=$(awk '$1 == 10001 { print $1 " " $2 " " $3 }' "$GUARDEN_FIXTURES/uid-map-admin")
[ "$admin_row" = "2002 0 1" ] \
    || _fail "the container's uid_map row for 2002 is [$admin_row] and must be [2002 0 1]: the admin's own drop-in is alphabetically last and its line is the one in force"
[ -z "$guarden_row" ] \
    || _fail "the container's uid_map still carries a row for guarden's own pinned pair 10001 ([$guarden_row]), so the admin's override did not take effect: the last drop-in's value is the one that runs"

# --- the removal leaves the admin's file alone ------------------------------

run weedr service remove dropin-staging
assert_exit 0
assert_file_exists "$admin_dropin"
assert_file_missing "$guarden_dropin"
echo "MEASURE: after the removal, the admin's file: $(cat "$admin_dropin" | tr '\n' '|')"
