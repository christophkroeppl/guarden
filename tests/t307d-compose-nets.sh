#!/usr/bin/env bash
# Compose networks as pod membership (ticket 307d, ADR-0026, spec §6.3/§7.1).
#
# What this proves:
#
#   1. A 2-service compose on the app's own network renders ONE `.pod` with both
#      containers as members.
#   2. A service with no `ports:` renders no `PublishPort=` anywhere.
#   3. `container_name:` and the service name both resolve for `AddHost=` — a
#      sibling dials the declared container name, and an edge dials the service
#      name.
#
# Real host, real useradd, real subuid range, real rootless podman, real pasta:
# `GUARDEN_PREFIX=/`.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-measured.toml
cp "$GUARDEN_ROOT/src/guarden/templates/podlet.release" "$GUARDEN_PREFIX/etc/guarden/podlet.release"
run soil packages --apply
assert_exit 0
run soil install --apply
assert_exit 0

# --- 1. a 2-service compose on one network renders ONE pod -------------------

staged=/var/lib/guarden/staging/twopod/0000001
mkdir -p "$staged/.guarden"
seed "$staged/.guarden/service.yml" \
    "project: twopod" "units: compose.yaml" \
    "" \
    "ports:" \
    "  - container: web" \
    "    port: 3000" \
    "  - container: worker" \
    "    port: 3001" \
    "siblings:" \
    "  - container: worker" \
    "    port: 3001"
seed "$staged/compose.yaml" \
    "services:" \
    "  web:" \
    "    image: docker.io/library/alpine:3.20" \
    "    networks:" \
    "      - twopod" \
    "    command: [\"sleep\", \"3600\"]" \
    "  worker:" \
    "    image: docker.io/library/alpine:3.20" \
    "    networks:" \
    "      - twopod" \
    "    command: [\"sleep\", \"3600\"]" \
    "networks:" \
    "  twopod: {}"
run weedr service ingest twopod-staging --from poke twopod@0000001
assert_exit 0
assert_stdout_has "created twopod-staging"

svc=twopod-staging
tree=/var/lib/guarden/services/$svc
home=$tree/home
units=$home/.config/containers/systemd
svc_uid=$(id -u "$svc")
svc_gid=$(id -g "$svc")
runtime=/run/user/"$svc_uid"

# Exactly one `.pod` in the directory.
count=$(find "$units" -maxdepth 1 -name '*.pod' | wc -l)
[ "$count" = 1 ] \
    || _fail "the service's unit directory holds $count .pod files, not one: $(ls "$units" | tr '\n' ' ')"

pod_unit=$units/twopod.pod
assert_file_exists "$pod_unit"
assert_file_has "$pod_unit" "[Pod]"
assert_file_has "$pod_unit" "Network=pasta:"
assert_file_has "$pod_unit" "PublishPort=127.0.0.1"
assert_file_has "$pod_unit" "PublishPort=127.0.0.1"

for container in web worker; do
    unit=$units/$container.container
    assert_file_exists "$unit"
    assert_file_has "$unit" "Pod=twopod.pod"
    assert_file_lacks "$unit" "Network="
    assert_file_lacks "$unit" "PublishPort="
done

# The pod actually runs.
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_dir_exists "$runtime"

run weedr service start "$svc"
assert_exit 0
assert_stdout_has "started"

podman_as() {
    run_in "$home" setpriv --reuid="$svc" --regid="$svc" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$svc" LOGNAME="$svc" \
        XDG_RUNTIME_DIR="$runtime" podman "$@"
}

podman_as pull docker.io/library/alpine:3.20
assert_exit 0

ready=0
for _ in $(seq 1 40); do
    up=0
    for container in "$svc-web" "$svc-worker"; do
        podman_as exec "$container" true
        if [ "$GUARDEN_EXIT" = 0 ]; then
            up=$((up + 1))
        fi
    done
    if [ "$up" = 2 ]; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" = 1 ] \
    || _fail "the two containers of $svc never became exec-able: $(podman_as ps -a 2>&1 | tr '\n' '|')"

podman_as pod ps --format '{{.Name}}'
assert_exit 0
assert_stdout_has "systemd-twopod"

podman_as pod inspect systemd-twopod --format '{{range .Containers}}{{.Name}} {{end}}'
assert_exit 0
assert_stdout_has "$svc-web"
assert_stdout_has "$svc-worker"

# --- 2. a service with no ports: renders no PublishPort ---------------------

noport=$GUARDEN_FIXTURES/noport
seed "$noport/.guarden/service.yml" "project: noport" "units: compose.yaml"
seed "$noport/compose.yaml" \
    "services:" \
    "  web:" \
    "    image: docker.io/library/nginx:1.27" \
    "networks:" \
    "  noport: {}"
run loom check "$noport"
assert_exit 0
assert_stderr_empty

seed "$GUARDEN_PREFIX/var/lib/guarden/registry/noport-staging.toml" \
    'service = "noport-staging"' 'workload = "noport"' 'project = "noport"' \
    'environment = "staging"' 'uid = 1103' 'created = "2026-09-30T09:00:00Z"'
out=$GUARDEN_FIXTURES/noport-render
run loom render "$noport" --service noport-staging --out "$out"
assert_exit 0
assert_stderr_empty
pod=$out/units/noport.pod
assert_file_exists "$pod"
assert_file_lacks "$pod" "PublishPort"

# --- 3. container_name: and the service name both resolve for AddHost ---------

addhost=$GUARDEN_FIXTURES/addhost
seed "$addhost/.guarden/service.yml" "project: addhost" "units: compose.yaml" \
    "" \
    "ports:" \
    "  - container: web" \
    "    port: 3000" \
    "siblings:" \
    "  - container: sidecar" \
    "    port: 4000" \
    "needs:" \
    "  - service: provider-staging" \
    "    as: api" \
    "    port: 5000" \
    "    auth: none"
seed "$addhost/compose.yaml" \
    "services:" \
    "  web:" \
    "    image: docker.io/library/alpine:3.20" \
    "    networks:" \
    "      - addhost" \
    "    command: [\"sleep\", \"3600\"]" \
    "  sidecar:" \
    "    image: docker.io/library/alpine:3.20" \
    "    container_name: the-sidecar" \
    "    networks:" \
    "      - addhost" \
    "    command: [\"sleep\", \"3600\"]" \
    "networks:" \
    "  addhost: {}"
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/provider-staging.toml" \
    'service = "provider-staging"' 'workload = "provider"' 'project = "provider"' \
    'environment = "staging"' 'uid = 1105' 'created = "2026-09-30T09:00:00Z"' \
    '[provides]' 'kinds = [ "api" ]'
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/addhost-staging.toml" \
    'service = "addhost-staging"' 'workload = "addhost"' 'project = "addhost"' \
    'environment = "staging"' 'uid = 1104' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20117' 'sidecar = 20118' \
    '[edges."provider-staging:5000:api"]' 'port = 5000' 'as = "api"' 'auth = "none"' \
    'publications = [ 20008 ]'
out=$GUARDEN_FIXTURES/addhost-render
run loom render "$addhost" --service addhost-staging --out "$out"
assert_exit 0
assert_stderr_empty

# The pod's AddHost carries the service name for the edge and the container_name
# for the sibling. The container's own name is not added: it resolves to itself.
pod=$out/units/addhost.pod
assert_file_has "$pod" "AddHost=provider-staging:10.0.2.2"
assert_file_has "$pod" "AddHost=the-sidecar:10.0.2.2"
assert_file_lacks "$pod" "AddHost=web:"
