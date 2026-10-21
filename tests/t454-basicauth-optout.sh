#!/usr/bin/env bash
# t454-basicauth-optout.sh — ticket 318: the default basic-auth middleware has
# a root-owned, per-service opt-out, and no repository can reach it.
#
# The gap this file exists for: ticket 292 put a per-service basic-auth
# credential in front of every new service that declares `routes:`, and there
# was NO act anywhere that could turn it off. The flag is on for every service
# created while the policy is in force, no manifest can remove it (by design),
# and no root-owned surface could either — spec 3.3 closed `overrides.toml`
# ("nothing else is overridable") and spec 3.1's `guarden.toml` table set
# carried no per-service table. An operator who needed one service without the
# middleware — a machine-to-machine endpoint, a webhook target — had no act to
# perform.
#
# What is asserted is STATE, not intent:
#
#   * the setting is in the root-owned `overrides.toml`, the file an operator
#     reads to know every way the host has been widened;
#   * the next render of that service carries it, and the edge's own file for
#     the service loses the middleware;
#   * the credential is NOT destroyed — the blob and the htpasswd entry stay,
#     because the mint is a fact and the opt-out is a setting;
#   * turning it back on re-attaches the SAME login, so an operator's stored
#     credential keeps working;
#   * a manifest asking for it is refused BY NAME, naming where the decision
#     is recorded;
#   * a service that was never minted one is already in the "off" state, and
#     the verb says so rather than claiming a change it did not make;
#   * the act is off the guarden sudoers rule, so a poke cannot re-posture the
#     fleet.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The real host, not a scratch one: a service allocates a real uid, a real
# `/etc/subuid` range, and `useradd` writes the machine's own database.
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# --- a service created before the policy was in force ------------------------
#
# A service created BEFORE the policy holds no login and carries no middleware:
# it is grandfathered, because the registry records nothing for it and no record
# means no middleware (spec 3.4). The act cannot turn off something that was
# never on, and it says so rather than claiming a change it did not make: the
# state is already the requested one, which is exit 0.
#
# This runs BEFORE `weedr module add gate-traefik`, which is the whole of the
# claim: minting happens at creation, for a new service, while the policy is in
# force — so a service created after the marker would carry a login like any
# other, and creating one here afterwards would assert the opposite of what
# ticket 292 does.
oldapp=$GUARDEN_PREFIX/var/lib/guarden/staging/oldopt/9f2c1ab
mkdir -p "$oldapp/.guarden/quadlet"
seed "$oldapp/.guarden/service.yml" "project: oldopt" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$oldapp/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest oldopt-staging --from poke oldopt@9f2c1ab
assert_exit 0
assert_file_lacks /var/lib/guarden/registry/oldopt-staging.toml "basicauth"

run weedr basicauth off oldopt-staging
assert_exit 0
assert_stdout_has "no basic-auth login"
# And it wrote nothing: a service with no login has no middleware to turn
# off, and a file claiming otherwise would be a lie an operator reads.
assert_file_lacks /etc/guarden/services/oldopt-staging/overrides.toml "required"

# Installing the gate generates the basic-auth policy, and from that moment
# every service created with `routes:` carries a login of its own.
run weedr module add gate-traefik
assert_exit 0
assert_stdout_has "basic auth policy"

entries=/var/lib/guarden/edge/basicauth

# --- a service that was minted a login --------------------------------------
app=$GUARDEN_PREFIX/var/lib/guarden/staging/optapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: optapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest optapp-staging --from poke optapp@9f2c1ab
assert_exit 0

reg=/var/lib/guarden/registry/optapp-staging.toml
overrides=/etc/guarden/services/optapp-staging/overrides.toml
slice=/var/lib/guarden/shared/optapp-staging/routes.toml
rendered=/var/lib/guarden/edge/dynamic/optapp-staging.yml
htpasswd=$entries/optapp-staging.htpasswd
blob=/etc/guarden/creds/optapp-staging/GUARDEN_BASICAUTH.cred

# The service carries the login and the middleware, and the file the operator
# reads has nothing about basic auth in it yet: the default is on.
assert_file_has "$reg" "basicauth = true"
assert_file_exists "$htpasswd"
assert_file_exists "$blob"
assert_file_lacks "$overrides" "basicauth"

run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_exists "$rendered"
assert_file_has "$rendered" "basicAuth:"
assert_file_has "$rendered" "usersFile: \"/etc/guarden/basicauth/optapp-staging.htpasswd\""

# --- the act: `weedr basicauth off` ------------------------------------------
#
# The act writes the SETTING into the root-owned per-service file, and it
# prints the file it wrote — a setting an operator cannot find is a setting
# nobody believes is in effect.
run weedr basicauth off optapp-staging
assert_exit 0
assert_stdout_has "overrides.toml"
assert_file_has "$overrides" "required = false"

# The setting is in the file the operator reads, and it is in the guarden
# group, so the unprivileged renderer can read it: a setting the renderer
# cannot read is a setting nothing acts on.
assert_mode "$overrides" 640
assert_owner "$overrides" root:guarden

# The registry is NOT where the setting lives. It is the mutator's record of
# what IS — the MINT — and a grant in the registry makes a projection a grant
# (ADR-0021). The registry therefore still says the login was minted, and
# carries no opt-out.
assert_file_has "$reg" "basicauth = true"
assert_file_lacks "$reg" "required"

# The credential is NOT destroyed. The mint is a fact about the past and the
# opt-out is a setting about the present; un-minting would destroy a
# credential the operator still holds, on the strength of a setting they can
# reverse with one command. The blob and the htpasswd entry both stay.
assert_file_exists "$blob"
assert_file_exists "$htpasswd"

