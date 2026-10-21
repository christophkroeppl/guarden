#!/usr/bin/env bash
# `weedr clone`: the snapshot-clone chain, end to end on a real machine.
#
# (ticket 327, ADR-0025)
#
# **The chain the operator named, as one suite.** "pinning a snapshot from pg
# and clone prod odoo db on staging pg and spin it up with staging odoo (spin up
# prod pg snapshot with tmp pg container, dump and push to staging pg)" — the
# The Phase A testrun did every step by hand and needed twelve manual steps
# guarden had no verb for (phase-a-snapshot-clone-testrun.md, §9).
#
# So this file is the chain, and it is the WHOLE chain: a snapshot pinned, a
# throwaway container cut from it, a dump out of that container, a scrub of the
# dump, a load of the scrubbed dump into the staging service's database, and the
# staging engine answering with the restored data.
#
# **Nothing here is a call log.** Every claim is a question to the box: a real
# btrfs subvolume with its real `ro` property, a real container in the source
# service's own podman store, a real `psql` counting rows, a real file on the
# filesystem. The podman image is pulled from the registry by the machine
# itself, and the assertions read the state the chain left rather than what a
# program said it was going to do.
#
# **The chain crosses services, and that is what makes it hard.** The snapshot
# belongs to the production postgres; the tmp container runs in the production
# service's own podman store; the dump is written to the STAGING service's bulk
# volume; the scrub rule is the staging service's own manifest; and the load
# happens in the staging service. One verb cannot own that, which is why the
# verbs are a group (`weedr clone`) rather than four more on `weedr service`.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-measured.toml
stage_podlet_release
run soil packages --apply
assert_exit 0
run soil install --apply
assert_exit 0

# --- the two services, one production and one staging ------------------------
#
# The production one is the SOURCE: its snapshot is what the chain clones. The
# staging one is the TARGET: its bulk volume is where the dump lands, and its
# engine is what answers at the end.
#
# `postgres` is a `db` provider with a state volume and one container, so the
# source has exactly one database container to find. `pgdual` is a `db` provider
# with a state volume AND a bulk volume — the landing area the operator named
# ("staging pg (bulk volume)") — and its own manifest carries the `scrub:` rule
# the transform applies.
stage_poke postgres 9f2c1ab
stage_poke pgdual 9f2c1ab
run weedr service ingest postgres-production --from poke postgres@9f2c1ab
assert_exit 0
run weedr service ingest pgdual-staging --from poke pgdual@9f2c1ab
assert_exit 0

prod=/var/lib/guarden/services/postgres-production
stage=/var/lib/guarden/services/pgdual-staging
config=postgres-production-pgdata

# One shape for "podman as this service user": the suite's own 0700 tree is
# scrubbed out of the environment, and the cwd is a directory the service user
# can enter. `run_in` is what makes the second half true — a bare `runuser` from
# the suite's root-owned tree fails `cannot chdir` before podman does anything.
as_podman() {
    local service=$1 home uid
    shift
    home="/var/lib/guarden/services/$service/home"
    uid=$(id -u "$service")
    run_in /tmp runuser -u "$service" -- env -C /tmp \
        HOME="$home" USER="$service" LOGNAME="$service" \
        XDG_RUNTIME_DIR="/run/user/$uid" podman "$@"
}

# wait_ready <service> <container>: the engine's own answer, not a sleep. The
# source's first start initialises a cluster and the tmp container's start
# recovers WAL; both take seconds after the container exists.
wait_ready() {
    local service=$1 container=$2 i
    for i in $(seq 1 90); do
        as_podman "$service" exec "$container" pg_isready -U postgres >/dev/null 2>&1
        if [ "$GUARDEN_EXIT" = 0 ]; then
            return 0
        fi
        sleep 1
    done
    _fail "$container in $service did not answer pg_isready within 90s"
}

# --- step 1: a snapshot of the production postgres, pinned -------------------
#
# The source must have the rows the scrub will remove and the rows it must keep,
# so the scrub's effect is observable in the restored database. They are planted
# through the container's own `psql` — the real engine, on the real data.
run weedr service start postgres-production
assert_exit 0
wait_ready postgres-production postgres-production-db

