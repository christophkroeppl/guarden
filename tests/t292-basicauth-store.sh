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
# **What is asserted here is STATE, and it is asserted twice, because the two
# questions are different.** "Is the credential in the store NOW" and "is it in
# the store EVENTUALLY" are two claims about two mechanisms, and a suite that
# asked only one of them would pass for the wrong reason.
#
# **NOW — the mint asked the materialiser to run.** `basicauth.mint` plants the
# encrypted blob and then asks the credential materialiser to carry it into
# the service's own podman store, the way every other plant does: `weedr
# secret set` (spec 6.2: "encrypts into
# `/etc/guarden/creds/<name>/<KEY>.cred` mode `0600`, then asks the
# credential materialiser to run") and the interactive creator. The store is
# what the container's `Secret=` line resolves against, so a credential that
# is in the blob and not in the store is a credential nothing can use.
#
# **To tell "the mint asked" apart from "a watcher noticed", the watcher is
# stopped for this half.** `guarden-creds.path` watches `/etc/guarden/creds/`
# and starts `guarden-creds-boot.service` when the tree changes, and it fires
# on the blob's own write while the mutator is still working — measured, the
# credential was in the store BEFORE the ingest returned, so an assertion
# with the watcher running cannot tell the mint's ask from the watcher's
# timing. **With the watcher stopped, the mint's own ask is the ONLY thing
# that can deliver the value**, so an assertion with no wait at all is a
# claim about the mint and not about a race. Measured on the other side:
# with the watcher stopped, the value never arrived — not immediately, not
# after fifteen seconds, and only when `guarden-creds-boot.service` was
# started by hand.
#
# **EVENTUALLY — the watcher still delivers.** The second half starts the
# watcher again and asks a question the mint cannot answer: a credential
# planted by the gate's own generated-value path (`gate.mint_generated`,
# which plants and does NOT ask) reaches the same store, through the
# watcher, within a bounded wait. That is the path the `.path` unit exists
# for, and a regression in it is a regression nobody else would see.
#
# **What is asserted is STATE, not intent**: the podman store under the
# service's own home carries the key, and the value in it is the SAME value
# the encrypted blob decrypts to AND the same value the htpasswd entry the
# edge reads verifies against. All three halves are one credential, measured
# rather than assumed.
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

# **The precondition of the first half, stated rather than assumed.** The
# materialiser is what carries a blob into a store, and the half below says
# the mint asks it to run. A box whose `soil install` has not converged has no
# materialiser at all, and `ask_materialiser` warns and returns for that case
# rather than raising — so the suite says out loud that it is on a host where
# the unit exists, and the claim it makes is the one that holds there.
assert_file_exists /etc/systemd/system/guarden-creds-boot.service

# The gate module generates the policy; without it a service created now is
# grandfathered and holds no login at all.
run weedr module add gate-traefik
assert_exit 0
assert_file_exists /etc/guarden/edge/basicauth-policy

# --- the watcher is stopped, so the mint's own ask is the only delivery ------
#
# **Stopped, not masked, and the reason is the unit's own file.** `guarden-
# creds.path` is a real installed file at `/etc/systemd/system/`, and
# `systemctl mask` refuses to replace a real file with its own symlink to
# /dev/null: it answers "Failed to mask unit: File
# '/etc/systemd/system/guarden-creds.path' already exists" and exits 1. So
# the unit is stopped, and the stop is what the measurement rests on: the
# path unit is not a socket or a timer and nothing else starts it, so a
# stopped path unit watches nothing until something starts it again.
#
# **The boot oneshot is NOT affected by this.** `guarden-creds.path` and
# `guarden-creds-boot.service` are two separate units, and the boot oneshot
# is a plain `Type=oneshot` with no `[Install]` — the path unit's `Unit=`
# line is what triggers it, and that trigger is now silent. The oneshot can
# still be started, which is exactly what the mint's own ask does.
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

