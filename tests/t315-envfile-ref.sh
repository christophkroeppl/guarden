#!/usr/bin/env bash
# ticket 315: an instance whose ref contains `/` names an env file quadlet
# unescapes into a file that does not exist.
#
# **The disagreement is between two vocabularies.** An instance's directory is
# named by the *escaped* ref — `feature/x` is `feature\x2fx`, and that is what
# spec 5.2 says, and what keeps `feature/x` and `feature-x` from colliding.
# The unit's `EnvironmentFile=` carries that path, and **quadlet reads that key
# by C-unescaping its value**: the generator's own `ExecStart` came out carrying
# `.../feature/x/...` while the file on disk was `.../feature\x2fx/...`.
#
# Podman was then handed a path that names a directory rather than a file, and
# refused the container with
#
#     Error: parsing file ".../feature/x/.../guarden.env": open ...: no such file or directory
#
# **What is asserted here is the container.** An instance with a slash ref is
# ingested, started, and its container is up — and the environment the edge
# wrote into it is what the container sees. A suite that asserted the presence
# of a configuration value would be asserting about the render, and the render
# was never what was broken.
#
# The provider is a separate service with a publication of its own, because the
# env file exists only for a consumer that declares an edge — and the edge is
# what the environment file carries.
#
# Real host, real podman, real systemd: `GUARDEN_PREFIX=/`, as `t440` and
# `t350` do.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry

purge() {
    for service in "$@"; do
        rm -rf "/var/lib/guarden/services/$service" "/etc/guarden/services/$service" \
            "/etc/guarden/creds/$service" "$registry/$service.toml"
        userdel "$service" >/dev/null 2>&1 || :
    done
}

cleanup() {
    purge pgprov-staging envconsumer-preview
    rm -f /etc/guarden/firewall/50-services.conf
}
trap cleanup EXIT

cleanup
ensure_accounts
stage_config guarden-measured.toml
stage_poke pgprov 9f2c1ab
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
# The firewall phase is what installs `guarden-firewall.service`, and the
# render writes `50-services.conf` whether or not anything has loaded it.
run soil firewall --apply
assert_not_rejected

# --- the provider: it owns the publication the consumer dials --------------
run weedr service ingest pgprov-staging --from poke pgprov@9f2c1ab
assert_exit 0
db_pub=$(sed -n 's/^db = \([0-9]*\)$/\1/p' "$registry/pgprov-staging.toml")
[ -n "$db_pub" ] || _fail "the provider names a db container and no publication was allocated"

# --- the consumer: a preview instance whose ref contains a slash ------------
#
# The consumer's tree is **staged here rather than taken from `fixtures/`**,
# because this suite needs one thing the shipped fixtures do not have: an edge
# with `auth: none`. The env file exists for a consumer that declares an edge,
# and `auth: none` is the edge that plants no credential — so the suite's
# subject is the env file and nothing else is in the way of it. A consumer with
# `auth: database` would need its credential materialised into the podman
# store before the container could start, and that is a second subject this
# file does not have.
staged=$GUARDEN_PREFIX/var/lib/guarden/staging/envconsumer/9f2c1ab
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" \
    "project: envconsumer" \
    "units: .guarden/quadlet/" \
    "state:" \
    "  - data" \
    "needs:" \
    "  - service: pgprov-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: none"
seed "$staged/.guarden/quadlet/web.container" \
    "[Unit]" \
    "Description=the consumer's web container" \
    "" \
    "[Container]" \
    "Image=docker.io/library/alpine:3.20" \
    "Network=pasta:--map-gw" \
    "Volume=data:/data" \
    "Exec=sleep 3600" \
    "" \
    "[Service]" \
    "Restart=always"
# **The container needs a command that STAYS UP.** Alpine's own CMD is
# `/bin/sh`, which reads its standard input, finds it at end of file and
# exits — so the container comes up and is gone before the exec probe can
# reach it, and the suite would be asserting about a race rather than about
# the env file. Measured on the golden VM with the unit exactly as it is
# above minus this line: the unit went `active`, the container was not in
# `podman ps`, and the exec probe never succeeded.
#
# `Exec=` is the container's command and it is in `[Container]`, which is
# where quadlet reads it from. The suite's subject is the env file, not
# what the container does, and `sleep` with a long argument is the shape
# every other suite that needs a container to outlive a probe uses
# (t350's `CMD ["sleep", "3600"]`).

