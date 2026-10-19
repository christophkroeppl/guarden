#!/usr/bin/env bash
# A sibling container named as a host is refused, naming `needs:` (ticket 285,
# spec 7.3).
#
# The ticket measured the silent version of this: a two-service compose where
# one names the other by service name rendered a unit with no `AddHost=` for the
# sibling, so `api` resolved to nothing and the worker could not reach the thing
# it named — the compose file converted, the units rendered, and the failure was
# invisible. Every container of one service has its own pasta namespace and there
# is no shared network, so the only name this design resolves is a **service**
# name through an edge (spec 7.3), and the host binds each container's allocated
# publication rather than the container port the compose value dials — so even a
# rendered sibling entry would not connect. The file is refused instead of
# rendering dead names, and the one line says what to do about it.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged manifest and staged unit
# source is under `$GUARDEN_FIXTURES`; `install_pinned_converter` reaches real
# apt for the reason t40-refusals.sh records — the negative cases below have to
# convert.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"

two_services() {
    seed "$project/compose.yaml" "services:" \
        "  api:" "    image: docker.io/library/alpine:3.20" \
        "  worker:" "    image: docker.io/library/alpine:3.20" "$@"
}

# The ticket's own compose file, in each shape a repository writes a hostname
# in. The fragment is the whole of what the diagnostic must carry: which
# container named which sibling, where, and the value it dialled. `check` and
# `render` both read the unit source before the host is asked anything, so both
# answer the same way whatever state the registry is in.
refuse_sibling() {
    local fragment=$1
    shift
    two_services "$@"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$fragment"
    assert_stderr_has "needs:"
}

# `http://<sibling>:<port>` — the shape the ticket rendered and measured.
refuse_sibling "sibling container 'api' as a host in environment API_URL ('http://api:3000')" \
    "    environment:" "      API_URL: http://api:3000"

# `<sibling>:<port>` with no scheme, and the list spelling of `environment:`.
refuse_sibling "sibling container 'api' as a host in environment API_HOST ('api:3000')" \
    "    environment:" "      - API_HOST=api:3000"

# A bare host with no port: an environment value that *is* the sibling's name is
# a hostname by construction (`BITCOIN_HOST=bitcoind` is the shape a stack
# actually writes).
refuse_sibling "sibling container 'api' as a host in environment API_HOST ('api')" \
    "    environment:" "      API_HOST: api"

# A hostname inside a command argument, which is where a health check lives.
refuse_sibling "sibling container 'api' as a host in command ('curl http://api:3000/health')" \
    "    command:" "      - sh" "      - -c" "      - curl http://api:3000/health"

# `extra_hosts` is the repository writing an `AddHost=` line itself, and it does
# not survive either: the key is the renderer's, and the host entries come from
# the declared edges (t40-untrusted.sh asserts the drop), so naming a sibling
# here is the same dead name.
refuse_sibling "sibling container 'api' as a host in extra_hosts ('api:10.0.0.1')" \
    "    extra_hosts:" "      - api:10.0.0.1"

# The same refusal from `render`, which is what a deploy reaches, and nothing is
# written: the refusal lands on the repository's own declaration, before the
# converter runs and before the host is asked for anything.
two_services "    environment:" "      API_URL: http://api:3000"
out=$GUARDEN_FIXTURES/render
run loom render "$project" --service myapp-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "sibling container 'api'"
assert_stderr_has "needs:"
assert_file_missing "$out"

# Two containers in one file are not on their own a refusal: what is refused is
# a value that dials one. The same file with nothing between them converts and
# renders.
two_services
run loom check "$project"
assert_exit 0
assert_stderr_empty
assert_stdout_has "is renderable"

# A name that only looks like the sibling's is not a reference: the authority
# after `//` runs until the next delimiter, so `apiary` is a different host and
# a value mentioning one is text. Refusing it would be a check that fires on its
# own shadow.
two_services "    environment:" "      API_DOCS: https://apiary.example.com/docs"
run loom check "$project"
assert_exit 0
assert_stderr_empty
