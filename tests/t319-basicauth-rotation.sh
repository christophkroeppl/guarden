#!/usr/bin/env bash
# t319-basicauth-rotation.sh — ticket 319: rotating the default basic-auth
# credential rewrites the htpasswd entry the edge reads.
#
# The defect this file exists for: `weedr secret set <name> GUARDEN_BASICAUTH`
# replaced the encrypted blob and the materialiser re-pushed the podman
# secret, but the edge does not read the blob — it reads the htpasswd entry
# `basicauth.mint` wrote at creation. So the login an operator had just
# rotated was not the one in front of the edge, and the two halves of one
# credential disagreed until somebody rewrote the entry by hand.
#
# What is asserted is state, and the entry is checked against a DECRYPT of the
# blob and against the value the operator typed — so "the credential and the
# login are the same value" is measured rather than assumed, and "the entry
# was written" is not the claim.
#
# **No value is checked in.** The value the mint wrote is read back out of the
# blob, and the value the operator rotates to is generated at runtime. Neither
# is a fixture, and neither reaches a file in this repository.
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

# The credential materialiser is NOT this suite's subject, and the boot
# oneshot materialises EVERY service's blobs — so a failure in it would be
# this suite reporting about something else. The units are moved aside the
# way `t60-secrets.sh` moves them, and `weedr secret set` then warns that the
# value is in the blob and not in the podman store. That warning is true and
# is not what this suite is about.
systemctl daemon-reload
for unit in guarden-creds.path guarden-creds-boot.service; do
    if [ -e "/etc/systemd/system/$unit" ]; then
        mv "/etc/systemd/system/$unit" "/etc/systemd/system/$unit.off"
    fi
done
systemctl daemon-reload

# Installing the gate generates the basic-auth policy, and from that moment
# every service created with `routes:` carries a login of its own.
run weedr module add gate-traefik
assert_exit 0
assert_stdout_has "basic auth policy"

app=$GUARDEN_PREFIX/var/lib/guarden/staging/rotapp/9f2c1ab
mkdir -p "$app/.guarden/quadlet"
seed "$app/.guarden/service.yml" "project: rotapp" "units: .guarden/quadlet/" \
    "routes:" "  - container: web" "    port: 8080" "    host: rot"
seed "$app/.guarden/quadlet/web.container" "[Container]" \
    "Image=docker.io/library/nginx:1.27"
run weedr service ingest rotapp-staging --from poke rotapp@9f2c1ab
assert_exit 0

entries=$GUARDEN_PREFIX/var/lib/guarden/edge/basicauth
entry=$entries/rotapp-staging.htpasswd
blob=/etc/guarden/creds/rotapp-staging/GUARDEN_BASICAUTH.cred

# The minted login is in both places, and the record says which services
# carry one.
assert_file_exists "$blob"
assert_file_exists "$entry"
assert_mode "$entry" 640
assert_owner "$entry" root:edge
assert_file_has "$GUARDEN_PREFIX/var/lib/guarden/registry/rotapp-staging.toml" \
    "basicauth = true"

# The value the mint wrote, read back OUT of the blob. It is never a
# fixture: it is the value this box minted, and it is on this box now.
OLD=$(systemd-creds decrypt --with-key=host "$blob")
[ -n "$OLD" ] || _fail "the minted basic-auth value did not come back out of the blob"

# The value the operator rotates TO, generated here and never written to a
# file: the substitution is a pipe, and the shell holds it.
NEW=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
[ -n "$NEW" ] || _fail "the rotated basic-auth value was not generated"

# --- the blast radius: an ordinary credential is unaffected ------------------
#
# `weedr secret set` is the general verb for EVERY credential and the hook
# sits in its path. A key no owner claims must therefore behave EXACTLY as
# before: the blob is written, the materialiser is asked, no owner is
# consulted and no entry is rewritten. This is the check that keeps the
# change from being a special case bolted onto a general verb.
#
# The service's own schema declares an ordinary key, and the service carries
# a login as well — so the owner list is consulted for this key and must
# decline it, on the key name alone.
PLAIN=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
run weedr secret set rotapp-staging LOG_LEVEL <<<"$PLAIN"
assert_exit 0
assert_stdout_has "planted LOG_LEVEL"
assert_stdout_lacks "$PLAIN"
plain_blob=/etc/guarden/creds/rotapp-staging/LOG_LEVEL.cred
assert_file_exists "$plain_blob"
run systemd-creds decrypt --with-key=host "$plain_blob"
assert_exit 0
assert_stdout_has "$PLAIN"
# And no entry was invented for it: the htpasswd directory holds one entry,
# for the one service that carries a login, and nothing else.
held=$(ls -A "$entries" | wc -l)
[ "$held" = 1 ] \
    || _fail "the htpasswd directory holds $held files, not the one entry"
assert_file_exists "$entry"