# The ref is taken raw and the escaping is internal (spec 5.2), so `feature/x`
# is the canonical instance shape and `weedr service start <name>/<ref>` is the
# verb surface that names it.
escaped='feature\x2fx'
run weedr service ingest envconsumer-preview/feature/x --from poke envconsumer@9f2c1ab
assert_exit 0

instance_home=/var/lib/guarden/services/envconsumer-preview/home/$escaped
instance_quadlet=$instance_home/.config/containers/systemd
env_file=$instance_quadlet/guarden.env
unit=$instance_quadlet/web.container

# **The env file is there, under the escaped ref's own directory.** This is the
# side of the disagreement that was already right: the file is written into the
# instance's own directory, and the directory is named by the escaped ref.
assert_file_exists "$env_file"
assert_file_has "$env_file" "DB_HOST=pgprov-staging"
assert_file_has "$env_file" "DB_PORT=$db_pub"
assert_file_exists "$unit"

uid=$(id -u envconsumer-preview)
[ -n "$uid" ] || _fail "the consumer was created and has no uid"
runtime=/run/user/"$uid"

# --- the manager's own answer about the argv -------------------------------
#
# **The assertion is on the ARGV, not on the text of the unit.** The text of
# the generated unit is a rendering: it carries the value QUOTED, with the
# backslashes doubled, and a grep over that text says nothing about what
# podman receives. The two unescapes that decide the answer are quadlet's
# (reading `EnvironmentFile=`) and systemd's (parsing the quoted `ExecStart`
# argument), and only the PARSED argv is downstream of both.
#
# `systemctl show -p ExecStart --value` prints systemd's parsed command line
# — the argv after systemd's own unescape — so it answers exactly the
# question: what path does podman receive? Measured on the golden VM: for a
# unit whose `EnvironmentFile=` carries ONE backslash, this prints
# `--env-file /.../feature/x/guarden.env` (the slash — a path that names a
# DIRECTORY), and for a unit that carries TWO, it prints
# `--env-file /.../feature\x2fx/guarden.env` (the one backslash the
# directory really has).
#
# **The manager is reloaded first, because the unit is a DECLARATION until
# the generator has run.** Without the reload the manager knows no such unit
# and answers nothing — which is not a failure of the render but of the
# question.
systemctl --user --machine envconsumer-preview@ daemon-reload 2>/dev/null || true

show_argv() {
    local unit_name=$1
    systemctl --user --machine envconsumer-preview@ show -p ExecStart --value \
        "$unit_name" 2>/dev/null
}

argv=$(show_argv "web-$escaped.service")
echo "MEASURE: the argv systemd hands podman: ${argv:-<none>}"
[ -n "$argv" ] || _fail "the manager knows no unit web-$escaped.service, so nothing was generated for the instance"

# The env file podman is handed, read out of the argv rather than retyped.
env_arg=$(printf '%s' "$argv" | tr ' ' '\n' | grep -A1 -x -- '--env-file' | tail -n 1)
echo "MEASURE: the env file podman is handed: ${env_arg:-<none>}"
[ -n "$env_arg" ] || _fail "the generated command carries no --env-file, so the edge's environment is not in the container at all"
[ -f "$env_arg" ] \
    || _fail "podman is handed the env file '$env_arg', which is not a file on this host"
[ "$env_arg" = "$env_file" ] \
    || _fail "podman is handed '$env_arg' and the file that exists is '$env_file'"

# --- and the sibling key is NOT escaped -------------------------------------
#
# **The escaping is a rule about the KEY, not about the path.** Quadlet reads
# `EnvironmentFile=` by C-unescaping its value and reads `Volume=` without
# doing so, so the volume's path -- which carries the same escaped ref, in
# the instance's own tree -- must reach podman with its ONE backslash.
# Escaping it too would point the mount at a directory that is not there, and
# the container would come up with an empty `/data`.
#
# **The backslash is counted, not pattern-matched.** A `case` pattern with
# `\\x2fx` in it is two literal backslashes in bash, and the value carries
# one — so the pattern would match a volume that had been escaped a second
# time and would NOT match one that had not, which is the exact opposite of
# what the assertion is for. The count is what the question is about.
vol_arg=$(printf '%s' "$argv" | tr ' ' '\n' | grep -A1 -x -- '-v' | tail -n 1)
echo "MEASURE: the volume podman is handed: ${vol_arg:-<none>}"
[ -n "$vol_arg" ] || _fail "the generated command carries no -v, so the declared volume is not mounted at all"
vol_backslashes=$(printf '%s' "$vol_arg" | tr -cd '\\' | wc -c)
echo "MEASURE: the backslashes in the volume path: $vol_backslashes"
[ "$vol_backslashes" = 1 ] \
    || _fail "the volume path '$vol_arg' carries $vol_backslashes backslashes and must carry exactly one: the escaped ref's own, and a second one would point the mount at a directory that is not there"

