#!/usr/bin/env bash
# Ticket 277: a volume is owned by the service uid, but the container may run
# as another — and the runbook's remedy for it BREAKS a pinned deployment.
#
# **What this file is.** ADR-0019 (accepted 2026-10-18) settled ticket 277's
# question by deciding the opposite of what the ticket proposed: guarden probes
# the image's user at first start and renders `UserNS=keep-id:uid=…,gid=…`,
# which maps the image's uid ONTO THE SERVICE IDENTITY. Under that pin the
# container's uid 10001 IS the host uid of the service user, so the 0700
# service-owned volume is writable — and `tests/t350-keepid.sh` measures it.
#
# **The residue this file measures.** The runbook still tells the operator to
# do the thing the pin made wrong. `docs/sysadmin.md` says:
#
#     The step is `podman unshare chown -R <image uid>:<image uid> <volume>`,
#     run as the service user (tickets 273 and 277).
#
# That step chowns the volume's tree to the IMAGE's uid. Under the pin, the
# image's uid is mapped onto the service identity — so a tree owned by host uid
# 10001 is owned, in the container's own namespace, by a uid the pin maps into
# the service's SUBUID band, and the container loses the write it had. The
# operator follows the runbook and breaks a deployment that was working.
#
# **Two claims, and each is a measurement of the machine:**
#
#   * **the pin case**: a service whose image declares `USER 10001`, deployed
#     and started with NO manual chown anywhere in this file, writes into its
#     own `state/data` volume from inside the container, and the file lands on
#     the host owned by the SERVICE uid. The volume's owner never became the
#     image's uid and never had to.
#   * **the runbook's remedy**: the SAME service, with the runbook's chown
#     applied — `podman unshare chown -R 10001:10001 <volume>` as the service
#     user — loses the write. The container's uid 10001 now lands on a
#     subuid-aliased owner and the write is refused.
#
# The second claim is what makes the first one load-bearing: it says the
# runbook's instruction is not merely unnecessary under the pin, it is
# destructive, and the reason is a property of the mapping rather than of any
# one image.
#
# Real host, real `useradd`, real subuid range, real rootless podman, real
# systemd: `GUARDEN_PREFIX=/`, as `t350-keepid.sh` does.

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

# --- the service: a Containerfile that drops to a non-root uid --------------
#
# The staged tree is written here rather than shipped as a fixture: `fixtures/`
# holds configuration inputs and manifests, and a Containerfile a suite needs
# is staged the way `t230-build` seeds one into a service's home.

staged=/var/lib/guarden/staging/kidv/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: kidv" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the volume-owner probe container" \
    "" \
    "[Container]" \
    "Image=localhost/kidv-staging:latest" \
    "Volume=data:/data"
seed "$staged/Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 10001 kiduser" \
    "USER 10001" \
    "CMD [\"sleep\", \"3600\"]"

run weedr service ingest kidv-staging --from poke kidv@0000001
assert_exit 0
run weedr service build kidv-staging
assert_exit 0
assert_stdout_has "localhost/kidv-staging:latest"

home=/var/lib/guarden/services/kidv-staging/home
unit=$home/.config/containers/systemd/app.container
record=$registry/kidv-staging.toml
svc_uid=$(id -u kidv-staging)
volume=/var/lib/guarden/services/kidv-staging/state/data
dropin_dir=/etc/containers/systemd/users/"$svc_uid"/app.container.d
pin=$dropin_dir/50-guarden-keepid.conf

# The image's own uid, read from the image's own passwd, the way the probe
# reads it — so the number asserted below is the image's and not a constant
# this file made up.

runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman run --rm --user 0 --entrypoint cat localhost/kidv-staging:latest /etc/passwd
assert_exit 0
image_uid=$(grep ":x:10001:" "$GUARDEN_STDOUT" | cut -d: -f3 || true)
[ -n "$image_uid" ] || _fail "the image's passwd names no entry for uid 10001 to resolve against"
echo "MEASURE: the image declares uid $image_uid"

# --- the volume's owner, before anything starts ----------------------------
#
# The volume is the service's, owned by the service uid, 0700 — the spec's
# rule (8.1) and the isolation boundary. This is asserted BEFORE the start so
# a reader can see the owner the create path chose and that the start does not
# change it.

assert_subvolume "$volume"
vol_owner=$(stat -c %u "$volume")
[ "$vol_owner" = "$svc_uid" ] \
    || _fail "the volume $volume is owned by host uid $vol_owner, not the service uid $svc_uid"
echo "MEASURE: the volume's owner before the start: $vol_owner"

# --- the pin, and the write it makes possible ------------------------------
#
# The start probes the image's user and renders the line. The volume is NOT
# chowned by this file, by the create path, or by anything else: the pin is
# what makes the write possible.

run weedr service start kidv-staging
assert_exit 0

container=kidv-staging-app
ready=0
for _ in $(seq 1 60); do
    run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
        XDG_RUNTIME_DIR="$runtime" podman exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] || _fail "the container $container never became exec-able"

# The pin guarden wrote, read out of the file guarden wrote it into.
assert_file_exists "$pin"
assert_file_has "$pin" "UserNS=keep-id:uid=10001"
assert_file_lacks "$unit" "UserNS="

# The write, from inside the container, into the service's own volume.
run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u > /data/written-by'
assert_exit 0

written=$volume/written-by
assert_file_exists "$written"
inside=$(cat "$written")
[ "$inside" = "10001" ] \
    || _fail "the container reports uid $inside inside; the image's uid 10001 must not change"
owner=$(stat -c %u "$written")
[ "$owner" = "$svc_uid" ] \
    || _fail "the file written inside the container is owned by host uid $owner, not the service uid $svc_uid"
echo "MEASURE: the file the container wrote is owned by host uid $owner (the service uid)"

# The volume's owner is UNCHANGED by the start: the pin did not need to
# change it, and a create path that had chowned it to the image's uid would
# have changed it.
vol_owner_after=$(stat -c %u "$volume")
[ "$vol_owner_after" = "$svc_uid" ] \
    || _fail "the volume $volume is owned by host uid $vol_owner_after after the start, not the service uid $svc_uid — the pin makes the write possible without touching the owner"

# --- the runbook's remedy, and what it does to a working deployment ---------
#
# `docs/sysadmin.md` tells the operator: "The step is `podman unshare chown -R
# <image uid>:<image uid> <volume>`, run as the service user (tickets 273 and
# 277)." This block applies exactly that, as the service user, and then asks
# the container to write again.
#
# The expectation is a REFUSAL, and the reason is the pin: the image's uid is
# mapped onto the service identity, so a tree owned by host uid 10001 is owned
# in the container by a uid that lands in the service's subuid band, and the
# container's own uid 10001 — which the pin put on the service identity — no
# longer owns what it wrote a moment ago.

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman unshare chown -R "$image_uid:$image_uid" "$volume"
assert_exit 0
echo "MEASURE: the runbook's chown applied: $(stat -c %u "$volume")"

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u > /data/written-after-chown'
echo "MEASURE: the write after the runbook's chown: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_stderr_has "Permission denied"
echo "MEASURE: the runbook's chown costs the container its write on the volume"

# The tree is the image's uid now, which is what the runbook's step produced.
chowned_owner=$(stat -c %u "$volume")
[ "$chowned_owner" = "$image_uid" ] \
    || _fail "the volume $volume is owned by host uid $chowned_owner after the runbook's chown, not the image's uid $image_uid"

echo "ok t277-volume-owner.sh"
