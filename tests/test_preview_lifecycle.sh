#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$WORK/project"
BARE="$WORK/bare"
EMPTY="$WORK/empty"
NOSCHEMA="$WORK/noschema"
BEDS="$GUARDEN_STATE/beds"
HOMES="$GUARDEN_STATE/homes"
PONDS="$GUARDEN_STATE/ponds"
HOSTS="$GUARDEN_STATE/hosts"
ROOTS="$GUARDEN_SYSROOT/var/lib/roots/dynamic"
TWIG_OUT="$GUARDEN_STATE/twig/services.yaml"
FIFO="$GUARDEN_STATE/previews/nutristack"
PINS="$GUARDEN_STATE/stakes/pins"

mkdir -p "$PROJECT/.guarden/widgets"
cat > "$PROJECT/compose.yaml" <<'EOF'
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
cat > "$PROJECT/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
pond:
  databases:
    app:
      roles:
        - name: app
          grants: ["ALL"]
hyphae:
  aliases: ["nutristack.internal"]
repo: "https://github.com/example/nutristack"
EOF
cat > "$PROJECT/.guarden/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
APP_SECRET= @required @sensitive @example EXAMPLE-secret
OPS_KEY=changeme @required
PORT=3000 @type number
EOF
cat > "$PROJECT/.guarden/widgets/api.yml" <<'EOF'
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cat > "$PROJECT/.guarden/widgets/web.yml" <<'EOF'
description: Nutristack Web
href: "https://${env}.${domain}"
icon: mdi-web
EOF

mkdir -p "$BARE/.guarden"
cat > "$BARE/compose.yaml" <<'EOF'
services:
  api:
    image: example/bare-api:v1
    ports:
      - "8081:80"
EOF
cat > "$BARE/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
pond:
  databases:
    app:
      roles:
        - name: app
          grants: ["ALL"]
EOF
cat > "$BARE/.guarden/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
PORT=3000 @type number
EOF

mkdir -p "$EMPTY/.guarden"
cat > "$EMPTY/compose.yaml" <<'EOF'
services:
  api:
    image: example/empty-api:v1
    ports:
      - "8081:80"
EOF
cat > "$EMPTY/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
EOF
cat > "$EMPTY/.guarden/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
PORT=3000 @type number
EOF

mkdir -p "$GUARDEN_STATE/pond"
echo "snap-42" > "$GUARDEN_STATE/pond/snapshot"

assert_output_has "dug pond: pond-production-postgres" weedr pond dig pond-production-postgres
assert_output_has "dug pond: pond-staging-postgres" weedr pond dig pond-staging-postgres

: > "$GUARDEN_CALL_LOG"
assert_output_has "created bed: bed-production-nutristack" weedr bed plow nutristack --env production --from "$PROJECT" -p pond-production-postgres
assert_call_log_lacks "pg_dump"
assert_call_log_lacks "REASSIGN"
if grep -q '^snapshot=' "$BEDS/bed-production-nutristack/meta"; then
  echo "assert: production must start with an empty database, never forked"
  failures=$((failures + 1))
fi
assert_output_has "ponddb=app_bed_production_nutristack" cat "$BEDS/bed-production-nutristack/meta"
PROD_LOCAL="$HOMES/bed-production-nutristack/.env.production.local"
assert_file "$PROD_LOCAL"
prod_url="$(sed -n 's/^DATABASE_URL=//p' "$PROD_LOCAL")"
prod_password="$(sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p' "$PROD_LOCAL")"
assert_exit 0 weedr bed plow nutristack --env staging --from "$PROJECT" -p pond-staging-postgres

: > "$GUARDEN_CALL_LOG"
got=0
out="$(weedr preview new nutristack --ref feat-1 --from "$PROJECT" 2>&1)" || got=$?
if [ "$got" -ne 0 ]; then
  echo "assert_exit: want=0 got=$got: weedr preview new feat-1"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "warning: gate issues" <<< "$out"; then
  echo "assert: preview create must warn only on the prod gate"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "created preview: bed-preview-nutristack/feat-1" <<< "$out"; then
  echo "assert: missing created preview line"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi

assert_call_log_has "exec pond-production-postgres pg_dump"
assert_call_log_has "app_bed_production_nutristack"
assert_call_log_has "CREATE ROLE"
assert_call_log_has "REASSIGN OWNED BY"
assert_call_log_has "api-feat-1.service"

assert_file "$BEDS/bed-preview-nutristack/feat-1/meta"
assert_output_has "snapshot=snap-42" cat "$BEDS/bed-preview-nutristack/feat-1/meta"
assert_output_has "pond=pond-staging-postgres" cat "$BEDS/bed-preview-nutristack/feat-1/meta"
assert_output_has "ponddb=app_bed_preview_nutristack_feat_1" cat "$BEDS/bed-preview-nutristack/feat-1/meta"

