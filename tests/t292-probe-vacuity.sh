#!/usr/bin/env bash
# PROBE (throwaway): the VACUITY proof for t292-basicauth-store.sh.
#
# The suite is green. A green suite proves nothing until it has been seen to
# FAIL for the reason it claims to test. The property under test is "the
# minted credential reaches the service's own podman store".
#
# So this probe removes the state that makes the property true — the
# `guarden-creds.path` watcher, which is what carries the blob into the store
# once `basicauth.mint` writes it — and leaves every assertion of the real
# suite exactly as it is. The suite must go RED naming the missing credential.
#
# If this probe is GREEN, the real suite is vacuous.
#
# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release

run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

run weedr module add gate-traefik
assert_exit 0

# **THE REMOVAL.** The watcher is stopped after the install converged it, so
# nothing carries the blob into the service's store. Everything else is
# untouched, and the ingest below is the real one.
#
# **Stopped, not masked.** `guarden-creds.path` is a real installed file, and
# `systemctl mask` refuses to replace a real file with a symlink to
# /dev/null — it answers "Failed to mask unit: File
# '/etc/systemd/system/guarden-creds.path' already exists" and exits 1. The
# stop is what the measurement rests on: the path unit watches nothing until
# something starts it again, and the boot oneshot it triggers is a separate
# unit that the mint's own ask can still start.
run systemctl stop guarden-creds.path
assert_exit 0
assert_inactive guarden-creds.path

app=$GUARDEN_PREFIX/var/lib/guarden/staging/basapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: basapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: bas"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0

blob=/etc/guarden/creds/basapp-staging/GUARDEN_BASICAUTH.cred
assert_file_exists "$blob"

home=$GUARDEN_PREFIX/var/lib/guarden/services/basapp-staging/home
containers=$home/.local/share/containers
driver=$containers/storage/secrets/filedriver
secrets_json=$containers/storage/secrets/secrets.json

# The wait, verbatim from the real suite.
waited=0
while [ "$waited" -lt 20 ]; do
    if grep -q GUARDEN_BASICAUTH "$secrets_json" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
grep -q GUARDEN_BASICAUTH "$secrets_json" 2>/dev/null \
    || _fail "the credential never reached $secrets_json after ${waited}s"

assert_file_exists "$driver/secretsdata.json"
assert_mode "$driver" 700
assert_owner "$driver" basapp-staging:basapp-staging
assert_file_has "$secrets_json" "GUARDEN_BASICAUTH"

run python3 -c "
import base64, hashlib, json, subprocess, sys

blob, secrets_json, data_json, htpasswd, user = sys.argv[1:6]
password = subprocess.run(
    ['systemd-creds', 'decrypt', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')

names = json.load(open(secrets_json, encoding='utf-8'))
ident = names.get('nameToID', {}).get('GUARDEN_BASICAUTH')
if ident is None:
    sys.stderr.write('GUARDEN_BASICAUTH is not named in the store\n')
    sys.exit(1)

stored = json.load(open(data_json, encoding='utf-8'))
raw = stored.get(ident)
if raw is None:
    sys.stderr.write(
        'the store names the key as %s but carries no value under that id; '
        'it holds %s\n' % (ident, sorted(stored))
    )
    sys.exit(1)

candidates = {raw}
try:
    candidates.add(base64.b64decode(raw, validate=True).decode('utf-8'))
except Exception:
    pass
if password not in candidates:
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
