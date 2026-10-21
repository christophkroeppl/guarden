#!/usr/bin/env bash
# t292-basicauth-store.sh — ticket 292, the half of the acceptance set that
# nothing asserted: the minted basic-auth credential reaches the SERVICE'S OWN
# podman store, under that service's `0700` home.
#
# t450-basicauth.sh asserts the blob on disk, the htpasswd entry, the route
# slice, the registry flag and the edge's rendered middleware. Every one of
# those is a file on the host. None of them is the credential in the store the
# container reads, and the gap is structural rather than an oversight in the
# suite: `basicauth.mint` calls `credentials.plant` — which writes the blob —
# and never calls `credentials.ask_materialiser`, and `service.create` does not
# call it either. The only two callers of `ask_materialiser` are
# `creator.py:959` and `weedr.py:1399` (`weedr secret set`).
#
# So the value reaches the store only when the `guarden-creds.path` watcher
# happens to fire on `/etc/guarden/creds/` changing, or at the next boot's
# `guarden-creds-boot.service`. Neither is a guarantee, and neither is
# something a service that starts right after its own creation can rely on.
#
# What is asserted here is STATE, not intent: the podman store under the
# service's own home carries the key, and the value in it is the SAME value the
# encrypted blob decrypts to — so "the credential and the login are one
# credential" is measured rather than assumed, and the htpasswd entry the edge
# reads is checked against the same value.
#
# The value is never written into this file: it is minted at runtime and read
# back out of the blob.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release

# The materialiser needs podman for the service user, and the real tool is the
# only thing that can carry a value into a store. `soil packages` installs it.
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The gate module generates the policy; without it a service created now is
# grandfathered and holds no login at all.
run weedr module add gate-traefik
assert_exit 0
assert_file_exists /etc/guarden/edge/basicauth-policy

app=$GUARDEN_PREFIX/var/lib/guarden/staging/basapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: basapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: bas"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0

# The blob is written: that half is proven elsewhere and is the precondition
# for everything below.
blob=/etc/guarden/creds/basapp-staging/GUARDEN_BASICAUTH.cred
assert_file_exists "$blob"
assert_mode "$blob" 600

# **THE CLAIM.** The credential is in the SERVICE'S OWN podman store, under that
# service's home — the `0700` tree that is the documented limit (spec 6.2).
#
# podman's `file` secret driver keeps each value base64-encoded in
# `.../storage/secrets/filedriver/secretsdata.json` and the names in
# `.../storage/secrets/secrets.json`. The encoding is not protection; the
# `0700` on the home is. `t60-secrets.sh` measures the same shape for a
# DB_PASSWORD, so this is the same measurement for the basic-auth login.
home=$GUARDEN_PREFIX/var/lib/guarden/services/basapp-staging/home
containers=$home/.local/share/containers
driver=$containers/storage/secrets/filedriver
assert_file_exists "$driver/secretsdata.json"
assert_mode "$driver" 700
assert_owner "$driver" basapp-staging:basapp-staging
assert_file_has "$containers/storage/secrets/secrets.json" "GUARDEN_BASICAUTH"

# **And the value in the store is the SAME value the blob decrypts to.** The
# htpasswd entry the edge reads is checked against the same password, so all
# three halves — blob, store, htpasswd — are one credential rather than three
# that merely look alike. The password never appears in this file: it is
# decrypted at runtime and compared in the machine.
run python3 -c "
import base64, hashlib, json, subprocess, sys

blob, secrets_json, data_json, htpasswd, user = sys.argv[1:6]
password = subprocess.run(
    ['systemd-creds', 'decrypt', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')

stored = json.load(open(data_json, encoding='utf-8'))
names = json.load(open(secrets_json, encoding='utf-8'))
if 'GUARDEN_BASICAUTH' not in names:
    sys.stderr.write('GUARDEN_BASICAUTH is not named in the store\n')
    sys.exit(1)
value = stored.get('GUARDEN_BASICAUTH')
if value is None:
    sys.stderr.write('the store names the key but carries no value for it\n')
    sys.exit(1)
if value != password:
    sys.stderr.write('the stored value is not the value the blob decrypts to\n')
    sys.exit(1)

name, found = open(htpasswd, encoding='utf-8').read().strip().split(':', 1)
expect = '{SHA}' + base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
if name != user or found != expect:
    sys.stderr.write('the htpasswd entry is not the same credential\n')
    sys.exit(1)
" "$blob" "$containers/storage/secrets/secrets.json" "$driver/secretsdata.json" \
  /var/lib/guarden/edge/basicauth/basapp-staging.htpasswd basapp-staging
assert_exit 0

# **And no verb prints the value.** `weedr secret list` is names and booleans
# (spec 6.2), and the credential path's whole boundary is that a value is
# never printed by anything. The value itself is read here from the blob, so
# the comparison is against the real one rather than a captured copy of it.
run weedr secret list basapp-staging
assert_exit 0
assert_stdout_has "GUARDEN_BASICAUTH"
run python3 -c "
import subprocess, sys
password = subprocess.run(
    ['systemd-creds', 'decrypt', sys.argv[1]],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')
printed = sys.argv[2]
if password and password in printed:
    sys.stderr.write('a verb printed the credential value\n')
    sys.exit(1)
" "$blob" "$GUARDEN_STDOUT"
assert_exit 0
