#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$WORK/project/widgets"
cat > "$WORK/project/compose.yaml" <<'EOF'
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
cat > "$WORK/project/bed.yaml" <<'EOF'
pond:
  databases: ["app"]
hyphae:
  aliases: ["nutristack.internal"]
repo: "https://github.com/example/nutristack"
EOF
cat > "$WORK/project/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
APP_SECRET= @required @sensitive @example EXAMPLE-secret
OPS_KEY=changeme @required
PORT=3000 @type number
EOF
cat > "$WORK/project/widgets/api.yml" <<'EOF'
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cat > "$WORK/project/widgets/web.yml" <<'EOF'
description: Nutristack Web
href: "https://${env}.${domain}"
icon: mdi-web
EOF

PROJECT="$WORK/project"
EDGE="$GUARDEN_STATE/edge"
TWIG_OUT="$GUARDEN_STATE/twig/services.yaml"
HOSTS="$GUARDEN_STATE/hosts"
PINS="$GUARDEN_STATE/stakes/pins"

mkdir -p "$GUARDEN_STATE/pond"
echo "snap-42" > "$GUARDEN_STATE/pond/snapshot"

assert_exit 0 pond up
assert_exit 0 weedr bed new nutristack --env production --from "$PROJECT"
assert_exit 0 weedr pond mint nutristack-production
PROD_LOCAL="$GUARDEN_STATE/homes/bed-nutristack-production/.env.production.local"
prod_url="$(grep '^DATABASE_URL=' "$PROD_LOCAL" | cut -d= -f2-)"

: > "$GUARDEN_CALL_LOG"
out="$(weedr preview new nutristack --ref feat-1 --from "$PROJECT" 2>&1)" || got=$?
if [ "${got:-0}" -ne 0 ]; then
  echo "assert_exit: want=0 got=${got:-0}: weedr preview new feat-1"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "warning: gate issues" <<< "$out"; then
  echo "assert: preview create must warn only on prod gate"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
assert_call_log_has "pg_dump"
assert_call_log_has "pond-prod"
assert_call_log_has "nutristack_production"
assert_call_log_has "pond-nonprod"
assert_call_log_has "CREATE ROLE"
assert_call_log_has "REASSIGN OWNED BY"
assert_call_log_has "systemctl --user start"

assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-1/meta"
PREV_LOCAL="$GUARDEN_STATE/homes/bed-nutristack-preview-feat-1/.env.preview-feat-1.local"
assert_file "$PREV_LOCAL"
assert_output_has "DATABASE_URL=postgres://" cat "$PREV_LOCAL"
prev_url="$(grep '^DATABASE_URL=' "$PREV_LOCAL" | cut -d= -f2-)"
if [ "$prev_url" = "$prod_url" ]; then
  echo "assert: production credential must never be reused"
  failures=$((failures + 1))
fi
assert_file "$EDGE/nutristack-preview-feat-1.yml"
assert_output_has 'Host(`preview.example.com`)' cat "$EDGE/nutristack-preview-feat-1.yml"
assert_output_has 'PathPrefix(`/feat-1`)' cat "$EDGE/nutristack-preview-feat-1.yml"
assert_file "$TWIG_OUT"
assert_output_has "Nutristack API" cat "$TWIG_OUT"
assert_output_has "Nutristack Web" cat "$TWIG_OUT"
assert_output_has "bed-nutristack-preview-feat-1.internal" cat "$HOSTS"
assert_output_has "nutristack.internal" cat "$HOSTS"
assert_output_has "holders=1" stakes query snap-42
assert_file "$PINS"

assert_exit 0 weedr preview new nutristack --ref feat-2 --from "$PROJECT"
assert_output_has "holders=2" stakes query snap-42

: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr preview drop nutristack --ref feat-1
assert_call_log_has "systemctl --user stop"
assert_call_log_has "DROP DATABASE"
assert_call_log_has "DROP ROLE"
assert_call_log_has "userdel"
assert_call_log_has "volume rm"
assert_output_has "holders=1" stakes query snap-42
assert_output_has "snap-42" cat "$PINS"
assert_no_file "$GUARDEN_STATE/beds/nutristack-preview-feat-1"
assert_no_file "$GUARDEN_STATE/homes/bed-nutristack-preview-feat-1"
if grep -q "bed-nutristack-preview-feat-1.internal" "$HOSTS" 2>/dev/null; then
  echo "assert: hyphae name should be freed"
  failures=$((failures + 1))
fi
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-2"

assert_exit 0 weedr preview new nutristack --ref develop --from "$PROJECT"
assert_file "$GUARDEN_STATE/beds/nutristack-staging/meta"
assert_file "$EDGE/nutristack-staging.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$EDGE/nutristack-staging.yml"

assert_exit 0 weedr preview new nutristack --ref feat-3 --from "$PROJECT"
assert_exit 0 weedr preview new nutristack --ref feat-4 --from "$PROJECT"
assert_exit 0 weedr preview new nutristack --ref feat-5 --from "$PROJECT"
assert_no_file "$GUARDEN_STATE/beds/nutristack-preview-feat-2"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-3"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-4"
assert_file "$GUARDEN_STATE/beds/nutristack-preview-feat-5"
assert_file "$GUARDEN_STATE/beds/nutristack-staging"

assert_exit 0 weedr preview drop nutristack --ref feat-5
assert_no_file "$GUARDEN_STATE/beds/nutristack-preview-feat-5"
assert_exit 1 weedr preview drop nutristack --ref feat-5

finish
