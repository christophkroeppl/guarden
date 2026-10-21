#!/usr/bin/env bash
# A declared edge, end to end at the CLI seam (ticket 80, spec 5.3 steps 6 and 10,
# 7.4, 7.6).
#
# One `needs:` entry produces three things and each is asserted where it lands: a
# name the consumer resolves, a firewall rule that lets **that one uid** reach
# **that one publication**, and a credential of its own. What a service *binds* is
# not policed and nothing here pretends otherwise.
#
# **The publication is the provider's own allocation, copied into the consumer's
# edge.** It cannot be a second allocation: the provider's container binds one
# `PublishPort` and the consumer's `<AS>_PORT` has to name it, so two independent
# numbers are two ports where one is expected. That equality is asserted directly,
# because nothing else on the box would notice it being wrong.
#
# Real host, real uids, a real `useradd` and a real `systemd-creds`. The credential
# half cannot be tested against a staged host: the blob is encrypted under this
# machine's host key, and a staged tree would be asserting about a key nobody holds.
# `GUARDEN_PREFIX=/`, as `t30-create`, `t50-route` and `t60-secrets` do.
#
# The reach criterion — a member connects and a non-member does not, with and
# without the rule — needs two live containers and is a golden-VM criterion, which
# the ticket says itself. What is assertable here is the rendered set.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

registry=/var/lib/guarden/registry
creds=/etc/guarden/creds
conf=/etc/guarden/firewall/50-services.conf

dialed_publication() {
    awk -v want="$2" '$0 == "port = " want {seen=1}
         seen && /^publications = /{gsub(/[][]/,"",$3); print $3; exit}' "$1"
}

purge() {
    local failed=0 service attempt path_was_active=0
    local -a paths
    # **The credential trigger is held while the trees are removed**, for the
    # reason `t315-envfile-ref.sh` states in full: deleting a creds blob starts
    # its oneshot, which runs `podman secret create` as every service that still
    # has one, inside that service's own `home` — the tree this loop is deleting.
    # The unit is put back only if this purge found it running.
    if systemctl is-active --quiet guarden-creds.path; then
        path_was_active=1
    fi
    systemctl stop guarden-creds.path guarden-creds-boot.service >/dev/null 2>&1 || :
    remove_snapper_configs "$@" || failed=1
    for service in "$@"; do
        paths=(
            "/var/lib/guarden/services/$service"
            "/etc/guarden/services/$service"
            "$creds/$service"
            "$registry/$service.toml"
        )
        attempt=0
        until rm -rf "${paths[@]}"; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 3 ]; then
                failed=1
                break
            fi
            sleep 1
        done
        userdel "$service" >/dev/null 2>&1 || :
    done
    if [ "$path_was_active" = 1 ]; then
        systemctl start guarden-creds.path >/dev/null 2>&1 || :
    fi
    # A teardown that cannot remove the tree is a failure, not a line in the
    # log; `t315-envfile-ref.sh` has the long form of that decision too.
    assert_no_snapper_configs "$@" || failed=1
    [ "$failed" = 0 ] || { _fail "purge could not remove every path of: $*"; return 1; }
}

cleanup() {
    # **Every name this file creates, not most of them.** A teardown that leaves
    # a service behind leaves its EDGES behind too, and an edge is a uid-matched
    # accept rule: a second run of this file on the same machine then reads a
    # firewall line the first run's `unmapped-staging` put there and fails an
    # assertion whose subject is not the leftover (measured 2026-10-21, ticket
    # 329's class of defect). The list is the suite's own inventory.
    #
    # The conf goes whatever the purge did, so the removal is done before the
    # status is raised; `t315-envfile-ref.sh` carries the long form.
    local rc=0
    purge pgprov-staging pgdual-staging needful-staging needy-staging multidb-staging \
        twin-staging ghost-staging redis-staging nowhere-staging \
        unpublished-staging unmapped-staging postgres-staging needful-production \
        postgres-production || rc=1
    rm -f "$conf"
    return "$rc"
}
trap cleanup EXIT

