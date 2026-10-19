#!/usr/bin/env bash
# A sibling container named as a host is refused from a hand-written quadlet
# unit source as well (ticket 299, spec 7.3).
#
# spec 7.3 states the refusal for "a unit source" and names no vocabulary:
# `loom` refuses "such a unit source", naming the container, the sibling, the
# key and the value, and the answer the diagnostic carries is `needs:`. What was
# checked was only a Compose file's service bodies (t400-sibling.sh, the Compose
# half), so `.guarden/quadlet/` — the other half of "either `compose.yaml` at
# its root or quadlet units in `.guarden/quadlet/`" — rendered names that
# resolve to nothing while loom overwrote `AddHost=`. Every container of one
# service is in its own pasta namespace (spec 7.1), so the name dials nothing
# either way; the file is refused instead of rendering dead names.
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
    assert_stderr_has "needs:"
}

# `Environment=<KEY>=<sibling>` — the shape the ticket measured, a unit whose
# environment dials the container beside it.
refuse_sibling "sibling container 'db' as a host in environment DB_HOST ('db')" \
    "Environment=DB_HOST=db"

# The same key with a scheme and a port, which is where a URL lives.
refuse_sibling "sibling container 'db' as a host in environment API_URL ('http://db:3000')" \
    "Environment=API_URL=http://db:3000"

# A hostname inside the command, which is where a health check lives.
refuse_sibling "sibling container 'db' as a host in command ('curl http://db:3000/health')" \
    "Exec=curl http://db:3000/health"

# The same for `HealthCmd=`, whose compose spelling is `healthcheck.test`.
refuse_sibling "sibling container 'db' as a host in healthcheck ('curl http://db:3000/health')" \
    "HealthCmd=curl http://db:3000/health"

# The repository writing an `AddHost=` line itself, which is compose's
# `extra_hosts` and does not survive either: the key is the renderer's and the
# host entries come from the declared edges, so a sibling named here is the same
# dead name.
refuse_sibling "sibling container 'db' as a host in extra_hosts ('db:10.0.0.1')" \
    "AddHost=db:10.0.0.1"

# The same refusal from `render`, which is what a deploy reaches, and nothing is
# written: the refusal lands on the repository's own declaration, before the
# renderer plans a single file.
two_units "Environment=DB_HOST=db"
out=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "sibling container 'db'"
assert_stderr_has "needs:"
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
