#!/usr/bin/env bash
# ticket 284 — a `database` edge creates its role and its databases, and one
# consumer owns several databases under ONE role.
#
# Two claims, and neither can be measured on a host without an engine:
#
#   * **step 10 actually happens.** On the deploy VM that found this ticket,
#     `pg_roles` held no role an edge had created and `pg_database` held no
#     database one had either: the ingest ran before the provider's container
#     was up, warned, planted the credential, and nothing ever re-attempted it —
#     the redeploy that would have answered `converged` and installed nothing.
#     So the ingest below runs with the provider DOWN (asserting the warning and
#     the credential), the provider is then started, and the consumer's own
#     `weedr service start` is what creates the role. A host that only ever
#     ingests is exactly the host that reported every edge decorative.
#   * **one role, several databases.** `databases: [odoo, btcpay]` gives the
#     consumer one role named after itself and two databases named
#     `<consumer>-<name>`, and `databases:` absent gives it one database named
#     after itself. The role is the authority and the databases are its objects,
#     which is what makes the edge the unit of authorization — so a role per
#     database is asserted ABSENT, and the login below is made with the single
#     credential the edge minted.
#
# **The engines are real**: postgres:17 in the provider's own rootless store,
# started by the provider's own unit through the mutator, and every assertion is
# a query against it or a login to it. A stand-in would be asserting the SQL
# this file wrote rather than the SQL the program issues, which is the whole
# question. The provider and the two consumers are declared inline, the way
# `t80-edges` declares `ghost` and `nowhere`, because what this file needs is a
# unit source of its own and not a fixture every other suite would then share.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
creds=/etc/guarden/creds
staging=$GUARDEN_PREFIX/var/lib/guarden/staging
superpass=guarden-superuser-probe