cleanup
# `host.admin_user` names the uid the whole OUTPUT accept set admits and the
# firewall refuses to render without it. `soil install` records the invoking user
# there, so the account is this fixture's own claim and it has to exist.
ensure_accounts
stage_config guarden-measured.toml
stage_poke pgprov 9f2c1ab
stage_poke pgdual 9f2c1ab
stage_poke needful 9f2c1ab
stage_poke needy 9f2c1ab
stage_poke unpublished 9f2c1ab

# `soil install --apply` is a precondition, not the subject: ingest renders through
# `loom`, and the programs are not on this host until install has run. The note
# below about the firewall unit is still true — install installs the unit but this
# file does not converge the rendered set, which is t20-firewall's business.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0

# The provider first: it is what a consumer dials, and a consumer whose provider does
# not exist is a separate case, asserted below.
run weedr service ingest pgprov-staging --from poke pgprov@9f2c1ab
assert_exit 0
# **No assertion on stderr being empty here**, and the reason is the firewall
# rather than this edge: every mutating verb that changes the rendered set asks
# `guarden-firewall.service` to load it, and on a host where `soil install` has
# never run that unit is not installed and says so. `t20-firewall.sh` owns that
# phase; converging it here would make this file's subject the install.

db_pub=$(sed -n 's/^db = \([0-9]*\)$/\1/p' "$registry/pgprov-staging.toml")
vault_pub=$(sed -n 's/^vault = \([0-9]*\)$/\1/p' "$registry/pgprov-staging.toml")
[ -n "$db_pub" ] || _fail "the provider names a db container and no publication was allocated"
[ -n "$vault_pub" ] || _fail "the provider names a vault container and no publication was allocated"
[ "$db_pub" != "$vault_pub" ] || _fail "two containers of one service share one publication"
for number in "$db_pub" "$vault_pub"; do
    [ "$number" -ge 20000 ] && [ "$number" -le 32767 ] \
        || _fail "publication $number is outside ingress.publication_range"
done
# `provides:` is written by the mutator from the manifest and is the only copy a
# consumer can read, so it is what the kind check below is really reading.
assert_file_has "$registry/pgprov-staging.toml" 'kinds = ["db", "secret"]'

# A second provider whose two kinds share ONE port, so a consumer can hold two
# edges to it on the same port under different `as:` prefixes — the case the
# three-part key exists for.
run weedr service ingest pgdual-staging --from poke pgdual@9f2c1ab
assert_exit 0
pgdual_pub=$(sed -n 's/^db = \([0-9]*\)$/\1/p' "$registry/pgdual-staging.toml")
[ -n "$pgdual_pub" ] || _fail "pgdual-staging names a db container and no publication was allocated"
assert_file_has "$registry/pgdual-staging.toml" 'kinds = ["db", "secret"]'

# The consumer: two edges to one provider, `auth: database` and `auth: secret`.
run weedr service ingest needful-staging --from poke needful@9f2c1ab
assert_exit 0
# The database edge's role is the one thing that needs a live container, and there
# is none on this host, so the mutator says which container and carries on. The
# credential is planted regardless: the role is created by the next deploy, and the
# password it is given is the one already in the consumer's store.
assert_stderr_has "pgprov-staging-db"
assert_stderr_has "not running"
needful_uid=$(getent passwd needful-staging | cut -d: -f3)
provider_uid=$(getent passwd pgprov-staging | cut -d: -f3)
[ -n "$needful_uid" ] || _fail "the consumer was created and has no uid"
[ -n "$provider_uid" ] || _fail "the provider was created and has no uid"

# The edge's publication is the provider's own number, copied — not allocated again.
consumer_registry=$registry/needful-staging.toml
assert_file_has "$consumer_registry" '[edges."pgprov-staging:5432:db"]'
assert_file_has "$consumer_registry" '[edges."pgprov-staging:8200:secret"]'
assert_file_has "$consumer_registry" 'as = "db"'
assert_file_has "$consumer_registry" 'auth = "database"'
assert_file_has "$consumer_registry" 'port = 5432'
# `as:` is the provider KIND as well as the variable prefix, and the kinds are db
# and secret — so this edge asks for `secret` on the vault container's PORT. The two
# edges are told apart by port, which is what the registry keys them on.
assert_file_has "$consumer_registry" 'as = "secret"'
assert_file_has "$consumer_registry" 'auth = "secret"'
assert_file_has "$consumer_registry" 'port = 8200'
dialed=$(dialed_publication "$consumer_registry" 5432)
[ "$dialed" = "$db_pub" ] \
    || _fail "the 5432 edge dials $dialed and the provider binds $db_pub"
