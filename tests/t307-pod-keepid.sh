#!/usr/bin/env bash
# What a pod actually gives us, measured before anything is built on it
# (ticket 307's t307b, which t307c depends on).
#
# A pod shares net/ipc/uts and NOT the user namespace, so the design has each
# container of one pod keep its OWN `UserNS=keep-id:uid=<image uid>` pin. If
# that is false — if the pin stops landing writes on the service user once the
# containers share a pod — the shape t307c would render has to be reconsidered
# BEFORE it is rendered, which is why this file exists and why it is the whole
# of the ticket.
#
# Three claims, each measured on a real cut machine and then asserted:
#
#   1. **Two keep-id pins in one pod.** `postgres:17` starts as root and hands
#      off to uid 999 through its entrypoint's `exec gosu postgres`; a second
#      image runs as uid 33 (`--user 33:33`, the spelling this card names).
#      Each carries `--userns=keep-id:uid=<image uid>,gid=<same>` — the line
#      ADR-0019 has the renderer write — and each writes a file into ONE
#      directory the service user owns at 0700. The HOST owner of both files is
#      the service user, read with `stat`, and the contents are read too so the
#      file is known to be the one that container wrote.
#
#      **The 0700 is the control, and a third container makes it observable.**
#      A container with no pin maps its root into the service's subuid band and
#      cannot write there at all, so the same directory proves the measurement
#      discriminates instead of merely passing: that container is run and its
#      refusal asserted. Without it, a green here would be a green about a
#      directory anything could write.
#
#   2. **Pasta on the POD, not on a lone container.** The pod is created with
#      the `[network] pasta_options` set read out of the host's own installed
#      `guarden.toml` (comma-flattened, which is exactly what podman runs and
#      what the renderer writes as `Network=pasta:`), the containers are
#      asserted to carry that addressing (`10.0.2.100/24`, default `via
#      10.0.2.2`), and a listener on the HOST's loopback is fetched from inside
#      a pod container at `10.0.2.2:<publication>` — pasta's map-gw measured
#      through a pod rather than through a container of its own.
#
#   3. **A payload that ROUND-TRIPS between two containers of the pod over
#      127.0.0.1.** One container's own process is a busybox `httpd` serving a
#      token; a second container's own process fetches it and the bytes are
#      compared; the server's request log is read back as well, so the request
#      as well as the response is evidence. A bare connect proves less than it
#      looks — busybox `nc` has no `-z` — so nothing here is a connect only.
#
# **If (1) is red, t307c must not be built.** The per-container pin is the one
# assumption one pod of several uids rests on; the other two are the pod's other
# load-bearing properties and are asserted here so that the same machine answers
# all three questions at once.
#
# Real host, real `useradd`, real subuid range, real rootless podman, real
# pasta: `GUARDEN_PREFIX=/`, the way `t350-keepid` and `t325-pgdata-subdir` do.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
run soil install --apply
assert_exit 0
run podman --version
assert_exit 0
echo "MEASURE: the rootless podman this was measured on: $(cat "$GUARDEN_STDOUT")"

# --- the service user, pasta's option set, and podman as that user ----------
#
# The service is created the way guarden creates one — a staged tree and
# `weedr service ingest` — because the pin's whole content is "the container's
# uid lands on THIS user": a plain `useradd` in the suite would measure the
# suite's idea of a service user rather than guarden's, and the home, the 0700
# on the tree and the subuid range are all part of the question.
staged=/var/lib/guarden/staging/podprobe/0000001
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: podprobe" \
    "units: .guarden/quadlet/"
seed "$staged/.guarden/quadlet/app.container" \
    "[Unit]" \
    "Description=the service the pod's containers are pinned to" \
    "" \
    "[Container]" \
    "Image=docker.io/library/alpine:3.20"
run weedr service ingest podprobe-staging --from poke podprobe@0000001
assert_exit 0
assert_stdout_has "created podprobe-staging"

svc=podprobe-staging
tree=/var/lib/guarden/services/$svc
home=$tree/home
svc_uid=$(id -u "$svc")
svc_gid=$(id -g "$svc")
svc_group=$(id -gn "$svc")
runtime=/run/user/"$svc_uid"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"
echo "MEASURE: the service user every pin below must land on: $(id "$svc")"

