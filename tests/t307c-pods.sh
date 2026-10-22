#!/usr/bin/env bash
# A pod is one network namespace per service, and the renderer builds it
# (ticket 307c, ADR-0026, spec §4/§6.3/§7.1).
#
# What this proves, in four parts:
#
#   1. **One app with two containers renders ONE `.pod`**, both container units
#      carry `Pod=<pod>.pod`, neither carries `Network=` or `PublishPort=`, and
#      the pod's own unit carries the host's pasta backend and the whole
#      published set — the two lines that moved.
#   2. **The pod the renderer writes actually runs**: two REAL containers in
#      one podman pod, one serving and one fetching over `127.0.0.1` (the
#      namespace they share), and the host reaching the same server through
#      the pod's publication on `127.0.0.1`. Both halves are needed: the
#      loopback round-trip proves the shared namespace, and the publication
#      proves the port the renderer moved onto the pod is the one the host
#      binds.
#   3. **The pod starts before its containers and stops after them** — the
#      generated container unit carries the dependency quadlet emits for
#      `Pod=`, and `weedr service stop` leaves the pod's own unit inactive.
#   4. **The shapes and the refusal.** `[pod] name` renames the one pod, two
#      apps naming two pods are two services and two pods, omitting `[pod]`
#      yields the workload's name, `loom check` renders all four with no host,
#      and a service whose containers' images run as DIFFERENT uids is refused
#      with both uids and both containers named — because a pod shares ONE user
#      namespace and its keep-id pin can put exactly one image uid on the
#      service user.
#
# Real host, real useradd, real subuid range, real rootless podman, real pasta:
# `GUARDEN_PREFIX=/`, the way `t350-keepid` and `t307-pod-keepid` do.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
run soil install --apply
assert_exit 0

# --- 1. one app, two containers, one pod -----------------------------------
#
# The default shape: the manifest omits `[pod]`, so the pod is named after the
# service's workload — `podprobe` for `podprobe-staging`, which is the project
# name for a repository that ships one app at its root.
staged=/var/lib/guarden/staging/podprobe/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: podprobe" \
    "units: .guarden/quadlet/" \
    "" \
    "ports:" \
    "  - container: web" \
    "    port: 3000" \
    "  - container: worker" \
    "    port: 3001"
seed "$staged/.guarden/quadlet/web.container" \
    "[Unit]" \
    "Description=the pod's server" \
    "" \
    "[Container]" \
    "Image=docker.io/library/alpine:3.20" \
    "Exec=sleep 3600"
seed "$staged/.guarden/quadlet/worker.container" \
    "[Unit]" \
    "Description=the pod's client" \
    "" \
    "[Container]" \
    "Image=docker.io/library/alpine:3.20" \
    "Exec=sleep 3600"
run weedr service ingest podprobe-staging --from poke podprobe@0000001
assert_exit 0
assert_stdout_has "created podprobe-staging"

svc=podprobe-staging
tree=/var/lib/guarden/services/$svc
home=$tree/home
units=$home/.config/containers/systemd
svc_uid=$(id -u "$svc")
svc_gid=$(id -g "$svc")
runtime=/run/user/"$svc_uid"

pod_unit=$units/podprobe.pod
assert_file_exists "$pod_unit"
assert_file_has "$pod_unit" "[Pod]"

# The backend moved to the pod, and the whole published set with it: podman
# binds a pod's ports on the pod, so a member container carries none of its own
# (spec §7.4). The option set is read out of the host's own installed
# guarden.toml rather than written here a second time — a suite that hardcoded
# it would be asserting its own constant.
pasta=$(sed -n 's/^pasta_options = \[\(.*\)\]$/\1/p' /etc/guarden/guarden.toml | tr -d ' "')
[ -n "$pasta" ] \
    || _fail "the installed /etc/guarden/guarden.toml carries no pasta_options line, so there is no backend to assert"
assert_file_has "$pod_unit" "Network=pasta:$pasta"

