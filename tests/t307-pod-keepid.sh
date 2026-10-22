#!/usr/bin/env bash
# What a pod actually gives us, measured before anything is built on it
# (ticket 307's t307b, which t307c depends on).
#
# **The card this file was written for assumed something, and the assumption is
# false.** It said a pod shares net/ipc/uts and NOT the user namespace, so every
# container could keep its own `UserNS=keep-id:uid=<image uid>` pin. On podman
# 5.7.0, measured on a cut machine on 2026-10-22, a pod shares the USER
# namespace too, and a container joining a pod cannot carry one of its own:
#
#   $ podman run --userns keep-id --pod podplain alpine true
#   Error: --userns and --pod cannot be set together          (exit 125)
#   $ podman run --pod podplain --uidmap 0:100000:65536 alpine true
#   Error: cannot specify a new uid/gid map when entering a pod with an infra
#   container: invalid argument                               (exit 125)
#
# `podman pod inspect --format '{{.SharedNamespaces}}'` answers `[ipc net user
# uts]` for a pod created with `--userns`, and `[uts ipc net]` for one created
# without — the user namespace is a POD property, not a container one. So
# t307c's per-container pin is not renderable at all, and what is left is a
# pod-level pin with a constraint the ticket must know: **one pod can put
# exactly one image uid onto the service user, plus container root.**
#
# This file therefore asserts the platform's real shape rather than the card's
# premise, in four parts:
#
#   1. **No container in a pod can carry its own user namespace** — three
#      spellings, each refused, each refusal asserted by its own words. This is
#      the tripwire: a podman that starts allowing it turns this suite red and
#      sends whoever sees it back to this measurement.
#   2. **The pod's own pin does the work, and only for one uid.** A pod created
#      with `--userns keep-id:uid=33,gid=33` puts a container running as 33 AND
#      a container running as root onto the service user (rootless podman's
#      default mapping is container root → the calling user, which is ADR-0019's
#      no-`USER` case), and REFUSES a container running as 999 writing into the
#      same 0700 directory. The same uid-33 container in a pod with no pin is
#      refused too, which is what says the POD's pin is the thing doing it.
#   3. **Pasta is a pod property too.** The pod is created with the `[network]
#      pasta_options` set read out of the host's own installed `guarden.toml`
#      (comma-flattened, which is what podman runs and what the renderer writes
#      as `Network=pasta:`), a pod container carries `10.0.2.100/24` with
#      `default via 10.0.2.2`, and it fetches a host publication from
#      `10.0.2.2:<publication>` while the pod's own address refuses — so the
#      reachable address is pasta's mapped gateway and not the pod's address.
#   4. **A payload round-trips between two containers of one pod over
#      127.0.0.1** — not a connect: one container serves a response, the other
#      fetches it, the bytes are compared, and the request the first one
#      received is read back out of its own filesystem. busybox has no `httpd`
#      in alpine:3.20 (measured: `httpd: not found`) and `nc` has no `-z`, so
#      the server is `nc` fed a canned response; the request is its captured
#      input, which is the half a bare connect would never show.
#
# **What a red here means.** Part 1 red: podman changed and pods may be able to
# carry per-container pins after all — re-run the measurement before t307c
# moves. Parts 2 to 4 red: the pod shape t307c would render does not work as
# measured.
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

# The image is pulled as the SERVICE user: a pull as root lands in root's store,
# which this user cannot use, and root's own pull cannot resolve the registry
# through the stub resolver (t325 records the same two reasons).
podman_as pull docker.io/library/alpine:3.20
assert_exit 0

# The directory the containers write into. A plain directory in the service's
# own tree rather than a declared volume: the volume's layout is ADR-0020's
# subject and not this one's, and what this measurement needs is the ownership
# and the 0700, which are the same either way.
vol=$tree/bulk/podprobe
mkdir -p "$vol"
chown "$svc:$svc_group" "$vol"
chmod 0700 "$vol"
assert_mode "$vol" 0700
assert_owner "$vol" "$svc:$svc_group"

# A pod with no pin of its own, which is the control for everything below.
# `--log-driver k8s-file` is needed wherever a container's own output is read
# back: this host's podman logs to `journald` (measured), a rootless user's
# journal is not there to read, and `podman logs` then answers empty with exit
# 0 — the container is silent and the reading is silent with it.
podman_as pod create --name podplain --network "pasta:$pasta"
assert_exit 0
podman_as pod start podplain
assert_exit 0