# --- the start, and the container -------------------------------------------
#
# **The observable behaviour.** The instance starts, the unit loads, and
# podman does not answer "no such file". A start that exits 0 while the
# container never came up would be a start that proved nothing, so the
# container is asked for.
run weedr service start envconsumer-preview/feature/x
assert_exit 0
assert_stdout_has "started envconsumer-preview"

active=''
for _ in $(seq 1 90); do
    active=$(systemctl --user --machine envconsumer-preview@ is-active "web-$escaped.service" 2>/dev/null || true)
    if [ "$active" = active ]; then
        break
    fi
    sleep 1
done
echo "MEASURE: the instance's unit is '${active:-unreadable}'"
[ "$active" = active ] \
    || _fail "the instance's unit web-$escaped.service is '${active:-unreadable}', not active"

# And the container itself, which is what the env file was for. The container
# is named with the instance's registry key in hex (spec 5.2), because podman
# accepts no backslash in a container name.
container=envconsumer-preview-web-$(printf %s "$escaped" | od -An -tx1 | tr -d ' \n')
ready=0
for _ in $(seq 1 60); do
    run_in /var/lib/guarden/services/envconsumer-preview/home setpriv \
        --reuid=envconsumer-preview --regid=envconsumer-preview --clear-groups \
        env -u OLDPWD HOME=/var/lib/guarden/services/envconsumer-preview/home \
        PWD=/var/lib/guarden/services/envconsumer-preview/home \
        USER=envconsumer-preview LOGNAME=envconsumer-preview \
        XDG_RUNTIME_DIR="$runtime" \
        podman exec "$container" true
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=1
        break
    fi
    sleep 2
done
[ "$ready" = 1 ] \
    || _fail "the container $container never became exec-able, so the instance did not really start"

# --- and the environment the edge wrote is what the container sees ----------
#
# The env file exists for the application to read, so the claim it makes is
# about the container's own environment. Read from inside the container, which
# is the only place the answer is about.
run_in /var/lib/guarden/services/envconsumer-preview/home setpriv \
    --reuid=envconsumer-preview --regid=envconsumer-preview --clear-groups \
    env -u OLDPWD HOME=/var/lib/guarden/services/envconsumer-preview/home \
    PWD=/var/lib/guarden/services/envconsumer-preview/home \
    USER=envconsumer-preview LOGNAME=envconsumer-preview \
    XDG_RUNTIME_DIR="$runtime" \
    podman exec "$container" sh -c 'echo "$DB_HOST:$DB_PORT"'
assert_exit 0
inside=$(cat "$GUARDEN_STDOUT")
echo "MEASURE: the container's own DB_HOST:DB_PORT: $inside"
[ "$inside" = "pgprov-staging:$db_pub" ] \
    || _fail "the container sees DB_HOST:DB_PORT '$inside' and the edge wrote 'pgprov-staging:$db_pub'"

# --- the sibling: a ref with no slash is untouched --------------------------
#
# The escape is a rule about the BACKSLASH, not about the slash: an instance
# whose ref has no awkward character reads the same env file the same way. If
# the escaping broke the ordinary case, this is where it shows.
run weedr service ingest envconsumer-preview/plain --from poke envconsumer@9f2c1ab
assert_exit 0
plain_quadlet=/var/lib/guarden/services/envconsumer-preview/home/plain/.config/containers/systemd
assert_file_exists "$plain_quadlet/guarden.env"
assert_file_exists "$plain_quadlet/web.container"
run weedr service start envconsumer-preview/plain
assert_exit 0
plain_active=''
for _ in $(seq 1 90); do
    plain_active=$(systemctl --user --machine envconsumer-preview@ is-active web-plain.service 2>/dev/null || true)
    if [ "$plain_active" = active ]; then
        break
    fi
    sleep 1
done
echo "MEASURE: the plain instance's unit is '${plain_active:-unreadable}'"
[ "$plain_active" = active ] \
    || _fail "the plain instance's unit web-plain.service is '${plain_active:-unreadable}', not active"
