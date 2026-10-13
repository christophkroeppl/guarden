#!/usr/bin/env bash
# The unit source is untrusted input, in whichever of the two vocabularies a
# repository wrote it (ticket 40, spec 4 and 6.3).
#
# **`loom` drives the pinned `podlet`, unprivileged, and overwrites or removes
# every field the design has an opinion about.** Running a converter is not
# trusting it: podlet owns the fields guarden has no opinion about — image,
# command, entrypoint, environment, user, working directory, labels — and is not
# a security boundary for the ones it does. That is spec 6.2 stated as a rule
# this repository follows, and the rule is what makes loom the boundary rather
# than the converter.
#
# **"Untrusted" is one meaning here and it is the same in both vocabularies:
# input guarden either refuses or owns a field of.** A Compose file's `cap_add`
# and a hand-written `PodmanArgs=` are the same request, and each is exit `2` with
# the directive named rather than arriving in a unit. The fields guarden
# *regenerates* rather than refuses — the whole `PublishPort` set, the network
# backend, the host entries — are written from the host and never carried over
# from the repository, which is the other half of the same claim.
#
# **These are guardrails against accidents and not a boundary against a hostile
# repository.** A unit source is arbitrary configuration and a text check cannot
# be a boundary: the repository's code runs as the service user, which can write
# files in its own home, and what actually holds is the per-service uid and the
# `0700` on its tree (ADR-0003, spec 6.3). Every diagnostic below that says a
# service "does not get it" is saying that, and the assertions here are about the
# refusal being total and named rather than about it being unbreakable.
#
# **The first block the fake tier carried is dropped rather than ported, and the
# claim it held is named.** This file used to begin by running the *fake* podlet
# and asserting the fields it passed through, because without that the rest
# would pass just as well against a converter that filtered them. The claim —
# "the converter passes `PublishPort`, `Network` and `AddHost` through, so loom
# is the boundary" — is a claim about **podlet**, and asserting it against
# `fixtures/bin` would have been asserting the fake, which is the thing the fake
# tier was retired for.
#
# What replaces it is the assertion that actually carries the weight and needs no
# converter: a repository that ships **quadlet units** states every one of those
# fields out loud, in the renderer's own vocabulary, and loom treats them
# identically. A hand-written `PublishPort=8080:80` is exactly as untrusted as a
# translated one, and this is the half of the file that survives without a
# podlet. What is lost, stated plainly: **"a mechanical converter really does
# pass these fields through" is no longer asserted anywhere**, because a suite
# that needs a converter to mean anything has to run one, and the only one this
# harness could have reached was the fake. The pin is filled now and
# `soil packages --apply` installs the real release, so the claim is reachable on
# a host that has run that phase — it is `tests/t20-podlet.sh` that says the
# installed artefact is a program that runs, and this file still says nothing
# about what it translates. No probe was invented to stand in for it either way.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). `.venv/bin` is kept first because it is the checkout's interpreter
# and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The renderer is unprivileged and writes only into `--out`, so it needs no root
# and no staged passwd — but it does read the service's registry, `overrides.toml`
# and `guarden.toml`, and those have to be where a real install put them. The
# service below is created by a real `weedr service ingest` rather than by a
# seeded registry, because a staged `/etc/passwd` cannot be reconciled with a real
# `useradd` and a hand-written record would be a service that never existed.
export GUARDEN_PREFIX=/
stage_config guarden-measured.toml
stage_poke myapp 9f2c1ab
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
registry=/var/lib/guarden/registry

# **The mutator never runs a converter, or any other program, over repository
# input** (ADR-0012). A poke's tree goes in through `weedr service ingest` and
# nothing is translated there.
#
# This was `assert_not_called "podlet"`, and it is now the state: the ingest
# produced a service whose home holds the repository's own tree and **no rendered
# units at all**. A mutator that ran a converter would have left the unit podlet
# produces under the home's quadlet directory, and the empty directory is the fact
# that says it did not. Nothing else in this file can say it: the render tree the
# renderer writes is elsewhere.
home=/var/lib/guarden/services/myapp-staging/home
# `loom` translated, and it did so as `guarden`: the units are under the service's
# own home and nobody else's. What ADR-0012 forbids is the MUTATOR driving a
# converter over repository input, and the tree that shows it did not is the
# mutator's own render directory, which an unprivileged render never writes.
assert_file_exists "$home/.config/containers/systemd"
assert_file_missing /var/lib/guarden/lib/render/myapp-staging
assert_file_has "$registry/myapp-staging.toml" 'service = "myapp-staging"'

