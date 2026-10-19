#!/usr/bin/env bash
# t450-basicauth.sh — ticket 292: installing the gate generates the basic-auth
# policy, a new service with `routes:` carries a login of its own through the
# existing credential machinery, and its edge routers get the middleware with
# no manifest change. A service created before the policy is grandfathered, a
# manifest cannot disable the middleware, and a re-ingest never re-mints the
# login.
#
# What is asserted is state: the marker, the encrypted blob, the htpasswd
# entry and the file provider's own output — and the htpasswd entry is checked
# against the decrypted password, so "the credential and the login are the same
# value" is measured rather than assumed.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

id -u operator >/dev/null 2>&1 || {
    getent group operator >/dev/null 2>&1 || groupadd --system operator
    useradd --system --no-create-home --gid operator --shell /usr/sbin/nologin operator
}
ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

policy=/etc/guarden/edge/basicauth-policy
entries=/var/lib/guarden/edge/basicauth

# The directory the edge unit mounts is converged by `soil install`, long
# before any unit mounts it: an unprivileged edge user cannot mkdir under a
# root-owned parent, so the bind source has to already be there. Its mode and
# owner are asserted too: the directory is the one the whole credential
# isolation rests on (everyone traverses, nobody but root writes), and a suite
# that only checks it exists would pass on a `0777` one.
run test -d "$entries"
assert_exit 0
assert_mode "$entries" 755
assert_owner "$entries" root:root

# Before the gate module is installed there is no policy and no service may be
# flagged — this is the state a staged, module-less host starts from.
run test -f "$policy"
assert_exit 1

# A service created now, while there is no policy, is the grandfathered case.
oldapp=$GUARDEN_PREFIX/var/lib/guarden/staging/oldapp/9f2c1ab
mkdir -p "$oldapp/.guarden/quadlet"
seed "$oldapp/.guarden/service.yml" "project: oldapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: old"
seed "$oldapp/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest oldapp-staging --from poke oldapp@9f2c1ab
assert_exit 0
oldreg=$GUARDEN_PREFIX/var/lib/guarden/registry/oldapp-staging.toml
assert_file_lacks "$oldreg" "basicauth"
assert_file_missing /etc/guarden/creds/oldapp-staging/GUARDEN_BASICAUTH.cred
assert_file_missing "$entries/oldapp-staging.htpasswd"
oldslice=$GUARDEN_PREFIX/var/lib/guarden/shared/oldapp-staging/routes.toml
assert_file_has "$oldslice" "basicauth = false"

# Installing the gate generates the policy, and says so: the marker lands
# root-owned beside the auth-provider marker's directory, before the module's
# own service is created.
run weedr module add gate-traefik
assert_exit 0
assert_stdout_has "basic auth policy"
assert_file_exists "$policy"
assert_file_has "$policy" "required"
assert_mode "$policy" 640
assert_owner "$policy" root:guarden
run test -d "$entries"
assert_exit 0

# The edge unit mounts the entries where each service's `usersFile` names
# them; without the mount the middleware would be aimed at a path the container
# cannot see, which is a traefik error per request rather than a login.
edge_unit=/var/lib/guarden/services/traefik-production/home/.config/containers/systemd/traefik.container
assert_file_has "$edge_unit" \
    "Volume=/var/lib/guarden/edge/basicauth:/etc/guarden/basicauth:ro"

# A new service created now carries the credential, and the manifest did not
# ask for any of it — its route even says `auth: false`, which is the default
# and must not reach this middleware.
newapp=$GUARDEN_PREFIX/var/lib/guarden/staging/newapp/9f2c1ab
mkdir -p "$newapp/.guarden/quadlet"
seed "$newapp/.guarden/service.yml" "project: newapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: new" "    auth: false"
seed "$newapp/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest newapp-staging --from poke newapp@9f2c1ab
assert_exit 0
newreg=$GUARDEN_PREFIX/var/lib/guarden/registry/newapp-staging.toml
assert_file_has "$newreg" "basicauth = true"
# The record that the value guarden minted was not one a human planted (spec
# 3.4's [generated]). The key is written bare — it is a bare TOML key — and the
# assertion names the assignment, not the section, because the section's exact
# spelling is the serializer's and not this ticket's.
assert_file_has "$newreg" "GUARDEN_BASICAUTH = "
blob=/etc/guarden/creds/newapp-staging/GUARDEN_BASICAUTH.cred
assert_file_exists "$blob"
assert_mode "$blob" 600
run weedr secret list newapp-staging
assert_exit 0
assert_stdout_has "GUARDEN_BASICAUTH"

# The htpasswd entry is the same value as the encrypted credential: the entry
# verifies against a decrypt of the blob, so a mismatch between the two halves
# is a login nobody can use rather than a green file assertion.
htpasswd=$entries/newapp-staging.htpasswd
assert_file_exists "$htpasswd"
assert_mode "$htpasswd" 640
assert_owner "$htpasswd" root:edge
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
" "$blob" "$htpasswd" "newapp-staging"
assert_exit 0

