#!/usr/bin/env bash
# Ticket 60, the gate half: exactly two outcomes, one per track, and nothing
# stopped before the gate has been asked.
#
# The blocked-gate case is the load-bearing one, so it is asserted three ways:
# the verb exits `1` and names the key, no unit of this service was stopped
# before the gate was asked, and the registry carries the state and the reason.
# The ungated case is asserted to do the opposite — a warning naming the key,
# `not-required` recorded, and the start proceeding.
#
# **There is no staged host here, and that is the whole of what this file
# changed.** Creating the service is `weedr service ingest`, which is step 2 of
# spec 5.3: a real `useradd` for `qapp-production`, a real uid, a real delegated
# `/etc/subuid` range. A staged `/etc/passwd` cannot be reconciled with that — the
# mutator reads back the database it promised to be written to, finds nothing, and
# reports "qapp-production was created but is not in <staged>/etc/passwd", which is a
# true sentence about two databases and a fact about no service. So `GUARDEN_PREFIX=/`
# and the machine's own tools, the way `t30-create` and `t30-remove` already do.

. "$(dirname "$0")/lib.sh"

VALUE=a-real-value-not-an-example

stage_quadlet()
{
    local project=qapp ref=9f2c1ab
    local staged=$GUARDEN_PREFIX/var/lib/guarden/staging/$project/$ref
    mkdir -p "$staged/.guarden/quadlet" "$staged/.guarden/widgets"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
       "$staged/.guarden/.env.schema"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/service.yml" \
       "$staged/.guarden/service.yml"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
       "$staged/.guarden/quadlet/web.container"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/worker.container" \
       "$staged/.guarden/quadlet/worker.container"
    cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/widgets/web.yml" \
       "$staged/.guarden/widgets/"
    printf '%s\n' "services: [qapp-production, qapp-staging]" \
        >"$staged/guarden-poke.json"
    mkdir -p "$GUARDEN_PREFIX/var/lib/guarden/staging/$project/HEAD"
}

# The machine's own tools. Nothing is faked (ADR-0014), so this line is a
# statement rather than a mechanism: `useradd`, `loginctl`, `systemd-creds` and
# `snapper` are the machine's, and `.venv/bin` is kept first because it is the
# checkout's interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
# The real path, not a relocated one: `stage_config` writes where guarden reads,
# and /etc/guarden is absent on a host where `soil install` has never run.
# `host.admin_user` names the uid the edge's API accept set admits, and install
# refuses to render the firewall without the account existing. useradd exits 9 when
# the GROUP exists and -g is not given, so the group is created first.
ensure_accounts
stage_config guarden-measured.toml
stage_quadlet

# install is a precondition, not the subject: ingest renders through loom.
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected
run weedr module add gate
assert_exit 0

# This golden has no podman for a service user, so no materialiser instance could
# succeed; moving its units aside is what makes `secret set` report the missing
# phase rather than a unit failure it cannot fix.
for unit in guarden-creds.path guarden-creds-boot.service; do
    if [ -e "/etc/systemd/system/$unit" ]; then
        mv "/etc/systemd/system/$unit" "/etc/systemd/system/$unit.off"
    fi
done
systemctl daemon-reload

# The provider first: it is what the consumer dials, and a consumer whose provider
# does not exist is a different case that this suite asserts separately.
stage_poke pgprov 9f2c1ab
run weedr service ingest postgres-staging --from poke pgprov@9f2c1ab
assert_exit 0

# Two services, one project, two tracks. The gate is per SERVICE and not per
# instance, and the track is what makes it two outcomes rather than one.
run weedr service ingest qapp-production --from poke qapp@9f2c1ab
assert_exit 0
run weedr service ingest qapp-staging --from poke qapp@9f2c1ab
assert_exit 0

registry=$GUARDEN_PREFIX/var/lib/guarden/registry
production=$registry/qapp-production.toml
staging=$registry/qapp-staging.toml

# **A service with no `[gate]` table has never been evaluated.** That is `null` in
# JSON and it is not the same as `ready`: a verdict nobody took is not a passing
# one. The service was created a moment ago and the gate has not run.
assert_file_lacks "$production" "[gate]"
run weedr service list --json
assert_exit 0
assert_json services.0.gate null
run weedr service list
assert_exit 0
assert_stdout_has "gate           not evaluated"

