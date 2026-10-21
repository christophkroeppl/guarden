#!/usr/bin/env bash
# THROWAWAY PROBE — measures what the runbook's chown actually does to a
# service's volume under a keep-id pin. Built, read, deleted.

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

staged=/var/lib/guarden/staging/kidp/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: kidp" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data" \
    "bulk:" \
    "  - scratch"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the probe container" \
    "" \
    "[Container]" \
    "Image=localhost/kidp-staging:latest" \
    "Volume=data:/data" \
    "Volume=scratch:/scratch"
seed "$staged/Containerfile" \
    "FROM docker.io/library/alpine:3.20" \
    "RUN adduser -D -u 10001 kiduser" \
    "USER 10001" \
    "CMD [\"sleep\", \"3600\"]"

run weedr service ingest kidp-staging --from poke kidp@0000001
assert_exit 0
run weedr service build kidp-staging
assert_exit 0

home=/var/lib/guarden/services/kidp-staging/home
svc_uid=$(id -u kidp-staging)
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done

state_vol=/var/lib/guarden/services/kidp-staging/state/data
bulk_vol=/var/lib/guarden/services/kidp-staging/bulk/scratch

echo "PROBE: svc_uid=$svc_uid state=$state_vol bulk=$bulk_vol"
echo "PROBE: state owner before=$(stat -c %u "$state_vol") bulk owner before=$(stat -c %u "$bulk_vol")"
echo "PROBE: state .snapshots owner=$(stat -c %u "$state_vol/.snapshots" 2>&1)"

run weedr service start kidp-staging
assert_exit 0

container=kidp-staging-app
for _ in $(seq 1 60); do
    run_in "$home" setpriv --reuid=kidp-staging --regid=kidp-staging --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER=kidp-staging LOGNAME=kidp-staging \
        XDG_RUNTIME_DIR="$runtime" podman exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then break; fi
    sleep 2
done

as_svc() {
    run_in "$home" setpriv --reuid=kidp-staging --regid=kidp-staging --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER=kidp-staging LOGNAME=kidp-staging \
        XDG_RUNTIME_DIR="$runtime" "$@"
}

# --- the state volume: the runbook's command, verbatim ----------------------
as_svc podman unshare chown -R 10001:10001 "$state_vol"
echo "PROBE: state chown exit=$GUARDEN_EXIT"
echo "PROBE: state chown stderr=$(tr '\n' '|' <"$GUARDEN_STDERR")"
echo "PROBE: state owner AFTER=$(stat -c %u "$state_vol")"

as_svc podman exec "$container" sh -c 'id -u > /data/after-state-chown'
echo "PROBE: write into state after the chown: exit=$GUARDEN_EXIT"
echo "PROBE: write stderr=$(tr '\n' '|' <"$GUARDEN_STDERR")"
echo "PROBE: state dir listing=$(ls -la "$state_vol" 2>&1 | tr '\n' '|')"

# --- the bulk volume: the same command, on a tree with no .snapshots -------
as_svc podman unshare chown -R 10001:10001 "$bulk_vol"
echo "PROBE: bulk chown exit=$GUARDEN_EXIT"
echo "PROBE: bulk chown stderr=$(tr '\n' '|' <"$GUARDEN_STDERR")"
echo "PROBE: bulk owner AFTER=$(stat -c %u "$bulk_vol")"

as_svc podman exec "$container" sh -c 'id -u > /scratch/after-bulk-chown'
echo "PROBE: write into bulk after the chown: exit=$GUARDEN_EXIT"
echo "PROBE: write stderr=$(tr '\n' '|' <"$GUARDEN_STDERR")"

echo "PROBE: bulk listing=$(ls -la "$bulk_vol" 2>&1 | tr '\n' '|')"

# --- what the container thinks the owners are -------------------------------
as_svc podman exec "$container" ls -lan /data /scratch
echo "PROBE: container view exit=$GUARDEN_EXIT"
echo "PROBE: container view=$(tr '\n' '|' <"$GUARDEN_STDOUT")"

as_svc podman exec "$container" cat /proc/self/uid_map
echo "PROBE: uid_map=$(tr '\n' '|' <"$GUARDEN_STDOUT")"

echo "PROBE: done"