vault_dialed=$(dialed_publication "$consumer_registry" 8200)
[ "$vault_dialed" = "$vault_pub" ] \
    || _fail "the 8200 edge dials $vault_dialed and the provider binds $vault_pub"

# The credential. `auth: database` plants one blob in the **consumer's** store and
# nothing in the provider's (spec 5.3 step 10): the provider's half of a database
# edge is the role, not a copy of the password.
db_blob=$creds/needful-staging/DB_PASSWORD.cred
assert_file_exists "$db_blob"
assert_mode "$db_blob" 600
assert_mode "$creds/needful-staging" 700
assert_file_missing "$creds/pgprov-staging/DB_PASSWORD.cred"
# `auth: secret` is planted in **both**, because the provider has to be able to
# verify it, and the two hold the same value — that is what makes it verifiable.
assert_file_exists "$creds/needful-staging/SECRET_SECRET.cred"
assert_file_exists "$creds/pgprov-staging/SECRET_SECRET.cred"

# The blob decrypts under this machine's host key, which is the fact rather than a
# record of an intent: the value came back, so the key is one this host holds.
run systemd-creds decrypt --with-key=host "$db_blob"
assert_exit 0
db_value=$(cat "$GUARDEN_STDOUT")
assert_file_lacks "$db_blob" "$db_value"
run systemd-creds decrypt --with-key=host "$creds/needful-staging/SECRET_SECRET.cred"
assert_exit 0
vault_own=$(cat "$GUARDEN_STDOUT")
run systemd-creds decrypt --with-key=host "$creds/pgprov-staging/SECRET_SECRET.cred"
assert_exit 0
[ "$vault_own" = "$(cat "$GUARDEN_STDOUT")" ] \
    || _fail "a secret edge's two stores hold different values, so the provider cannot verify it"
# Distinct per edge, so no two edges of one service share a credential.
[ "$vault_own" != "$db_value" ] \
    || _fail "two edges of one service share a credential value"

# The firewall. The consumer's uid reaches the publications it declared, and the
# provider reaches its own so it can answer on its own listener.
assert_file_has "$conf" \
    "mod owner uid-owner $provider_uid daddr 127.0.0.1 proto tcp dport $db_pub jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $provider_uid daddr 127.0.0.1 proto tcp dport $vault_pub jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $needful_uid daddr 127.0.0.1 proto tcp dport $db_pub jump ACCEPT;"
assert_file_has "$conf" \
    "mod owner uid-owner $needful_uid daddr 127.0.0.1 proto tcp dport $vault_pub jump ACCEPT;"

# The loopback is closed by default: one deny, last, carrying no owner match, over
# the whole of loopback rather than 127.0.0.1 alone.
assert_file_has "$conf" "chain guarden-svc"
assert_file_has "$conf" "daddr 127.0.0.0/8 jump DROP;"
# Rule lines only, so the provenance comments cannot answer for it.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE '^[[:space:]]+daddr 127\.0\.0\.0/8 jump DROP;$' || true)" = 1 ] \
    || _fail "the loopback deny is not a single rule"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE 'uid-owner [0-9]+ daddr 127\.0\.0\.0/8' || true)" = 0 ] \
    || _fail "the loopback deny names a uid and is therefore not a default deny"
# Every destination is 127.0.0.1 and never ingress.alias: pasta maps the gateway onto
# the host's loopback in userspace before the kernel's packet path, so a rule naming
# the alias matches no packet in either direction.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner $provider_uid daddr 127\.0\.0\.1 proto tcp dport $db_pub jump ACCEPT;\$" || true)" = 1 ] \
    || _fail "no accept rule gives the provider the db publication on the loopback address"