# The gated track, blocked. LOG_LEVEL is required — `@defaultRequired=infer` makes a
# key declared with a value required — and nothing plants it, so the gate says so and
# the verb exits `1`. DB_PASSWORD is required too, but the `database` edge mints the
# consumer's copy at ingest, so there is nothing for the gate to block on there.
run weedr service gate qapp-production
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "cannot start"
assert_stderr_has "LOG_LEVEL"
assert_stdout_empty
assert_file_has "$production" 'state = "blocked"'
assert_file_has "$production" 'missing required key: LOG_LEVEL'
assert_file_has "$production" 'checked = "'

# **The gate is evaluated before the old container is stopped.**
#
# The assertion that used to sit here — that no `stop` appears in the call log
# for a unit of this service — is **dropped rather than ported**: nothing on the
# box records whether a stop was issued, and "the program did not call systemctl"
# is not a fact about a machine.
#
# It is a real claim and it is not lost to carelessness. It is lost to the host
# this file runs on: no container of this service has ever run here, so there is
# no running unit for a stop to have been issued against, and
# `assert_unit_not_active qapp-production web` would read "not active" whether the
# gate stopped it or never started it. An assertion that passes whatever the
# program did reads as evidence and is none — which is the same reason
# `assert_stopped_in_manager` in `t30-remove.sh` only means something there.
#
# No probe was invented to preserve it. The check belongs to a service with a
# running container on a real user manager, where "the unit is not active" is a
# state the box can report and a unit that was running is one that was stopped.
# Holding it here needs the golden VM to run a container, which is ticket 140's
# work and not this file's.

# A start refuses for the same reason and in the same place, which is the whole of
# the "the way out is not a re-push" instruction in the runbook. What is
# observable on this host is the refusal and the state it recorded.
run weedr service start qapp-production
assert_exit 1
assert_stderr_has "LOG_LEVEL"
assert_stdout_empty
assert_file_has "$production" 'state = "blocked"'

# A value that is still the schema's example is not a credential. It is planted,
# so `weedr secret list` calls it set, and the gate still refuses it and names it.
#
# **The credential materialiser is absent here and that is not what this file
# tests.** `weedr secret set` writes the blob and asks
# `guarden-creds-boot.service` to carry it into the service's podman secret
# store; that unit is installed by `soil install`, no suite here runs a soil
# phase, and the store needs a podman the golden does not carry
# (`t60-secrets.sh` says so where it asserts the store). So the verb reports the
# unit it could not ask and exits `0`, and what this file is about — the gate
# reading the blob the plant wrote — is untouched by it. Exit `1` would say the
# value was not planted, which is false: `weedr secret list` below reads the blob
# back and reports it set.
run weedr secret set qapp-production DB_PASSWORD <<<"EXAMPLE-not-a-real-password"
assert_exit 0
run weedr secret list qapp-production --json
assert_exit 0
assert_json secrets.0.set true
assert_json secrets.0.example true
run weedr service gate qapp-production
assert_exit 1
assert_stderr_has "required key DB_PASSWORD is still the example"

# `changeme` is the other convention, and an empty value is the third. Both are
# refused, and both name the key.
run weedr secret set qapp-production DB_PASSWORD <<<"changeme"
assert_exit 0
run weedr service gate qapp-production
assert_exit 1
assert_stderr_has "required key DB_PASSWORD is still changeme"

# The operator plants a value. Nothing else is re-pushed and nothing is rebuilt:
# the same verb that refused now answers ready, because `start` re-evaluates every
# time.
run weedr secret set qapp-production DB_PASSWORD <<<"$VALUE"
assert_exit 0
run weedr secret list qapp-production --json
assert_exit 0
assert_json secrets.0.example false

# `LOG_LEVEL` is required by `@defaultRequired=infer` and is **not** `@sensitive`,
# so on a gated track nothing mints it and it is the gate's business. Planted, the
# gate is ready.
run weedr secret set qapp-production LOG_LEVEL <<<"info"
assert_exit 0
run weedr service gate qapp-production
assert_exit 0
assert_stdout_has "qapp-production gate ready"
assert_stderr_empty
assert_file_has "$production" 'state = "ready"'