# The option set is read from the host guarden installed itself onto rather
# than written here a second time: a suite that hardcoded the set it put on the
# pod would be asserting its own constant, not the one the renderer emits.
pasta=$(sed -n 's/^pasta_options = \[\(.*\)\]$/\1/p' /etc/guarden/guarden.toml | tr -d ' "')
echo "MEASURE: the pasta option set the renderer writes as Network=pasta:$pasta"
[ -n "$pasta" ] \
    || _fail "the installed /etc/guarden/guarden.toml carries no pasta_options line, so there is no set to put on a pod"

# podman_as <podman args...>: podman as the service user, with USER and LOGNAME
# named for it. `runuser` keeps the caller's environment and the caller is root,
# and podman's keep-id mapping reads the subid files keyed by `$USER`, so the
# environment is stated rather than inherited.
podman_as() {
    run_in "$home" setpriv --reuid="$svc" --regid="$svc" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$svc" LOGNAME="$svc" \
        XDG_RUNTIME_DIR="$runtime" podman "$@"
}

# The images are pulled as the SERVICE user: a pull as root lands in root's
# store, which this user cannot use, and root's own pull cannot resolve the
# registry through the stub resolver (t325 records the same two reasons).
podman_as pull docker.io/library/alpine:3.20
assert_exit 0
podman_as pull docker.io/library/postgres:17
assert_exit 0

# The directory both pinned containers write into. It is a plain directory in
# the service's own tree rather than a declared volume because the volume's
# layout is ADR-0020's subject and not this one's; what the measurement needs is
# the ownership and the 0700, and those are the same either way.
vol=$tree/bulk/podprobe
mkdir -p "$vol"
chown "$svc:$svc_group" "$vol"
chmod 0700 "$vol"
assert_mode "$vol" 0700
assert_owner "$vol" "$svc:$svc_group"

# --- 1. two keep-id pins in one pod -----------------------------------------
#
# The pod is created with the pinned pasta set and started before any container
# joins it: a pod that was created and never started has no infra container and
# no network namespace, and a container that joined it would be measuring a pod
# that is not running.
podman_as pod create --name podkid --network "pasta:$pasta"
assert_exit 0
podman_as pod start podkid
assert_exit 0
podman_as pod ps --format '{{.Name}} {{.Status}}'
assert_exit 0
echo "MEASURE: the pod after create+start: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "Running"

# postgres:17 has no `USER` line: it starts as root and its entrypoint drops to
# `postgres` (uid 999) — which is why 999 is the uid guarden's probe records for
# this image. The command writes the file the host is asked about and then
# sleeps, so the container is still there to be asked what it is; its own
# `id -u` is printed first, so a container that stayed root says so in its log
# rather than only in a permission error.
podman_as run -d --pod podkid --name kid-pg \
    --userns "keep-id:uid=999,gid=999" \
    -e POSTGRES_PASSWORD=podprobe \
    -v "$vol:/data" \
    docker.io/library/postgres:17 \
    sh -c "echo uid=\$(id -u); printf '%s\n' pg-999 > /data/pg.txt; exec sleep 3600"
if [ "$GUARDEN_EXIT" != 0 ]; then
    echo "MEASURE: podman refused a keep-id pin on a container in a pod: $(tr '\n' '|' <"$GUARDEN_STDERR")"
    _fail "a container with its own keep-id pin cannot join a pod (exit $GUARDEN_EXIT), so t307c's per-container pin is not available"
fi

# The second uid, and it is genuinely a different one: `--user 33:33` is the
# spelling this card names for a container whose own process is not root. The
# image is alpine, so this container has nothing to do with the postgres one
# beyond the pod.
podman_as run -d --pod podkid --name kid-app \
    --userns "keep-id:uid=33,gid=33" \
    --user 33:33 \
    -v "$vol:/data" \
    docker.io/library/alpine:3.20 \
    sh -c "printf '%s\n' app-33 > /data/app.txt; exec sleep 3600"
if [ "$GUARDEN_EXIT" != 0 ]; then
    echo "MEASURE: podman refused a second, differently pinned container in the same pod: $(tr '\n' '|' <"$GUARDEN_STDERR")"
    _fail "two containers of one pod cannot carry different keep-id pins (exit $GUARDEN_EXIT), which is the assumption t307c is built on"
fi

podman_as ps -a --format '{{.Names}} {{.Status}}'
echo "MEASURE: the pod's containers: $(tr '\n' '|' <"$GUARDEN_STDOUT")"