assert_file_lacks "$conf" "10.0.2.2"
# **No interface match, per spec 7.6.** The spec was rewritten (00bdddd — `git
# log -S 'no interface match' -- docs/spec.md` finds it alone) to say
# the code has never emitted `-o lo` — the example was corrected rather than the
# render — so this asserts the reconciled state in the form that would have to
# change for the claim to become true: **the count of accept rules carrying an
# `-o lo` interface match is zero**. A render that grew one fails here. The block
# previously carried this as a KNOWN DIVERGENCE against the old spec text; there
# is no divergence left to name.
accepts=$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -c 'mod owner' || true)
with_iface=$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep 'mod owner' | grep -c -- '-o lo' || true)
[ "$accepts" -gt 0 ] || _fail "50-services.conf carries no owner-matched accept at all"
[ "$with_iface" = 0 ] \
    || _fail "50-services.conf has $with_iface owner-matched accepts carrying -o lo; spec 7.6 emits no interface match and the count must stay zero" 
# A poke granted nothing: `weedr service ingest` has no flag that can, so the
# provider's two requested ports stay pending and the file carries no DNAT at all.
assert_file_lacks "$conf" "DNAT"
run weedr port list --json
assert_exit 0
assert_stdout_has "5432"

# A second consumer of the same provider and the same port. It dials the **same**
# publication — that is the provider's binding, not the consumer's — and holds a
# credential of its own, so two consumers of one provider never share a value.
run weedr service ingest needy-staging --from poke needy@9f2c1ab
assert_exit 0
needy_uid=$(getent passwd needy-staging | cut -d: -f3)
needy_dialed=$(dialed_publication "$registry/needy-staging.toml" 5432)
[ "$needy_dialed" = "$db_pub" ] \
    || _fail "the second consumer dials $needy_dialed and the provider binds $db_pub"
run systemd-creds decrypt --with-key=host "$creds/needy-staging/DB_PASSWORD.cred"
assert_exit 0
[ "$GUARDEN_STDOUT" != "$db_value" ] \
    || _fail "two consumers of one provider share one database password"
# Three uids on the db publication now, and the second consumer never declared the
# vault edge, so its uid is **not** on the vault publication. A uid granted per
# provider rather than per publication would reach a port it never asked for, and
# this is the only assertion that tells the two designs apart.
assert_file_has "$conf" \
    "mod owner uid-owner $needy_uid daddr 127.0.0.1 proto tcp dport $db_pub jump ACCEPT;"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner [0-9]+ daddr 127\.0\.0\.1 proto tcp dport $db_pub jump ACCEPT;\$" || true)" = 3 ] \
    || _fail "the db publication's accept set is not the provider and its two consumers"
# Anchored on the whole match: a bare dport would match another publication.
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner $needy_uid daddr 127\.0\.0\.1 proto tcp dport $vault_pub jump ACCEPT;\$" || true)" = 0 ] \
    || _fail "the vault publication's accept set gained a consumer that declared no such edge"
[ "$(grep -vE '^[[:space:]]*(#|$)' "$conf" \
    | grep -cE "^[[:space:]]+mod owner uid-owner [0-9]+ daddr 127\.0\.0\.1 proto tcp dport $vault_pub jump ACCEPT;\$" || true)" = 2 ] \
    || _fail "the vault publication's accept set gained a consumer that declared no such edge"

# The rendered consumer. `AddHost=` into **every** unit, the two generated variables
# per edge, and a `Secret=` request naming the credential that was planted. The name
# is the provider's own service name: no suffix, no alias, no name map.
home=/var/lib/guarden/services/needful-staging/home
render=$GUARDEN_FIXTURES/render
run loom render "$home" --service needful-staging --out "$render"
assert_exit 0
for unit in web worker; do
    assert_file_has "$render/units/$unit.container" "AddHost=pgprov-staging:10.0.2.2"
done
assert_file_has "$render/units/guarden.env" "DB_HOST=pgprov-staging"
assert_file_has "$render/units/guarden.env" "DB_PORT=$db_pub"
assert_file_has "$render/units/guarden.env" "SECRET_HOST=pgprov-staging"
assert_file_has "$render/units/guarden.env" "SECRET_PORT=$vault_pub"
assert_file_has "$render/units/web.container" "Secret=DB_PASSWORD,type=mount"
assert_file_has "$render/units/web.container" "Secret=SECRET_SECRET,type=mount"
# The credential arrives as a request and never as a value, and the renderer's
# `LoadCredentialEncrypted=` would be a unit its own user manager cannot start.
assert_file_lacks "$render/units/web.container" "$db_value"
assert_file_lacks "$render/units/web.container" "$vault_own"
assert_file_lacks "$render/units/web.container" "LoadCredentialEncrypted="
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/hosts"
# A down provider must not stop its consumers: the edges are `Wants=`, never
# `Requires=` (spec 6.10, ADR-0011).
assert_file_has "$render/system/guarden-order.target" "Wants=pgprov-staging.target"
assert_file_lacks "$render/system/guarden-order.target" "Requires="