# The same, in the vocabulary a Compose file is written in: a `cap_add` in a
# repository is refused by the renderer, and nothing about that refusal depends
# on a converter — the check runs on the file as it was written.
#
# The refusal happens **before** the converter is driven at all, which is the
# point of doing it first: a repository asking for a capability is turned away
# without the question ever reaching the translator. There is no podlet on this
# host, and two things say that the refusal is loom's own: the diagnostic names
# the key and the container and nothing about an artefact, and it never mentions
# the converter at all. A run that had reached the translator and died there
# would have named it (that is `tests/t40-converter.sh`'s subject).
out=$GUARDEN_FIXTURES/caps-render
run loom render "$GUARDEN_ROOT/fixtures/refused/caps" --service myapp-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cap_add"
assert_stderr_lacks "podlet"
# And the refusal is total: no tree was created at all, so nothing downstream can
# have acted on a partially-rendered set.
assert_file_missing "$out"

# The refusal names the container as well as the key, because those are the two
# facts somebody needs to fix it — and it names the boundary it is not, which is
# the sentence that keeps this file from being read as a security claim.
assert_stderr_has "'web'"
assert_stderr_has "uid"

# **The same list, in the vocabulary a hand-written quadlet file is written in,
# is refused by name too — and that is the whole of what this block claims.** A
# unit source is input (spec 1.2), so every one of these is exit `2`, names the
# directive as it was written, and writes nothing. `t40-refusals.sh` walks the
# list from the other vocabulary; this walks it in the one a repository uses when
# it is asking for the thing directly, which is the case where "a converter
# passed it through" and "a repository wrote it down" have to be
# indistinguishable.
quadlet=$GUARDEN_FIXTURES/quadlet
seed "$quadlet/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/"

refuse_directive() {
    local directive=$1
    local line=$2
    seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
        "Image=docker.io/library/nginx:1.27" "$line"
    run loom check "$quadlet"
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "$directive"
    # The container is named too, **quoted** — the file is called `web.container`
    # and a bare `web` is in the path of every one of these diagnostics, so the
    # assertion that is worth making is the one that cannot be satisfied by the
    # path.
    assert_stderr_has "'web'"
}

# The subject of this rewrite, first and on its own: **`PodmanArgs=` is refused,
# not stripped.** A `PodmanArgs=` line is a repository asking for podman flags,
# and the flags it can ask for include every capability the design says a service
# never gets. An earlier version of this file asserted exit `0` for a unit
# carrying one and then asserted the rendered unit lacked it, which asserted a
# refusal and its opposite in the same run and stopped at the first.
refuse_directive "PodmanArgs" "PodmanArgs=--privileged"

# The rest of the list, one directive per run so the diagnostic is unambiguous.
refuse_directive "PodmanArgs" "PodmanArgs=--cap-add=ALL"
refuse_directive "Device" "Device=/dev/dri"
refuse_directive "AddDevice" "AddDevice=/dev/dri"
refuse_directive "Userns" "Userns=keep-id"
refuse_directive "HostUsers" "HostUsers=keep-id"
refuse_directive "Rootfs" "Rootfs=/"
refuse_directive "BindReadOnlyPaths" "BindReadOnlyPaths=/etc/shadow"
refuse_directive "BindPaths" "BindPaths=/var/lib/postgresql/data:/data"
# `Mount` and not `Mounts`: quadlet's key is `Mount` and its long form spells the
# source `source=`, so the old spelling asked a question about no key at all.
refuse_directive "Mount" "Mount=type=bind,source=/,destination=/host"
refuse_directive "NoNewPrivileges" "NoNewPrivileges=no"
refuse_directive "Privileged" "Privileged=yes"

# A backend other than pasta is refused with the key named, and a pasta option
# list that would remove the host mapping is **not** refused in the unit source —
# it is overwritten, because the whole `Network=` value is guarden's and a
# repository's copy of it has no meaning. Both halves are here because the second
# one is the one that is easy to get backwards.
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Network=slirp4netns"
run loom check "$quadlet"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "Network"
assert_stderr_has "pasta"

# And the refusal is total on `render` as well as on `check`, which is the whole
# of "nothing downstream can have acted on a partially-rendered set": the out
# directory is never created, so there is no tree for the mutator to install.
refused_out=$GUARDEN_FIXTURES/refused-render
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "PodmanArgs=--privileged"
run loom render "$quadlet" --service myapp-staging --out "$refused_out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "PodmanArgs"
assert_file_missing "$refused_out"