PREV_LOCAL="$HOMES/bed-preview-nutristack/feat-1/.env.preview.local"
assert_file "$PREV_LOCAL"
assert_file "$HOMES/bed-preview-nutristack/.env"
assert_output_has "DATABASE_URL=postgres://" cat "$PREV_LOCAL"
assert_output_has "@pond-staging-postgres.internal:5432/" cat "$PREV_LOCAL"
assert_output_has "app_bed_preview_nutristack_feat_1:" cat "$PREV_LOCAL"
prev_url="$(sed -n 's/^DATABASE_URL=//p' "$PREV_LOCAL")"
if [ -z "$prev_url" ] || [ "$prev_url" = "$prod_url" ]; then
  echo "assert: production credential must never be reused"
  failures=$((failures + 1))
fi
if [ -n "$prod_password" ] && grep -qF "$prod_password" "$PREV_LOCAL"; then
  echo "assert: production password must never appear in the preview credential"
  failures=$((failures + 1))
fi

assert_file "$HOMES/bed-preview-nutristack/.config/containers/systemd/api-feat-1.container"
assert_file "$HOMES/bed-preview-nutristack/.config/containers/systemd/web-feat-1.container"
assert_file "$HOMES/bed-preview-nutristack/.config/containers/systemd/api-feat-1.container.d/bed.env"
assert_output_has "EnvironmentFile=%h/feat-1/.env" cat "$HOMES/bed-preview-nutristack/.config/containers/systemd/api-feat-1.container.d/bed.env"

assert_file "$ROOTS/bed-preview-nutristack.yml"
assert_output_has 'Host(`preview.example.com`)' cat "$ROOTS/bed-preview-nutristack.yml"
assert_output_has 'PathPrefix(`/feat-1`)' cat "$ROOTS/bed-preview-nutristack.yml"
assert_file "$TWIG_OUT"
assert_output_has "Nutristack API" cat "$TWIG_OUT"
assert_output_has "Nutristack Web" cat "$TWIG_OUT"
assert_output_has "bed-preview-nutristack.internal" cat "$HOSTS"
assert_output_has "nutristack.internal" cat "$HOSTS"
assert_output_has "holders=1 bed-preview-nutristack/feat-1" stakes query snap-42
assert_file "$PINS"
assert_file "$FIFO"

assert_exit 0 weedr preview new nutristack --ref feat-2 --from "$PROJECT"
assert_output_has "holders=2" stakes query snap-42

: > "$GUARDEN_CALL_LOG"
assert_output_has "dropped preview: bed-preview-nutristack/feat-1" weedr preview drop nutristack --ref feat-1
assert_call_log_has "systemctl --user stop"
assert_call_log_has "DROP DATABASE"
assert_call_log_has "DROP ROLE"
assert_call_log_lacks "userdel"
assert_output_has "holders=1" stakes query snap-42
assert_output_has "bed-preview-nutristack/feat-2" stakes query snap-42
assert_no_file "$BEDS/bed-preview-nutristack/feat-1"
assert_no_file "$HOMES/bed-preview-nutristack/feat-1"
assert_no_file "$HOMES/bed-preview-nutristack/.config/containers/systemd/api-feat-1.container"
if grep -qF 'PathPrefix(`/feat-1`)' "$ROOTS/bed-preview-nutristack.yml"; then
  echo "assert: dropped ref must lose its route"
  failures=$((failures + 1))
fi
assert_output_has "bed-preview-nutristack.internal" cat "$HOSTS"
assert_exit 1 weedr preview drop nutristack --ref feat-1
assert_output_has "weedr: no such preview: bed-preview-nutristack/feat-1" weedr preview drop nutristack --ref feat-1

: > "$GUARDEN_CALL_LOG"
assert_output_has "converged preview: bed-staging-nutristack" weedr preview new nutristack --ref develop --from "$PROJECT"
assert_call_log_has "pg_dump"
assert_call_log_has "CREATE ROLE"
assert_call_log_has "REASSIGN OWNED BY"
assert_file "$BEDS/bed-staging-nutristack/meta"
assert_file "$BEDS/bed-staging-nutristack/compose.yaml"
assert_file "$ROOTS/bed-staging-nutristack.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$ROOTS/bed-staging-nutristack.yml"
assert_output_has "holders=2" stakes query snap-42

assert_exit 0 weedr preview new nutristack --ref feat-3 --from "$PROJECT"
assert_exit 0 weedr preview new nutristack --ref feat-4 --from "$PROJECT"
assert_output_has "created preview: bed-preview-nutristack/feat-5" weedr preview new nutristack --ref feat-5 --from "$PROJECT"
assert_no_file "$BEDS/bed-preview-nutristack/feat-2"
assert_no_file "$HOMES/bed-preview-nutristack/feat-2"
assert_file "$BEDS/bed-preview-nutristack/feat-3/meta"
assert_file "$BEDS/bed-preview-nutristack/feat-4/meta"
assert_file "$BEDS/bed-preview-nutristack/feat-5/meta"
assert_file "$BEDS/bed-staging-nutristack/meta"
assert_output_has "holders=4" stakes query snap-42
if [ "$(wc -l < "$FIFO")" -ne 3 ]; then
  echo "assert: fifo must hold the three newest refs"
  printf '  | %s\n' "$(cat "$FIFO")"
  failures=$((failures + 1))