# The publication numbers are the host's allocation, in the service's own
# registry — read from there rather than guessed, because the renderer writes
# whatever the mutator allocated.
record=/var/lib/guarden/registry/$svc.toml
assert_file_exists "$record"
publication() {
    sed -n "/^\[publication\]/,/^\[/s/^$2 = //p" "$1" | head -1
}
web_pub=$(publication "$record" web)
worker_pub=$(publication "$record" worker)
[ -n "$web_pub" ] && [ -n "$worker_pub" ] \
    || _fail "the registry entry of $svc allocates no publication for web and worker: $(tr '\n' '|' <"$record")"
assert_file_has "$pod_unit" "PublishPort=127.0.0.1:$web_pub:3000"
assert_file_has "$pod_unit" "PublishPort=127.0.0.1:$worker_pub:3001"

for container in web worker; do
    unit=$units/$container.container
    assert_file_exists "$unit"
    assert_file_has "$unit" "Pod=podprobe.pod"
    assert_file_lacks "$unit" "Network="
    assert_file_lacks "$unit" "PublishPort="
done

# Exactly one `.pod` in the directory: two names for one app would be a pod the
# service cannot start, and a second pod is what a second network namespace
# would look like.
count=$(find "$units" -maxdepth 1 -name '*.pod' | wc -l)
[ "$count" = 1 ] \
    || _fail "the service's unit directory holds $count .pod files, not one: $(ls "$units" | tr '\n' ' ')"

# --- 2. the pod runs, and its loopback is shared ---------------------------
# The runtime directory exists only once the service user's manager has
# started; the poll asks for the state the reads below need.
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_dir_exists "$runtime"

run weedr service start "$svc"
assert_exit 0
assert_stdout_has "started"

# podman_as <args...>: podman as the service user, with the environment a
# rootless podman needs. `runuser` keeps root's environment and keep-id reads
# `$USER` to find the subuid range, so the environment is stated.
podman_as() {
    run_in "$home" setpriv --reuid="$svc" --regid="$svc" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$svc" LOGNAME="$svc" \
        XDG_RUNTIME_DIR="$runtime" podman "$@"
}

# The image is pulled as the SERVICE user: a pull as root lands in root's store,
# which this user cannot use.
podman_as pull docker.io/library/alpine:3.20
assert_exit 0

# Both containers are up before either is asked anything: `run -d` returns
# before the process inside is ready, and a container that never started is a
# measurement of nothing. The poll asks the question the reads need answered.
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

# The pod is the renderer's, so its name is the unit's: a `.pod` file named
# `podprobe.pod` is the `podprobe-pod.service` unit and the `systemd-podprobe`
# podman pod (measured against podman 5.7.0's generator).
podman_as pod ps --format '{{.Name}}'
assert_exit 0
echo "MEASURE: the pods the service user has: $(tr '\n' ' ' <"$GUARDEN_STDOUT")"
assert_stdout_has "systemd-podprobe"

podman_as pod inspect systemd-podprobe --format '{{range .Containers}}{{.Name}} {{end}}'
assert_exit 0
echo "MEASURE: the containers of the pod: $(cat "$GUARDEN_STDOUT")"
assert_stdout_has "$svc-web"
assert_stdout_has "$svc-worker"

# **Does a member accept `--add-host`?** §7.3's name map is `AddHost=` on the
# member container, and ADR-0026 keeps it there because `/etc/hosts` belongs to
# the container. That is measured here rather than assumed: if podman refuses
# the flag on a container joining a pod, the name map has to move to the pod.
podman_as run --rm --pod systemd-podprobe --add-host edge:10.0.2.2 \
    docker.io/library/alpine:3.20 true
echo "MEASURE: a member container's --add-host: exit $GUARDEN_EXIT, $(tr '\n' '|' <"$GUARDEN_STDERR")"

# The server is the container's OWN init process — a `while` loop around a
# one-shot `nc` listening on the pod's loopback — so the round-trip below is
# between two containers and not between two `podman exec` calls.
podman_as exec -d "$svc-web" sh -c \
    'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 18\r\nConnection: close\r\n\r\npod-roundtrip-307c" | nc -l -p 3000; done'
assert_exit 0

