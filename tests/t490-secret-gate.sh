#!/usr/bin/env bash
# Tickets 305 and 313, the gate half: a credential the units ask for and nobody
# planted is a GATE STATE, never a raw podman error.
#
# **The promise spec 6.6 makes is about a blocked gate, and it is a state.**
# The deploy exits `0`, the service is installed and waiting, `[gate] reason`
# says why, and `weedr service start` re-checks and starts once the operator
# has planted the credentials. That machinery keys on the manifest's
# `.env.schema` — and a service with NO schema has nothing for it to key on.
#
# Two shapes of the same hole, and both were measured in a VM:
#
#   305  a template-created service ships neither manifest nor schema, so its
#        unit can name a `Secret=<KEY>` nothing knows about. The gate's answer
#        is `not-required`/`ready`, the start proceeds, and podman refuses the
#        container with a raw `125 no such secret`.
#
#   313  a key marked `@required` but NOT `@sensitive` is planted by nobody:
#        spec 5.3 step 9 mints only `@sensitive` keys, and the renderer asks
#        podman for a `@required` key too (spec 6.3). The gate says
#        `not-required` on an ungated track, the start proceeds, and podman
#        refuses the unit with a raw `125 no such secret`.
#
# So the gate's subject is the set of credential REQUESTS the service's units
# make, not the set of keys its schema declares. A request nobody can satisfy
# is reported the way a missing required key is reported — one answer, and the
# two tracks still differ only in what they do about it.
#
# What is asserted here is state: the exit code, the diagnostic, and the
# registry's `[gate]` table. No call log and no stand-in (ADR-0014).
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

registry=/var/lib/guarden/registry

# ---------------------------------------------------------------------------
# 305: a template-created service, whose unit asks for a key nothing declares.
#
# The template ships a quadlet file and nothing else — no manifest, no schema
# (docs/sysadmin.md, "templates"). The `Secret=` line in it is the request
# nothing satisfies: no schema declares the key, so the gate has nothing to
# ask about, and podman is the one that refuses the start.
# ---------------------------------------------------------------------------

install -d -m 0755 /usr/lib/guarden/templates/services/secretgate
seed /usr/lib/guarden/templates/services/secretgate/app.container \
    '[Unit]' \
    'Description=a template service with a credential nobody plants' \
    '[Container]' \
    'Image=docker.io/library/nginx:1.27' \
    'Secret=UNPLANTED_KEY,type=mount'

run weedr service create gateapp-production --env production --template secretgate
assert_exit 0
assert_stdout_has "created gateapp-production"

unit=/var/lib/guarden/services/gateapp-production/home/.config/containers/systemd/app.container
assert_file_exists "$unit"
assert_file_has "$unit" "Secret=UNPLANTED_KEY,type=mount"

# **The gate's answer before anything is planted.** A service whose units ask
# for a credential nothing satisfies is not `ready`, whatever its schema says
# — and the schema here says nothing at all, which is the whole of ticket 305.
#
# The state is `blocked` and the reason names the key. Before the fix this
# recorded `ready` (a gated track with an empty schema), the start proceeded,
# and podman answered `125 no such secret` — a runtime error where the spec
# promises a gate state.
run weedr service gate gateapp-production
assert_exit 1
assert_stderr_has "cannot start"
assert_stderr_has "UNPLANTED_KEY"
assert_file_has "$registry/gateapp-production.toml" 'state = "blocked"'
assert_file_has "$registry/gateapp-production.toml" "UNPLANTED_KEY"

# **A start refuses for the same reason and in the same place** (spec 6.6
# step 3, and the exit table in spec 1.2: "`weedr service start` on a gated
# track whose gate is blocked" is `1`). This is the line the operator reads,
# and before the fix it was podman's own `125 no such secret`.
run weedr service start gateapp-production
assert_exit 1
assert_stderr_has "UNPLANTED_KEY"
assert_stdout_empty
assert_file_has "$registry/gateapp-production.toml" 'state = "blocked"'

# The container is NOT running, and the refusal is what kept it that way: a
# gated track's service waits for its credentials rather than starting and
# failing. What is observable on this host is the unit's state.
assert_file_has "$registry/gateapp-production.toml" 'state = "blocked"'

# **The operator plants the credential and the gate opens** — the same verb
# that refused now answers ready, because `start` re-evaluates every time
# (spec 6.6). No second push, no re-render.
run weedr secret set gateapp-production UNPLANTED_KEY <<<"a-real-value"
assert_exit 0
run weedr service gate gateapp-production
assert_exit 0
assert_stdout_has "gateapp-production gate ready"
assert_file_has "$registry/gateapp-production.toml" 'state = "ready"'
# `reason` is present only when the state is `blocked` (spec 3.4).
assert_file_lacks "$registry/gateapp-production.toml" "reason ="

