#!/usr/bin/env bash
# Tickets 321 and 332: the `runuser -u` call sites, and the environment they
# run in.
#
# **What was false.** The repository claimed, in four places, that "`runuser -u`
# swaps the uid but keeps the caller's environment, and the caller is root — so
# podman saw `USER=root`". That is REFUTED by measurement on the golden VM
# (util-linux 2.41.3, podman 5.7.0):
#
#   $ runuser -u probe-svc -- env | grep -E '^(HOME|USER|LOGNAME)='
#   HOME=/var/lib/guarden/services/probe-svc/home
#   LOGNAME=probe-svc
#   USER=probe-svc
#
# `runuser` SETS HOME, USER, LOGNAME, SHELL and PATH for a non-root target and
# inherits everything ELSE verbatim: XDG_RUNTIME_DIR, XDG_DATA_HOME,
# XDG_CONFIG_HOME, XDG_CACHE_HOME, DBUS_SESSION_BUS_ADDRESS, CONTAINERS_*,
# PWD, OLDPWD. The measurement that produced the refuted claim was `setpriv`,
# which is what t350-keepid.sh uses and which genuinely keeps the caller's
# environment.
#
# **What this file asserts is the STATE, and never a configuration value.**
#
#   * **The secret lands in the service's own store.** `credentials.materialise`
#     is the only path that puts a secret's VALUE into a store, and the store's
#     location is decided by `XDG_DATA_HOME`. With a HOSTILE `XDG_DATA_HOME`
#     in the caller's environment, the secret database must still land INSIDE
#     the service's own `0700` home — the limit `credentials.py:190-195`
#     names — and nothing of it may land under the hostile path.
#   * **The caller's environment must not break the call.** Three of the
#     inherited variables make podman FAIL outright when they are present
#     (measured on the golden VM, and quoted in the block below): the
#     caller's `XDG_RUNTIME_DIR`, its `CONTAINERS_STORAGE_CONF` and its
#     `CONTAINERS_CONF`. So the materialiser must still SUCCEED with all three
#     hostile in the caller's environment — which is a statement about the
#     product's behaviour and not about a variable's presence in a source file.
#
# The hostile path is a real directory on the machine, created by this suite,
# and it is world-readable on purpose: if the value ever landed there, the
# directory's own mode would not have saved it.
#
# Real host, real `useradd`, real rootless podman, real secret store:
# `GUARDEN_PREFIX=/`, as `t230-build` and `t491-creds-trigger` do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- the service, with a credential ------------------------------------------
#
# A real one, created the way a poke creates it: a real uid, a real home, and
# a schema with a key nothing has planted.
project=ruenv
ref=9f2c1ab
staged=/var/lib/guarden/staging/$project/$ref
mkdir -p "$staged/.guarden/quadlet"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
   "$staged/.guarden/.env.schema"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
   "$staged/.guarden/quadlet/web.container"
cat >"$staged/.guarden/service.yml" <<'YAML'
project: ruenv
units: .guarden/quadlet/
schema: .guarden/.env.schema
state:
  - data
YAML
printf '%s\n' "services: [ruenv-staging]" >"$staged/guarden-poke.json"

run weedr service ingest ruenv-staging --from poke $project@$ref
assert_exit 0

home=/var/lib/guarden/services/ruenv-staging/home
svc=ruenv-staging
assert_file_exists "$home"
assert_mode "$home" 700

# **The service's own user manager, waited for.** `XDG_RUNTIME_DIR` is the
# service's `/run/user/<uid>` — and the helper sets it only when that
# directory exists, because a manager that has not come up yet is worse than
# none. The manager comes up asynchronously after an ingest, so the suite
# waits for it rather than assuming it: the wait is on the DIRECTORY here
# because this file is about the environment, and ticket 322's finding (that
# the directory outlives a dead manager) is a question about the BUILD's
# sandbox cgroup rather than about which variables reach the command.
runtime=/run/user/"$(id -u "$svc")"
for _ in $(seq 1 30); do
    [ -d "$runtime" ] && break
    sleep 1
done
assert_file_exists "$runtime"
echo "MEASURE: the service's runtime directory is $runtime"

# --- the hostile environment -------------------------------------------------
#
# A real directory on the machine, world-readable, so that "the value landed
# somewhere the service's own 0700 home does not cover" is a fact this suite
# can read rather than a thing it has to imagine.
hostile=/tmp/ruenv-hostile
rm -rf "$hostile"
mkdir -p "$hostile"
chmod 0777 "$hostile"

