#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$WORK/project"
BEDS="$GUARDEN_STATE/beds"
HOMES="$GUARDEN_STATE/homes"
PINS="$GUARDEN_STATE/stakes/pins"

mkdir -p "$PROJECT/.guarden"
cat > "$PROJECT/compose.yaml" <<'EOF'
services:
  api:
    image: example/nutristack-api:v1
    ports:
      - "8081:80"

volumes:
  data:
EOF
cat > "$PROJECT/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
EOF
cat > "$PROJECT/.guarden/.env.schema" <<'EOF'
DATABASE_URL= @required @sensitive
PORT=3000 @type number
EOF

assert_no_file "$GUARDEN_STATE/ponds"

assert_output_has "created preview: bed-preview-nutristack/feat-x" weedr preview new nutristack --ref feat-x --from "$PROJECT"

assert_file "$BEDS/bed-preview-nutristack/feat-x/meta"
if grep -q '^snapshot=' "$BEDS/bed-preview-nutristack/feat-x/meta"; then
  echo "assert: meta must lack snapshot= line"
  failures=$((failures + 1))
fi
if grep -q '^ponddb=' "$BEDS/bed-preview-nutristack/feat-x/meta"; then
  echo "assert: meta must lack ponddb= line"
  failures=$((failures + 1))
fi
if grep -q '^pond=' "$BEDS/bed-preview-nutristack/feat-x/meta"; then
  echo "assert: meta must lack pond= line"
  failures=$((failures + 1))
fi
assert_no_file "$PINS"
assert_no_file "$GUARDEN_STATE/ponds"
assert_file "$HOMES/bed-preview-nutristack/feat-x/.env"
assert_file "$HOMES/bed-preview-nutristack/.config/containers/systemd/api-feat-x.container"

assert_output_has "dropped preview: bed-preview-nutristack/feat-x" weedr preview drop nutristack --ref feat-x

assert_no_file "$BEDS/bed-preview-nutristack/feat-x"
assert_no_file "$BEDS/bed-preview-nutristack"
assert_no_file "$HOMES/bed-preview-nutristack"
assert_no_file "$PINS"

finish
