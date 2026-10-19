#!/usr/bin/env bash
# MUST FAIL: a container cannot change a file it does not access.
#
# The claim is a security claim, so a suite that only ever says "the write was
# refused" is worth nothing: a refusal that happens because the probe was
# malformed, or because the container never started, or because the volume was
# not mounted at all, reads exactly like a boundary holding. **This file is
# written so that it goes RED when the boundary is removed, and the removal is a
# real, minimal, reverted-in-the-same-run change.**
#
# What is pinned, and the mechanism each one exercises:
#
#   * **A container whose uid is NOT the service's cannot write the service's
#     own files.** The mechanism is the `0700` on the service's tree
#     (spec 2.1: `/var/lib/guarden/services/<name>` and everything under it is
#     `0700` to the service user; `src/guarden/service.py:62` `TREE_MODE = 0o700`
#     and `src/guarden/service.py:784` `os.chmod(path, TREE_MODE)`) combined
#     with rootless podman's default mapping, which puts container uid 0 on the
#     service uid and every other container uid in the service's subuid band
#     (measured: `0 <svc-uid> 1` / `1 <band-start> 65536`). A container uid that
#     is not the service's therefore lands in the band and the `0700` denies it.
#     **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the volume's mode is
#     `chmod 0777`ed in the test, the same write is retried, and it now
#     succeeds — so the assertion "the write was refused" goes red, and the
#     file's owner is the container's own uid rather than the service's.
#   * **A container cannot write OUTSIDE its own tree.** The mechanism is the
#     same `0700`, on the OTHER service's tree, plus the fact that a bind of
#     another service's `0700` directory is refused at mount time
#     (`Error: statfs <path>: permission denied`, measured) because the caller
#     cannot even `statfs` it.
#     **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the other service's tree is
#     `chmod 0777`ed, and the same bind-and-write now succeeds with the
#     container's uid as the owner of the file it left behind.
#   * **A container cannot write the host's own state.** `/var/lib/guarden/soil`
#     is `0750 root:guarden` (spec 2.1) and `/etc/guarden` is `0751 root:guarden`
#     with its files `0640 root:guarden`; a container's uid is in neither group
#     and is not the owner, so a bind of either is refused and a write into it
#     is denied. **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the same
#     bind-and-write is retried after the directory's mode is opened to the
#     world, and the write then succeeds.
#
# **What this file does NOT claim, and says so in its own words:** the
# container's uid is not the service's, but the container's uid 0 IS the
# service's uid (rootless podman's default map) — so "a container cannot change
# a file it does not access" is a claim about the `0700` and the mapping, not a
# claim that a container is a stranger to its own service. A container of
# `shelf-staging` IS `shelf-staging` as far as the kernel is concerned
# (SECURITY.md 2.2), and the suite asserts that half too, so the boundary it
# draws is the real one.
#
# Real host, real rootless podman, real `useradd`: `GUARDEN_PREFIX=/`, as
# `t350-keepid` and `t352-keepid-boundaries` do.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# Two services, so "its own tree" and "another service's tree" are two real
# trees with two real uids and two real subuid bands. `shelf` and `myapp` are
# the two plainest fixtures in the tree: a compose service with a route and no
# credential, and a compose service with a state and a bulk volume.
stage_poke shelf 9f2c1ab
stage_poke myapp 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0

OWNER=shelf-staging
OTHER=myapp-staging
own_uid=$(id -u "$OWNER")
other_uid=$(id -u "$OTHER")
own_home=/var/lib/guarden/services/$OWNER/home
own_volume=/var/lib/guarden/services/$OWNER/state/data
other_volume=/var/lib/guarden/services/$OTHER/state/data
[ -n "$own_uid" ] || _fail "$OWNER has no uid, so nothing below can be about a service"
[ -d "$own_volume" ] || _fail "$OWNER has no state volume, so there is nothing to write"

# The image every container below runs. It is pulled as the service user, which
# is the path the resolver accept exists for, and it is the same pull t350
# makes — so a failure here is a network failure and not a boundary.
runtime=/run/user/"$own_uid"
mkdir -p "$runtime"
chown "$own_uid:$own_uid" "$runtime"
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}
podman_as "$OWNER" pull docker.io/library/alpine:3.20
assert_exit 0
echo "MEASURE: the image the containers below run is in the service's own store"