ensure_accounts
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# One shape for "podman as this service user", the way `t350-keepid.sh` states
# it: the suite's own 0700 tree is scrubbed out of the environment, and the
# XDG_* scrub is what keeps podman's store inside the service's own home.
podman_as() {
    local service=$1 home uid
    shift
    home=/var/lib/guarden/services/$service/home
    uid=$(id -u "$service")
    run_in "$home" setpriv --reuid="$service" --regid="$service" --clear-groups \
        env -u OLDPWD HOME="$home" PWD="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# answer_as <service> <podman args...>: what podman printed, as a value.
# `run_in` captures into the suite's step files, so a `$(podman_as …)` would
# capture the harness's silence rather than the tool's answer.
answer_as() {
    local service=$1
    shift
    podman_as "$service" "$@"
    cat "$GUARDEN_STDOUT" "$GUARDEN_STDERR"
}

# sql <statement>: one `-At` query against the provider's engine, as its own
# superuser over the container's local socket — the host's way in, and not the
# credential under test.
sql() {
    answer_as pgbox-staging exec pgbox-staging-db psql -U postgres -Atc "$1"
}

# A provider of the `db` kind with one container. `POSTGRES_PASSWORD` is the
# image's own requirement, not guarden's: `docker.io/library/postgres` refuses to
# initialise a volume with no superuser password, and setting one is also what
# makes pg_hba use scram on the host path — so the login at the end of each phase
# is a real password check and not a trust socket.
pgbox=$staging/pgbox/9f2c1ab
mkdir -p "$pgbox/.guarden/quadlet"
seed "$pgbox/.guarden/service.yml" \
    "project: pgbox" \
    "units: .guarden/quadlet/" \
    "provides:" \
    "  - db" \
    "state:" \
    "  - pgdata" \
    "ports:" \
    "  - container: db" \
    "    port: 5432"
seed "$pgbox/.guarden/quadlet/db.container" \
    "[Container]" \
    "Image=docker.io/library/postgres:17" \
    "Volume=pgdata:/var/lib/postgresql/data" \
    "Environment=PGDATA=/var/lib/postgresql/data/pgdata" \
    "Environment=POSTGRES_PASSWORD=$superpass"

# The consumer that names two databases, and the one that names none.
appbox=$staging/appbox/9f2c1ab
mkdir -p "$appbox/.guarden/quadlet"
seed "$appbox/.guarden/service.yml" \
    "project: appbox" \
    "units: .guarden/quadlet/" \
    "needs:" \
    "  - service: pgbox-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: database" \
    "    databases:" \
    "      - odoo" \
    "      - btcpay"
seed "$appbox/.guarden/quadlet/web.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"

solo=$staging/solo/9f2c1ab
mkdir -p "$solo/.guarden/quadlet"
seed "$solo/.guarden/service.yml" \
    "project: solo" \
    "units: .guarden/quadlet/" \
    "needs:" \
    "  - service: pgbox-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: database"
seed "$solo/.guarden/quadlet/web.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"

# ---------------------------------------------------------------------------
# The provider exists and is NOT running: the state every poke leaves at ingest
# ---------------------------------------------------------------------------

run weedr service ingest pgbox-staging --from poke pgbox@9f2c1ab
assert_exit 0
assert_file_exists "$registry/pgbox-staging.toml"

run weedr service ingest appbox-staging --from poke appbox@9f2c1ab
assert_exit 0
# The warning names the container and the provider, because that is the state the
# operator has to change — and it is the one diagnostic the old code emitted
# before never trying again.
assert_stderr_has "the container pgbox-staging-db of pgbox-staging is not running"
# The credential is planted either way, which is what makes the missing role a
# *decorative* credential rather than an absent one.
assert_file_exists "$creds/appbox-staging/DB_PASSWORD.cred"
assert_mode "$creds/appbox-staging/DB_PASSWORD.cred" 600
# The edge is recorded with the database names the manifest declared, so the
# registry and the render agree about them before anything exists in the engine.
assert_file_has "$registry/appbox-staging.toml" 'databases = ["odoo", "btcpay"]'

# The provider comes up. The start is what pulls the image (the ADR-0019 probe
# needs it) and what the unit generator turns into a running container, so the
# wait is for the ENGINE, not for the command: a postgres that has not finished
# initdb answers nothing, and `pg_isready` is the image's own question.
run weedr service start pgbox-staging
assert_exit 0
ready=no
for _ in $(seq 1 90); do
    podman_as pgbox-staging exec pgbox-staging-db pg_isready -q -U postgres
    if [ "$GUARDEN_EXIT" = 0 ]; then
        ready=yes
        break
    fi
    sleep 1
done
[ "$ready" = yes ] || _fail "the provider's postgres never answered pg_isready"
echo "MEASURE: the provider's engine is up: $(sql 'SHOW server_version_num')"

# **Before the consumer's start, the role does not exist** — the ticket's own
# measurement, and the state the ingest left behind. If this ever fails because
# the role IS there, the ingest has started provisioning out of band and the
# re-attempt below is proving nothing.
role_before=$(sql "SELECT rolname FROM pg_roles WHERE rolname = 'appbox-staging'")
[ -z "$role_before" ] \
    || _fail "the role 'appbox-staging' exists before the consumer's start, so the ingest provisioned it after all: '$role_before'"

# ---------------------------------------------------------------------------
# The start creates what the ingest could not: one role, its two databases
# ---------------------------------------------------------------------------

# The consumer's unit asks for `Secret=DB_PASSWORD`, so the value has to be in
# its own podman store before the start can reach the pods. The ingest planted
# the blob; putting it into the store is the materialiser's job, and the
# `.path` trigger that normally gets it there is asynchronous and is ticket
# 314's subject — not this file's. So it is run here, explicitly, because what
# this suite measures is the role in the provider.
run weedr secret materialise appbox-staging
assert_exit 0

run weedr service start appbox-staging
assert_exit 0

role=$(sql "SELECT rolname FROM pg_roles WHERE rolname = 'appbox-staging'")
[ "$role" = "appbox-staging" ] \
    || _fail "the consumer's role is '$role', not 'appbox-staging': the edge did not create it"

# **One role, and it is the consumer's.** A role per database is the shape this
# ticket replaced: it makes one authority into several names to revoke, and the
# names are not the consumer's.
perdb=$(sql "SELECT count(*) FROM pg_roles WHERE rolname IN ('appbox-staging-odoo', 'appbox-staging-btcpay')")
[ "$perdb" = 0 ] \
    || _fail "the edge created $perdb role(s) named after its databases, and the role is one per consumer"

# Two databases, named `<consumer>-<name>`, both owned by that one role.
owned=$(sql "SELECT string_agg(datname || ':' || pg_get_userbyid(datdba), ',' ORDER BY datname) FROM pg_database WHERE datname IN ('appbox-staging-odoo', 'appbox-staging-btcpay')")
[ "$owned" = "appbox-staging-btcpay:appbox-staging,appbox-staging-odoo:appbox-staging" ] \
    || _fail "the edge's databases are '$owned', not two databases owned by appbox-staging"

# The rendered environment names the role and both databases, and the names come
# from the same two functions the mutator created the objects with.
run loom render /var/lib/guarden/services/appbox-staging/home \
    --service appbox-staging --out "$GUARDEN_FIXTURES/appbox-render"
assert_exit 0
appbox_env=$GUARDEN_FIXTURES/appbox-render/units/guarden.env
assert_file_has "$appbox_env" "DB_HOST=pgbox-staging"
assert_file_has "$appbox_env" "DB_USER=appbox-staging"
assert_file_has "$appbox_env" "DB_ODOO_DATABASE=appbox-staging-odoo"
assert_file_has "$appbox_env" "DB_BTCPAY_DATABASE=appbox-staging-btcpay"
assert_file_lacks "$appbox_env" "DB_ODOO_USER"
assert_file_has "$GUARDEN_FIXTURES/appbox-render/units/web.container" "Secret=DB_PASSWORD,type=mount"

# **The credential the consumer holds is the role's password**, which is the
# claim a role that merely exists does not make. The login is over TCP, so the
# image's `host … scram-sha-256` rules apply and a wrong password fails here.
run systemd-creds decrypt --with-key=host "$creds/appbox-staging/DB_PASSWORD.cred"
assert_exit 0
appbox_pass=$(cat "$GUARDEN_STDOUT")
[ -n "$appbox_pass" ] || _fail "the consumer's credential decrypted to nothing"
for database in appbox-staging-odoo appbox-staging-btcpay; do
    who=$(answer_as pgbox-staging exec -e "PGPASSWORD=$appbox_pass" pgbox-staging-db \
        psql -h 127.0.0.1 -U appbox-staging -d "$database" -Atc \
        "SELECT current_user || '@' || current_database()")
    [ "$who" = "appbox-staging@$database" ] \
        || _fail "logging in to $database as the edge's role answered '$who'"
done

# ---------------------------------------------------------------------------
# No `databases:`: one database, named after the consumer
# ---------------------------------------------------------------------------

run weedr service ingest solo-staging --from poke solo@9f2c1ab
assert_exit 0
run weedr secret materialise solo-staging
assert_exit 0
run weedr service start solo-staging
assert_exit 0

solo_owned=$(sql "SELECT datname || ':' || pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'solo-staging'")
[ "$solo_owned" = "solo-staging:solo-staging" ] \
    || _fail "a consumer with no databases: got '$solo_owned', not one database named after it"
run loom render /var/lib/guarden/services/solo-staging/home \
    --service solo-staging --out "$GUARDEN_FIXTURES/solo-render"
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/solo-render/units/guarden.env" "DB_DATABASE=solo-staging"
assert_file_has "$GUARDEN_FIXTURES/solo-render/units/guarden.env" "DB_USER=solo-staging"

# ---------------------------------------------------------------------------
# A database of the edge's own name that somebody else owns is refused
# ---------------------------------------------------------------------------

# `taken-staging` is the database this consumer would own by default. Created
# here as the superuser, so the edge meets a database with its own name and
# another owner — the one case `CREATE DATABASE … WHERE NOT EXISTS` passes over
# in silence, and the one where taking it over would take another consumer's data.
sql "CREATE DATABASE \"taken-staging\" OWNER postgres" >/dev/null

taken=$staging/taken/9f2c1ab
mkdir -p "$taken/.guarden/quadlet"
seed "$taken/.guarden/service.yml" \
    "project: taken" \
    "units: .guarden/quadlet/" \
    "needs:" \
    "  - service: pgbox-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: database"
seed "$taken/.guarden/quadlet/web.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"
# The provider is up by now, so the ingest's own step 10 is what meets the
# database — and it is the INGEST that refuses, not the start.
run weedr service ingest taken-staging --from poke taken@9f2c1ab
assert_exit 1
assert_stderr_has "taken-staging"
assert_stderr_has "owner postgres"
assert_stderr_has "refuses it rather than taking it over"
# **The refusal changes nothing in the provider**: the database is still the
# other role's, and no role was created for the consumer. That is what the
# ownership check running BEFORE the DDL buys, and it is the difference between
# refusing a name and leaving a name behind.
still=$(sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'taken-staging'")
[ "$still" = "postgres" ] \
    || _fail "the refused database is owned by '$still', not postgres: the edge took it over"
leftover=$(sql "SELECT rolname FROM pg_roles WHERE rolname = 'taken-staging'")
[ -z "$leftover" ] \
    || _fail "the refused edge created the role '$leftover' anyway"

# ---------------------------------------------------------------------------
# `databases:` is a `database`-edge key, and its names are a closed set
# ---------------------------------------------------------------------------

# On an edge of another kind the list would be a declaration that creates
# nothing, which is the silent-drop class this repository refuses instead.
mute=$staging/mute/9f2c1ab
mkdir -p "$mute/.guarden/quadlet"
seed "$mute/.guarden/service.yml" \
    "project: mute" \
    "units: .guarden/quadlet/" \
    "needs:" \
    "  - service: pgbox-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: none" \
    "    databases:" \
    "      - odoo"
seed "$mute/.guarden/quadlet/web.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest mute-staging --from poke mute@9f2c1ab
assert_exit 2
assert_stderr_has "databases:"

# The same name twice in one list is one database asked for twice, and the
# second would be a no-op that reads like a grant.
twice=$staging/twice/9f2c1ab
mkdir -p "$twice/.guarden/quadlet"
seed "$twice/.guarden/service.yml" \
    "project: twice" \
    "units: .guarden/quadlet/" \
    "needs:" \
    "  - service: pgbox-staging" \
    "    as: db" \
    "    port: 5432" \
    "    auth: database" \
    "    databases:" \
    "      - odoo" \
    "      - odoo"
seed "$twice/.guarden/quadlet/web.container" \
    "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest twice-staging --from poke twice@9f2c1ab
assert_exit 2
assert_stderr_has "contains 'odoo' more than once"

echo "MEASURE: roles an edge created: $(sql "SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%'")"
echo "MEASURE: databases an edge created: $(sql "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE datname LIKE 'appbox-%' OR datname LIKE 'solo-%' OR datname LIKE 'taken-%'")"
