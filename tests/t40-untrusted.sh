#!/usr/bin/env bash
# The converter's output is untrusted input, not a finished unit (ticket 40,
# spec 4 and 6.3).
#
# **`loom` drives the pinned `podlet`, unprivileged, and overwrites or removes
# every field the design has an opinion about.** Running a converter is not
# trusting it: podlet owns the fields guarden has no opinion about — image,
# command, entrypoint, environment, user, working directory, labels — and is not
# a security boundary for the ones it does.
#
# The first assertion in this file is that the converter really does pass them
# through. Without it the rest of the file would pass just as well against a
# converter that filtered them, and would prove nothing about loom.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The mutator never runs a converter, or any other program, over repository input
# (ADR-0012). A poke's tree goes in through `weedr service ingest` and nothing is
# translated there. This comes first in the file because the call log is shared
# across the file and this is a claim about the log being empty of one thing.
stage_poke myapp 9f2c1ab
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0
assert_not_called "podlet"

converted=$GUARDEN_FIXTURES/converted
fake podlet quadlet --outdir "$converted" "$GUARDEN_ROOT/fixtures/projects/hostnet/compose.yaml"
assert_exit 0
assert_called "podlet quadlet --outdir"
assert_file_exists "$converted/web.container"
# What a mechanical translator makes of a Compose file: the port verbatim, the
# host's network namespace, and a host entry of the repository's choosing.
assert_file_has "$converted/web.container" "PublishPort=8080:80"
assert_file_has "$converted/web.container" "Network=host"
assert_file_has "$converted/web.container" "AddHost=elsewhere:10.0.0.1"
assert_file_has "$converted/web.container" "Image=docker.io/library/nginx:1.27"

# Now the same Compose file through the renderer, which drives that converter.
# `cap_add` is the one the refusal list stops: the `network_mode` would be
# replaced and the `PublishPort` stripped, and the render does not go ahead.
out=$GUARDEN_FIXTURES/caps-render
run loom render "$GUARDEN_ROOT/fixtures/refused/caps" --service caps-staging --out "$out"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "cap_add"
assert_file_missing "$out"

# The refusal is a guardrail against a repository asking for a capability, and
# it names the container as well as the key, because those are the two facts
# somebody needs to fix it.
assert_stderr_has "web"

# A repository that ships quadlet units has them used as they are, after the
# same checks. The two accepted unit sources get the same treatment, because a
# converter that passed a field through is not a boundary and a hand-written one
# is a repository asking out loud. The container set is the stems and the
# `ContainerName=` each unit carries, so a quadlet-only repository is validated
# exactly as a Compose one is — and the name the repository chose is its own.
quadlet=$GUARDEN_FIXTURES/quadlet
seed "$quadlet/.guarden/service.yml" "project: myapp" "units: .guarden/quadlet/" "state:" "  - data"
seed "$quadlet/.guarden/quadlet/web.container" "[Container]" \
  "Image=docker.io/library/nginx:1.27" "Volume=data:/var/lib/nginx" \
  "PublishPort=8080:80" "AddHost=elsewhere:10.0.0.1" "Network=pasta:--map-gw" \
  "ContainerName=web-by-another-name"
run loom check "$quadlet"
assert_exit 0
assert_stderr_empty

seed "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-staging.toml" \
  'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
  'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
  '[publication]' 'web = 20114' 'node = 20115' \
  '[ports]' 'requested = [ 8080 ]' 'granted = [ 8080 ]'
run loom render "$quadlet" --service myapp-staging --out "$GUARDEN_FIXTURES/quadlet-render"
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/quadlet-render/units/web.container" \
    "ContainerName=web-by-another-name"

# The render is the only thing that runs a converter, and it runs it as itself.
seed "$GUARDEN_PREFIX/var/lib/guarden/registry/myapp-staging.toml" \
  'service = "myapp-staging"' 'workload = "myapp"' 'project = "myapp"' \
  'environment = "staging"' 'uid = 1101' 'created = "2026-09-30T09:00:00Z"' \
  '[publication]' 'web = 20114' 'node = 20115' \
  '[ports]' 'requested = [ 8080 ]' 'granted = [ 8080 ]'
seed "$GUARDEN_PREFIX/etc/guarden/services/myapp-staging/overrides.toml" \
  '[ports]' 'open = [ "8080/tcp" ]'

render=$GUARDEN_FIXTURES/render
run loom render "$GUARDEN_ROOT/fixtures/projects/hostnet" --service myapp-staging --out "$render"
assert_exit 0
assert_called "podlet quadlet --outdir"
assert_not_called "sudo"

# None of the three survives. The network backend is the host's own, the
# repository's PublishPort is gone, and the repository's AddHost is gone with the
# repository's idea of who a host is.
unit=$render/units/web.container
assert_file_has "$unit" "Network=pasta:--map-gw"
assert_file_lacks "$unit" "Network=host"
assert_file_lacks "$unit" "PublishPort=8080:80"
assert_file_lacks "$unit" "elsewhere"
assert_file_lacks "$unit" "PodmanArgs"

# The whole set comes from the allocations instead, and every one of them is a
# **loopback** publication: nothing in a rendered unit binds a non-loopback
# address, and a granted public port is a translation onto one of these written
# by the mutator, never a bind (spec 7.5).
assert_file_has "$unit" "PublishPort=127.0.0.1:20114:3000"
assert_file_has "$unit" 'ContainerName=myapp-staging-web'

# The granted port is in the admin's file and in the registry, and in neither the
# rendered unit nor anything loom wrote: a grant is a translation, and the
# renderer does not render the firewall.
assert_file_lacks "$unit" "8080"
assert_file_lacks "$render/shared/routes.toml" "8080"

# `loom` writes only into --out. The project's own tree is input, and the host's
# configuration is read.
assert_file_missing "$GUARDEN_ROOT/fixtures/projects/hostnet/render"
assert_file_has "$GUARDEN_PREFIX/etc/guarden/guarden.toml" 'alias = "192.0.2.1"'