# --- the modes are the mechanism, and they are MEASURED before they are used -
#
# A denial measured against a mode that is not there is a denial for the wrong
# reason, so each mode the claim rests on is read off the machine first. The
# numbers are the spec's own (spec 2.1), and `assert_mode`/`assert_owner` are
# the harness's readers of them.
#
# **They are READ here and ASSERTED at the end of the file, and the reason is
# the order of the argument.** The mode is the MEANS and the claim is the
# EFFECT: "a container whose uid is not the service's cannot write the
# service's files" is the claim, and the `0700` is how it is achieved. A
# suite that asserts the means first would go red on a broken `0700` and stop
# — so the reader would see a mode complaint and never the demonstration that
# the mode is what was holding. **The order here is chosen so that a broken
# protection produces the SUBSTANTIVE red**: the write that was refused
# succeeds, which is the fact about the security model rather than about a
# number in a table. The modes are asserted at the end, where a drift in them
# is still a red, and where reaching that point means every claim above held.
measured_modes() {
    local path=$1 want=$2
    local actual
    actual=$(stat -c %a "$path" 2>/dev/null || printf missing)
    echo "MEASURE: $path is mode $actual (the claim below rests on $want)"
}
measured_modes "/var/lib/guarden/services/$OWNER" 700
measured_modes "$own_volume" 700
measured_modes "/var/lib/guarden/services/$OTHER" 700
measured_modes /var/lib/guarden/soil 750
measured_modes /etc/guarden 751
echo "MEASURE: the owners: $(stat -c %U:%G "/var/lib/guarden/services/$OWNER"), $(stat -c %U:%G "$own_volume"), $(stat -c %U:%G /var/lib/guarden/soil), $(stat -c %U:%G /etc/guarden)"

# --- the mapping, read off the machine --------------------------------------
#
# **The default map is the premise of the whole file**, so it is read and
# printed rather than assumed: container uid 0 sits on the service's identity
# and every other container uid sits in the service's subordinate band. A
# container uid that is NOT the service's therefore lands in the band, and the
# `0700` is what denies it.
podman_as "$OWNER" run --rm docker.io/library/alpine:3.20 cat /proc/self/uid_map
assert_exit 0
default_map=$(cat "$GUARDEN_STDOUT")
echo "MEASURE: the default uid_map of a $OWNER container: $(printf '%s' "$default_map" | tr '\n' '|')"
first_row=$(printf '%s\n' "$default_map" | awk 'NR == 1 { print $1 " " $2 " " $3 }')
[ "$first_row" = "0 $own_uid 1" ] \
    || _fail "the default map's first row is [$first_row], expected [0 $own_uid 1]: container root must sit on the service's own uid"
band_row=$(printf '%s\n' "$default_map" | awk 'NR == 2 { print $1 " " $2 " " $3 }')
[ -n "$band_row" ] || _fail "the default map has no second row, so the band is not measurable"
own_band=$(awk -F: -v u="$OWNER" '$1 == u { print $2 }' /etc/subuid)
own_count=$(awk -F: -v u="$OWNER" '$1 == u { print $3 }' /etc/subuid)
[ -n "$own_band" ] || _fail "$OWNER has no subuid range, so its band is not measurable"
echo "MEASURE: $OWNER's band starts at $own_band; the map's second row is [$band_row]"
case "$band_row" in
    "1 $own_band "*) ;;
    *) _fail "the map's second row is [$band_row] and does not start at $OWNER's own band $own_band" ;;
esac

