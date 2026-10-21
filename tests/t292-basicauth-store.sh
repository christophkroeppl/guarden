#!/usr/bin/env bash
# t292-basicauth-store.sh — ticket 292, the half of the acceptance set that
# nothing asserted: the minted basic-auth credential reaches the SERVICE'S OWN
# podman store, under that service's `0700` home.
#
# t450-basicauth.sh asserts the blob on disk, the htpasswd entry, the route
# slice, the registry flag and the edge's rendered middleware. Every one of
# those is a file on the host. None of them is the credential in the store the
# container reads.
#
# **How the value gets there is the thing worth stating, and it was measured
# rather than assumed.** `basicauth.mint` calls `credentials.plant`, which
# writes the encrypted blob; it does NOT call `credentials.ask_materialiser`.
# The value reaches the store because `guarden-creds.path` watches
# `/etc/guarden/creds/` for a change and starts `guarden-creds-boot.service`,
# which materialises every blob into its own service's podman store. So the
# credential arrives ASYNCHRONOUSLY after the ingest, and this suite waits for
# it rather than asserting the instant the ingest returns.
#
# That wait is not politeness: an assertion that reads the store the moment
# the ingest returns is racing a unit that has not run yet, and it is green or
# red depending on how fast the machine was. The first version of this file
# asserted instantly and went red with "GUARDEN_BASICAUTH is not named in the
# store" — and the probe that followed found the secret PRESENT, which is how
# the race was told apart from a missing credential.
#
# What is asserted here is STATE: the podman store under the service's own
# home carries the key, and the value in it is the SAME value the encrypted
# blob decrypts to AND the same value the htpasswd entry the edge reads
# verifies against. All three halves are one credential, measured rather than
# assumed.
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

# The service's own home is the limit the credential is confined to (spec 6.2):
# `0700`, owned by the service itself, so nothing but that uid reaches it.
home=$GUARDEN_PREFIX/var/lib/guarden/services/basapp-staging/home
assert_mode "$home" 700

containers=$home/.local/share/containers
driver=$containers/storage/secrets/filedriver
secrets_json=$containers/storage/secrets/secrets.json

# **THE WAIT.** The credential arrives when the path watcher fires, so the
# store is read in a loop until it carries the key. The bound is generous
# because the trigger is a systemd unit on a busy machine; the failure says
# what was missing rather than only that it was missing.
waited=0
while [ "$waited" -lt 60 ]; do
    if grep -q GUARDEN_BASICAUTH "$secrets_json" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
grep -q GUARDEN_BASICAUTH "$secrets_json" 2>/dev/null \
    || _fail "the credential never reached $secrets_json after ${waited}s"

# **THE CLAIM.** The credential is in the SERVICE'S OWN podman store, under that
# service's home — the `0700` tree that is the documented limit (spec 6.2).
#
# podman's `file` secret driver keeps each value base64-encoded in
# `.../storage/secrets/filedriver/secretsdata.json` and the names in
# `.../storage/secrets/secrets.json`. The encoding is not protection; the
# `0700` on the home is. `t60-secrets.sh` measures the same shape for a
# DB_PASSWORD, so this is the same measurement for the basic-auth login.
assert_file_exists "$driver/secretsdata.json"
assert_mode "$driver" 700
assert_owner "$driver" basapp-staging:basapp-staging
assert_file_has "$secrets_json" "GUARDEN_BASICAUTH"

# **And the value in the store is the SAME value the blob decrypts to.** The
# htpasswd entry the edge reads is checked against the same password, so all
# three halves — blob, store, htpasswd — are one credential rather than three
# that merely look alike. The password never appears in this file: it is
# decrypted at runtime and compared in the machine.
#
# podman's `secretsdata.json` holds the value base64-encoded, and
# `secrets.json` names the keys in a NESTED document (`nameToID` /
# `idToName`), not a flat list — which is what the first version of this
# assertion got wrong, and the reason it reported a missing key for a key
# that was there.
run python3 -c "
import base64, hashlib, json, subprocess, sys

blob, secrets_json, data_json, htpasswd, user = sys.argv[1:6]
password = subprocess.run(
    ['systemd-creds', 'decrypt', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')

names = json.load(open(secrets_json, encoding='utf-8'))
if 'GUARDEN_BASICAUTH' not in names.get('nameToID', {}):
    sys.stderr.write('GUARDEN_BASICAUTH is not named in the store\n')
    sys.exit(1)

stored = json.load(open(data_json, encoding='utf-8'))
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
" "$blob" "$secrets_json" "$driver/secretsdata.json" \
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