# --- the rotation ------------------------------------------------------------
#
# The ordinary root-side act. It reads the value with the terminal's echo
# off and encrypts it; nothing about it is special-cased for this key, which
# is the point: the act an operator already knows is the act that has to keep
# the two halves in step.
run weedr secret set rotapp-staging GUARDEN_BASICAUTH <<<"$NEW"
assert_exit 0
assert_stdout_has "planted GUARDEN_BASICAUTH"
# The value is not in what the verb said.
assert_stdout_lacks "$NEW"

# **The new entry verifies against the new blob.** The entry the edge would
# read is compared with a hash of the value the operator rotated to, and with
# the hash the product's own `basicauth.digest` produces, and the blob is
# decrypted to prove the two are the same value. The third comparison is the
# independent one: a test that checked the entry against the product's own
# digest alone could not tell a correct entry from a digest that was wrong in
# the same way twice.
run python3 -c "
import base64, hashlib, subprocess, sys
from guarden import basicauth
blob, path, user, password = sys.argv[1:5]
stored = subprocess.run(
    ['systemd-creds', 'decrypt', '--with-key=host', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')
name, found = open(path, encoding='utf-8').read().strip().split(':', 1)
expect = basicauth.digest(password)
independent = '{SHA}' + base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
ok = stored == password and name == user and found == expect and expect == independent
sys.exit(0 if ok else 1)
" "$blob" "$entry" rotapp-staging "$NEW"
assert_exit 0
echo "MEASURE: the entry verifies against the rotated value"

# **The old password stops working.** The entry is the new one, so the old
# value's hash is not in it.
run python3 -c "
import sys
from guarden import basicauth
path, old = sys.argv[1:3]
name, found = open(path, encoding='utf-8').read().strip().split(':', 1)
sys.exit(0 if found != basicauth.digest(old) else 1)
" "$entry" "$OLD"
assert_exit 0
echo "MEASURE: the old value no longer verifies against the entry"

# **The entry is replaced, not appended to.** One line, one login.
entries_held=$(grep -c ':' "$entry")
[ "$entries_held" = 1 ] \
    || _fail "the htpasswd entry holds $entries_held lines, not one"
run python3 -c "
import sys
from guarden import basicauth
path, old = sys.argv[1:3]
sys.exit(0 if basicauth.digest(old) not in open(path, encoding='utf-8').read() else 1)
" "$entry" "$OLD"
assert_exit 0

# **No value leaks.** `weedr secret list` prints names and booleans, the
# verb's own output carries no value, and the value is in no file of
# guarden's own footprint — the blob is ciphertext and the htpasswd entry
# is a hash of it.
run weedr secret list rotapp-staging
assert_exit 0
assert_stdout_has "GUARDEN_BASICAUTH"
assert_stdout_lacks "$NEW"

matches=$(grep -rl -- "$NEW" /etc/guarden /var/lib/guarden /usr/lib/guarden 2>/dev/null || true)
[ -z "$matches" ] || {
    printf 'the rotated value is in:\n%s\n' "$matches" >&2
    exit 1
}
echo "MEASURE: the rotated value is in no file of guarden's footprint"

# --- a rotation that fails --------------------------------------------------
#
# **The failure property is part of the ticket.** A rotation that cannot write
# the entry must be loud, must name the service, and must not leave one half
# of the credential advanced and the other behind — so the value the operator
# typed is not half in force.
#
# The entries directory is made immutable, which is a real answer from the
# machine: even root cannot write into it. The rotation therefore cannot
# write the entry, and the two halves would disagree if the act did not put
# the blob back.
NEWER=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
chattr +i "$entries"
run weedr secret set rotapp-staging GUARDEN_BASICAUTH <<<"$NEWER"
assert_exit 1
# One line, and it names the service: an operator told only that the verb
# failed would not know which credential is out of step.
assert_one_diagnostic "error:"
assert_stderr_has "rotapp-staging"
chattr -i "$entries"

# **Neither half advanced.** The blob is back to the value that was in front
# of the edge, and the entry still verifies that same value — so the service
# is not half-rotated, and the value the operator typed the second time never
# reached the host at all.
run python3 -c "
import subprocess, sys
from guarden import basicauth
blob, path, user, password = sys.argv[1:5]
stored = subprocess.run(
    ['systemd-creds', 'decrypt', '--with-key=host', blob],
    capture_output=True, text=True, check=True,
).stdout.rstrip('\n')
name, found = open(path, encoding='utf-8').read().strip().split(':', 1)
ok = stored == password and name == user and found == basicauth.digest(password)
sys.exit(0 if ok else 1)
" "$blob" "$entry" rotapp-staging "$NEW"
assert_exit 0
echo "MEASURE: the failed rotation left the blob and the entry in step"

matches=$(grep -rl -- "$NEWER" /etc/guarden /var/lib/guarden /usr/lib/guarden 2>/dev/null || true)
[ -z "$matches" ] || {
    printf 'the value of the failed rotation is in:\n%s\n' "$matches" >&2
    exit 1
}