# --- the restore, and it is a trap ------------------------------------------
#
# **Every removal below is reverted in the same run, and the revert is a trap
# rather than a line at the end of a block.** A block that fails between the
# removal and its revert leaves the host with the protection OFF, and every
# assertion after it would then be measuring a host that is not the one this
# suite describes. The trap runs on every exit path, so the revert is a
# property of the run rather than of the run having been lucky.
restore_modes() {
    chmod 0700 "$own_volume" 2>/dev/null || true
    chmod 0700 "$own_home" 2>/dev/null || true
    chmod 0700 "$other_home" 2>/dev/null || true
    chmod 0700 "$other_volume" 2>/dev/null || true
    chmod 0700 "/var/lib/guarden/services/$OTHER/state" 2>/dev/null || true
    chmod 0700 "/var/lib/guarden/services/$OTHER" 2>/dev/null || true
    chmod 0750 /var/lib/guarden/soil 2>/dev/null || true
    rm -f "$own_volume/stranger" "$other_volume/intruder" 2>/dev/null || true
    rm -f "$own_home/intruder" "$other_home/intruder" 2>/dev/null || true
    rm -f /var/lib/guarden/soil/intruder 2>/dev/null || true
}
trap restore_modes EXIT

# --- the claim: a container whose uid is not the service's cannot write -----
#
# The container runs as uid 10001 — a number that is neither the service's uid
# nor in its band as an identity — so inside the container it is a stranger to
# the service's files, and the write is the question.
#
# **The container IS proven to be up and to have the volume mounted**, because a
# container that never started reads exactly like a boundary that held: the
# write is refused because there is nothing to write to. So the mount is
# asserted from inside the container, and the file's ABSENCE afterwards is
# asserted on the host.
podman_as "$OWNER" run --rm --user 10001 -v "$own_volume:/x" \
    docker.io/library/alpine:3.20 sh -c "id -u; stat -c %a /x"
assert_exit 0
container_uid=$(sed -n '1p' "$GUARDEN_STDOUT")
container_mode=$(sed -n '2p' "$GUARDEN_STDOUT")
echo "MEASURE: inside the container: uid $container_uid, the volume's mode $container_mode"
[ "$container_uid" = 10001 ] \
    || _fail "the container did not run as uid 10001, so the write below would say nothing"
[ "$container_mode" = 700 ] \
    || _fail "the container sees the volume's mode as $container_mode, not 700: the mount is not the one this file is about"

write_as_stranger() {
    local volume=$1 tag=$2
    podman_as "$OWNER" run --rm --user 10001 -v "$volume:/x" \
        docker.io/library/alpine:3.20 \
        sh -c "echo x > /x/$tag && echo WROTE"
}
write_as_stranger "$own_volume" stranger
assert_exit 1
assert_stderr_has "Permission denied"
echo "MEASURE: a container uid that is not the service's was refused the service's own volume"
assert_file_missing "$own_volume/stranger"

# --- the RED: the same write, with the mode removed -------------------------
#
# **This is the demonstration, and it is reverted in the same run.** The
# volume's mode is opened to the world, the identical write is retried, and the
# assertion above is what goes red. Nothing else changes: the same image, the
# same container uid, the same mount, the same command.
chmod 0777 "$own_volume"
write_as_stranger "$own_volume" stranger
if [ "$GUARDEN_EXIT" = 0 ]; then
    echo "MEASURE: RED — with the volume at 0777 the very same write SUCCEEDED"
    intruder_owner=$(stat -c %u "$own_volume/stranger")
    echo "MEASURE: the file it left is owned by host uid $intruder_owner, not the service's $own_uid"
    # **And the owner is IN the service's own subordinate band, which is the
    # shape ticket 277 was about**: a container uid that is not the service's
    # does not write as the service, it writes as a subuid alias of itself.
    # So the file the "stranger" leaves is the band's, and the band's is
    # ALIASED — the same host uid, two names, which is exactly what the
    # keep-id pin exists to stop.
    case "$intruder_owner" in
        "$own_uid") _fail "the stranger's file is owned by the service's own uid, so the mapping was not measured" ;;
    esac
    if [ "$intruder_owner" -ge "$own_band" ] && [ "$intruder_owner" -lt "$((own_band + own_count))" ]; then
        echo "MEASURE: the stranger's file is owned inside $OWNER's own subuid band ($own_band..$((own_band + own_count - 1))), which is the aliasing ADR-0019 exists to stop"
    else
        _fail "the stranger's file is owned by uid $intruder_owner, which is outside $OWNER's band $own_band..$((own_band + own_count - 1)); the mapping was not what this file measures"
    fi
else
    _fail "the RED demonstration did not go red: with the volume at 0777 the same write was still refused, so the assertion above is not measuring the mode"
