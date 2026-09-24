#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EDGE="$GUARDEN_STATE/edge"
HOSTS="$GUARDEN_STATE/hosts"

mkdir -p "$WORK/seed/widgets"
cat > "$WORK/seed/compose.yaml" <<'EOF'
services:
  api:
    image: example/nutristack-api:v1
    ports:
      - "8081:80"
  web:
    image: example/nutristack-web:v1
    ports:
      - "8080:80"

volumes:
  data:
EOF
cat > "$WORK/seed/bed.yaml" <<'EOF'
pond:
  databases: ["app"]
hyphae:
  aliases: ["nutristack.internal"]
repo: "https://github.com/example/nutristack"
EOF
cat > "$WORK/seed/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
APP_SECRET= @required @sensitive @example EXAMPLE-secret
PORT=3000 @type number
EOF
cat > "$WORK/seed/widgets/api.yml" <<'EOF'
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cat > "$WORK/seed/widgets/web.yml" <<'EOF'
description: Nutristack Web
href: "https://${env}.${domain}"
icon: mdi-web
EOF

mkdir -p "$WORK/repo/widgets"
cp "$WORK/seed/compose.yaml" "$WORK/repo/compose.yaml"
cp "$WORK/seed/bed.yaml" "$WORK/repo/bed.yaml"
cp "$WORK/seed/.env.schema" "$WORK/repo/.env.schema"
cp "$WORK/seed/widgets/api.yml" "$WORK/repo/widgets/api.yml"
cp "$WORK/seed/widgets/web.yml" "$WORK/repo/widgets/web.yml"

git -C "$WORK/repo" init
git -C "$WORK/repo" config user.email hose@test
git -C "$WORK/repo" config user.name hose
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit -m init
git -C "$WORK/repo" branch develop
git -C "$WORK/repo" branch feat-1
git -C "$WORK/repo" branch feat-2

printf 'nutristack %s\n' "$WORK/repo" > "$WORK/ops"

mkdir -p "$GUARDEN_STATE/pond"
echo "snap-7" > "$GUARDEN_STATE/pond/snapshot"
assert_exit 0 pond up
assert_exit 0 weedr bed new nutristack --env production --from "$WORK/seed"
assert_exit 0 weedr pond mint nutristack-production

assert_exit 1 hose sync --ops "$WORK/nope"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose sync --ops "$WORK/ops"
assert_call_log_has "git -C"
assert_call_log_has "sudo weedr preview new nutristack --ref feat-1"
assert_call_log_has "sudo weedr preview new nutristack --ref feat-2"
assert_call_log_has "sudo weedr preview new nutristack --ref develop"
assert_call_log_lacks "sudo git"
assert_call_log_lacks "sudo [^w]"
assert_call_log_lacks "runuser -u root"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-1/meta"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-2/meta"
assert_file "$GUARDEN_STATE/beds/nutristack-staging/meta"
assert_file "$EDGE/nutristack-preview-feat-1.yml"
assert_file "$EDGE/nutristack-staging.yml"

SUDOERS="$GUARDEN_SYSROOT/etc/sudoers.d/hose-weedr"
assert_file "$SUDOERS"
assert_output_has "weedr" cat "$SUDOERS"
bad="$(grep -v "weedr" "$SUDOERS" | grep -v '^#' | grep -v '^$' || true)"
if [ -n "$bad" ]; then
  echo "assert: sudoers rule must only allow weedr"
  printf '  | %s\n' "$bad"
  failures=$((failures + 1))
fi

git -C "$WORK/repo" checkout develop
sed -i 's|nutristack-api:v1|nutristack-api:v2|' "$WORK/repo/compose.yaml"
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit -m api-v2

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose sync --ops "$WORK/ops"
assert_call_log_has "sudo weedr redeploy nutristack-staging"
assert_call_log_has "systemctl --user stop api.service"
assert_call_log_has "systemctl --user start api.service"
assert_call_log_lacks "web.service"
assert_call_log_lacks "redeploy nutristack-preview-feat-1"
assert_call_log_lacks "redeploy nutristack-preview-feat-2"
assert_call_log_lacks "sudo [^w]"

git -C "$WORK/repo" checkout develop
git -C "$WORK/repo" branch -D feat-1

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose sync --ops "$WORK/ops"
assert_call_log_has "sudo weedr preview drop nutristack --ref feat-1"
assert_no_file "$GUARDEN_STATE/beds/nutristack-preview-feat-1"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-2"
assert_file "$GUARDEN_STATE/beds/nutristack-staging"

sed -i 's|nutristack-api:v2|nutristack-api:v3|' "$WORK/repo/compose.yaml"
sed -i 's|"8081:80"|"9091:80"|' "$WORK/repo/compose.yaml"
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit -m api-v3-fails

export GUARDEN_FAIL_UNIT=api.service
: > "$GUARDEN_CALL_LOG"
assert_exit 1 weedr redeploy nutristack-staging --from "$WORK/repo"
unset GUARDEN_FAIL_UNIT
assert_call_log_has "systemctl --user start api.service"
assert_output_has "8081" cat "$EDGE/nutristack-staging.yml"
if grep -q "9091" "$EDGE/nutristack-staging.yml" 2>/dev/null; then
  echo "assert: old route target must be unchanged after failed migration"
  failures=$((failures + 1))
fi

: > "$GUARDEN_CALL_LOG"
assert_exit 2 weedr redeploy nutristack-production --from "$WORK/seed"
assert_output_has "refusing to redeploy production" weedr redeploy nutristack-production --from "$WORK/seed"
assert_exit 0 weedr redeploy nutristack-production --from "$WORK/seed" --yes

finish