# An edge on a port the provider names no container for. There is no bind, so there
# is no publication to dial, and the render — which runs in the same ingest — refuses
# the consumer's units. So the mutator refuses the edge before identity: no user, no
# home, no volume and no registry record, and the one line names the port, the
# provider and the consumer (ticket 289).
run weedr service ingest unpublished-staging --from poke unpublished@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "9999"
assert_stderr_has "pgprov-staging"
assert_stderr_has "unpublished-staging"
assert_no_passwd unpublished-staging
assert_file_missing "$registry/unpublished-staging.toml"
assert_file_missing "/var/lib/guarden/services/unpublished-staging"

# An edge to a service this host has never heard of. A provider has to exist before
# its consumer: the edge dials the provider's own allocated publication, the render
# refuses an edge it cannot dial, and the ingest renders the consumer in the same
# command — so the mutator refuses the edge before identity and nothing of the
# consumer is created (ticket 289). A poke creates services in dependency order.
nowhere=$GUARDEN_PREFIX/var/lib/guarden/staging/nowhere/9f2c1ab
mkdir -p "$nowhere/.guarden/quadlet"
seed "$nowhere/.guarden/service.yml" "project: nowhere" "units: .guarden/quadlet/" \
    "needs:" "  - service: absent-staging" "    as: db" "    port: 5432" \
    "    auth: database"
seed "$nowhere/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest nowhere-staging --from poke nowhere@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "absent-staging"
assert_stderr_has "nowhere-staging"
assert_stderr_has "no registry entry"
assert_no_passwd nowhere-staging
assert_file_missing "$registry/nowhere-staging.toml"
assert_file_missing "/var/lib/guarden/services/nowhere-staging"

# A provider that exists and does not offer the kind. Both services and both kinds
# are named, because "the edge is wrong" is not an answer a person can act on, and
# the answer came from the host so it is exit 1 rather than 2 (spec 1.2).
seed "$registry/redis-staging.toml" \
    'service = "redis-staging"' 'workload = "redis"' 'project = "redis"' \
    'environment = "staging"' 'uid = 1096' 'created = "2026-10-03T09:00:00Z"' \
    '[provides]' 'kinds = [ "cache" ]'
ghost=$GUARDEN_PREFIX/var/lib/guarden/staging/ghost/9f2c1ab
mkdir -p "$ghost/.guarden/quadlet"
seed "$ghost/.guarden/service.yml" "project: ghost" "units: .guarden/quadlet/" \
    "needs:" "  - service: redis-staging" "    as: db" "    port: 6379" \
    "    auth: database"
seed "$ghost/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest ghost-staging --from poke ghost@9f2c1ab
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "redis-staging"
assert_stderr_has "ghost-staging"
assert_stderr_has "db"
assert_stderr_has "cache"
# A refused edge installs nothing at all. **`edges.check` runs before identity**, so
# there is no system user either: a refusal discovered at the end of the mutator's
# ordering would leave a user, a home and subvolumes behind for a service that is in
# no registry, and the next deploy would then find a half-built service it did not
# create.
assert_no_passwd ghost-staging
assert_file_missing "$registry/ghost-staging.toml"
assert_file_missing "/var/lib/guarden/services/ghost-staging"
assert_file_missing "$creds/ghost-staging/DB_PASSWORD.cred"

# And the credential the database edge planted is still there after everything
# above, encrypted and unreadable at rest.
assert_file_exists "$creds/needful-staging/DB_PASSWORD.cred"
assert_mode "$creds/needful-staging/DB_PASSWORD.cred" 600

# ---------------------------------------------------------------------------
# A multi-database edge: `databases:` on one needs entry
# ---------------------------------------------------------------------------
#
# A second edge to the same provider and the same port is refused by the
# provider's own kind list — `as:` must name a kind, and `db` is already
# used — so a consumer that needs several databases has exactly one way to
# say it: a list on one edge. That is the shape asserted here, in the three
# places the list lands: the registry record, the rendered environment, and
# the one credential the edge mints.


