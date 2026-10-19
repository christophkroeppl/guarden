#!/usr/bin/env bash
# A `ports:` entry is refused in both of the forms Compose interpolates in
# (ticket 300).
#
# The converter parses the host-IP field before any substitution, so
# `127.0.0.1:${PORT:-19069}:8069` died in podlet's parser with "invalid IP
# address syntax" — a message about an IP address that is written correctly —
# and the refusal that pre-empts it matched the literal `${` and nothing else.
# The bare form a Compose file also writes, `127.0.0.1:$PORT:8069`, therefore
# reached podlet and died there instead. Both are one rule: a port entry
# carries no `$`, in either spelling, and guarden allocates the loopback
# publication from the manifest's ingress rather than the repository stating
# a host IP.
#
# The refusal lands on the repository's own declaration, before the converter
# is driven, so `check` and `render` answer the same way and a render writes
# nothing. The two entries that are not interpolations have to convert, so
# this suite drives the pinned converter for the reason t400-sibling.sh and
# t40-refusals.sh record.
#
# machine: shared
# `guarden_prefix` stages the host, and every staged manifest and staged unit
# source is under `$GUARDEN_FIXTURES`; `install_pinned_converter` reaches real
# apt because the positive case below has to convert.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml
install_pinned_converter

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"

seed_port() {
    local entry=$1
    seed "$project/compose.yaml" "services:" "  web:" \
        "    image: docker.io/library/nginx:1.27" "    ports:" \
        "      - \"$entry\""
}

# Both forms from the same entry point, each naming the construct it carries
# and the rule, and neither mentioning the converter the refusal exists to
# pre-empt.
refuse_port() {
    local entry=$1
    seed_port "$entry"
    run loom check "$project"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$entry"
    assert_stderr_has "templated"
    assert_stderr_has "publication"
    assert_stderr_lacks "podlet"
}

# The form the refusal already matched (ticket 283).
refuse_port '127.0.0.1:${PORT:-19069}:8069'

# The bare form, which reached podlet and died in its parser.
refuse_port '127.0.0.1:$PORT:8069'

# The same two from `render`, which is what a deploy reaches, and nothing is
# written: the refusal is on the declaration, before the plan exists.
for entry in '127.0.0.1:${PORT:-19069}:8069' '127.0.0.1:$PORT:8069'; do
    seed_port "$entry"
    out=$GUARDEN_FIXTURES/render
    run loom render "$project" --service myapp-staging --out "$out"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$entry"
    assert_stderr_has "publication"
    assert_file_missing "$out"
done

# The refusal is about the interpolation and not about ports: the same entry
# with a literal host port is a Compose file guarden has no quarrel with, and
# it converts.
seed_port '8080:80'
run loom check "$project"
assert_exit 0
assert_stderr_empty
assert_stdout_has "is renderable"

# Nor about the container side, which is the repository's own port: a
# container port with no host IP at all is the shape a repository writes when
# it does not know the host's allocation, and it is the renderer's job to
# replace it rather than the reader's to refuse it.
seed_port '3000:3000'
run loom check "$project"
assert_exit 0
assert_stderr_empty
