#!/usr/bin/env bash
# A container of one unit source named as a host is refused from a hand-written
# quadlet unit source too, unless the manifest declares it under `siblings:`
# (ticket 299, narrowed by ticket 316, ADR-0023, spec 7.3).
#
# spec 7.3 states the refusal for "a unit source" and names no vocabulary:
# `loom` refuses "such a unit source", naming the container, the sibling, the
# key and the value. What was checked was only a Compose file's service bodies
# (t400-sibling.sh, the Compose half), so `.guarden/quadlet/` — the other half
# of "either `compose.yaml` at its root or quadlet units in `.guarden/quadlet/`"
# — rendered names that resolve to nothing while loom overwrote `AddHost=`.
#
# **The refusal is now narrower, and the narrowing is the point.** A container
# of THIS source resolves — but only when the manifest declares it under
# `siblings:` with the port it serves, because the port is what guarden has to
# translate into the container's publication (ADR-0023).
#
# The shapes mirror t400-sibling.sh's, one per key a repository writes a host
# in, in the vocabulary a hand-written unit is written in.
#
# machine: shared
# `guarden_prefix` stages the host and every staged manifest and staged unit
# source is under `$GUARDEN_FIXTURES`; the unit source is hand-written quadlet,
# so no converter is driven, nothing is fetched, and `loom` writes only into
# `--out` (which the refusals below never reach).

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet"

two_units() {
    seed "$project/.guarden/quadlet/db.container" "[Container]" \
        "Image=docker.io/library/postgres:17"
    seed "$project/.guarden/quadlet/api.container" "[Container]" \
        "Image=docker.io/library/alpine:3.20" "$@"
}

# The ticket's own line, in each key a unit source dials a host through. The
# fragment is the whole of what the diagnostic must carry: which container named
# which sibling, where, and the value it dialled. `check` and `render` both read
# the unit source before the host is asked anything, so both answer the same way
# whatever state the registry is in.
refuse_sibling() {
    local fragment=$1
    shift
    two_units "$@"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$fragment"
    assert_stderr_has "siblings:"
}

# `Environment=<KEY>=<sibling>` — the shape the ticket measured, a unit whose
# environment dials the container beside it.
refuse_sibling "names the container 'db' as a host in environment DB_HOST ('db')" \
    "Environment=DB_HOST=db"

# The same key with a scheme and a port, which is where a URL lives.
refuse_sibling "names the container 'db' as a host in environment API_URL ('http://db:3000')" \
    "Environment=API_URL=http://db:3000"

# A hostname inside the command, which is where a health check lives.
refuse_sibling "names the container 'db' as a host in command ('curl http://db:3000/health')" \
    "Exec=curl http://db:3000/health"

# The same for `HealthCmd=`, whose compose spelling is `healthcheck.test`.
refuse_sibling "names the container 'db' as a host in healthcheck ('curl http://db:3000/health')" \
    "HealthCmd=curl http://db:3000/health"

# The repository writing an `AddHost=` line itself, which is compose's
# `extra_hosts` and does not survive either: the key is the renderer's and the
# host entries come from the declared edges and the manifest's own `siblings:`
# block, so a sibling named here is the same dead name.
refuse_sibling "writes extra_hosts ('db:10.0.0.1')" \
    "AddHost=db:10.0.0.1"

# The same refusal from `render`, which is what a deploy reaches, and nothing is
# written: the refusal lands on the repository's own declaration, before the
# renderer plans a single file.
two_units "Environment=DB_HOST=db"
out=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "names the container 'db'"
assert_stderr_has "siblings:"
assert_file_missing "$out"

# Two containers in one unit source are not on their own a refusal: what is
# refused is a value that dials one. The same pair with nothing between them
# renders as far as `check` goes, and `check` writes nothing.
two_units
run loom check "$project"
assert_exit 0
assert_stderr_empty
assert_stdout_has "is renderable"

# A value that only looks like the sibling's is not a reference: the authority
# after `//` runs until the next delimiter of a hostname, so `dbmetrics` is a
# different host and a value mentioning one is text. Refusing it would be a
# check that fires on its own shadow.
two_units "Environment=API_URL=https://dbmetrics.example.com"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# --- a quoted Environment= line reads as systemd reads it --------------------
# systemd takes a quoted stretch as ONE string: `Environment="ROLE=db
# mode=prod"` is the single variable ROLE with the value `db mode=prod`,
# which dials nothing. Splitting the line on whitespace and unquoting each
# token read it as ROLE=db beside mode=prod, and the sibling rule refused a
# file on a dial systemd would never make. The quoted shape is refused at
# write time anyway (`unitsource.format_line`, one quoted argument holding
# several words), so what this pins is WHICH refusal the reader gets: the
# repository's, not the rule's.
two_units 'Environment="ROLE=db mode=prod"'
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_lacks "names the container"
assert_stderr_has "one quoted argument"

# The other direction, which the correct reader refuses for the right reason:
# the quoted string is ONE value, and `http://db:3000` inside it dials the
# sibling exactly as the unquoted form does.
two_units 'Environment="API_URL=http://db:3000 mode=prod"'
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "names the container 'db'"
assert_stderr_has "siblings:"

# --- the rule reads the value ${domain} becomes ------------------------------
# `${domain}` is the host's own `host.domain` (spec 4), substituted as the
# unit is written. The sibling rule read the value before that, so
# `Environment=APP_HOST=${domain}` beside a `domain.container` rendered
# APP_HOST=<domain> — the same dead dial as the literal form — and was
# refused by nothing. The host's domain is not repository input, so `check`
# cannot know it (loom: check reads no host) and answers as it always did;
# the refusal is `render`'s, on the values the unit will carry.
registry=$GUARDEN_PREFIX/var/lib/guarden/registry
seed "$registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1103' 'created = "2026-10-19T08:00:00Z"'
# The domain has to equal the sibling's stem for the dial to happen at all,
# and `db` is the sibling this suite has always staged.
sed -i 's/^domain = .*/domain = "db"/' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"

two_units 'Environment=APP_HOST=${domain}'
out=$GUARDEN_FIXTURES/render-substituted
run loom check "$project"
assert_exit 0
assert_stdout_has "is renderable"
run loom render "$project" --service myapp-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "names the container 'db' as a host in environment APP_HOST"
assert_stderr_has "siblings:"
assert_file_missing "$out"

# And the same render with a domain that names no sibling renders, carrying
# the value the substitution gives it: the rule refuses the dial, not the
# marker, and a unit source that has always written ${domain} still renders.
sed -i 's/^domain = .*/domain = "example.com"/' "$GUARDEN_PREFIX/etc/guarden/guarden.toml"
run loom render "$project" --service myapp-staging --out "$out"
assert_exit 0
assert_stderr_empty
assert_file_has "$out/units/api.container" "APP_HOST=example.com"

# --- and the declaration that makes it resolve ------------------------------
#
# **The sibling's port is what guarden could not know.** The unit source does
# not declare it anywhere guarden reads, so the manifest does, and the file is
# then renderable — the same file that was refused a moment ago, with the
# declaration added.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet" \
    "siblings:" "  - container: db" "    port: 5432"
two_units "Environment=DB_HOST=db"
run loom check "$project"
assert_exit 0
assert_stderr_empty
assert_stdout_has "is renderable"

echo "ok   t430-quadlet-sibling.sh"
