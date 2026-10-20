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
    purge pgprov-staging needful-preview
    rm -f /etc/guarden/firewall/50-services.conf
}
trap cleanup EXIT

cleanup
ensure_accounts
stage_config guarden-measured.toml
stage_poke pgprov 9f2c1ab
stage_poke needful 9f2c1ab
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
# The ref is taken raw and the escaping is internal (spec 5.2), so `feature/x`
# is the canonical instance shape and `weedr service start <name>/<ref>` is the
# verb surface that names it.
escaped='feature\x2fx'
run weedr service ingest needful-preview/feature/x --from poke needful@9f2c1ab
assert_exit 0

instance_home=/var/lib/guarden/services/needful-preview/home/$escaped
instance_quadlet=$instance_home/.config/containers/systemd
env_file=$instance_quadlet/guarden.env
unit=$instance_quadlet/web.container

# **The env file is there, under the escaped ref's own directory.** This is the
# side of the disagreement that was already right: the file is written into the
# instance's own directory, and the directory is named by the escaped ref.
assert_file_exists "$env_file"
assert_file_has "$env_file" "DB_HOST=pgprov-staging"
assert_file_has "$env_file" "DB_PORT=$db_pub"

# --- the unit's own line, and what the generator makes of it ---------------
#
# The unit carries the path. It has to carry it in the form that survives
# quadlet's C-unescape, so the assertion is on the **argv podman is handed**,
# not on the text of the line: the text is a rendering and the argv is the
# thing that names the file.
assert_file_exists "$unit"

# The generator's own answer, read where it is falsifiable: the unit the
# generator produced out of the installed declaration, in the service user's
# own generator directory.
uid=$(id -u needful-preview)
[ -n "$uid" ] || _fail "the consumer was created and has no uid"
generated=/run/user/$uid/systemd/generator.normal/web-feature\x2fx.service
[ -f "$generated" ] || generated=/run/user/$uid/systemd/generator.normal/web.service

# The env file the generated unit hands podman must be the one that exists.
# Read out of the generated `ExecStart` rather than retyped, so what is
# measured is what the generator produced.
env_arg=$(grep -a '^ExecStart=' "$generated" | tr ' ' '\n' | grep -A1 -x -- '--env-file' | tail -n 1)
echo "MEASURE: the env file podman is handed: ${env_arg:-<none>}"
[ -n "$env_arg" ] || _fail "the generated unit carries no --env-file, so the edge's environment is not in the container at all"
[ -f "$env_arg" ] \
    || _fail "the generated unit hands podman the env file '$env_arg', which is not a file on this host"
[ "$env_arg" = "$env_file" ] \
    || _fail "the generated unit hands podman '$env_arg' and the file that exists is '$env_file'"

# --- the start, and the container -------------------------------------------
#
# **The observable behaviour.** The instance starts, the unit loads, and
# podman does not answer "no such file". A start that exits 0 while the
# container never came up would be a start that proved nothing, so the
# container is asked for.
run weedr service start needful-preview/feature/x
assert_exit 0
assert_stdout_has "started needful-preview"

active=''
for _ in $(seq 1 90); do
    active=$(systemctl --user --machine needful-preview@ is-active "web-$escaped.service" 2>/dev/null || true)
    if [ "$active" = active ]; then
        break
    fi
    sleep 1
done
echo "MEASURE: the instance's unit is '${active:-unreadable}'"
[ "$active" = active ] \
    || _fail "the instance's unit web-$escaped.service is '${active:-unreadable}', not active"

# And the container itself, which is what the env file was for.
container=needful-preview-web-$(printf %s "$escaped" | od -An -tx1 | tr -d ' \n')
ready=0
for _ in $(seq 1 60); do
    run_in /var/lib/guarden/services/needful-preview/home setpriv \
        --reuid=needful-preview --regid=needful-preview --clear-groups \
        env -u OLDPWD HOME=/var/lib/guarden/services/needful-preview/home \
        PWD=/var/lib/guarden/services/needful-preview/home \
        USER=needful-preview LOGNAME=needful-preview \
        XDG_RUNTIME_DIR=/run/user/$uid \
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
run_in /var/lib/guarden/services/needful-preview/home setpriv \
    --reuid=needful-preview --regid=needful-preview --clear-groups \
    env -u OLDPWD HOME=/var/lib/guarden/services/needful-preview/home \
    PWD=/var/lib/guarden/services/needful-preview/home \
    USER=needful-preview LOGNAME=needful-preview \
    XDG_RUNTIME_DIR=/run/user/$uid \
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
run weedr service ingest needful-preview/plain --from poke needful@9f2c1ab
assert_exit 0
plain_quadlet=/var/lib/guarden/services/needful-preview/home/plain/.config/containers/systemd
assert_file_exists "$plain_quadlet/guarden.env"
assert_file_exists "$plain_quadlet/web.container"
run weedr service start needful-preview/plain
assert_exit 0
plain_active=''
for _ in $(seq 1 90); do
    plain_active=$(systemctl --user --machine needful-preview@ is-active web-plain.service 2>/dev/null || true)
    if [ "$plain_active" = active ]; then
        break
    fi
    sleep 1
done
echo "MEASURE: the plain instance's unit is '${plain_active:-unreadable}'"
[ "$plain_active" = active ] \
    || _fail "the plain instance's unit web-plain.service is '${plain_active:-unreadable}', not active"