# The caller's environment, with the hostile values in it. This is the shape
# an operator's root shell carries — measured reachable, and the only shape
# reachable at all: `sudo -u root` resets the environment and a systemd
# oneshot's environment is only PWD=/ and USER=root.
#
# **The three that make podman FAIL, measured on the golden VM:**
#
#   XDG_RUNTIME_DIR=/run/user/0
#     -> "Failed to obtain podman configuration: lstat /run/user/0: no such
#         file or directory"
#   CONTAINERS_STORAGE_CONF=<a file that is not there>
#     -> "Failed to obtain podman configuration: stat <file>: no such file or
#         directory"
#   CONTAINERS_CONF=<a file that is not there>
#     -> "Failed to obtain podman configuration: finding config on system:
#         CONTAINERS_CONF file: faccessat <file>: no such file or directory"
#
# The two XDG_DATA_HOME cases are the LEAK rather than the failure: with the
# caller's own XDG_DATA_HOME, podman puts its whole store — the secret
# database inside it — under that path.
export XDG_DATA_HOME="$hostile"
export XDG_RUNTIME_DIR=/run/user/0
export XDG_CONFIG_HOME="$hostile"
export XDG_CACHE_HOME="$hostile"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$hostile/bus"
export CONTAINERS_STORAGE_CONF="$hostile/containers-storage.conf"
export CONTAINERS_CONF="$hostile/containers.conf"
echo "MEASURE: the caller's XDG_DATA_HOME is $XDG_DATA_HOME, its XDG_RUNTIME_DIR is $XDG_RUNTIME_DIR"

# --- the plant ---------------------------------------------------------------
#
# `weedr secret set` writes the blob and asks the materialiser to carry it
# into the service's store — **but it asks through the systemd oneshot**, and
# a oneshot's environment is only `PWD=/` and `USER=root` with no `XDG_*` at
# all (measured). So the plant's own shell is NOT the path this file is about:
# the hostile environment never reaches it.
#
# **The path that IS about it is `weedr secret materialise` run directly**, in
# the caller's shell — which is the shape an operator has when they run it by
# hand, and the shape the ticket names. The verb is the same one the oneshot
# runs (`ExecStart=/usr/lib/guarden/bin/weedr secret materialise %i`), so what
# this drives is the product's own credential path and not a reimplementation
# of it.
run weedr secret set "$svc" DB_PASSWORD <<<"a-real-value"
assert_exit 0
assert_stdout_has "planted DB_PASSWORD of $svc"

# The blob is on disk, encrypted, root-owned.
assert_file_exists /etc/guarden/creds/$svc/DB_PASSWORD.cred
assert_mode /etc/guarden/creds/$svc/DB_PASSWORD.cred 600

# **And now the materialiser runs in THIS shell, with the hostile
# environment.** Before the scrub, the caller's `XDG_RUNTIME_DIR` alone was
# enough to stop it: podman answers "Failed to obtain podman configuration:
# lstat /run/user/0: no such file or directory" and the value never reaches
# the store at all.
run weedr secret materialise "$svc"
assert_exit 0
echo "MEASURE: the materialiser said: $(cat "$GUARDEN_STDOUT")"

# --- the STATE: the secret database is inside the service's own home ---------
#
# **This is the assertion the ticket turns on.** The materialiser ran podman
# as the service user with the caller's hostile `XDG_DATA_HOME` in the
# environment. Before the fix, podman put its whole store — the secret
# database inside it — under the hostile path, OUTSIDE the service's `0700`
# home, which is the documented limit on that value.
#
# The store's own place is `<home>/.local/share/containers/storage` (spec 2.1's
# `paths.PODMAN_STORE`), and the secret database is inside it:
#   containers/storage/secrets/secrets.json
#   containers/storage/secrets/filedriver/secretsdata.json
store=$home/.local/share/containers/storage
assert_file_exists "$store/secrets/secrets.json"
assert_file_exists "$store/secrets/filedriver/secretsdata.json"

# The value itself, base64-encoded by podman's `file` driver, is in the
# service's own store — and NOT under the hostile path. The value is read back
# out of the store rather than compared against a variable the suite wrote, so
# this is what the machine holds.
encoded=$(printf '%s' "a-real-value" | base64 -w0)
assert_file_has "$store/secrets/filedriver/secretsdata.json" "$encoded"

# **And nothing of it is under the hostile path.** This is the negative half,
# and it is what makes the positive half mean something: a value in the
# service's store AND a copy under the caller's own directory is a leak, not a
# fix.
assert_file_missing "$hostile/containers/storage/secrets/secrets.json"
assert_file_missing "$hostile/containers/storage/secrets/filedriver/secretsdata.json"
hostile_matches=$(grep -rlF "$encoded" "$hostile" 2>/dev/null || true)
[ -z "$hostile_matches" ] \
    || _fail "the materialised value is under the caller's own $hostile ($hostile_matches), outside the service's 0700 home"

