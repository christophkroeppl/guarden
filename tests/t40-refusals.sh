#!/usr/bin/env bash
# The refusal list, and the mounts that are not the service's own (ticket 40,
# spec 6.3).
#
# **These refusals are guardrails against accidents and not a boundary against a
# hostile repository.** The repository's code runs as the service user, the
# service user can write files in its own home, and the property that actually
# holds is the per-service uid with `0700` on the service tree. What these buy is
# that a capability, a device or a host mount cannot be obtained by adding a line
# to a file, and that the mistake is visible in review.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged manifest, staged unit
# source and staged `guarden.toml` is under `$GUARDEN_PREFIX` or
# `$GUARDEN_FIXTURES`; the refused renders name `/var/lib/postgresql/data`
# in a *diagnostic* and never touch it. `install_pinned_converter` reaches
# real apt and the machine's apt timers; see the note in t40-manifest.sh.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The blocks below that reach `render` do so on a Compose source, and the
# converter is what turns one into units — installed by the phase that owns the
# fetch, at the pinned path, and a program rather than a file that merely exists.
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"

# The refusal list, in the vocabulary a Compose file is written in. Each is exit 2
# and each names the key, because a diagnostic that says "not allowed" is not one
# a developer can act on.
refuse_compose() {
    local key=$1
    seed "$project/compose.yaml" "services:" "  web:" \
        "    image: docker.io/library/nginx:1.27" "    $2"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$key"
}

refuse_compose "cap_add" "cap_add: [ SYS_ADMIN ]"
refuse_compose "cap_drop" "cap_drop: [ ALL ]"
refuse_compose "devices" "devices: [ /dev/dri ]"
refuse_compose "privileged" "privileged: true"
refuse_compose "pid" "pid: host"
refuse_compose "userns_mode" "userns_mode: keep-id"
refuse_compose "podman_args" "podman_args: [ --privileged ]"

# **A `ports:` entry carrying `${...}` is refused by guarden, naming the
# construct (ticket 283).** The converter reads the host-IP field before any
# substitution, so `127.0.0.1:${PORT:-19069}:8069` dies in podlet's parser with
# `invalid IP address syntax` — a message about an IP address that is written
# correctly — and the reader is sent to the wrong line entirely. The refusal is
# guarden's and happens before the converter is driven: on a guarden host the
# publication is not the repository's to state in the first place, because
# `render._publications` writes `PublishPort=127.0.0.1:<allocated>:<port>` from
# the ingress the manifest declares.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    ports:" \
    "      - \"127.0.0.1:\${PORT:-19069}:8069\""
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "ports"
assert_stderr_has "\${PORT:-19069}"
assert_stderr_has "templated"
assert_stderr_has "publication"
assert_stderr_lacks "podlet"

# The refusal is about the substitution and not about ports: the same entry with
# a literal host port is a Compose file guarden has no quarrel with.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    ports:" \
    "      - \"8080:80\""
run loom check "$project"
assert_exit 0
assert_stderr_empty

# The same list in the vocabulary a hand-written quadlet file is written in.
quadlet=$GUARDEN_FIXTURES/quadlet
seed "$quadlet/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/"

refuse_quadlet() {
    local key=$1
    seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
        "Image=docker.io/library/nginx:1.27" "  $2"
    run loom check "$quadlet"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$key"
}

refuse_quadlet "PodmanArgs" "PodmanArgs=--privileged"
refuse_quadlet "PodmanArgs" "PodmanArgs=--cap-add=ALL"
refuse_quadlet "BindReadOnlyPaths" "BindReadOnlyPaths=/etc/shadow"
refuse_quadlet "Mount" "Mount=type=bind,source=/,destination=/host"
refuse_quadlet "Device" "Device=/dev/dri"
refuse_quadlet "Userns" "Userns=keep-id"
# The same directive in quadlet's OWN spelling (podman-systemd.unit(5) writes
# `UserNS=`), which is the spelling a repository copies out of the manual and
# the one guarden's own line is written in — so refusing it here is what keeps
# every `UserNS=` a generated unit carries the renderer's (ADR-0019). The two
# spellings are two lookups (unitsource's table is case-exact), and only the
# `Userns=` one was asserted before this line.
refuse_quadlet "UserNS" "UserNS=keep-id:uid=200,gid=210"

