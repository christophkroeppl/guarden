#!/usr/bin/env bash
# Ticket 277: a volume is owned by the service uid, but the container may run
# as another — and the runbook's remedy for it BREAKS a working deployment.
#
# **What this file is.** ADR-0019 (accepted 2026-10-18) settled ticket 277's
# question by deciding the opposite of what the ticket proposed: guarden probes
# the image's user at first start and renders `UserNS=keep-id:uid=…,gid=…`,
# which maps the image's uid ONTO THE SERVICE IDENTITY. Under that pin the
# container's uid 10001 IS the host uid of the service user, so the 0700
# service-owned volume is writable — with the volume owned by the service uid,
# and with no chown anywhere.
#
# **The residue this file measures.** The runbook still prescribed the step the
# pin made wrong. `docs/sysadmin.md` said:
#
#     The step is `podman unshare chown -R <image uid>:<image uid> <volume>`,
#     run as the service user (tickets 273 and 277).
#
# That step moves the volume's tree onto a uid the container does not own
# under the pin, and the measurement below is what it costs.
#
# **Three claims, and each is a measurement of the machine:**
#
#   * **the create path's owner** (the decision lock): the volume is owned by
#     the SERVICE uid before the start and after it, the container writes into
#     it with no chown anywhere in this file, and the file lands on the host
#     owned by the service uid. **The volume's owner must NOT become the
#     image's uid** — the pin is what makes the container's write possible, and
#     a chown to the image's uid takes it away.
#   * **what the runbook's step costs**, measured on both kinds of volume. On a
#     `bulk` volume the chown COMPLETES, the tree ends up owned by the
#     subuid-aliased host uid, and the container's write is refused. On a
#     `state` volume the chown FAILS on snapper's root-owned `.snapshots` —
#     and it has already moved the volume's own owner when it does, so a
#     command that reports failure still breaks the deployment.
#   * **the spec's `[ownership]` sentence, measured**: §3.3 now records that the
#     table ADR-0021 decided is refused by the program until it lands. A
#     sentence about an exit code is a claim about a machine, so the file the
#     spec names is written here and the verb that reads it is asked.
#   * **the tree does not prescribe it any more**: a grep over the standing
#     documents and the programs for the step, the same shape as t350's
#     refuted-claims block. A runbook that tells an operator to break a
#     working deployment is a defect, and this is where it is caught.
#
# Real host, real `useradd`, real subuid range, real rootless podman, real
# systemd: `GUARDEN_PREFIX=/`, as `t350-keepid.sh` does.

# machine: fresh
#
# The documents are in this suite's read set because the first and the last
# claim are assertions about their text. `docs/` is out of every cache key by
# design, so a suite that asserts on a document is the one whose result has to
# move when that document does — without this line the suite that catches a
# runbook reintroducing the step would inherit its green over the edit
# (ticket 309).
# reads: docs/spec.md docs/sysadmin.md CONTEXT.md AGENTS.md

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
#
# It declares BOTH kinds of volume, because the runbook's step behaves
# differently on each and the difference is the measurement.

staged=/var/lib/guarden/staging/kidv/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: kidv" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data" \
    "bulk:" \
    "  - scratch"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the volume-owner probe container" \
    "" \
    "[Container]" \
    "Image=localhost/kidv-staging:latest" \
    "Volume=data:/data" \
    "Volume=scratch:/scratch"
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
state_vol=/var/lib/guarden/services/kidv-staging/state/data
bulk_vol=/var/lib/guarden/services/kidv-staging/bulk/scratch
dropin_dir=/etc/containers/systemd/users/"$svc_uid"/app.container.d
pin=$dropin_dir/50-guarden-keepid.conf

# The image's own uid, read from the image's own passwd, the way the probe
# reads it — so the number asserted below is the image's and not a constant
# this file made up. And the service's subuid base, read from the host's own
# `/etc/subuid`, because the host uid the runbook's step lands the tree on is
# DERIVED from it and the derivation is the claim.

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

subuid_base=$(grep "^kidv-staging:" /etc/subuid | cut -d: -f2 || true)
[ -n "$subuid_base" ] || _fail "/etc/subuid holds no range for kidv-staging"
aliased_uid=$((subuid_base + image_uid - 1))
echo "MEASURE: the service's subuid base is $subuid_base, so the image's uid $image_uid is host uid $aliased_uid"

# --- claim 1: the create path's owner, and the write it allows --------------
#
# The volume is the service's, owned by the service uid, 0700 — the spec's rule
# (8.1) and the isolation boundary. Asserted BEFORE the start, so a reader can
# see the owner the create path chose.

assert_subvolume "$state_vol"
assert_subvolume "$bulk_vol"
for volume in "$state_vol" "$bulk_vol"; do
    owner=$(stat -c %u "$volume")
    [ "$owner" = "$svc_uid" ] \
        || _fail "the volume $volume is owned by host uid $owner, not the service uid $svc_uid"
done
echo "MEASURE: both volumes are owned by the service uid $svc_uid before the start"

# The start probes the image's user and renders the line. The volumes are NOT
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

# **The file lands in the volume's PAYLOAD, one level down inside the
# subvolume** (ADR-0020): the unit mounts `state/data/data`, so a write at
# `/data` inside the container is a write into the payload and never into the
# subvolume root that carries snapper's root-owned `.snapshots` subtree.
written=$state_vol/data/written-by
assert_file_exists "$written"
inside=$(cat "$written")
[ "$inside" = "10001" ] \
    || _fail "the container reports uid $inside inside; the image's uid 10001 must not change"