# What each container's own pid 1 is, read the way t352 reads it. `podman exec`
# runs as the container's CONFIGURED user, so exec's own `id -u` would answer 33
# for the alpine container whatever the pin did — pid 1's `/proc/1/status` is
# the only reading that answers "who is running under this pin".
podman_as exec kid-pg sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the postgres container (its gosu handoff) under its pin: $(cat "$GUARDEN_STDOUT")"
pg_pid1=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$pg_pid1" = 999 ] \
    || _fail "pid 1 of the postgres container answers uid $pg_pid1 under keep-id:uid=999, and this image's entrypoint hands off to 999"

podman_as exec kid-app sh -c 'grep ^Uid: /proc/1/status'
assert_exit 0
echo "MEASURE: pid 1 of the uid-33 container under its pin: $(cat "$GUARDEN_STDOUT")"
app_pid1=$(awk '/^Uid:/ { print $2 }' "$GUARDEN_STDOUT")
[ "$app_pid1" = 33 ] \
    || _fail "pid 1 of the --user 33:33 container answers uid $app_pid1 under keep-id:uid=33"

# The host side of both writes. A missing file is reported with the container's
# own log, because the interesting failure is a write that was REFUSED (the
# directory is 0700 and owned by the service user) and the log says so in one
# line where an absent path says nothing.
if [ ! -f "$vol/pg.txt" ]; then
    podman_as logs kid-pg
    _fail "the postgres container wrote no /data/pg.txt into the service user's 0700 directory: $(tr '\n' '|' <"$GUARDEN_STDERR")"
fi
echo "MEASURE: the host owner of the postgres container's write: $(stat -c '%U:%G %u:%g %a' "$vol/pg.txt")"
[ "$(stat -c %U "$vol/pg.txt")" = "$svc" ] \
    || _fail "the file the pinned postgres container wrote is owned by $(stat -c '%U:%G' "$vol/pg.txt") on the host, not by $svc"
[ "$(stat -c %u "$vol/pg.txt")" = "$svc_uid" ] \
    || _fail "the pinned postgres container's write landed on host uid $(stat -c %u "$vol/pg.txt"), not on $svc's $svc_uid"
[ "$(cat "$vol/pg.txt")" = "pg-999" ] \
    || _fail "the file on the host does not carry what the postgres container wrote: $(cat "$vol/pg.txt")"

if [ ! -f "$vol/app.txt" ]; then
    podman_as logs kid-app
    _fail "the uid-33 container wrote no /data/app.txt into the service user's 0700 directory: $(tr '\n' '|' <"$GUARDEN_STDERR")"
fi
echo "MEASURE: the host owner of the uid-33 container's write: $(stat -c '%U:%G %u:%g %a' "$vol/app.txt")"
[ "$(stat -c %U "$vol/app.txt")" = "$svc" ] \
    || _fail "the file the pinned uid-33 container wrote is owned by $(stat -c '%U:%G' "$vol/app.txt") on the host, not by $svc"
[ "$(stat -c %u "$vol/app.txt")" = "$svc_uid" ] \
    || _fail "the pinned uid-33 container's write landed on host uid $(stat -c %u "$vol/app.txt"), not on $svc's $svc_uid"
[ "$(cat "$vol/app.txt")" = "app-33" ] \
    || _fail "the file on the host does not carry what the uid-33 container wrote: $(cat "$vol/app.txt")"

# **The control.** The same directory, the same pod, the same image as the
# second container — and no pin. Container root maps into the service's subuid
# band, which is not the service user, so this write cannot succeed. If it ever
# does, the two greens above are greens about a directory anything can write and
# this suite measures nothing.
podman_as run --rm --pod podkid --name kid-unpinned \
    -v "$vol:/data" \
    docker.io/library/alpine:3.20 \
    sh -c 'printf unpinned > /data/unpinned.txt'
echo "MEASURE: an UNPINNED container writing into the same 0700 directory: exit $GUARDEN_EXIT, $(tr '\n' '|' <"$GUARDEN_STDERR")"
[ "$GUARDEN_EXIT" != 0 ] \
    || _fail "a container with no keep-id pin wrote into the service user's 0700 directory, so the owner assertions above prove nothing"
assert_file_missing "$vol/unpinned.txt"