stage_poke multidb 9f2c1ab
run weedr service ingest multidb-staging --from poke multidb@9f2c1ab
assert_exit 0
assert_file_has "$registry/multidb-staging.toml" 'databases = ["odoo", "btcpay"]'

# The rendered environment names each database's own role. The role and the
# database are `{provider.service}-{db_name}`, so the consumer addresses them
# by name and never by position.
multidb_home=/var/lib/guarden/services/multidb-staging/home
multidb_render=$GUARDEN_FIXTURES/multidb-render
run loom render "$multidb_home" --service multidb-staging --out "$multidb_render"
assert_exit 0
assert_file_has "$multidb_render/units/guarden.env" "DB_ODOO_HOST=pgprov-staging"
assert_file_has "$multidb_render/units/guarden.env" "DB_ODOO_PORT=$db_pub"
assert_file_has "$multidb_render/units/guarden.env" "DB_ODOO_USER=pgprov-staging-odoo"
assert_file_has "$multidb_render/units/guarden.env" "DB_BTCPAY_HOST=pgprov-staging"
assert_file_has "$multidb_render/units/guarden.env" "DB_BTCPAY_USER=pgprov-staging-btcpay"
assert_file_has "$multidb_render/units/web.container" "Secret=DB_PASSWORD,type=mount"

# One password for the edge: the two databases share it, which is what the
# naming in provision() says and the trade-off the fixture's own comment names.
assert_file_exists "$creds/multidb-staging/DB_PASSWORD.cred"
assert_mode "$creds/multidb-staging/DB_PASSWORD.cred" 600

# The consumer is granted on the publication once, not once per database: the
# databases live in the provider's container, so the reach rule is unchanged.
multidb_uid=$(getent passwd multidb-staging | cut -d: -f3)
assert_file_has "$conf" \
    "mod owner uid-owner $multidb_uid daddr 127.0.0.1 proto tcp dport $db_pub jump ACCEPT;"






stage_poke twin 9f2c1ab
run weedr service ingest twin-staging --from poke twin@9f2c1ab
assert_exit 0
twin_registry=$registry/twin-staging.toml
# Both edges recorded under their own three-part keys — one provider, one port
assert_file_has "$twin_registry" '[edges."pgdual-staging:5432:db"]'
assert_file_has "$twin_registry" '[edges."pgdual-staging:5432:secret"]'
# Each edge carries its own kind and credential
assert_file_has "$twin_registry" 'as = "db"'
assert_file_has "$twin_registry" 'as = "secret"'
assert_file_has "$twin_registry" 'auth = "database"'
assert_file_has "$twin_registry" 'auth = "secret"'
# Both dial the same provider publication
twin_db_dialed=$(dialed_publication "$twin_registry" 5432)
[ "$twin_db_dialed" = "$pgdual_pub" ] \
    || _fail "the twin's db edge dials $twin_db_dialed and the provider binds $pgdual_pub"
# Each edge gets its own credential blob
assert_file_exists "$creds/twin-staging/DB_PASSWORD.cred"
assert_file_exists "$creds/twin-staging/SECRET_SECRET.cred"
assert_mode "$creds/twin-staging/DB_PASSWORD.cred" 600
assert_mode "$creds/twin-staging/SECRET_SECRET.cred" 600
# The two credentials are distinct
run systemd-creds decrypt --with-key=host "$creds/twin-staging/DB_PASSWORD.cred"
assert_exit 0
twin_db_value=$(cat "$GUARDEN_STDOUT")
run systemd-creds decrypt --with-key=host "$creds/twin-staging/SECRET_SECRET.cred"
assert_exit 0
twin_secret_value=$(cat "$GUARDEN_STDOUT")
[ "$twin_db_value" != "$twin_secret_value" ] \
    || _fail "two edges on one provider+port share a credential value"
# The render succeeds — both edges resolve to the same publication
run loom render /var/lib/guarden/services/twin-staging/home \
    --service twin-staging --out "$GUARDEN_FIXTURES/twin-render"