newslice=$GUARDEN_PREFIX/var/lib/guarden/shared/newapp-staging/routes.toml
assert_file_has "$newslice" "basicauth = true"

# A service with no routes has nothing the edge would serve, so it is minted
# nothing: the credential is for a login, not a badge.
nodbapp=$GUARDEN_PREFIX/var/lib/guarden/staging/nodbapp/9f2c1ab
mkdir -p "$nodbapp/.guarden/quadlet"
seed "$nodbapp/.guarden/service.yml" "project: nodbapp" "units: .guarden/quadlet/"
seed "$nodbapp/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest nodbapp-staging --from poke nodbapp@9f2c1ab
assert_exit 0
assert_file_missing /etc/guarden/creds/nodbapp-staging/GUARDEN_BASICAUTH.cred
assert_file_lacks "$GUARDEN_PREFIX/var/lib/guarden/registry/nodbapp-staging.toml" \
    "basicauth"

# `roots sync` attaches the middleware to every route the flagged service
# serves, with the definition in that service's own file, and leaves the
# grandfathered service's file byte-identical to an unprotected one.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
rendered=/var/lib/guarden/edge/dynamic/newapp-staging.yml
assert_file_exists "$rendered"
assert_file_has "$rendered" "- newapp-staging-basicauth"
assert_file_has "$rendered" "basicAuth:"
assert_file_has "$rendered" 'usersFile: "/etc/guarden/basicauth/newapp-staging.htpasswd"'
oldrendered=/var/lib/guarden/edge/dynamic/oldapp-staging.yml
assert_file_exists "$oldrendered"
assert_file_lacks "$oldrendered" "basicAuth"
assert_file_lacks "$oldrendered" "basicauth"
assert_file_missing /var/lib/guarden/edge/dynamic/nodbapp-staging.yml

# Re-ingest is converged and changes nothing, and the login is the first mint
# and only the first: a credential that rotated under an operator's stored
# copy would be worse than no credential.
before=$(cat "$htpasswd")
run weedr service ingest newapp-staging --from poke newapp@9f2c1ab
assert_exit 0
assert_stdout_has "converged"
after=$(cat "$htpasswd")
[ "$before" = "$after" ] \
    || _fail "a re-ingest re-minted the basic-auth login"

# The grandfathered service still renders exactly what it rendered before, on
# a second sync as well: no flag ever arrives for it by rendering alone.
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
cp "$oldrendered" "$GUARDEN_FIXTURES/first-sync.yml"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
run cmp -s "$oldrendered" "$GUARDEN_FIXTURES/first-sync.yml"
assert_exit 0
assert_file_lacks "$oldrendered" "basicAuth"

# Removing the module takes the policy and every htpasswd entry with it, but
# the records keep their flags: `basicauth = true` was decided at creation and
# a module's absence does not undo a decision. What must NOT survive is a
# dangling middleware: `roots` renders `usersFile` at the entry's path for any
# flagged service, whether or not the file is there.
# Removing the module's own service out of the gated production track is the
# operator's deliberate act, signalled the way t30-remove and t100-homepage
# signal it: the `allow-gated-drop` marker, taken away again immediately.
marker=/etc/guarden/allow-gated-drop
touch "$marker"
run weedr module remove gate-traefik
assert_exit 0
rm -f "$marker"
assert_file_missing "$policy"
assert_file_missing "$htpasswd"
assert_file_missing "$entries/oldapp-staging.htpasswd"
assert_file_has "$newreg" "basicauth = true"

# Re-adding the module must put the entries back — from the blobs that were
# never dropped, so the restored login is the same one and not a re-mint.
# Without this the edge points every flagged service's basicAuth middleware at
# a file that does not exist, and nothing in guarden reports it.
run weedr module add gate-traefik
assert_exit 0
# The act that restores an entry says which service it restored it for: a
# silent repair is a repair an operator cannot audit.
assert_stdout_has "restored the basic-auth login for newapp-staging"
assert_stdout_lacks "restored the basic-auth login for oldapp-staging"
assert_file_exists "$policy"
assert_file_exists "$htpasswd"
assert_mode "$htpasswd" 640
assert_owner "$htpasswd" root:edge
restored=$(cat "$htpasswd")
[ "$before" = "$restored" ] \
    || _fail "re-adding the gate did not restore the basic-auth login it dropped"
# And the restored entry is still the credential's other half: it verifies
# against the same encrypted blob, so nothing was re-minted underneath an
# operator's stored copy.
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
" "$blob" "$htpasswd" "newapp-staging"
assert_exit 0

# The grandfathered service gained nothing from the round trip, and the edge's
# rendered file names a usersFile that is really on the host again.
assert_file_missing "$entries/oldapp-staging.htpasswd"
run runuser -u guarden -- /usr/lib/guarden/bin/roots sync
assert_exit 0
assert_file_has "$rendered" 'usersFile: "/etc/guarden/basicauth/newapp-staging.htpasswd"'
assert_file_lacks "$oldrendered" "basicauth"