# --- 1. no container in a pod can carry its own user namespace --------------
#
# The three spellings: the pin itself, the same pin with the uid named (which is
# exactly what ADR-0019 has the renderer write), and a hand-written uid map,
# which is the only other way to express one. Each is refused by podman before
# anything is created, and each refusal is read rather than assumed.
podman_as run --rm --userns keep-id --pod podplain docker.io/library/alpine:3.20 true
assert_exit 125
echo "MEASURE: a keep-id pin on a container in a pod: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_stderr_has "--userns and --pod cannot be set together"

podman_as run --rm --pod podplain --userns "keep-id:uid=33,gid=33" docker.io/library/alpine:3.20 true
assert_exit 125
echo "MEASURE: the uid-bearing pin, flags in the other order: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_stderr_has "--userns and --pod cannot be set together"

podman_as run --rm --pod podplain --uidmap "0:100000:65536" docker.io/library/alpine:3.20 true
assert_exit 125
echo "MEASURE: a uid map on a container in a pod: $(tr '\n' '|' <"$GUARDEN_STDERR")"
assert_stderr_has "cannot specify a new uid/gid map when entering a pod"

# --- 2. the pod's own pin: one uid, plus container root ---------------------
podman_as pod create --name podpin --network "pasta:$pasta" --userns "keep-id:uid=33,gid=33"
assert_exit 0
podman_as pod start podpin
assert_exit 0
podman_as pod inspect podpin --format '{{.SharedNamespaces}}'
assert_exit 0
echo "MEASURE: the namespaces a pinned pod shares with its containers: $(cat "$GUARDEN_STDOUT")"
assert_stdout_has "user"

# Three containers, one pod, three uids, all writing into the service user's
# 0700 directory. The file each one leaves on the host is the whole question:
# the pinned uid and root land on the service user, and any other uid maps into
# the service's subuid band and is refused.
podman_as run -d --log-driver k8s-file --pod podpin --name pin-app --user 33:33 \
    -v "$vol:/data" docker.io/library/alpine:3.20 \
    sh -c 'echo uid=$(id -u); printf "%s\n" pinned-33 > /data/pinned-33.txt; exec sleep 3600'
assert_exit 0
podman_as run -d --log-driver k8s-file --pod podpin --name pin-root \
    -v "$vol:/data" docker.io/library/alpine:3.20 \
    sh -c 'echo uid=$(id -u); printf "%s\n" root > /data/root.txt; exec sleep 3600'
assert_exit 0
podman_as run -d --log-driver k8s-file --pod podpin --name pin-other --user 999:999 \
    -v "$vol:/data" docker.io/library/alpine:3.20 \
    sh -c 'echo uid=$(id -u); printf "%s\n" other > /data/other.txt; exec sleep 3600'
assert_exit 0

# The control, at the same time: the same uid-33 container in the pod with NO
# pin. It is refused, which is what says the POD's pin — not `--user` — is what
# puts a non-root uid on the service user.
podman_as run -d --log-driver k8s-file --pod podplain --name plain-33 --user 33:33 \
    -v "$vol:/data" docker.io/library/alpine:3.20 \
    sh -c 'echo uid=$(id -u); printf "%s\n" plain > /data/plain-33.txt; exec sleep 3600'
assert_exit 0

# The writes are given a moment to land before the host is asked about them. The
# poll reads the STATE — the files — rather than sleeping a fixed time.
landed=0
for _ in $(seq 1 20); do
    if [ -f "$vol/pinned-33.txt" ] && [ -f "$vol/root.txt" ]; then
        landed=1
        break
    fi
    sleep 1
done
[ "$landed" = 1 ] \
    || _fail "the pinned pod's containers wrote no files into the service user's directory: $(ls -la "$vol" | tr '\n' '|')"

for f in pinned-33.txt root.txt; do
    echo "MEASURE: the host owner of the container's $f: $(stat -c '%U:%G %u:%g %a' "$vol/$f")"
    [ "$(stat -c %u "$vol/$f")" = "$svc_uid" ] \
        || _fail "the file $f was written by host uid $(stat -c %u "$vol/$f"), not by $svc's $svc_uid — the pod's pin did not land it"