fi

assert_output_has "created preview: bed-preview-nutristack/feat-6" env GUARDEN_PREVIEW_CAP=1 weedr preview new nutristack --ref feat-6 --from "$PROJECT"
assert_no_file "$BEDS/bed-preview-nutristack/feat-3"
assert_no_file "$BEDS/bed-preview-nutristack/feat-4"
assert_no_file "$BEDS/bed-preview-nutristack/feat-5"
assert_file "$BEDS/bed-preview-nutristack/feat-6/meta"
assert_output_has "holders=2" stakes query snap-42
if [ "$(wc -l < "$FIFO")" -ne 1 ]; then
  echo "assert: cap override must leave one ref in the fifo"
  printf '  | %s\n' "$(cat "$FIFO")"
  failures=$((failures + 1))
fi
assert_output_has "feat-6" cat "$FIFO"

: > "$GUARDEN_CALL_LOG"
assert_output_has "dropped preview: bed-preview-nutristack/feat-6" weedr preview drop nutristack --ref feat-6
assert_call_log_has "userdel"
assert_no_file "$BEDS/bed-preview-nutristack"
assert_no_file "$HOMES/bed-preview-nutristack"
assert_no_file "$ROOTS/bed-preview-nutristack.yml"
if grep -qF "bed-preview-nutristack.internal" "$HOSTS"; then
  echo "assert: last ref drop must free the preview bed hyphae"
  failures=$((failures + 1))
fi
assert_output_has "holders=1" stakes query snap-42
assert_exit 1 weedr preview drop nutristack --ref feat-6

assert_output_has "dropped preview: bed-staging-nutristack" weedr preview drop nutristack --ref develop
assert_no_file "$BEDS/bed-staging-nutristack"
assert_no_file "$HOMES/bed-staging-nutristack"
assert_no_file "$ROOTS/bed-staging-nutristack.yml"
assert_output_has "holders=0" stakes query snap-42

assert_output_has "created bed: bed-staging-bare" weedr bed plow bare --env staging --from "$BARE" -p pond-staging-postgres
: > "$GUARDEN_CALL_LOG"
assert_output_has "created preview: bed-preview-bare/feat-1" weedr preview new bare --ref feat-1 --from "$BARE"
assert_call_log_has "exec pond-staging-postgres pg_dump"
assert_call_log_has "app_bed_staging_bare"
assert_call_log_has "REASSIGN OWNED BY app_bed_staging_bare"
assert_output_has "snapshot=snap-42" cat "$BEDS/bed-preview-bare/feat-1/meta"
assert_output_has "ponddb=app_bed_preview_bare_feat_1" cat "$BEDS/bed-preview-bare/feat-1/meta"
assert_output_has "@pond-staging-postgres.internal:5432/" cat "$HOMES/bed-preview-bare/feat-1/.env.preview.local"
assert_output_has "holders=1 bed-preview-bare/feat-1" stakes query snap-42

assert_output_has "created preview: bed-preview-empty/feat-1" weedr preview new empty --ref feat-1 --from "$EMPTY"
if grep -q '^snapshot=' "$BEDS/bed-preview-empty/feat-1/meta"; then
  echo "assert: an instance with no pond must not pin a snapshot"
  failures=$((failures + 1))
fi
if grep -q '^ponddb=' "$BEDS/bed-preview-empty/feat-1/meta"; then
  echo "assert: an instance with no pond must not claim a database"
  failures=$((failures + 1))
fi
assert_file "$HOMES/bed-preview-empty/feat-1/.env"
assert_output_has "holders=1 bed-preview-bare/feat-1" stakes query snap-42
assert_output_has "dropped preview: bed-preview-empty/feat-1" weedr preview drop empty --ref feat-1
assert_no_file "$BEDS/bed-preview-empty"

mkdir -p "$NOSCHEMA/.guarden"
cat > "$NOSCHEMA/compose.yaml" <<'EOF'
services:
  api:
    image: example/noschema-api:v1
    ports:
      - "8081:80"
EOF
cat > "$NOSCHEMA/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
EOF
assert_output_has "created preview: bed-preview-noschema/feat-1" weedr preview new noschema --ref feat-1 --from "$NOSCHEMA"
assert_no_file "$HOMES/bed-preview-noschema/feat-1/.env"
assert_no_file "$HOMES/bed-preview-noschema/.env"
assert_no_file "$NOSCHEMA/.env.example"
assert_output_has "dropped preview: bed-preview-noschema/feat-1" weedr preview drop noschema --ref feat-1

finish