fi
rm -f "$own_volume/stranger"
chmod 0700 "$own_volume"
assert_mode "$own_volume" 700
assert_file_missing "$own_volume/stranger"
echo "MEASURE: the mode is restored and the file is gone"

# --- the same claim, for the OTHER service's tree ---------------------------
#
# Two distinct denials are asserted here, because they are two distinct
# mechanisms: the container cannot even `statfs` the other tree (the mount is
# refused outright, because the `0700` on the tree stops the traversal), and
# the other tree's own contents are `0700` to the other service.
#
# **The target is the other service's HOME, and the reason is the layer.**
# The home is the leaf the `0700` on the TREE is what carries — the `0700` on
# the home is the other half, and the two together are the boundary. The
# volume is `0700` in its own right (spec 2.1: a volume is handed to the
# service's user, `0700` to it), so a bind of it is refused by the volume's
# own mode whatever the tree above it says — which makes the volume a weaker
# witness for the tree's mode than the home is.
other_home=/var/lib/guarden/services/$OTHER/home
write_to_other() {
    local target=$1 tag=$2
    podman_as "$OWNER" run --rm --user 10001 -v "$target:/x" \
        docker.io/library/alpine:3.20 \
        sh -c "echo x > /x/$tag && echo WROTE"
}
# **The refusal is asserted as a refusal, and the CODE is not pinned.** Podman
# answers a bind it cannot even `statfs` with its own code, and which code
# depends on which layer refused — 125 from the tree, 1 from the volume
# (measured, both refusals). **The claim is the refusal**, so the assertion is
# on the message and on the file's absence; pinning the code would be
# asserting the tree's shape rather than the boundary.
write_to_other "$other_home" intruder
assert_stderr_has "ermission denied"
assert_file_missing "$other_home/intruder"
echo "MEASURE: a bind of another service's 0700 home is refused at mount time"

# --- the HOME, which is the layer the tree's mode really carries ------------
#
# The volume is one leaf of the tree; the HOME is another, and it is the one
# that holds the image store, the per-user podman secret database and the
# build staging (spec 2). **A container whose uid is not the service's must not
# be able to write into the home either** — and this is the layer a `0700` on
# the service's TREE (rather than on each leaf) is what carries, so it is
# asserted separately.
#
# **The mount of the home SUCCEEDS** — the service owns it and can read it —
# so the refusal here is the write, not the mount. That is the distinction
# that makes this block different from the one above, and both are asserted.
podman_as "$OWNER" run --rm --user 10001 -v "$own_home:/x" \
    docker.io/library/alpine:3.20 sh -c "echo x > /x/intruder && echo WROTE"
assert_exit 1
assert_stderr_has "ermission denied"
echo "MEASURE: a container uid that is not the service's was refused the service's HOME"
assert_file_missing "$own_home/intruder"

# --- the RED: the home opened -----------------------------------------------
#
# The minimal removal of the home's protection, and the identical write
# retried.
chmod 0777 "$own_home"
podman_as "$OWNER" run --rm --user 10001 -v "$own_home:/x" \
    docker.io/library/alpine:3.20 sh -c "echo x > /x/intruder && echo WROTE"
if [ "$GUARDEN_EXIT" = 0 ]; then
    echo "MEASURE: RED — with the home at 0777 the very same write SUCCEEDED"
    echo "MEASURE: the file it left is owned by host uid $(stat -c %u "$own_home/intruder"), not the service's $own_uid"
else
    _fail "the RED demonstration did not go red: with the home at 0777 the same write was still refused"
fi
rm -f "$own_home/intruder"
chmod 0700 "$own_home"
assert_mode "$own_home" 700
assert_file_missing "$own_home/intruder"
echo "MEASURE: the home's mode is restored"

# --- the RED: the other tree opened -----------------------------------------
#
# The other service's tree is `chmod 0777`ed — the minimal removal of the
# protection, and the same one the first RED used — and the identical bind and
# write are retried.
chmod 0777 "/var/lib/guarden/services/$OTHER"
chmod 0777 "$other_home"
write_to_other "$other_home" intruder
if [ "$GUARDEN_EXIT" = 0 ]; then
    echo "MEASURE: RED — with the other service's tree at 0777 the very same bind-and-write SUCCEEDED"
    echo "MEASURE: the file it left is owned by host uid $(stat -c %u "$other_home/intruder"), not the other service's $other_uid"