# The middleware comes off at the EDGE's next sync, and it comes off of the
# EDGE's own file — which is the file the edge reads. `weedr basicauth off`
# already synced once (a verb that writes the setting and leaves the edge
# serving the old file would report a change it had not made), and this is the
# same answer reached again from the same two files.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_lacks "$rendered" "basicAuth"
assert_file_lacks "$rendered" "basicauth"
assert_file_lacks "$rendered" "usersFile"

# And the route itself is still served: the opt-out removes the LOGIN, not the
# route. A service whose route vanished would be a different defect.
assert_file_has "$rendered" "optapp-staging-web"

# --- the act is reversible, and the SAME login comes back --------------------
#
# This is the half that makes the setting a setting rather than a deletion.
# The password is read out of the blob BEFORE the middleware comes back, and
# the entry is checked against it afterwards: a re-mint would have produced a
# different value, and an operator's stored credential would have stopped
# working.
before=$(cat "$htpasswd")
run weedr basicauth on optapp-staging
assert_exit 0
assert_file_has "$overrides" "required = true"

run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_has "$rendered" "basicAuth:"
assert_file_has "$rendered" "usersFile: \"/etc/guarden/basicauth/optapp-staging.htpasswd\""

after=$(cat "$htpasswd")
[ "$before" = "$after" ] \
    || _fail "turning the middleware back on re-minted the login"

# And the entry still verifies against the blob, so the login in front of the
# edge is the one the credential holds.
run python3 -c "
import base64, hashlib, subprocess, sys
blob, path, user = sys.argv[1], sys.argv[2], sys.argv[3]
password = subprocess.run(
    ['systemd-creds', 'decrypt', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')
name, found = open(path, encoding='utf-8').read().strip().split(':', 1)
expect = '{SHA}' + base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
sys.exit(0 if name == user and found == expect else 1)
" "$blob" "$htpasswd" "optapp-staging"
assert_exit 0

# --- a manifest cannot reach it ----------------------------------------------
#
# The default is trustworthy because the repository cannot remove it. A
# manifest carrying `basicauth:` is refused BY NAME, with a message naming
# where the decision IS recorded — the same shape `exposure:` gets.
refused=$GUARDEN_PREFIX/var/lib/guarden/staging/refused/9f2c1ab
mkdir -p "$refused/.guarden/quadlet"
seed "$refused/.guarden/service.yml" "project: refused" "units: .guarden/quadlet/" \
    "basicauth: false" "routes:" "  - container: web" "    port: 8080" "    host: web"
seed "$refused/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest refused-staging --from poke refused@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "basicauth"
# The refusal is "by name": the message says where the decision IS recorded.
# The generic closed-key-set line names the key too, so only the verb's own
# name tells the two messages apart.
assert_stderr_has "weedr basicauth off"
assert_file_missing /var/lib/guarden/registry/refused-staging.toml
assert_no_passwd refused-staging

# The same key inside a block is refused by name as well: two vocabularies,
# one answer.
refused2=$GUARDEN_PREFIX/var/lib/guarden/staging/refused2/9f2c1ab
mkdir -p "$refused2/.guarden/quadlet"
seed "$refused2/.guarden/service.yml" "project: refused2" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: web" \
    "    basicauth: false"
seed "$refused2/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest refused2-staging --from poke refused2@9f2c1ab
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "basicauth"
assert_stderr_has "weedr basicauth off"
assert_file_missing /var/lib/guarden/registry/refused2-staging.toml

# --- a service that was never minted one ------------------------------------
#
# The act is refused nothing and claims nothing: `oldopt-staging` was created
# before the policy was in force, has no login and no middleware, and
# `weedr basicauth off` said so and wrote nothing (the block at the top of this
# file). The same answers hold for a service created with no routes: it was
# never minted anything either, and `mint` is only reached by a manifest that
# declares `routes:` (spec 5.3 step 4).

# --- the act is off the guarden sudoers rule ---------------------------------
#
# A poke may deploy and may not re-posture the fleet. The refusal is exit 2,
# and it is the VERB LIST's refusal and not sudo's: the mutator enforces the
# list itself, so a caller that may not run the verb is named by guarden.
run runuser -u hose -- /usr/lib/guarden/bin/weedr basicauth off optapp-staging
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "may not run weedr basicauth off"
assert_file_has /etc/guarden/services/optapp-staging/overrides.toml "required = true"

# --- the posture is reported ------------------------------------------------
#
# `list` reports the two facts separately, because they are separate: a
# service that was never minted one has no middleware and no opt-out, and a
# service whose middleware is off by the operator's setting still holds its
# login.
run weedr basicauth list
assert_exit 0
assert_stdout_has "optapp-staging"
run weedr basicauth list --json
assert_exit 0
assert_stdout_lines 1
assert_stdout_has '"service": "optapp-staging"'
assert_stdout_has '"middleware": "on"'
assert_stdout_has '"minted": true'
assert_stdout_has '"opt_out": false'

# And with the middleware off, the report says the middleware is off while the
# login is still there — the two facts are separate and the report says so.
run weedr basicauth off optapp-staging
assert_exit 0
run weedr basicauth list --json
assert_exit 0
assert_stdout_has '"middleware": "off"'
assert_stdout_has '"minted": true'
assert_stdout_has '"opt_out": true'

# The grandfathered service is reported as never minted, and its middleware is
# off — because it was never on.
run weedr basicauth list --json
assert_exit 0
assert_stdout_has '"service": "oldopt-staging"'
assert_stdout_has '"minted": false'

echo "t454-basicauth-optout: ok"