# `reason` is present only when the state is `blocked`. A `ready` record with an
# empty reason would be a second way to say something.
assert_file_lacks "$production" "reason ="

# An empty value is nothing to encrypt, and it is rejected input rather than a
# host fact: the operator typed nothing.
run weedr secret set qapp-production STRIPE_KEY <<<""
assert_exit 2
assert_stderr_has "nothing was typed"
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/creds/qapp-production/STRIPE_KEY.cred"

# **The verdict is per SERVICE, so there is no `[/ref]` to ask about.** Every
# instance of a service shares the one store, and a per-instance verdict would be a
# thing an operator could hold against one ref and act on.
run weedr service gate qapp-production/feature-login
assert_exit 2
assert_stderr_has "/<ref>"
assert_stdout_empty

# The ungated track: the same schema, the same missing keys, and the start
# proceeds. This is the whole difference between the two tracks — one warning
# naming the key, `not-required` recorded, and no refusal.
run weedr service gate qapp-staging
assert_exit 0
assert_one_diagnostic "warning:"
assert_stderr_has "LOG_LEVEL"
assert_stdout_has "qapp-staging gate not-required"
assert_file_has "$staging" 'state = "not-required"'
assert_file_lacks "$staging" 'state = "blocked"'

# On an ungated track the value is minted at creation rather than asked for, so a
# poke is never blocked on a human. `SESSION_SIGNING_KEY` is `@sensitive` and got
# one; `LOG_LEVEL` is required and is not sensitive, so it did not, and the warning
# above is the honest report of that. The generated table is the only record that a
# value was minted rather than planted.
assert_file_has "$staging" "[generated]"
assert_file_has "$staging" "SESSION_SIGNING_KEY"
assert_file_lacks "$staging" "LOG_LEVEL"
assert_file_exists "$GUARDEN_PREFIX/etc/guarden/creds/qapp-staging/SESSION_SIGNING_KEY.cred"
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/creds/qapp-staging/LOG_LEVEL.cred"
run weedr secret list qapp-staging --json
assert_exit 0
assert_json secrets.0.source '"generated"'

# The mint happens once. A second ingest of a converged service says converged
# and mints nothing.
#
# "Mints nothing" was a call-log assertion — that the ingest asked
# `systemd-creds` for nothing — and it is now the state the box can answer: the
# store holds the same keys it held, and the blob for the generated one is
# byte-for-byte the blob the first ingest wrote. A second mint would produce a
# new blob, because `systemd-creds` is randomised, so a digest that is unchanged
# is not merely a plausible outcome — it is the one outcome a second encryption
# cannot produce. No extra key is what `[generated]` staying free of `LOG_LEVEL`
# already claimed, and it is repeated here because the claim is now about the
# second run rather than about the first.
run weedr service ingest qapp-staging --from poke qapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
before=$(sha256sum "$GUARDEN_PREFIX/etc/guarden/creds/qapp-staging/SESSION_SIGNING_KEY.cred" \
    | cut -d' ' -f1)
run weedr service ingest qapp-staging --from poke qapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
after=$(sha256sum "$GUARDEN_PREFIX/etc/guarden/creds/qapp-staging/SESSION_SIGNING_KEY.cred" \
    | cut -d' ' -f1)
[ "$before" = "$after" ] || _fail "a converged ingest re-encrypted the generated value"
# And nothing new appeared beside it: the store holds one key for this service,
# and a mint of a second one would be a file this does not find.
assert_file_missing "$GUARDEN_PREFIX/etc/guarden/creds/qapp-staging/LOG_LEVEL.cred"
assert_file_has "$staging" 'state = "not-required"'
assert_file_lacks "$staging" 'state = "blocked"'

# `weedr service list` shows the generated value as generated and the gate state
# beside it. The JSON field set is closed, so the generated values are in the human
# report and `weedr secret list --json` is where a key's origin is machine-readable.
run weedr service list
assert_exit 0
assert_stdout_has "generated      SESSION_SIGNING_KEY"
assert_stdout_has "gate           not-required"

# A second plant of a generated key does not make it a planted one: nothing could
# tell the difference in the store, which is exactly why the table exists.
run weedr secret list qapp-staging --json
assert_exit 0
assert_json secrets.0.source '"generated"'