as_podman postgres-production exec postgres-production-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE ir_mail_server (id serial primary key, smtp_host text, smtp_pass text)"
assert_exit 0
as_podman postgres-production exec postgres-production-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE ir_config_parameter (id serial primary key, key text, value text)"
assert_exit 0
as_podman postgres-production exec postgres-production-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "INSERT INTO ir_mail_server (smtp_host, smtp_pass) VALUES ('smtp.prod.example.com', 'ProdSmtpSecret')"
assert_exit 0
as_podman postgres-production exec postgres-production-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "INSERT INTO ir_config_parameter (key, value) VALUES ('mail.default.from', 'prod-mailer@example.com')"
assert_exit 0
as_podman postgres-production exec postgres-production-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "INSERT INTO ir_config_parameter (key, value) VALUES ('ir.config_parameter', 'kept-value')"
assert_exit 0

# The snapshot is taken WHILE the service runs, which is the design (spec 8.1):
# the engine's own recovery makes it consistent. An on-demand snapshot is
# `number`-tagged, which is the kind a pin's mark protects — a routine
# `timeline` snapshot is not a candidate for the number cleaner, so a mark on one
# would prove nothing.
run snapper -c "$config" create --cleanup-algorithm number --description "the clone source"
assert_exit 0
assert_newest_snapshot "$config" 1

# The operator's own first step: "pinning a snapshot from pg". The pin is a file
# and the mark is the reconciler's, and both are read back off the machine.
run stakes pin "postgres-production:pgdata@1" "the clone source for the staging refresh"
assert_exit 0
assert_stdout_has "pinned postgres-production:pgdata@1"
run weedr pin sync
assert_exit 0
assert_snapshot_marked "$config" 1 yes

# --- step 2: the throwaway container, cut from the snapshot ------------------
#
# The operator's own step: "spin up prod pg snapshot with tmp pg container".
run weedr clone snapshot "postgres-production:pgdata@1" --as pgclone
assert_exit 0
assert_stdout_has "cloned postgres-production:pgdata@1"
assert_stdout_has "pgclone"

# The clone is a REAL btrfs subvolume, it is writable (the entrypoint chowns its
# data directory), and the SOURCE snapshot is still read-only — nothing wrote to
# the snapshot to make a clone.
assert_subvolume "$prod/clones/pgclone"
assert_property "$prod/clones/pgclone" ro false
assert_property "$prod/state/pgdata/.snapshots/1/snapshot" ro true
assert_owner "$prod/clones/pgclone" postgres-production:postgres-production
assert_mode "$prod/clones/pgclone" 700

# The container is running, in the SOURCE service's own podman store, and it is
# NOT a service: no registry record, no unit, and no line in `weedr service list`.
as_podman postgres-production ps --filter name=pgclone --format '{{.Names}}'
assert_exit 0
assert_stdout_has "pgclone"
assert_file_missing "/var/lib/guarden/registry/pgclone.toml"
assert_file_missing "$prod/home/.guarden/quadlet/pgclone.container"
run weedr service list
assert_exit 0
assert_stdout_lacks "pgclone"

# --- step 3: the dump, out of the tmp container into the target's bulk volume -
#
# The operator's own step: "dump". The dump is plain SQL because the scrub in
# step 4 is a filter over text; a custom-format dump is a binary archive no
# filter can read.
run weedr clone dump pgdual-staging --db postgres --out clone.sql \
    --from postgres-production:pgclone
assert_exit 0
assert_file_exists "$stage/bulk/bulk/clone.sql"
assert_file_has "$stage/bulk/bulk/clone.sql" "PostgreSQL database dump"
assert_file_has "$stage/bulk/bulk/clone.sql" "ProdSmtpSecret"

# `--from` and `--out` naming one file is refused: the verb writes a new dump.
run weedr clone transform pgdual-staging --from clone.sql --out clone.sql
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "both name"

# --- step 4: the scrub, and what it removed ----------------------------------
#
# The operator's own step: "deleting email settings". The rule is a POLICY and
# it lives in the staging service's own manifest (ADR-0025) — the fixture's
# `scrub:` block is the one applied here.
run weedr clone transform pgdual-staging --from clone.sql --out scrubbed.sql
assert_exit 0
assert_stdout_has "transformed"
assert_stdout_has "ir_mail_server"
assert_file_exists "$stage/bulk/bulk/scrubbed.sql"

# The secret is GONE from the transformed dump; the row that is not a mail
# setting is KEPT; and the source dump still carries both, because the verb
# writes a new file rather than rewriting the one it read.
assert_file_lacks "$stage/bulk/bulk/scrubbed.sql" "ProdSmtpSecret"
assert_file_lacks "$stage/bulk/bulk/scrubbed.sql" "mail.default.from"
assert_file_has "$stage/bulk/bulk/scrubbed.sql" "kept-value"
assert_file_has "$stage/bulk/bulk/clone.sql" "ProdSmtpSecret"

