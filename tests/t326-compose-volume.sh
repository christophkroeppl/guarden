#!/usr/bin/env bash
# A `db` provider that declares no volume is refused (ticket 326, spec 4).
#
# **What was false.** A Compose project that declared no volume at all deployed
# fine, started fine, and lost its data. The container mounted nothing, so
# podman created an ANONYMOUS volume for the path the IMAGE declares
# (`/var/lib/postgresql/data` for the postgres image) and podman's garbage
# collector removed that volume when the container was recreated. The operator
# measured 96 MB of database gone after a re-ingest, and the volume's identity
# changed from `2a4c367f…` to `ee1247dc…` between two runs.
#
# **What the rule is, and what it is NOT.** The rule is on the DECLARATION: a
# manifest that provides the `db` kind declares a `state:` or a `bulk:` volume
# or it is refused, exit 2, one line.
#
# It is NOT "the compose names a data path", and the difference is the whole
# shape of the ticket. The compose that lost the data named NO path at all —
# the path was the image's own `VOLUME`. Guarden cannot read an image: the
# renderer is unprivileged and pure (spec 6.3) and the image is not pulled
# until a start. So a rule keyed on a named path could never fire on the case
# that lost the data, and a rule keyed on the declaration fires on exactly that
# case. The spec says so in §4, with the limits stated.
#
# `db` and not every kind: guarden writes INTO a `db` provider itself (the
# role and the database a consumer's edge asks for are created in the
# provider's own engine), so a `db` provider provably holds data guarden
# made. The other kinds are reachability — an endpoint with no data of its own
# — and a service that keeps files declares a volume for them whatever it
# provides. The operator's own real bitcoind provides `bitcoin` with no volume,
# and that is correct for guarden.
#
# machine: shared
# `guarden_prefix` stages the host; every staged manifest and staged unit
# source is under `$GUARDEN_PREFIX` or `$GUARDEN_FIXTURES`. The refusal names a
# path in a *diagnostic* and never touches it.
# `install_pinned_converter` reaches real apt and the machine's apt timers; see
# the note in t40-manifest.sh, which is the same leak in the same suites. It is
# needed for the half of this suite that renders a Compose source, because the
# converter is what turns one into units.

. "$(dirname "$0")/lib.sh"

guarden_prefix
stage_config guarden-measured.toml

# The last block of this file renders a Compose source, and the converter is
# what turns one into units — installed by the phase that owns the fetch, at
# the pinned path, and a program rather than a file that merely exists.
install_pinned_converter

project=$GUARDEN_FIXTURES/project

# The operator's own shape, read from the deployment repository: a `db`
# provider, a compose that mounts nothing, and no volume declared anywhere.
# This is the case that lost 96 MB, and it is refused with one line.
seed "$project/.guarden/service.yml" "project: pg" "units: compose.yaml" \
    "provides:" "  - db" "ports:" "  - container: postgres" "    port: 5432"
seed "$project/compose.yaml" "services:" "  postgres:" \
    "    image: docker.io/library/postgres:17"
run loom check "$project"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "db"
assert_stderr_has "no volume"
assert_stderr_has "anonymous volume"
# The line says what to do, and it says the thing that is easy to get wrong:
# the new volume starts EMPTY, so the data does not follow the declaration.
assert_stderr_has "state:"
assert_stderr_has "bulk:"
assert_stderr_has "EMPTY"
# The manifest is named, because a diagnostic that does not say which file is
# a diagnostic that sends the reader to the wrong place.
assert_stderr_has "service.yml"

# The same refusal on the hand-written quadlet path, because the rule is on
# the manifest and not on the vocabulary the unit source is written in.
quadlet=$GUARDEN_FIXTURES/quadlet
seed "$quadlet/.guarden/service.yml" "project: pg" "units: .guarden/quadlet/" \
    "provides:" "  - db"
seed "$quadlet/.guarden/quadlet/db.container" "[Container]" \
    "Image=docker.io/library/postgres:17"
run loom check "$quadlet"
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no volume"

# A `state:` volume satisfies the rule, and the render carries the volume's own
# path — the whole point of the declaration is that the data lands in a
# subvolume podman's collector never touches.
seed "$project/.guarden/service.yml" "project: pg" "units: compose.yaml" \
    "provides:" "  - db" "state:" "  - pgdata" "ports:" \
    "  - container: postgres" "    port: 5432"
seed "$project/compose.yaml" "services:" "  postgres:" \
    "    image: docker.io/library/postgres:17" "    volumes:" \
    "      - pgdata:/var/lib/postgresql/data"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# A `bulk:` volume satisfies it too: it is never snapshotted, but it is a
# subvolume under the service's own tree, and the collector does not touch it.
# What the rule protects is the data being GONE.
seed "$project/.guarden/service.yml" "project: pg" "units: compose.yaml" \
    "provides:" "  - db" "bulk:" "  - pgdata" "ports:" \
    "  - container: postgres" "    port: 5432"
run loom check "$project"
assert_exit 0
assert_stderr_empty

# **A service that provides no `db` kind is not refused, and this is the
# counter-example that keeps the rule honest.** A stateless service has no
# data to lose, and refusing it would be wrong rather than strict: the
# modules' own services (traefik, homepage, authelia, cloudflared) declare no
# volume at all and must keep rendering. So does a reachability provider: the
# operator's own bitcoind provides `bitcoin` and declares no volume, which is
# correct for guarden — guarden writes nothing into it.
#
# **The compose file is re-seeded for each of these**, because the file above
# still mounts the `pgdata` volume the previous manifest declared. A manifest
# that declares no volume beside a compose that mounts one is refused by the
# OTHER rule — the undeclared named volume — and a suite that reused the file
# would be asserting a pass for a refusal it never provoked.
seed "$project/compose.yaml" "services:" "  web:" \
    "    image: docker.io/library/nginx:1.27"
seed "$project/.guarden/service.yml" "project: web" "units: compose.yaml" \
    "ports:" "  - container: web" "    port: 8080"
run loom check "$project"
assert_exit 0
assert_stderr_empty

seed "$project/compose.yaml" "services:" "  node:" \
    "    image: docker.io/bitcoin/bitcoin:27.0"
seed "$project/.guarden/service.yml" "project: node" "units: compose.yaml" \
    "provides:" "  - bitcoin" "ports:" "  - container: node" "    port: 8332"
run loom check "$project"
assert_exit 0
assert_stderr_empty
