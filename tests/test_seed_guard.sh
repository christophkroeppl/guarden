#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$WORK/seedguard"
BEDS="$GUARDEN_STATE/beds"
HOMES="$GUARDEN_STATE/homes"

mkdir -p "$PROJECT/.guarden"
cat > "$PROJECT/compose.yaml" <<'EOF'
services:
  api:
    image: example/seedguard-api:v1
    ports:
      - "8081:80"
EOF
cat > "$PROJECT/.guarden/bed.yaml" <<'EOF'
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
cat > "$PROJECT/.guarden/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
PORT=3000 @type number
EOF

mkdir -p "$GUARDEN_STATE/pond"
echo "snap-77" > "$GUARDEN_STATE/pond/snapshot"

assert_output_has "dug pond: pond-production-postgres" weedr pond dig pond-production-postgres
assert_output_has "created bed: bed-production-seedguard" weedr bed plow seedguard --env production --from "$PROJECT" -p pond-production-postgres

: > "$GUARDEN_CALL_LOG"
got=0
out="$(weedr preview new seedguard --ref feat-1 --from "$PROJECT" 2>&1)" || got=$?
if [ "$got" -ne 0 ]; then
  echo "assert_exit: want=0 got=$got: weedr preview new seedguard --ref feat-1"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "seeding into a production pond is not automatic" <<< "$out"; then
  echo "assert: seeding with only a production pond must warn and skip"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "created preview: bed-preview-seedguard/feat-1" <<< "$out"; then
  echo "assert: the preview bed must still converge"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
assert_call_log_lacks "pg_dump"
assert_call_log_lacks "pond-production-postgres"
assert_no_file "$HOMES/bed-preview-seedguard/feat-1/.env.preview.local"
if grep -q '^ponddb=' "$BEDS/bed-preview-seedguard/feat-1/meta"; then
  echo "assert: production-only seeding must not claim a database"
  failures=$((failures + 1))
fi

assert_output_has "dug pond: pond-staging-postgres" weedr pond dig pond-staging-postgres
assert_output_has "created bed: bed-staging-seedguard" weedr bed plow seedguard --env staging --from "$PROJECT" -p pond-staging-postgres

: > "$GUARDEN_CALL_LOG"
got=0
out="$(weedr preview new seedguard --ref feat-2 --from "$PROJECT" 2>&1)" || got=$?
if [ "$got" -ne 0 ]; then
  echo "assert_exit: want=0 got=$got: weedr preview new seedguard --ref feat-2"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if ! grep -qF "created preview: bed-preview-seedguard/feat-2" <<< "$out"; then
  echo "assert: the non-production seed path must still create the preview"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
assert_call_log_has "exec pond-production-postgres pg_dump"
assert_call_log_has "exec -i pond-staging-postgres psql"
assert_call_log_has "REASSIGN OWNED BY"
assert_call_log_lacks "exec -i pond-production-postgres psql"
assert_output_has "ponddb=app_bed_preview_seedguard_feat_2" cat "$BEDS/bed-preview-seedguard/feat-2/meta"
assert_output_has "@pond-staging-postgres.internal:5432/" cat "$HOMES/bed-preview-seedguard/feat-2/.env.preview.local"

finish