# A container-to-container fetch over 127.0.0.1 is what the shared namespace
# buys (ADR-0026's traded property). The server's `nc` needs a moment to bind,
# and the poll asks for the PAYLOAD rather than for a connect.
trip=0
for _ in $(seq 1 20); do
    podman_as exec "$svc-worker" wget -qO- http://127.0.0.1:3000/proof.txt
    if [ "$GUARDEN_EXIT" = 0 ] && [ "$(cat "$GUARDEN_STDOUT")" = "pod-roundtrip-307c" ]; then
        trip=1
        break
    fi
    sleep 1
done
[ "$trip" = 1 ] \
    || _fail "no payload crossed between the two containers of the pod: the last attempt exited $GUARDEN_EXIT with $(tr '\n' '|' <"$GUARDEN_STDERR") and got $(cat "$GUARDEN_STDOUT")"
echo "MEASURE: what the second container fetched over 127.0.0.1 from the first: $(cat "$GUARDEN_STDOUT")"

# And the same server through the pod's PUBLICATION, from the host. This is the
# half the loopback cannot show: the `PublishPort=` line lives on the pod unit
# now, and the host's `127.0.0.1:<publication>` is what an edge or a sibling
# dials (spec §7.4).
host_trip=0
for _ in $(seq 1 20); do
    run curl -fsS "http://127.0.0.1:$web_pub/proof.txt"
    if [ "$GUARDEN_EXIT" = 0 ] && [ "$(cat "$GUARDEN_STDOUT")" = "pod-roundtrip-307c" ]; then
        host_trip=1
        break
    fi
    sleep 1
done
[ "$host_trip" = 1 ] \
    || _fail "the pod's publication 127.0.0.1:$web_pub never served the payload: exit $GUARDEN_EXIT, $(tr '\n' '|' <"$GUARDEN_STDERR")"
echo "MEASURE: what the host fetched from the pod's publication $web_pub: $(cat "$GUARDEN_STDOUT")"

# --- 3. the pod's own unit, before the containers and after them -----------
#
# Quadlet translates `Pod=` into a service dependency between the two units, so
# the ordering is the generator's and not a `[Unit]` block a repository wrote.
# The generated unit is read from the manager's own generator output, because
# `systemctl --user --machine <name>@ cat` answers "Cannot remotely cat units".
generated=/run/user/"$svc_uid"/systemd/generator
assert_file_exists "$generated/web.service"
deps=$(grep -E '^(Requires|After|BindsTo|Wants|PartOf)=' "$generated/web.service" | tr '\n' ' ')
echo "MEASURE: the pod member's generated dependencies: $deps"
assert_string_contains "$deps" "podprobe-pod.service"
assert_file_has "$generated/worker.service" "podprobe-pod.service"

run weedr service stop "$svc"
assert_exit 0
state=$(systemctl --user --machine "$svc@" is-active podprobe-pod 2>/dev/null || true)
echo "MEASURE: the pod unit's state after the service stopped: $state"
[ "$state" != "active" ] \
    || _fail "the pod's own unit is still active after \`weedr service stop\`, so it did not stop after its containers"

# --- 4a. the four shapes, and what `[pod] name` renames --------------------
#
# Two apps, each naming its own pod: two services, two pods, and the two
# containers of `api` still in ONE of them.
stage_poke pods 0000001
run weedr service ingest pods-web-staging --from poke pods@0000001
assert_exit 0
run weedr service ingest pods-api-staging --from poke pods@0000001
assert_exit 0

web_units=/var/lib/guarden/services/pods-web-staging/home/.config/containers/systemd
api_units=/var/lib/guarden/services/pods-api-staging/home/.config/containers/systemd
assert_file_exists "$web_units/pods-web.pod"
assert_file_exists "$api_units/pods-api.pod"
assert_file_has "$web_units/web.container" "Pod=pods-web.pod"
assert_file_has "$api_units/api.container" "Pod=pods-api.pod"
assert_file_has "$api_units/worker.container" "Pod=pods-api.pod"
for directory in "$web_units" "$api_units"; do
    count=$(find "$directory" -maxdepth 1 -name '*.pod' | wc -l)
    [ "$count" = 1 ] \
        || _fail "$directory holds $count .pod files, and one app is one pod: $(ls "$directory" | tr '\n' ' ')"