# --- the STATE: the secret is in the store, as podman itself reports it ------
#
# Read through podman as the service user, in the service's own home: the
# store is the service's, and this is the question asked of the store's owner.
#
# **The suite's own question is asked in a CLEAN environment**, because the
# suite is not the product: the product's path is the materialiser above, and
# this is the suite checking what the machine now holds. The hostile
# environment stays exported for the rest of the file — the point of it is
# that the PRODUCT survives it.
run_in "$home" env -u XDG_RUNTIME_DIR -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    -u XDG_CACHE_HOME -u DBUS_SESSION_BUS_ADDRESS \
    -u CONTAINERS_STORAGE_CONF -u CONTAINERS_CONF \
    runuser -u "$svc" -- podman secret ls
assert_exit 0
assert_stdout_has "DB_PASSWORD"

# --- the STATE: podman's own store is the service's own ----------------------
#
# Asked of podman, as the service user, in the service's own home. This is the
# store's OWN answer and not the suite's reading of a path: `podman info`
# reports where it put its graphroot, and that is the whole claim.
#
# **The caller's hostile XDG_DATA_HOME is IN the environment here**, because
# the question is whether the service's own podman finds its own store or the
# caller's — and a scrub that is only in guarden's own helper would not
# answer it.
run_in "$home" env -u XDG_RUNTIME_DIR -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
    -u DBUS_SESSION_BUS_ADDRESS -u CONTAINERS_STORAGE_CONF -u CONTAINERS_CONF \
    "XDG_DATA_HOME=$hostile" \
    runuser -u "$svc" -- podman info --format '{{.Store.GraphRoot}}'
assert_exit 0
echo "MEASURE: podman's graphroot with the caller's XDG_DATA_HOME still set: $(cat "$GUARDEN_STDOUT")"
graphroot=$(cat "$GUARDEN_STDOUT")
[ "$graphroot" = "$store" ] \
    || _fail "podman's graphroot is $graphroot, and the store the repository names is $store"

# --- the secret's own limit, and the home that is it -------------------------
#
# The value is `0600` to the service uid, and the DIRECTORY holding it is
# inside a home the service uid alone owns. The home's own mode is asserted
# again here, because it is the limit and the whole point of the store being
# under it.
assert_mode "$home" 700
assert_mode "$store/secrets" 700

# --- a rotation goes through the same path -----------------------------------
#
# The materialiser removes the old secret before it creates the new one, so a
# store holding both would be a store holding a stale credential — and this is
# the same call site a second time, under the same hostile environment.
#
# **The materialiser is run DIRECTLY here too**, because the oneshot's
# environment is clean and would not exercise the path. The `secret rm` that
# precedes the `create` is the half that matters: it runs `podman secret rm`
# as the service user, under the caller's environment, and a removal that did
# not happen is a `create` that answers "secret name in use".
run weedr secret materialise "$svc"
assert_exit 0
echo "MEASURE: the rotation's materialiser said: $(cat "$GUARDEN_STDOUT")"

rotated=$(printf '%s' "a-rotated-value" | base64 -w0)
assert_file_has "$store/secrets/filedriver/secretsdata.json" "$rotated"
stale=$(printf '%s' "a-real-value" | base64 -w0)
assert_file_lacks "$store/secrets/filedriver/secretsdata.json" "$stale"

# And the rotated value did not follow the caller either.
rotated_matches=$(grep -rlF "$rotated" "$hostile" 2>/dev/null || true)
[ -z "$rotated_matches" ] \
    || _fail "the rotated value is under the caller's own $hostile ($rotated_matches), outside the service's 0700 home"

# --- the build path, under the same hostile environment ----------------------
#
# The other `podman` call site: `weedr service build` runs podman as the
# service user too, and it is the one the ticket was opened for. A build that
# inherits the caller's `XDG_RUNTIME_DIR` dies in podman's configuration
# before it runs anything — so the build's own answer is the assertion.
#
# **FROM scratch**, so no base image is fetched: the verb is what is under
# test and not the network.
seed "$home/Containerfile" \
    "FROM scratch" "COPY .guarden/quadlet/web.container /unit"

run weedr service build "$svc"
assert_exit 0
echo "MEASURE: the build said: $(cat "$GUARDEN_STDOUT")"
assert_stdout_has "docker.io/library/nginx:1.27"

# The build's image landed in the SERVICE's own store — the same store the
# secret database is in, and not under the hostile path.
run_in "$home" env -u XDG_RUNTIME_DIR -u XDG_DATA_HOME -u XDG_CONFIG_HOME \
    -u XDG_CACHE_HOME -u DBUS_SESSION_BUS_ADDRESS \
    -u CONTAINERS_STORAGE_CONF -u CONTAINERS_CONF \
    runuser -u "$svc" -- podman image inspect docker.io/library/nginx:1.27 \
    --format '{{.Id}}'
assert_exit 0
echo "MEASURE: the built image's id: $(cat "$GUARDEN_STDOUT")"

assert_file_missing "$hostile/containers/storage"

rm -rf "$hostile"
