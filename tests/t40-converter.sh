#!/usr/bin/env bash
# The converter itself: the pinned artefact's path, and what a host without it
# says (ticket 40, spec 6.3).
#
# **The converter is the one third-party binary, and a host without it must say so
# in one line.** The pin ships filled in, so "no podlet" is the state of a host that
# has not run `soil packages --apply` — the phase that fetches, verifies and
# unpacks it — and it is a fact about the host rather than about the repository's
# document, so exit `1`, not the `2` that would read as "your manifest is wrong"
# (spec 1.2). It was a Python traceback out of
# `subprocess.run`, which is neither: it named a `FileNotFoundError` and no
# artefact, and a developer whose Compose file was fine was told nothing about
# which binary was missing or which phase installs it.
#
# **The renderer resolves `podlet` at the pinned path, not from PATH.** That is the
# security half of the same line: the fetch is digest-verified, and a lookup that
# consulted PATH would run whatever executable a repository could place first on
# the renderer's PATH — the "unverified third-party binary" the pin exists to
# prevent. A repository cannot name the converter; it cannot even reach it.
#
# **This file needs no converter to pass.** Every assertion here is about a host
# that does *not* have one, which is the state of every machine until the pin is
# filled, so this suite is green on the golden today and stays green after. It
# cannot assert that translation works — that needs the real binary and belongs to
# the suites that render a Compose file.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

project=$GUARDEN_FIXTURES/project
seed "$project/.guarden/service.yml" "project: myapp" "units: compose.yaml"
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"

# A Compose source on a host with no converter: one line, exit 1, and it names the
# artefact, the path, and the phase. `assert_one_diagnostic` is what makes "one
# line" a claim rather than a hope — it is the assertion that fails on the
# traceback this replaced.
assert_no_converter() {
    run "$@"
    assert_exit 1
    assert_one_diagnostic "error:"
    assert_stderr_has "podlet"
    assert_stderr_has "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
    assert_stderr_has "soil packages --apply"
    assert_stderr_has "podlet.release"
}

assert_no_converter loom check "$project"

# `render` needs a service, because a publication and the track's weight are
# answers from the host, so the registry is staged rather than invented. It is
# staged because `loom` reads it and nothing else about the service has to exist:
# the point of this block is that the converter is missing, which is reached
# before anything is written.
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-staging.toml" \
    'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
    'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
    '[publication]' 'web = 20114'

assert_no_converter loom render "$project" --service myapp-staging \
    --out "$GUARDEN_FIXTURES/render"

# Nothing was written, which is what makes the refusal total: a host that cannot
# translate leaves no tree behind for anything downstream to act on.
assert_file_missing "$GUARDEN_FIXTURES/render"

# **A refusal on the repository's own declaration still comes first.** `cap_add`
# is loom's check on the Compose file as it was written, and it does not depend on
# a converter existing — so a host with no podlet refuses this in exactly the same
# words, and exit 2. The order is the point: the repository is asked a question
# guarden can answer by itself before the question of whether it can translate the
# answer ever arises.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27" "    cap_add: [ SYS_ADMIN ]"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cap_add"
assert_stderr_has "web"

# The ambiguity and absence refusals are likewise loom's own and need no converter,
# so a host with none still names both accepted locations.
seed "$project/.guarden/quadlet/web.container" "[Container]" "Image=nginx:1.27"
run loom check "$project"
assert_exit 2
assert_stderr_has "compose.yaml"
assert_stderr_has ".guarden/quadlet"
rm -r "$project/.guarden/quadlet"

# A file that is there but is not executable is not a converter, and saying
# "installed" would be a lie: `soil packages --check` installs it 0755, so the
# bit is part of what the pin's install produces. This is the assertion that keeps
# a truncated or wrongly-moded fetch from being reported as a working converter.
mkdir -p "$GUARDEN_PREFIX/usr/lib/guarden/bin"
seed "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet" "not the pinned release"
chmod 0644 "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
seed "$project/compose.yaml" "services:" "  web:" "    image: docker.io/library/nginx:1.27"
run loom check "$project"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "not installed"

# And an empty file with the bit set is the same fault one stage further on: the
# executable bit is there, so the "not installed" check passes, and `exec` is what
# refuses. This was a traceback too — `OSError: [Errno 8] Exec format error` out
# of `subprocess` — and it is the shape a truncated `curl` or an archive installed
# as though it were a binary leaves behind, so it gets the same one line. The
# first `run` below is the one that used to print a stack trace.
: >"$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
chmod 0755 "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
run loom check "$project"
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "could not be run"
assert_stderr_has "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"
assert_stderr_has "soil packages --apply"

rm -f "$GUARDEN_PREFIX/usr/lib/guarden/bin/podlet"

# **A hand-written quadlet source needs no converter at all**, and that is the
# supported alternative rather than a consolation: spec 4 takes `compose.yaml`
# **or** `.guarden/quadlet/`, and a repository that ships units is validated the
# same way a Compose one is. This is why a host whose converter is not installed is
# a reduced host rather than an unrenderable one.
seed "$project/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/"
seed "$project/.guarden/quadlet/web.container" "[Container]" "Image=nginx:1.27"
# The Compose file goes, because a project ships exactly one of the two and
# "both present" is the refusal two blocks above — a repository that switched to
# units does not delete its Compose file in the same commit.
rm -f "$project/compose.yaml"
run loom check "$project"
assert_exit 0
assert_stderr_empty