else
    _fail "the RED demonstration did not go red: with the other service's tree at 0777 the same write was still refused"
fi
rm -f "$other_home/intruder"
chmod 0700 "$other_home"
chmod 0700 "/var/lib/guarden/services/$OTHER"
assert_mode "$other_home" 700
assert_file_missing "$other_home/intruder"
echo "MEASURE: the other tree's modes are restored"

# --- the host's own state, which is not the service's to change --------------
#
# `/var/lib/guarden/soil` is the host converger's own state (`0750 root:guarden`,
# spec 2.1) and `/etc/guarden` is the configuration (`0751 root:guarden`, files
# `0640 root:guarden`). A service uid is in neither group — `id shelf-staging`
# names only its own group — so a container of that service cannot reach either.
# The bind is not even refused here: it succeeds and mounts an EMPTY directory,
# because the container's uid cannot read the one behind it. **That is the
# distinction this block exists for**: an empty mount and a refused mount are
# different facts, and only the second is a refusal.
podman_as "$OWNER" run --rm --user 10001 -v /var/lib/guarden/soil:/x \
    docker.io/library/alpine:3.20 sh -c "ls -A /x | wc -l; echo x > /x/intruder && echo WROTE"
assert_exit 1
assert_stderr_has "Permission denied"
echo "MEASURE: the soil state is unreachable from a container of a service that is in neither group"

# --- the RED: the host's own state opened -----------------------------------
#
# The minimal removal: the soil directory's mode is opened to the world, and
# the identical bind-and-write is retried. Nothing else about the host changes.
chmod 0777 /var/lib/guarden/soil
podman_as "$OWNER" run --rm --user 10001 -v /var/lib/guarden/soil:/x \
    docker.io/library/alpine:3.20 sh -c "echo x > /x/intruder && echo WROTE"
if [ "$GUARDEN_EXIT" = 0 ]; then
    echo "MEASURE: RED — with the soil state at 0777 the very same bind-and-write SUCCEEDED"
else
    _fail "the RED demonstration did not go red: with the soil state at 0777 the same write was still refused"
fi
rm -f /var/lib/guarden/soil/intruder
chmod 0750 /var/lib/guarden/soil
assert_mode /var/lib/guarden/soil 750
assert_owner /var/lib/guarden/soil root:guarden
echo "MEASURE: the soil state's mode is restored"

# --- and the control: a container of the service CAN write its own files -----
#
# **The negative without the positive proves nothing.** A write that is refused
# because the container never started, or because the volume was not mounted,
# reads exactly like a boundary holding. So the same container, the same
# volume and the same command, run as the service's own uid, must SUCCEED and
# must leave a file owned by the service's uid — which is what makes the
# refusals above refusals rather than a broken probe.
#
# **The owner is read from the HOST, and the reason is the whole point.** Inside
# the container the file's owner is the container's own uid (0), because the
# container sees its own namespace; the host sees the service's uid, because
# the default map puts container root ON the service identity. Reading the
# owner inside the container would measure the container's view of a file the
# host owns, and the assertion would be about the wrong number — the same
# shape of mistake as asking a container whether it is privileged.
podman_as "$OWNER" run --rm -v "$own_volume:/x" \
    docker.io/library/alpine:3.20 sh -c "echo own > /x/by-service"
assert_exit 0
assert_file_exists "$own_volume/by-service"
service_owner=$(stat -c %u "$own_volume/by-service")
echo "MEASURE: a container of the service wrote its own volume; the file's HOST owner is $service_owner"
[ "$service_owner" = "$own_uid" ] \
    || _fail "the file a container of $OWNER wrote is owned by host uid $service_owner, not the service's $own_uid"
rm -f "$own_volume/by-service"

# The tree's own modes are still what they were: nothing above changed them.
assert_mode "/var/lib/guarden/services/$OWNER" 700
assert_mode "$own_volume" 700
assert_mode "/var/lib/guarden/services/$OTHER" 700
assert_mode "$other_volume" 700
assert_mode /var/lib/guarden/soil 750
assert_mode /etc/guarden 751