# **What guarden owns and does not refuse: written out loud by the repository and
# none of it survives.** The fields below are the ones the renderer *regenerates*
# rather than rejects, so a source carrying them renders, and the rendered unit
# carries the host's answers instead of the repository's. The `Network=` here is a
# pasta backend with an option the renderer itself refuses in `guarden.toml`
# (`--no-map-gw`, ticket 15 item E): it is accepted here precisely because the
# whole value is replaced, which is the strongest form of "a repository's option
# list does not survive". A source asking for `slirp4netns` is the case above,
# and the two together are the rule.
#
# This is the assertion that carries the file without a converter: every field
# the fake was asked to demonstrate was transparently passed through is here
# written by hand in the renderer's own vocabulary.
seed "$quadlet/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" \
    "state:" "  - data" "routes:" "  - container: web" "    port: 3000" "    host: web"
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/nginx" \
    "PublishPort=8080:80" "AddHost=elsewhere:10.0.0.1" "Network=pasta:--no-map-gw" \
    "ContainerName=web-by-another-name"
run loom check "$quadlet"
assert_exit 0
assert_stderr_empty

# The grant is the admin's, in the admin's file. A port is **requested** by a
# manifest and **granted** by the admin in a root-owned `overrides.toml`; the
# renderer refuses every grant that is not in that file, and a poke never grants.
seed /etc/guarden/services/myapp-staging/overrides.toml \
    '[ports]' 'open = [ "8080/tcp" ]'

# Two things the mutator owns are written into the real registry rather than into
# a staged one, because both are real keys the mutator writes and this suite is
# standing in for the install that has not run on this machine: the allocation a
# `routes:` entry is rendered against, and the grant. The registry this suite
# reads is the one `weedr service ingest` wrote, and neither table was in it —
# the ingested project declares no route and no port — so both are appended, which
# is the same edit the mutator makes.
printf '%s\n' '[ports]' 'requested = [ 8080 ]' 'granted = [ 8080 ]' \
    >>"$registry/myapp-staging.toml"
printf '%s\n' '[publication]' 'web = 20114' >>"$registry/myapp-staging.toml"

render=$GUARDEN_FIXTURES/render
run loom render "$quadlet" --service myapp-staging --out "$render"
assert_exit 0
unit=$render/units/web.container

# None of the four survives. The backend is the host's own option list, so the
# repository's `--no-map-gw` is gone and the pinned set `guarden.toml` states is
# written; the published-port set is the whole set from the allocation, so the
# repository's `8080:80` is gone; and the host entries come from the declared
# edges, of which this service has none, so the repository's own name for another
# host is gone with the key.
assert_file_has "$unit" "Network=pasta:--map-gw,--ipv4-only,-a,10.0.2.100,-n,24,-g,10.0.2.2"
assert_file_lacks "$unit" "Network=pasta:--no-map-gw"
assert_file_lacks "$unit" "PublishPort=8080:80"
assert_file_lacks "$unit" "elsewhere"
assert_file_lacks "$unit" "AddHost"

# The whole set comes from the allocation instead, and every one of them is a
# loopback publication: nothing in a rendered unit binds a non-loopback address,
# and a granted public port is a translation onto one of these written by the
# mutator, never a bind (spec 7.5).
assert_file_has "$unit" "PublishPort=127.0.0.1:20114:3000"
# The `ContainerName` the repository chose is its own: guarden has no opinion
# about a name, and rewriting it would break a repository's own volume naming for
# no gain. That is the other half of "podlet owns the fields guarden has no
# opinion about" and it is asserted on a hand-written unit, so it holds without a
# converter. It is also what makes this a boundary claim rather than a scrubbing
# claim: what is refused and what is kept are both named here.
assert_file_has "$unit" "ContainerName=web-by-another-name"

# The granted port is in the admin's file and in the registry, and in neither the
# rendered unit nor anything loom wrote: a grant is a translation, and the
# renderer does not render the firewall. A repository that requested it got a
# publication for its own container, and the public number is the mutator's
# problem on a different file.
assert_file_lacks "$unit" "8080"
assert_file_lacks "$render/shared/routes.toml" "8080"

# The repository's own tree is input, and the host's configuration is read. `loom`
# writes only into `--out`; the two assertions are that the input tree gained
# nothing and that the alias the render depends on was the one in the config.
assert_file_missing "$quadlet/render"
assert_file_has /etc/guarden/guarden.toml 'alias = "10.0.2.2"'

# **The render is unprivileged and that is the property, not the absence of a
# `sudo`.** The old assertion was `assert_not_called "sudo"`, which read a log.
# The state that matches it is the tree the render produced and the tree it did
# not: `--out` is the only place anything was written, the service's own home
# carries no rendered unit, and the host's configuration was read rather than
# rewritten. A renderer that escalated to change any of them would have written
# where the assertions above say it did not.
assert_file_missing /var/lib/guarden/services/myapp-staging/render
assert_file_has "$registry/myapp-staging.toml" 'service = "myapp-staging"'