# A manifest with no `scrub:` block is refused: there is nothing to do, and a
# verb that silently did nothing would report a transform it never performed.
run weedr clone transform postgres-production --from clone.sql --out none.sql
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "scrub"
assert_file_missing "$stage/bulk/bulk/none.sql"

# --- step 5: the load, into the staging engine -------------------------------
#
# The operator's own step: "push to staging pg". The target database is the
# edge's to create — `edges.provision` does it — so this file creates it the way
# the edge does, with the engine's own `psql`, and then measures the RESTORED
# DATABASE rather than the dump.
run weedr service start pgdual-staging
assert_exit 0
wait_ready pgdual-staging pgdual-staging-db

# The same dump verb against the target's OWN running database, which is the
# path without `--from`: a service can dump itself into its own bulk volume.
run weedr clone dump pgdual-staging --db postgres --out self.sql
assert_exit 0
assert_file_exists "$stage/bulk/bulk/self.sql"

as_podman pgdual-staging exec pgdual-staging-db \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE restored"
assert_exit 0

# A database that does not exist is refused, and the refusal names it: the load
# restores into a database, it does not create one.
run weedr clone load pgdual-staging --db nosuchdb --from scrubbed.sql
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "nosuchdb"

run weedr clone load pgdual-staging --db restored --from scrubbed.sql
assert_exit 0
assert_stdout_has "loaded"

# The secret is not in the restored database, and the kept row is.
as_podman pgdual-staging exec pgdual-staging-db \
    psql -U postgres -d restored -tAc "select count(*) from ir_mail_server"
assert_exit 0
[ "$(tr -d '[:space:]' <"$GUARDEN_STDOUT")" = "0" ] \
    || _fail "the restored database did not keep ir_mail_server empty"
as_podman pgdual-staging exec pgdual-staging-db \
    psql -U postgres -d restored -tAc \
    "select count(*) from ir_config_parameter where key = 'ir.config_parameter'"
assert_exit 0
[ "$(tr -d '[:space:]' <"$GUARDEN_STDOUT")" = "1" ] \
    || _fail "the restored database did not keep the row the scrub was not about"

# "A staging service answering": the target's own unit is active in its user
# manager, and the engine inside it is the one that just answered above.
state=$(systemctl --user --machine pgdual-staging@ is-active db.service 2>/dev/null || true)
[ "$state" = active ] || _fail "the staging unit db.service is '$state', not active"

# --- the verbs are root-only, and no sudoers rule carries them --------------
#
# A clone reads production data and a load writes it, so a poke must not reach
# them. The installed rule says so twice over, and both halves are read off the
# file: the poke's rule grants the deploy verbs and names no `weedr` command at
# all, and the mutator's own rule grants `guarden` `weedr` whole — the verb list
# is enforced inside the program, so nothing in the file can name a clone verb.
assert_file_has /etc/sudoers.d/guarden \
    "hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/furrow deploy *"
assert_file_lacks /etc/sudoers.d/guarden \
    "hose ALL=(guarden) NOPASSWD: /usr/lib/guarden/bin/weedr"
assert_file_lacks /etc/sudoers.d/guarden "weedr clone"

# --- a refusal that changes nothing ------------------------------------------
#
# A load into a service with NO bulk volume is refused, naming the volume the
# operator should declare: the chain's target is a bulk volume by definition.
run weedr clone load postgres-production --db postgres --from clone.sql
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "bulk"

# A snapshot id that names nothing is refused, and no clone is left behind.
run weedr clone snapshot "postgres-production:nosuchvolume@99" --as pgclone2
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "nosuchvolume"
assert_no_subvolume "$prod/clones/pgclone2"

# A container name that is a path is refused as input, and nothing is created.
run weedr clone snapshot "postgres-production:pgdata@1" --as ../escape
assert_exit 2
assert_one_diagnostic "error:"
assert_no_subvolume "$prod/escape"

# --- step 6: the cleanup, and it removes only what the verb made -------------
run weedr clone remove postgres-production --as pgclone
assert_exit 0
assert_no_subvolume "$prod/clones/pgclone"
as_podman postgres-production ps --filter name=pgclone --format '{{.Names}}'
assert_exit 0
assert_stdout_empty
# The source snapshot is still the source snapshot.
assert_property "$prod/state/pgdata/.snapshots/1/snapshot" ro true
assert_snapshot_marked "$config" 1 yes

# Removing it twice is exit 1: the clone is not there, and `0` would report
# work that did not happen.
run weedr clone remove postgres-production --as pgclone
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "no clone"
