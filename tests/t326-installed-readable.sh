#!/usr/bin/env bash
# The rule fires where a repository's DECLARATION is accepted, and not where
# guarden reads back a document it already holds (ticket 326, spec 4).
#
# **What was false.** Commit 432e5f4 put the rule inside `manifest.read()`, the
# one parser every caller shares. Its commit message claimed "a service already
# installed and managed keeps being readable, because the readers of an
# installed service's manifest read a document guarden did not just accept" —
# and that claim is FALSE for the code as written: the check was in `read()`,
# so it fired on EVERY read, including the read of the copy of the manifest
# guarden keeps in an installed service's home.
#
# **Why that matters, and it is not a theoretical one.** The operator's real
# staging postgres — the ticket's own subject, finding F4 — is exactly such an
# installed service: its manifest provides `db` and declares no volume. Under
# the shared-parser placement it could not be started, gated, restarted or
# built, and the firewall render refused it, because every one of those verbs
# reads that manifest. A rule that fires on the operator's own existing,
# running service is a rule that bricks the box it is meant to protect.
#
# **The second consequence, and it is on the privileged surface.** `weedr
# service remove` removes the service and THEN re-renders the firewall; that
# render resolves every surviving service's grant through the manifest in its
# home, so one surviving `db` provider with no volume and a granted port made
# the removal die in its second half, leaving the removed uid's accepts live in
# `50-services.conf`. A removal that half-completes is worse than one that
# refuses.
#
# **What the rule is, and where it is.** A manifest that provides the `db` kind
# declares a `state:` or a `bulk:` volume, or it is refused, exit 2, one line —
# and it is refused where the declaration is ACCEPTED: `weedr service ingest`,
# `weedr service add`, and `loom check`. A document guarden already holds stays
# readable.
#
# machine: shared
# `guarden_prefix` stages the host; every staged manifest and staged unit
# source is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`. The refusal names a
# path in a *diagnostic* and never touches it.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
tree=$GUARDEN_PREFIX/var/lib/guarden/services

# **The installed service.** A `db` provider with no volume, already installed:
# its manifest sits in its own home, which is where guarden reads it back from
# when it manages the service. This is the operator's staging postgres, and the
# service the ticket is about.
seed "$registry/pg-staging.toml" \
    'service = "pg-staging"' 'workload = "pg"' 'project = "pg"' \
    'environment = "staging"' 'uid = 1099' 'created = "2026-10-19T09:00:00Z"' \
    '[provides]' 'kinds = [ "db" ]'
seed "$tree/pg-staging/home/.guarden/service.yml" \
    'project: pg' 'units: .guarden/quadlet/' 'provides:' '  - db'

# **`weedr secret list` reads the manifest** — the gate's `schema_for` reads the
# service's own copy of it — and it is a verb that answers a question about a
# service guarden ALREADY HAS. It must answer. The refusal of a repository's
# declaration must not reach a service that is already installed.
run weedr secret list pg-staging
assert_exit 0

# **The gate is the same read** (`weedr service gate` evaluates the schema of an
# installed service), and so is the start that re-checks it.
run weedr service gate pg-staging
assert_exit 0
assert_not_rejected

# **The service's own manifest is still a valid manifest**, and the render path
# reads it: `loom check` on the installed service's own tree must not refuse it
# either. The tree is `0700` to the service and the renderer is `guarden`, so
# the copy is made with the same modes the mutator gives it.
installed=$tree/pg-staging/home
mkdir -p "$installed/.guarden/quadlet"
seed "$installed/.guarden/quadlet/db.container" "[Container]" \
    "Image=docker.io/library/postgres:17"
run loom check "$installed"
assert_exit 0
assert_stderr_empty

# **`weedr service add --from <service>` is an acceptance too, and it is the
# one the path cannot say.** The source's manifest is a HELD document — it
# lives in the source service's home, under the installed services' tree — and
# `add` copies it into a NEW service as that service's declaration. So a `db`
# provider with no volume, copied this way, is a new service with ephemeral
# data, which is the whole of what the rule is for. The path says "held" and
# the caller says "declaration", and only the caller knows which it is doing.
#
# The source is installed first, so it must itself be a `db` provider with no
# volume — which is the operator's staging postgres, installed before this
# rule existed. Its manifest is then copied.
run weedr service add pg-production --from pg-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no volume"
# Nothing was created: the refusal came before the identity, so the new service
# has no user, no tree and no registry entry.
assert_file_missing "$registry/pg-production.toml"
assert_file_missing "$tree/pg-production"

# **The staged copy of a held document is a held document too.** The renderer
# cannot enter a service's `0700` home, so the mutator stages the tree under
# `render-source/<service>/` and hands THAT to `loom` (ADR-0012, ticket 301).
# The staged copy is the same document under another name, so the rule must not
# fire on it either — or every re-render of an installed service would fail.
staged=$GUARDEN_PREFIX/var/lib/guarden/render-source/pg-staging/pid-1
mkdir -p "$staged/.guarden/quadlet"
seed "$staged/.guarden/service.yml" "project: pg" "units: .guarden/quadlet/" \
    "provides:" "  - db"
seed "$staged/.guarden/quadlet/db.container" "[Container]" \
    "Image=docker.io/library/postgres:17"
run loom check "$staged"
assert_exit 0
assert_stderr_empty

# **And the guided creator's staged tree is a DECLARATION, not a held
# document.** The creator stages the operator's own tree under
# `render-source/guided/` so the renderer can read it, and a `db` service
# created that way with no volume is exactly the declaration the rule is for.
# The two live under the same parent and are told apart by the directory under
# it, and this is the assertion that they are.
guided=$GUARDEN_PREFIX/var/lib/guarden/render-source/guided/pid-2
mkdir -p "$guided/.guarden/quadlet"
seed "$guided/.guarden/service.yml" "project: guided" "units: .guarden/quadlet/" \
    "provides:" "  - db"
seed "$guided/.guarden/quadlet/db.container" "[Container]" \
    "Image=docker.io/library/postgres:17"
run loom check "$guided"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no volume"