# **THE CLAIM, ASSERTED NOW.** No wait, no loop, no tolerance: the value is in
# the store at the moment the creation returned, because the mint asked the
# materialiser to run before it returned. The watcher is stopped, so nothing
# else could have put it there.
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
# **podman's file driver keys the data by the secret's ID, not by its name.**
# `secrets.json` is a NESTED document — `secrets: {<id>: {name: …}}` plus
# `nameToID` and `idToName` — and `secretsdata.json` is keyed by that same
# `<id>`. Looking the value up by the NAME therefore finds nothing for a
# secret that is present. The ID is taken from `nameToID` and the value is
# read under it, and it is compared both raw and base64-decoded, because
# whether the file driver encodes is podman's business and the property under
# test is that the store holds THIS credential.
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

# **A re-ingest never re-mints.** The first mint is the login, and a login
# that changed underneath an operator's stored credential is worse than no
# credential at all. The htpasswd entry is the visible half of that, and it is
# compared before and after.
htpasswd=/var/lib/guarden/edge/basicauth/basapp-staging.htpasswd
before=$(cat "$htpasswd")
run weedr service ingest basapp-staging --from poke basapp@9f2c1ab
assert_exit 0
after=$(cat "$htpasswd")
[ "$before" = "$after" ] \
    || _fail "a re-ingest re-minted the basic-auth login"

# --- and the watcher still delivers ------------------------------------------
#
# The second question: the credential in the store EVENTUALLY, by the path the
# `.path` unit exists for. The service here declares a schema, so the gate
# mints a generated value for its `@sensitive` key — and the gate's mint does
# NOT ask the materialiser, so that value can only arrive by the watcher.
run systemctl start guarden-creds.path
assert_exit 0

# **The manifest declares the volume the container mounts.** The quadlet-app
# container mounts a named volume `data`, and guarden refuses a manifest that
# does not declare a volume the container mounts: "the container 'web' mounts
# the named volume 'data', which the manifest declares in neither `state:`
# nor `bulk:`". A hand-written manifest grows that field by hand, which is
# the sort of thing a fixture exists to avoid, so the field is stated here
# and the rest of the manifest is the fixture's shape.
wapp=$GUARDEN_PREFIX/var/lib/guarden/staging/watchapp/9f2c1ab
mkdir -p "$wapp/.guarden/quadlet"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/.env.schema" \
   "$wapp/.guarden/.env.schema"
cp "$GUARDEN_ROOT/fixtures/projects/quadlet-app/.guarden/quadlet/web.container" \
   "$wapp/.guarden/quadlet/web.container"
seed "$wapp/.guarden/service.yml" "project: watchapp" "units: .guarden/quadlet/" \
    "schema: .guarden/.env.schema" \
    "state:" "  - data" \
    "routes:" "  - container: web" "    port: 8080" "    host: watch"
run weedr service ingest watchapp-staging --from poke watchapp@9f2c1ab
assert_exit 0

wcontainers=$GUARDEN_PREFIX/var/lib/guarden/services/watchapp-staging/home/.local/share/containers
wsecrets=$wcontainers/storage/secrets/secrets.json
wdriver=$wcontainers/storage/secrets/filedriver

# The bounded wait. DB_PASSWORD is `@sensitive` in the fixture's schema, so
# the gate minted a value for it, and the gate's mint does not ask — so the
# watcher is the only thing that can carry it into the store.
waited=0
while [ "$waited" -lt 60 ]; do
    if grep -q DB_PASSWORD "$wsecrets" 2>/dev/null; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done
grep -q DB_PASSWORD "$wsecrets" 2>/dev/null \
    || _fail "the watcher never carried DB_PASSWORD into $wsecrets after ${waited}s"
assert_file_exists "$wdriver/secretsdata.json"
# The NAME is in `secrets.json`; the DATA file is keyed by the secret's id, so
# the name is not in it and asserting it there would be the same wrong
# assertion twice.
assert_file_has "$wsecrets" "DB_PASSWORD"

# --- and no verb prints the value -------------------------------------------
#
# `weedr secret list` is names and booleans (spec 6.2), and the credential
# path's whole boundary is that a value is never printed by anything. The
# value itself is read here from the blob, so the comparison is against the
# real one rather than a captured copy of it.
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