# --- 2 and 3. one pasta pod: the host at 10.0.2.2, and a payload in the pod --
#
# A second pod, so (1)'s containers are untouched by the network measurement and
# a failure here cannot be read as a failure of the pins.
podman_as pod create --name podnet --network "pasta:$pasta"
assert_exit 0
podman_as pod start podnet
assert_exit 0

# The server is the container's OWN process (`httpd -f` stays in the
# foreground), not a process exec'd into it afterwards: the round-trip below has
# to be between the two containers' init processes, which is what "two
# containers talking" means.
podman_as run -d --pod podnet --name net-srv \
    docker.io/library/alpine:3.20 \
    sh -c "mkdir -p /www; printf '%s\n' pod-roundtrip-307 > /www/proof.txt; exec httpd -f -p 8080 -h /www"
assert_exit 0

# The pod's own addressing, read inside a container of the pod: the option set
# was applied to the POD, and this is what says so rather than the podman
# command line that asked for it.
podman_as exec net-srv ip addr show dev eth0
assert_exit 0
echo "MEASURE: the pod container's addressing: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "10.0.2.100/24"
podman_as exec net-srv ip route
assert_exit 0
echo "MEASURE: the pod container's route: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "default via 10.0.2.2"

# The round-trip. The client is a THIRD container in the same pod, run in the
# foreground so its own stdout is the payload's evidence; `wget -qO-` prints the
# body and nothing else.
podman_as run --rm --pod podnet --name net-cli \
    docker.io/library/alpine:3.20 \
    wget -qO- http://127.0.0.1:8080/proof.txt
assert_exit 0
echo "MEASURE: what the second container fetched over 127.0.0.1 from the first: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = "pod-roundtrip-307" ] \
    || _fail "the payload fetched between two containers of one pod over 127.0.0.1 is $(cat "$GUARDEN_STDOUT"), not the token the first container served"

# And the request half: the server's own log is where the arriving request is,
# and a response without a logged request would be a response from something
# else.
podman_as logs net-srv
assert_exit 0
echo "MEASURE: the server's own record of the request: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "GET /proof.txt"
assert_stdout_has " 200 "

# --- 2, second half: the host, at 10.0.2.2, from inside the pod --------------
#
# A publication is a listener on the host's LOOPBACK, bound by the service user
# (spec §7.7: no service binds a non-loopback address). The container reaches it
# at the pinned gateway address because pasta maps that address onto the host's
# loopback — and here the container is a pod's, which is the part that had not
# been measured.
pub_dir=$tree/bulk/publication
mkdir -p "$pub_dir"
printf '%s\n' host-publication-307 >"$pub_dir/hostproof.txt"
chown -R "$svc:$svc_group" "$pub_dir"
pub_port=24123
setsid setpriv --reuid="$svc" --regid="$svc" --clear-groups \
    env -u OLDPWD HOME="$home" PWD="$home" USER="$svc" LOGNAME="$svc" \
    XDG_RUNTIME_DIR="$runtime" \
    python3 -m http.server "$pub_port" --bind 127.0.0.1 --directory "$pub_dir" \
    >"$GUARDEN_FIXTURES/publication.log" 2>&1 &
pub_pid=$!
# A suite that fails below must not leave the listener holding a port on a
# machine that is about to be handed to nothing; the VM is throwaway but the
# assertion's after-life is not the place to rely on that.
trap 'kill "$pub_pid" 2>/dev/null || true' EXIT

pub_up=0
for _ in $(seq 1 30); do
    run curl -fsS "http://127.0.0.1:$pub_port/hostproof.txt"
    if [ "$GUARDEN_EXIT" = 0 ]; then
        pub_up=1
        break
    fi
    sleep 1
done
[ "$pub_up" = 1 ] \
    || _fail "the host-side listener on 127.0.0.1:$pub_port never answered, so no reachability result below would mean anything"
echo "MEASURE: the publication on the host's own loopback: $(cat "$GUARDEN_STDOUT")"

podman_as run --rm --pod podnet --name net-host \
    docker.io/library/alpine:3.20 \
    wget -qO- "http://10.0.2.2:$pub_port/hostproof.txt"
assert_exit 0
echo "MEASURE: what a pod container fetched from the host at 10.0.2.2:$pub_port: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = "host-publication-307" ] \
    || _fail "a pod container fetched $(cat "$GUARDEN_STDOUT") from the host at 10.0.2.2:$pub_port, not the token the host was serving"
