#!/usr/bin/env bash
# Ticket 314: the credential materialiser's trigger.
#
# `systemctl list-unit-files` says `guarden-creds.path` is ENABLED, and on a
# freshly converged box it is not RUNNING until the next boot. So the
# automation the unit exists for does not engage on first use, and the
# measurement in the ticket was "no podman secret exists at all".
#
# The runbook compensates by hand (docs/sysadmin.md, "Plant a credential before
# you start": `systemctl start guarden-creds-boot.service`), and that manual
# step is the thing this ticket removes: a first `weedr secret set` on a
# converged box must leave the value in the service's own podman store, with
# no hand-run of the materialiser.
#
# What is asserted is the state of the machine: which units are enabled, which
# are running, and whether the podman secret exists in the service's own
# store. No call log and no stand-in (ADR-0014).
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

# --- the installed state of the pair -----------------------------------------
#
# The two units are spec 6.9's pair: the path unit watches the blob directory
# and triggers the boot oneshot, and the oneshot is the only place a blob is
# decrypted. Both are installed, and the path unit is enabled.
assert_file_exists /etc/systemd/system/guarden-creds.path
assert_file_exists /etc/systemd/system/guarden-creds-boot.service
assert_enabled guarden-creds.path
assert_enabled guarden-creds-boot.service

# **And the path unit is RUNNING.** This is the half that was missing: enabled
# is a symlink, and a `.path` unit that is enabled but not started watches
# nothing. The unit's own automation therefore engaged on the NEXT BOOT and not
# before, which is what the ticket measured.
assert_active guarden-creds.path

# --- a service with a credential --------------------------------------------
#
# A real one, created the way a poke creates it: a real uid, a real home, and a
# schema with a key nothing has planted.
project=credstrig
ref=9f2c1ab
staged=/var/lib/guarden/staging/$project/$ref
mkdir -p "$staged/.guarden/quadlet"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
   "$staged/.guarden/.env.schema"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
   "$staged/.guarden/quadlet/web.container"
cat >"$staged/.guarden/service.yml" <<'YAML'
project: credstrig
units: .guarden/quadlet/
schema: .guarden/.env.schema
state:
  - data
YAML
printf '%s\n' "services: [credstrig-staging]" >"$staged/guarden-poke.json"

run weedr service ingest credstrig-staging --from poke $project@$ref
assert_exit 0

home=/var/lib/guarden/services/credstrig-staging/home
assert_file_exists "$home"

# --- the first plant ---------------------------------------------------------
#
# The measurement the ticket names, asked of the machine: after ONE
# `weedr secret set`, does the value reach the service's own podman store?
#
# **No manual `systemctl start guarden-creds-boot.service` anywhere in this
# file.** That is the whole claim: the runbook's compensation by hand is what
# this removes, and a suite that ran it would be testing its own line.
run weedr secret set credstrig-staging DB_PASSWORD <<<"a-real-value"
assert_exit 0
assert_stdout_has "planted DB_PASSWORD of credstrig-staging"

# The blob is on disk — the verb did its own half.
assert_file_exists /etc/guarden/creds/credstrig-staging/DB_PASSWORD.cred
assert_mode /etc/guarden/creds/credstrig-staging/DB_PASSWORD.cred 600

# And the value is in the service's own podman store, which is the half that
# did not happen before. The store is the service's own home (spec 6.2), and
# podman is asked as the service user, because that is whose store it is.
run_in "$home" runuser -u credstrig-staging -- podman secret ls
assert_exit 0
assert_stdout_has "DB_PASSWORD"

# **The materialiser did not need the operator's hand.** The unit that did the
# work is the one the spec names, and it ran because the plant asked for it.
# What the ticket's measurement was missing is here rather than in a call log:
# the secret exists in the store.
run_in "$home" runuser -u credstrig-staging -- podman secret inspect DB_PASSWORD
assert_exit 0

# --- and a second plant is the same plant ------------------------------------
#
# Rotation is the same path, and a path unit that watches a directory does not
# fire on a second change either: the verb asks, so the value lands.
run weedr secret set credstrig-staging DB_PASSWORD <<<"a-rotated-value"
assert_exit 0
run_in "$home" runuser -u credstrig-staging -- podman secret ls
assert_exit 0
assert_stdout_has "DB_PASSWORD"

# The value that is in the store is the rotated one and not the first: the
# materialiser removes the old secret before it creates the new one (ticket
# 287), so a store holding both would be a store holding a stale credential.
encoded=$(printf '%s' "a-rotated-value" | base64 -w0)
driver=$home/.local/share/containers/storage/secrets/filedriver
assert_file_has "$driver/secretsdata.json" "$encoded"
first=$(printf '%s' "a-real-value" | base64 -w0)
assert_file_lacks "$driver/secretsdata.json" "$first"

# --- the unit is still the trigger for a change made outside the verb --------
#
# The path unit watches the blob directory, so a blob written by anything else
# — a restored backup, an operator's own `cp` — is materialised without the
# verb being involved. That is the unit's whole job, and it is the reason it
# has to be RUNNING rather than merely enabled.
assert_file_has /etc/systemd/system/guarden-creds.path "PathChanged=/etc/guarden/creds/"
assert_file_has /etc/systemd/system/guarden-creds.path "Unit=guarden-creds-boot.service"