# A unit source naming a backend other than pasta is refused with the key named.
# On the Compose path `network_mode` is *replaced* rather than refused, which is
# what the spec says and is checked in t40-untrusted.sh.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Network=slirp4netns"
run loom check "$quadlet"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "Network"
assert_stderr_has "pasta"

# A host-path bind outside the service's own volumes, `/etc/guarden` and the
# admin's allow list, naming the path.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=/var/lib/postgresql/data:/data"
run loom check "$quadlet"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "/var/lib/postgresql/data"
assert_stderr_has "mounts"

# `/etc/guarden` is the one tree every service may read, because it is root-owned
# and holds no secret a service has any business seeing.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=/etc/guarden/edge:/etc/guarden:ro"
run loom check "$quadlet"
assert_exit 0
assert_stderr_empty

# A relative host path is refused: it resolves against whatever directory
# podman happens to be started in, which is not a thing a manifest gets to choose.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=./config:/etc/app"
run loom check "$quadlet"
assert_exit 2
assert_stderr_has "relative"

# A volume with no source is an anonymous volume in the service's image store,
# which is the same mistake as an undeclared one.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    volumes:" "      - /var/lib/nginx"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "anonymous volume"

# A tmpfs is neither a named volume nor a host path, and a manifest that wants
# one gets a name for what it is asking for.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    volumes:" \
    "      - type: tmpfs" "        target: /scratch"
run loom check "$project"
assert_exit 2
assert_stderr_has "tmpfs"

# The host's own configuration is refused the same way: pasta is the only backend
# v1 supports, and an option that removes the host mapping would leave a box where
# no container can reach any other (spec 3.1, ticket 15 item E). These are only
# reachable through `render`, because the render is what reads them. Each set
# below is the pinned one plus the offender, so the option under test is the only
# thing wrong with the table.
stage_service() {
    seed "$GUARDEN_PREFIX/var/lib/guarden/registry/$1.toml" \
        "service = \"$1\"" "workload = \"myapp\"" "project = \"myapp\"" \
        "environment = \"staging\"" "uid = 1101" "created = \"2026-09-30T09:00:00Z\""
}
stage_service myapp-staging
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"

refuse_config() {
    local expected=$1
    shift
    seed "$GUARDEN_PREFIX/etc/guarden/guarden.toml" \
        '[host]' 'domain = "example.com"' 'admin_user = "operator"' \
        '[ingress]' 'alias = "10.0.2.2"' 'publication_range = [ 20000, 32767 ]' \
        '[build]' 'lanes = 1' '[network]' "$@" \
        '[[environments]]' 'name = "staging"' 'host_prefix = "staging."' 'weight = 100' \
        'kind = "slot"' 'fork_from = ""'
    run loom render "$project" --service myapp-staging --out "$GUARDEN_FIXTURES/render"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$expected"
}

refuse_config 'slirp4netns' 'backend = "slirp4netns"'
refuse_config '--no-map-gw' \
    'pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2", "--no-map-gw" ]'
refuse_config '--map-host-loopback none' \
    'pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2", "--map-host-loopback", "none" ]'
refuse_config '--map-host-loopback=none' \
    'pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2", "--map-host-loopback=none" ]'

# `--no-map-gw` again, this time packed behind a comma inside one entry: podman
# splits the value on commas and runs every piece, so a refusal that tested
# whole entries would let this through while podman still honoured the option.
# The pinned pieces sit beside it, so the packed entry is the only thing wrong.
refuse_config '--no-map-gw' \
    'pasta_options = [ "--map-gw,--no-map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]'