done
assert_file_lacks "$api_units/api.container" "Network="

# --- 4a-bis. an instance has a pod of its own too --------------------------
#
# A preview is an instance, and its units are the service's with the escaped
# ref appended (spec §5.2) — so its pod is `<pod>-<escaped-ref>.pod`, its
# podman pod carries a name no backslash can break, and it is the ONE thing two
# previews of one service cannot share.
inst_staged=/var/lib/guarden/staging/instprobe/0000001
mkdir -p "$inst_staged/.guarden/quadlet"
seed "$inst_staged/.guarden/service.yml" \
    "project: instprobe" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data"
seed "$inst_staged/.guarden/quadlet/app.container" \
    "[Container]" \
    "Image=docker.io/library/alpine:3.20" \
    "Volume=data:/data" \
    "Exec=sleep 3600"
run weedr service ingest instprobe-preview/feature/x --from poke instprobe@0000001
assert_exit 0
inst_units=/var/lib/guarden/services/instprobe-preview/home/feature\\x2fx/.config/containers/systemd
assert_file_exists "$inst_units/instprobe.pod"
assert_file_has "$inst_units/instprobe.pod" "PodName="
assert_file_has "$inst_units/app.container" "Pod=instprobe-feature\\x2fx.pod"
run weedr service start instprobe-preview/feature/x
if [ "$GUARDEN_EXIT" != 0 ]; then
    journalctl --user -M instprobe-preview@ -xeu "app-feature\\x2fx.service" 2>&1 | tail -20
    _fail "starting an instance's pod failed: $(tr '\n' '|' <"$GUARDEN_STDERR")"
fi

# `loom check` renders every shape with no host at all — it is the verb a
# repository runs in CI, and it writes nothing.
for source in "$GUARDEN_ROOT/fixtures/projects/solo" \
              "$GUARDEN_ROOT/fixtures/projects/pods/apps/web" \
              "$GUARDEN_ROOT/fixtures/projects/pods/apps/api" \
              "$staged"; do
    run loom check "$source"
    assert_exit 0
    assert_stdout_has "renderable"
done

# --- 4b. a source whose images disagree on a uid is REFUSED ---------------
#
# The record is what the probe writes, so seeding it is how a service whose two
# images resolve to two users is put in front of the renderer without pulling
# two images to find out. nginx runs as 33, postgres as 999, and one pod's pin
# can serve exactly one of them.
split=$GUARDEN_FIXTURES/split
seed "$split/.guarden/service.yml" \
    "project: splitpod" \
    "units: .guarden/quadlet/" \
    "" \
    "ports:" \
    "  - container: api" \
    "    port: 8080" \
    "  - container: worker" \
    "    port: 5432"
seed "$split/.guarden/quadlet/api.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"
seed "$split/.guarden/quadlet/worker.container" \
    "[Container]" \
    "Image=docker.io/library/postgres:17"
seed /var/lib/guarden/registry/splitpod-staging.toml \
    'service = "splitpod-staging"' 'workload = "splitpod"' 'project = "splitpod"' \
    'environment = "staging"' 'uid = 1119' 'created = "2026-10-22T09:00:00Z"' \
    '[publication]' 'api = 20201' 'worker = 20202' \
    '[owner_units.api]' 'image = "docker.io/library/nginx:1.27"' 'uid = 33' 'gid = 33' \
    '[owner_units.worker]' 'image = "docker.io/library/postgres:17"' 'uid = 999' 'gid = 999'

run loom render "$split" --service splitpod-staging --out "$GUARDEN_FIXTURES/split-render"
assert_exit 2
echo "MEASURE: the refusal of a pod whose images disagree: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_stderr_has "33:33"
assert_stderr_has "999:999"
assert_stderr_has "docker.io/library/nginx:1.27"
assert_stderr_has "docker.io/library/postgres:17"
assert_stderr_has "api"
assert_stderr_has "worker"
assert_file_missing "$GUARDEN_FIXTURES/split-render/units/splitpod.pod"

echo "MEASURE: a pod is one namespace, one pin, and one renderer"