assert_exit 0
assert_file_has "$GUARDEN_FIXTURES/twin-render/units/guarden.env" "DB_PORT=$pgdual_pub"
assert_file_has "$GUARDEN_FIXTURES/twin-render/units/guarden.env" "SECRET_PORT=$pgdual_pub"
# Both edges' credentials are requested in the rendered unit
assert_file_has "$GUARDEN_FIXTURES/twin-render/units/web.container" "Secret=DB_PASSWORD,type=mount"
assert_file_has "$GUARDEN_FIXTURES/twin-render/units/web.container" "Secret=SECRET_SECRET,type=mount"
# The twin's uid appears on the db publication (provider + needful + needy + twin = 4)
twin_uid=$(getent passwd twin-staging | cut -d: -f3)
assert_file_has "$conf" \
    "mod owner uid-owner $twin_uid daddr 127.0.0.1 proto tcp dport $pgdual_pub jump ACCEPT;"

                                                                             
                                             
                                                                             
 
                                                                              
                                                                        
                                                                           
           

                                                                              
stage_config guarden-providers.toml
stage_poke postgres 9f2c1ab
stage_poke needful-providers 9f2c1ab
run weedr service ingest postgres-staging --from poke postgres@9f2c1ab
assert_exit 0
run weedr service ingest needful-staging --from poke needful-providers@9f2c1ab
assert_exit 0

# The edge is keyed by the CONCRETE name, not the logical one.
assert_file_has "$registry/needful-staging.toml" '[edges."postgres-staging:5432:db"]'

# The rendered host is the concrete name.
needful_home=/var/lib/guarden/services/needful-staging/home
needful_render=$GUARDEN_FIXTURES/needful-providers-render
run loom render "$needful_home" --service needful-staging --out "$needful_render"
assert_exit 0
assert_file_has "$needful_render/units/guarden.env" "DB_HOST=postgres-staging"
assert_file_has "$needful_render/units/web.container" "AddHost=postgres-staging:10.0.2.2"
assert_file_has "$needful_render/system/guarden-order.target" "Wants=postgres-staging.target"

# The same logical name in production resolves to the concrete production name.
run weedr service ingest postgres-production --from poke postgres@9f2c1ab
assert_exit 0
run weedr service ingest needful-production --from poke needful-providers@9f2c1ab
assert_exit 0

prod_home=/var/lib/guarden/services/needful-production/home
prod_render=$GUARDEN_FIXTURES/needful-providers-prod-render
run loom render "$prod_home" --service needful-production --out "$prod_render"
assert_exit 0
assert_file_has "$prod_render/units/guarden.env" "DB_HOST=postgres-production"
assert_file_has "$prod_render/units/web.container" "AddHost=postgres-production:10.0.2.2"
assert_file_has "$prod_render/system/guarden-order.target" "Wants=postgres-production.target"

# An unmapped name passes through unchanged — a manifest naming a full
# service name directly keeps working. The key is that full name exactly as
# the manifest wrote it, and it names a provider that exists: a name resolving
# to the declaring service itself is a self-edge, which spec 4 refuses.
stage_poke unmapped 9f2c1ab
run weedr service ingest unmapped-staging --from poke unmapped@9f2c1ab
assert_exit 0
assert_file_has "$registry/unmapped-staging.toml" '[edges."pgprov-staging:5432:db"]'

# ---------------------------------------------------------------------------
# The teardown takes the name with the tree
# ---------------------------------------------------------------------------
#
# **A service name is a runtime resource, and two suites spelling it the same
# way is a channel between them.** This file's provider used to be
# `t315-envfile-ref`'s too, so a `home` that suite's teardown could not remove
# was the state this file started from, and the failure then surfaced here as an
# assertion about something else (ticket 329). `t315` now names its own
# provider, and this is the other half: what the teardown promises is asserted,
# `home` by name.
#
# `.../home` is the path the ticket's own measurement named, and it is the
# directory that holds podman's store; the whole tree is asserted as well,
# because a surviving `state/pgdata` subvolume is the same defect one layer
# down. This is the last thing the file does: every edge above needs the
# provider, so nothing after it can.
purge pgprov-staging
assert_file_missing /var/lib/guarden/services/pgprov-staging
assert_file_missing /var/lib/guarden/services/pgprov-staging/home
assert_file_missing /etc/guarden/services/pgprov-staging
assert_file_missing "$registry/pgprov-staging.toml"
