#!/usr/bin/env bash
# PROBE (throwaway): the properties, checked against the machine rather than
# against the source.
#
#   1. The minted value is in NO plaintext file: not in guarden's own tree,
#      not in the registry, not in a rendered unit, not in the htpasswd entry
#      (which carries the SHA-1, not the value).
#   2. The materialised secret lands in the service's OWN 0700 home, owned
#      by the service.
#   3. The value in the store is the SAME value the blob decrypts to, and the
#      htpasswd entry verifies against that same value.
#   4. A re-ingest never re-mints: the blob's bytes and the store's value are
#      unchanged after a second ingest.
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

app=$GUARDEN_PREFIX/var/lib/guarden/staging/basapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: basapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: bas"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"

# The watcher stopped, so the MINT is what carries the value.
run systemctl stop guarden-creds.path
assert_exit 0

run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0

blob=/etc/guarden/creds/basapp-staging/GUARDEN_BASICAUTH.cred
home=$GUARDEN_PREFIX/var/lib/guarden/services/basapp-staging/home
containers=$home/.local/share/containers
driver=$containers/storage/secrets/filedriver
secrets_json=$containers/storage/secrets/secrets.json
htpasswd=/var/lib/guarden/edge/basicauth/basapp-staging.htpasswd

# The value, read at runtime. It is never printed and never written.
value=$(run systemd-creds decrypt "$blob"; cat "$GUARDEN_STDOUT")
[ -n "$value" ] || _fail "the blob decrypts to nothing"

printf 'PROBE value-length=%s\n' "${#value}"

# **PROPERTY 1: the value is in no plaintext file of guarden's own tree.**
#
# The three roots guarden owns on a host are /etc/guarden, /var/lib/guarden
# and /usr/lib/guarden. The value is searched for in all three, and the
# store is the ONE place it is expected to be — base64-encoded inside the
# service's own 0700 home, which is the documented limit and not a boundary
# of its own. So the search names the store's own file and every other hit
# is a defect.
#
# The base64 of the value is the form podman's file driver keeps, so the
# encoded form is searched for too: a plaintext hit and an encoded hit are
# different questions and both matter.
encoded=$(printf '%s' "$value" | base64 -w0)
printf 'PROBE searching-for-the-plaintext-value\n'
plain=$(grep -rlF -- "$value" /etc/guarden /var/lib/guarden /usr/lib/guarden 2>/dev/null || true)
printf 'PROBE plaintext-hits=[%s]\n' "$(printf '%s' "$plain" | tr '\n' ' ')"

printf 'PROBE searching-for-the-encoded-value\n'
enc=$(grep -rlF -- "$encoded" /etc/guarden /var/lib/guarden /usr/lib/guarden 2>/dev/null || true)
printf 'PROBE encoded-hits=[%s]\n' "$(printf '%s' "$enc" | tr '\n' ' ')"

# **PROPERTY 2: the store is the service's own 0700 home, owned by it.**
printf 'PROBE home-mode-owner=%s\n' "$(stat -c '%a %U:%G' "$home")"
printf 'PROBE driver-mode-owner=%s\n' "$(stat -c '%a %U:%G' "$driver")"
printf 'PROBE secrets-json-owner=%s\n' "$(stat -c '%a %U:%G' "$secrets_json")"
printf 'PROBE htpasswd-mode-owner=%s\n' "$(stat -c '%a %U:%G' "$htpasswd")"
printf 'PROBE blob-mode-owner=%s\n' "$(stat -c '%a %U:%G' "$blob")"

# **PROPERTY 3: the store's value IS the blob's value, and the htpasswd entry
# verifies against that same value.**
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
    sys.stderr.write('not named\n'); sys.exit(1)
raw = json.load(open(data_json, encoding='utf-8')).get(ident)
if raw is None:
    sys.stderr.write('no value\n'); sys.exit(1)
candidates = {raw}
try:
    candidates.add(base64.b64decode(raw, validate=True).decode('utf-8'))
except Exception:
    pass
if password not in candidates:
    sys.stderr.write('store value != blob value\n'); sys.exit(1)
name, found = open(htpasswd, encoding='utf-8').read().strip().split(':', 1)
expect = '{SHA}' + base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
if name != user or found != expect:
    sys.stderr.write('htpasswd != the same credential\n'); sys.exit(1)
sys.stdout.write('all three halves are one credential\n')
" "$blob" "$secrets_json" "$driver/secretsdata.json" "$htpasswd" basapp-staging
assert_exit 0
printf 'PROBE three-halves=%s\n' "$(cat "$GUARDEN_STDOUT")"

# **PROPERTY 4: a re-ingest never re-mints.**
before_blob=$(sha256sum "$blob" | cut -d' ' -f1)
before_store=$(cat "$driver/secretsdata.json")
before_htpasswd=$(cat "$htpasswd")
run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0
after_blob=$(sha256sum "$blob" | cut -d' ' -f1)
after_store=$(cat "$driver/secretsdata.json")
after_htpasswd=$(cat "$htpasswd")
printf 'PROBE reingest-blob-same=%s\n' \
    "$([ "$before_blob" = "$after_blob" ] && echo yes || echo no)"
printf 'PROBE reingest-store-same=%s\n' \
    "$([ "$before_store" = "$after_store" ] && echo yes || echo no)"
printf 'PROBE reingest-htpasswd-same=%s\n' \
    "$([ "$before_htpasswd" = "$after_htpasswd" ] && echo yes || echo no)"

printf 'PROBE done\n'
