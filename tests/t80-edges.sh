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
conf=/etc/guarden/firewall/30-services.conf

dialed_publication() {
    awk -v want="$2" '$0 == "port = " want {seen=1}
         seen && /^publications = /{gsub(/[][]/,"",$3); print $3; exit}' "$1"
}

purge() {
    for service in "$@"; do
        rm -rf "/var/lib/guarden/services/$service" "/etc/guarden/services/$service" \
            "$creds/$service" "$registry/$service.toml"
        userdel "$service" >/dev/null 2>&1 || :
    done
}

cleanup() {
    purge pgprov-staging needful-staging needy-staging ghost-staging redis-staging \
        nowhere-staging
    rm -f "$conf"
}
trap cleanup EXIT

cleanup
getent group guarden >/dev/null 2>&1 || groupadd --system guarden
id -u guarden >/dev/null 2>&1 || useradd --system --no-create-home --gid guarden guarden
# `host.admin_user` names the uid the whole OUTPUT accept set admits and the
# firewall refuses to render without it. `soil install` records the invoking user
# there, so the account is this fixture's own claim and it has to exist.
getent group operator >/dev/null 2>&1 || groupadd --system operator
id -u operator >/dev/null 2>&1 ||
    useradd --create-home --gid operator --shell /bin/bash operator
mkdir -p /etc/guarden
stage_config guarden-measured.toml
stage_poke pgprov 9f2c1ab
stage_poke needful 9f2c1ab
stage_poke needy 9f2c1ab
stage_poke unpublished 9f2c1ab

# `soil install --apply` is a precondition, not the subject: ingest renders through
# `loom`, and the programs are not on this host until install has run. The note
# below about the firewall unit is still true — install installs the unit but this
# file does not converge the rendered set, which is t20-firewall's business.
install -D -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" \
    "$GUARDEN_PREFIX/etc/guarden/podlet.release"
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
assert_file_has "$consumer_registry" '[edges."pgprov-staging:5432"]'
assert_file_has "$consumer_registry" '[edges."pgprov-staging:8200"]'
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
db_blob=$creds/needful-staging/DB_PASSWORD_5432.cred
assert_file_exists "$db_blob"
assert_mode "$db_blob" 600
assert_mode "$creds/needful-staging" 700
assert_file_missing "$creds/pgprov-staging/DB_PASSWORD_5432.cred"
# `auth: secret` is planted in **both**, because the provider has to be able to
# verify it, and the two hold the same value — that is what makes it verifiable.
assert_file_exists "$creds/needful-staging/SECRET_SECRET_8200.cred"
assert_file_exists "$creds/pgprov-staging/SECRET_SECRET_8200.cred"

# The blob decrypts under this machine's host key, which is the fact rather than a
# record of an intent: the value came back, so the key is one this host holds.
run systemd-creds decrypt --with-key=host "$db_blob"
assert_exit 0
db_value=$(cat "$GUARDEN_STDOUT")
assert_file_lacks "$db_blob" "$db_value"
run systemd-creds decrypt --with-key=host "$creds/needful-staging/SECRET_SECRET_8200.cred"
assert_exit 0
vault_own=$(cat "$GUARDEN_STDOUT")
run systemd-creds decrypt --with-key=host "$creds/pgprov-staging/SECRET_SECRET_8200.cred"
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
assert_file_lacks "$conf" "192.0.2.1"
# KNOWN DIVERGENCE, asserted not deleted: spec 7.6 puts `-o lo` on every accept;
# firewall.py emits no interface match at all. Fails until reconciled.
if grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -q 'mod owner'; then
    grep -vE '^[[:space:]]*(#|$)' "$conf" | grep 'mod owner' \
        || _fail "30-services.conf's loopback deny is not daddr-scoped; spec 7.6 has no interface match and the kernel routes 127.0.0.0/8 over lo"
fi
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
run systemd-creds decrypt --with-key=host "$creds/needy-staging/DB_PASSWORD_5432.cred"
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
    assert_file_has "$render/units/$unit.container" "AddHost=pgprov-staging:192.0.2.1"
done
assert_file_has "$render/units/guarden.env" "DB_HOST=pgprov-staging"
assert_file_has "$render/units/guarden.env" "DB_PORT=$db_pub"
assert_file_has "$render/units/guarden.env" "SECRET_HOST=pgprov-staging"
assert_file_has "$render/units/guarden.env" "SECRET_PORT=$vault_pub"
assert_file_has "$render/units/web.container" "Secret=DB_PASSWORD_5432,type=file"
assert_file_has "$render/units/web.container" "Secret=SECRET_SECRET_8200,type=file"
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
# is no publication to dial and no credential to plant: the edge is recorded with an
# empty list and the mutator says which container is missing. The render is what
# refuses it, because the manifest was fine and the answer came from the host.
run weedr service ingest unpublished-staging --from poke unpublished@9f2c1ab
assert_exit 0
assert_stderr_has "9999"
assert_stderr_has "pgprov-staging"
assert_file_has "$registry/unpublished-staging.toml" 'publications = []'
# `auth: none` plants nothing, so the claim is that the service holds NO credential
# — stated over the directory rather than one file name, so it does not depend on
# how a key is spelled.
assert_file_missing "$creds/unpublished-staging/DB_PASSWORD_9999.cred"
leftover=$(ls -A "$creds/unpublished-staging" 2>/dev/null || true)
[ -z "$leftover" ] || _fail "auth: none left credentials behind: $leftover"
assert_file_missing "$creds/unpublished-staging/BOTH_SECRET.cred"
run loom render /var/lib/guarden/services/unpublished-staging/home \
    --service unpublished-staging --out "$GUARDEN_FIXTURES/unpublished"
assert_exit 1
assert_stderr_has "publication"

# An edge to a service this host has never heard of. A poke creates services in
# dependency order and a manifest may name one a later deploy brings into being, so
# this is a warning and the consumer is created with the edge incomplete — not a
# refusal, which would make every poke that outruns its own dependency fail.
nowhere=$GUARDEN_PREFIX/var/lib/guarden/staging/nowhere/9f2c1ab
mkdir -p "$nowhere/.guarden/quadlet"
seed "$nowhere/.guarden/service.yml" "project: nowhere" "units: .guarden/quadlet/" \
    "needs:" "  - service: nowhere-staging" "    as: db" "    port: 5432" \
    "    auth: database"
seed "$nowhere/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest nowhere-staging --from poke nowhere@9f2c1ab
assert_exit 0
assert_stderr_has "nowhere-staging"
assert_file_has "$registry/nowhere-staging.toml" 'publications = []'
assert_file_missing "$creds/nowhere-staging/DB_PASSWORD_5432.cred"
purge nowhere-staging

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
assert_file_missing "$creds/ghost-staging/DB_PASSWORD_5432.cred"

# And the credential the database edge planted is still there after everything
# above, encrypted and unreadable at rest.
assert_file_exists "$creds/needful-staging/DB_PASSWORD_5432.cred"
assert_mode "$creds/needful-staging/DB_PASSWORD_5432.cred" 600