# ---------------------------------------------------------------------------
# 313: a schema key marked `@required` but NOT `@sensitive`.
#
# `@defaultRequired=infer` makes a key declared WITH a value required, and
# `@defaultSensitive=false` makes it not a credential. So `LOG_LEVEL=info` is
# required and is not sensitive: spec 5.3 step 9 mints only `@sensitive` keys,
# so nothing plants it, and the renderer asks podman for it anyway (spec 6.3
# emits a request for a `@sensitive` OR a `@required` key).
# ---------------------------------------------------------------------------

# A project of its own, so the schema is this suite's subject and not the
# quadlet-app fixture's (whose `LOG_LEVEL` a database edge also touches).
project=reqnot
ref=9f2c1ab
staged=/var/lib/guarden/staging/$project/$ref
mkdir -p "$staged/.guarden/quadlet"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
   "$staged/.guarden/.env.schema"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
   "$staged/.guarden/quadlet/web.container"
cat >"$staged/.guarden/service.yml" <<'YAML'
project: reqnot
units: .guarden/quadlet/
schema: .guarden/.env.schema
state:
  - data
YAML
printf '%s\n' "services: [reqnot-staging]" >"$staged/guarden-poke.json"

run weedr service ingest reqnot-staging --from poke $project@$ref
assert_exit 0

# The unit asks podman for the key, because the schema requires it. That is
# spec 6.3 and it is not what is broken; what is broken is that nothing plants
# a value for it.
web=/var/lib/guarden/services/reqnot-staging/home/.config/containers/systemd/web.container
assert_file_exists "$web"
assert_file_has "$web" "Secret=LOG_LEVEL"

# **Nothing minted it.** The schema's `LOG_LEVEL` is required and is not
# sensitive, so spec 5.3 step 9's mint — which is for `@sensitive` keys — does
# not reach it, and the registry's `[generated]` table says so. This is the
# half of the hole that is a fact about the host rather than about the gate:
# there is no value in the service's store.
assert_file_lacks "$registry/reqnot-staging.toml" "LOG_LEVEL"
assert_file_missing /etc/guarden/creds/reqnot-staging/LOG_LEVEL.cred

# **The gate's answer on an ungated track.** The track is not gated, so the
# gate does not withhold the start — but it says what is missing, in a
# `warning:` that names the key, and records `not-required`. That is the
# whole difference between the two tracks (spec 6.6 step 3).
run weedr service gate reqnot-staging
assert_exit 0
assert_one_diagnostic "warning:"
assert_stderr_has "LOG_LEVEL"
assert_stdout_has "reqnot-staging gate not-required"
assert_file_has "$registry/reqnot-staging.toml" 'state = "not-required"'

# **And the start refuses with the key in the line, rather than letting podman
# answer `125 no such secret`.** Before the fix this is where the raw runtime
# error came from: the gate said not-required, the start proceeded, and podman
# refused the unit with `no such secret for LOG_LEVEL` — a runtime error
# naming a podman message, where the operator needs the key.
#
# The refusal is one line, it names the key, and it names the command that
# plants it. It is exit `1` — the host is not in the state the request assumed
# (spec 1.2) — and it is the same code a blocked gate's start answers with.
run weedr service start reqnot-staging
assert_exit 1
assert_stderr_has "LOG_LEVEL"
assert_stderr_has "secret set"
assert_stdout_empty

# **The gate's state on the ungated track is unchanged by that refusal.** The
# track's difference is what the DEPLOY does with a blocked gate (spec 6.6
# step 5), and the gate's own verdict is still `not-required` — a warning
# naming the key, and a start that the operator unblocks by planting it. The
# refusal above is the start's own precondition, not a change to the verdict.
assert_file_has "$registry/reqnot-staging.toml" 'state = "not-required"'

# **The operator plants it and the start has what it needs.** The same verb
# that reported it now has a value, and the gate's warning is gone.
run weedr secret set reqnot-staging LOG_LEVEL <<<"info"
assert_exit 0
run weedr service gate reqnot-staging
assert_exit 0
assert_stderr_empty
assert_file_has "$registry/reqnot-staging.toml" 'state = "not-required"'

# ---------------------------------------------------------------------------
# The two answers are one answer.
#
# A key the units ask for and the schema does not declare (305) and a key the
# schema requires and nothing plants (313) are reported the same way, and
# they are the same thing: a credential request with no value behind it. Two
# answers for one condition would mean an operator had to know which half of
# the hole they were in.
# ---------------------------------------------------------------------------

run weedr service gate gateapp-production
assert_exit 0
assert_stderr_empty
assert_stdout_has "gateapp-production gate ready"

rm -rf /usr/lib/guarden/templates/services/secretgate
