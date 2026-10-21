#!/usr/bin/env bash
# PROBE (throwaway): three facts the fix's shape and the suite's design need.
#
#   1. THE RACE MARGIN. With the watcher running, the credential arrived
#      "immediately" in an earlier probe — so the watcher's win is a margin,
#      not a guarantee. Measure the margin: when was the secret created, and
#      when did the ingest return?
#
#   2. IS THE WATCHER THE ONLY DELIVERY MECHANISM? Stop guarden-creds.path
#      (the only automatic trigger) and create a second service. If the value
#      never reaches the store, then the mint's own ask is the only thing
#      that can put it there, and stopping the watcher is what makes the
#      assertion deterministic instead of a race.
#
#   3. CONFIRM the materialiser is what carries it: with the watcher stopped,
#      start guarden-creds-boot.service by hand and see the value arrive.
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

seed_service() {
    local project=$1
    local app=$GUARDEN_PREFIX/var/lib/guarden/staging/$project/9f2c1ab
    mkdir -p "$app/.guarden/quadlet"
    seed "$app/.guarden/service.yml" "project: $project" "units: .guarden/quadlet/" \
        "routes:" "  - container: web" "    port: 8080" "    host: $project"
    seed "$app/.guarden/quadlet/web.container" "[Container]" \
        "Image=docker.io/library/nginx:1.27"
}

store_of() {
    printf '%s' "$GUARDEN_PREFIX/var/lib/guarden/services/$1/home/.local/share/containers/storage/secrets/secrets.json"
}

created_at() {
    python3 -c "
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
print(doc['secrets'][doc['nameToID']['GUARDEN_BASICAUTH']]['createdAt'])
" "$1" 2>/dev/null || echo none
}

# --- 1. the watcher running: what is the margin? ---------------------------
seed_service oneapp
printf 'PROBE t-ingest-start=%s\n' "$(date +%s.%N)"
run weedr service ingest oneapp-staging --from poke oneapp@9f2c1ab
printf 'PROBE t-ingest-end=%s\n' "$(date +%s.%N)"
assert_exit 0

one=$(store_of oneapp-staging)
printf 'PROBE one-created-at=%s\n' "$(created_at "$one")"
printf 'PROBE one-present-now=%s\n' \
    "$(grep -q GUARDEN_BASICAUTH "$one" 2>/dev/null && echo yes || echo no)"

# --- 2. the watcher stopped: is it the only delivery mechanism? ------------
printf 'PROBE stopping-watcher\n'
run systemctl stop guarden-creds.path
assert_exit 0
printf 'PROBE watcher-active=%s\n' "$(systemctl is-active guarden-creds.path 2>&1)"

seed_service twoapp
run weedr service ingest twoapp-staging --from poke twoapp@9f2c1ab
assert_exit 0

two=$(store_of twoapp-staging)
printf 'PROBE two-present-immediately=%s\n' \
    "$(grep -q GUARDEN_BASICAUTH "$two" 2>/dev/null && echo yes || echo no)"
sleep 15
printf 'PROBE two-present-after-15s=%s\n' \
    "$(grep -q GUARDEN_BASICAUTH "$two" 2>/dev/null && echo yes || echo no)"

# --- 3. the materialiser carries it, when somebody asks --------------------
printf 'PROBE starting-materialiser-by-hand\n'
run systemctl start guarden-creds-boot.service
assert_exit 0
printf 'PROBE two-present-after-manual=%s\n' \
    "$(grep -q GUARDEN_BASICAUTH "$two" 2>/dev/null && echo yes || echo no)"

# And what the render names, for the record.
printf 'PROBE rendered-unit-secrets:\n'
for f in "$GUARDEN_PREFIX/var/lib/guarden/services/oneapp-staging/home/.config/containers/systemd"/*.container; do
    [ -f "$f" ] || continue
    printf 'PROBE-UNIT-FILE %s\n' "$(basename "$f")"
    grep -c "Secret=" "$f" 2>/dev/null | sed 's/^/PROBE-UNIT Secret-count=/' || true
done
printf 'PROBE done\n'