owner=$(stat -c %u "$written")
[ "$owner" = "$svc_uid" ] \
    || _fail "the file written inside the container is owned by host uid $owner, not the service uid $svc_uid"
echo "MEASURE: the file the container wrote is owned by host uid $owner (the service uid)"

# **The decision lock.** The volume's owner is UNCHANGED by the start: the pin
# did not need to change it, and a create path that had chowned it to the
# image's uid would have changed it. A later implementer reading this ticket
# must not "fix" it by making the owner the image's uid — that is the step
# claim 2 measures the cost of.
for volume in "$state_vol" "$bulk_vol"; do
    owner=$(stat -c %u "$volume")
    [ "$owner" = "$svc_uid" ] \
        || _fail "the volume $volume is owned by host uid $owner after the start, not the service uid $svc_uid — the pin makes the write possible without touching the owner"
done

# --- the spec's §3.3 sentence, measured --------------------------------------
#
# ADR-0021 decided `[ownership]` and ticket 308's item 2 implements it. Until
# then §3.3 says a file carrying the table is REFUSED by name, with exit 1 —
# and a sentence about an exit code is a claim about a machine. So the file the
# spec documents is written here, and the verb that reads `overrides.toml` is
# asked. `weedr expose set` is the cheapest caller: it loads the grants before
# it writes anything, so a refused file leaves the record untouched.
#
# The day the table lands this section fails with "expected exit 1, got 0", and
# that failure is the reminder that §3.3 and the ADR both have to stop calling
# it unimplemented in the same change.

mkdir -p /etc/guarden/services/kidv-staging
seed /etc/guarden/services/kidv-staging/overrides.toml \
    "[ownership]" \
    'volumes = { "data" = 999 }'
run weedr expose set kidv-staging loopback
echo "MEASURE: a file carrying the table §3.3 records: exit=$GUARDEN_EXIT $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_stderr_has "unknown key 'ownership'"
rm -f /etc/guarden/services/kidv-staging/overrides.toml

# --- claim 2: what the runbook's step costs ---------------------------------
#
# The step the runbook prescribed, verbatim: `podman unshare chown -R <image
# uid>:<image uid> <volume>`, run as the service user.
#
# **On a BULK volume it completes.** A bulk volume carries no snapper
# configuration and therefore no `.snapshots`, so nothing refuses it — and the
# tree ends up owned by the subuid-aliased host uid, which under the pin is a
# uid the container does not own, so the container's write is refused.

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman unshare chown -R "$image_uid:$image_uid" "$bulk_vol"
assert_exit 0
bulk_owner=$(stat -c %u "$bulk_vol")
[ "$bulk_owner" = "$aliased_uid" ] \
    || _fail "the bulk volume $bulk_vol is owned by host uid $bulk_owner after the runbook's chown, not the subuid-aliased host uid $aliased_uid"
echo "MEASURE: the runbook's chown left the bulk volume owned by host uid $bulk_owner (the image's uid, aliased)"

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u > /scratch/after-bulk-chown'
echo "MEASURE: the write into the bulk volume after the chown: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_stderr_has "Permission denied"
echo "MEASURE: the runbook's chown costs the container its write on the volume"

# **On a STATE volume it FAILS — and it has already moved the owner when it
# does.** Snapper's `.snapshots` is root-owned `0750` and a read-only btrfs
# subvolume, so the recursive chown cannot complete; but the walk chowns the
# volume's own root before it reaches `.snapshots`, so a command that reports
# failure has already broken the deployment. This is the sharper half of the
# claim: the operator sees a red command and a broken volume.

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman unshare chown -R "$image_uid:$image_uid" "$state_vol"
echo "MEASURE: the runbook's chown on the state volume: exit=$GUARDEN_EXIT"
echo "MEASURE: its stderr: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_stderr_has ".snapshots"

state_owner=$(stat -c %u "$state_vol")
[ "$state_owner" = "$aliased_uid" ] \
    || _fail "the state volume $state_vol is owned by host uid $state_owner after the runbook's FAILED chown, not the subuid-aliased host uid $aliased_uid — a chown that reports failure has already moved the owner"
echo "MEASURE: the failed chown still moved the state volume onto host uid $state_owner"

run_in "$home" setpriv --reuid=kidv-staging --regid=kidv-staging --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER=kidv-staging LOGNAME=kidv-staging \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'id -u > /data/after-state-chown'
echo "MEASURE: the write into the state volume after the failed chown: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_exit 1
assert_stderr_has "Permission denied"

# --- claim 3: the tree does not prescribe it any more ------------------------
#
# The same shape as t350's refuted-claims block: prose is the one surface no
# assertion in this family reads, which is how a superseded rule survives in a
# runbook. The standing documents and the programs are the scope — the spec,
# the runbook, the glossary and the sources — and NOT `docs/tickets/`, which
# is the findings ledger where a finding is recorded and this ticket's own file
# is deleted when the work merges.
#
# The bracketed spellings keep this line out of its own match, and `-I` keeps a
# stale `__pycache__` byte-compilation of an older docstring from answering for
# the file beside it.

run grep -rnI -e 'unshare chown' -e 'chown -R <image' -e 'chown -R 10001' \
    "$GUARDEN_ROOT/docs/spec.md" \
    "$GUARDEN_ROOT/docs/sysadmin.md" \
    "$GUARDEN_ROOT/CONTEXT.md" \
    "$GUARDEN_ROOT/AGENTS.md" \
    "$GUARDEN_ROOT/src"
echo "MEASURE: the superseded step still in the tree: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_exit 1

echo "ok t277-volume-owner.sh"