done
[ "$(cat "$vol/pinned-33.txt")" = "pinned-33" ] \
    || _fail "the uid-33 container's file on the host is $(cat "$vol/pinned-33.txt"), not what it wrote"
[ "$(cat "$vol/root.txt")" = "root" ] \
    || _fail "the root container's file on the host is $(cat "$vol/root.txt"), not what it wrote"

# The third uid, refused — and refused by the directory, which is what makes the
# two greens above mean something. The container itself stays up (its shell
# carries on after the failed redirect), so the refusal is read out of its log.
assert_file_missing "$vol/other.txt"
podman_as logs pin-other
assert_exit 0
echo "MEASURE: the third uid in the pinned pod: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "Permission denied"

# The same uid, the same command, in the pod with NO pin: refused as well.
assert_file_missing "$vol/plain-33.txt"
podman_as logs plain-33
assert_exit 0
echo "MEASURE: uid 33 in a pod with no pin: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "Permission denied"

# --- 3 and 4. one pasta pod: the addressing, the host, and a payload --------
#
# A second pod, so part 2's containers are untouched by the network measurement
# and a failure here cannot be read as a failure of the pins.
podman_as pod create --name podnet --network "pasta:$pasta"
assert_exit 0
podman_as pod start podnet
assert_exit 0

# The server is the container's OWN process — a `while` loop around a one-shot
# `nc` listening on 127.0.0.1 — not a process exec'd into it afterwards, so the
# round-trip below is between two containers' init processes. The canned
# response is what busybox can serve: alpine:3.20's busybox carries no `httpd`
# applet (measured) and `nc` has no `-z`. `Content-Length: 17` is the length of
# `pod-roundtrip-307`; the appended file is the REQUEST, which is the half a
# bare connect would never show.
podman_as run -d --log-driver k8s-file --pod podnet --name net-srv \
    docker.io/library/alpine:3.20 \
    sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 17\r\nConnection: close\r\n\r\npod-roundtrip-307" | nc -l -p 8080 >> /tmp/request.txt; done'
assert_exit 0

# The pod's own addressing, read inside a container of the pod: the option set
# was applied to the POD, and this is what says so rather than the command line
# that asked for it.
podman_as exec net-srv ip addr show dev eth0
assert_exit 0
echo "MEASURE: the pod container's addressing: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "10.0.2.100/24"
podman_as exec net-srv ip route
assert_exit 0
echo "MEASURE: the pod container's route: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "default via 10.0.2.2"

# The round-trip: a third container in the same pod, in the foreground, whose
# own stdout is the payload's evidence.
podman_as run --rm --pod podnet --name net-cli \
    docker.io/library/alpine:3.20 \
    wget -qO- http://127.0.0.1:8080/proof.txt
assert_exit 0
echo "MEASURE: what the second container fetched over 127.0.0.1 from the first: $(cat "$GUARDEN_STDOUT")"
[ "$(cat "$GUARDEN_STDOUT")" = "pod-roundtrip-307" ] \
    || _fail "the payload fetched between two containers of one pod is $(cat "$GUARDEN_STDOUT"), not the token the first container served"

# And the request half, read out of the server's own filesystem: a response
# without a request that arrived would be a response from something else.
podman_as exec net-srv cat /tmp/request.txt
assert_exit 0
echo "MEASURE: the request the server received: $(tr '\n' '|' <"$GUARDEN_STDOUT")"
assert_stdout_has "GET /proof.txt"

# --- 3, second half: the host, at 10.0.2.2, from inside the pod -------------
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
# A suite that fails below must not leave the listener behind on a machine that
# is about to be handed to the next suite; the VM is throwaway and the
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

# The discriminator: the pod's OWN address is not the address the host is on, so
# the same fetch fails there. Without this, the success above could be read as
# "the container had the host's loopback", which is the thing it must not be.
podman_as run --rm --pod podnet --name net-self \
    docker.io/library/alpine:3.20 \
    wget -qO- "http://10.0.2.100:$pub_port/hostproof.txt"
echo "MEASURE: the same publication fetched at the pod's own address: exit $GUARDEN_EXIT, $(tr '\n' '|' <"$GUARDEN_STDERR")"
[ "$GUARDEN_EXIT" != 0 ] \
    || _fail "the host's publication answered at 10.0.2.100, the pod's own address, so the 10.0.2.2 fetch was not pasta's gateway mapping"
