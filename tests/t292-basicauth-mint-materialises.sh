#!/usr/bin/env bash
# t292-basicauth-mint-materialises.sh — ticket 292, the property the store
# assertion alone does not measure: **the mint carries the credential into the
# service's own podman store, and it does not depend on the watcher to do it.**
#
# `tests/t292-basicauth-store.sh` asserts that the credential IS in the
# service's store. That assertion is green on the current tree WITHOUT any
# product change, because `guarden-creds.path` watches `/etc/guarden/creds/`
# and starts `guarden-creds-boot.service` the moment `basicauth.mint` writes
# the blob — and the watcher usually wins the race, so the value is in the
# store before the ingest even returns (measured at 0s).
#
# **A green assertion that holds because of a timing win is not the property
# the ticket asks for.** The ticket's bullet is "the value reaches the
# service's own podman store", and the blob alone is not enough, because the
# container resolves `Secret=` against that store and not against the blob.
# A delivery that depends on a watcher firing is a delivery that depends on
# the watcher being alive.
#
# So this suite stops the watcher, and then asks the question directly: with
# the path unit unable to deliver, does the minted credential reach the
# service's own store anyway?
#
# With the fix (the mint asks the materialiser to run, the way `weedr secret
# set` and the interactive creator do) the answer is YES, because the mint
# itself starts `guarden-creds-boot.service`.
# WITHOUT the fix the answer is NO — the blob is written, the htpasswd entry
# is written, and the store holds nothing until the next boot — and this
# suite goes RED naming the missing credential.
#
# That is the difference between this suite and the store assertion: the
# store assertion passes on the timing, and this one passes on the product.
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
# only thing that can carry a value into a store.
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_not_rejected

# The gate module generates the policy; without it a service created now is
# grandfathered and holds no login at all.
run weedr module add gate-traefik
assert_exit 0
assert_file_exists /etc/guarden/edge/basicauth-policy

# **THE REMOVAL.** The watcher is the only automatic trigger, so stopping it
# takes away the delivery that hides the question. Everything else is
# untouched: the boot oneshot is still installed, and the mint can still
# start it.
run systemctl stop guarden-creds.path
assert_exit 0
assert_inactive guarden-creds.path

# **When the materialiser last ran**, so the end of the suite can tell
# whether the CREATION started it. `soil install` enables the boot oneshot
# and starts the path unit, so the unit may already have run once by the
# time the tree is built; what matters is that it runs AGAIN, during the
# creation below.
before=$(systemctl show guarden-creds-boot.service --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)

app=$GUARDEN_PREFIX/var/lib/guarden/staging/basapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: basapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: bas"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0

# The blob is written either way: the mint plants it before it asks.
blob=/etc/guarden/creds/basapp-staging/GUARDEN_BASICAUTH.cred
assert_file_exists "$blob"
assert_mode "$blob" 600

# **THE CLAIM.** The credential is in the SERVICE'S OWN podman store, under
# that service's `0700` home — with the watcher unable to deliver it.
#
# podman's `file` secret driver keeps each value base64-encoded in
# `.../storage/secrets/filedriver/secretsdata.json` and the names in
# `.../storage/secrets/secrets.json`. The encoding is not protection; the
# `0700` on the home is. `t60-secrets.sh` measures the same shape for a
# DB_PASSWORD, so this is the same measurement for the basic-auth login.
home=$GUARDEN_PREFIX/var/lib/guarden/services/basapp-staging/home
assert_mode "$home" 700
containers=$home/.local/share/containers
driver=$containers/storage/secrets/filedriver
secrets_json=$containers/storage/secrets/secrets.json

# **No wait.** The point of this suite is that the value is there when the
# creation returns, so a wait would hide exactly the defect it exists to
# catch.
#
# The KEY is asserted first, and before the file's existence: a store that
# does not exist at all is the same defect as a store that does not name the
# key, and the diagnostic that names the credential is the useful one.
assert_file_has "$secrets_json" "GUARDEN_BASICAUTH"
assert_file_exists "$secrets_json"
assert_file_exists "$driver/secretsdata.json"
assert_mode "$driver" 700
assert_owner "$driver" basapp-staging:basapp-staging

# **And the value in the store is the SAME value the blob decrypts to.** The
# htpasswd entry the edge reads is checked against the same password, so all
# three halves — blob, store, htpasswd — are one credential rather than three
# that merely look alike. The password never appears in this file: it is
# decrypted at runtime and compared in the machine.
#
# **podman's file driver keys the data by the secret's ID, not by its name.**
# `secrets.json` is a NESTED document — `secrets: {<id>: {name: …}}` plus
# `nameToID` and `idToName` — and `secretsdata.json` is keyed by that same
# `<id>`. The ID is taken from `nameToID` and the value is read under it.
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

# **And the CREATION is what carried it.** The watcher was stopped for the
# whole of this suite, so the only thing that could have started
# `guarden-creds-boot.service` between the two reads above is the mint.
after=$(systemctl show guarden-creds-boot.service --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || true)
[ "$before" != "$after" ] \
    || _fail "the materialiser did not run during the creation, so the credential reached the store by something other than the mint"
