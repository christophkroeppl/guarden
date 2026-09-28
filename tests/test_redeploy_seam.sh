#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEDS="$GUARDEN_STATE/beds"
ROOTS="$GUARDEN_SYSROOT/var/lib/roots/dynamic"
V1="$WORK/v1"
V2="$WORK/v2"
V3="$WORK/v3"
SHA1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA3="cccccccccccccccccccccccccccccccccccccccc"

mkdir -p "$V1/.guarden/widgets" "$V2/.guarden/widgets" "$V3/.guarden/widgets"
cat > "$V1/compose.yaml" <<'EOF'
services:
  api:
    image: example/seam-api:v1
    ports:
      - "8081:80"
  web:
    image: example/seam-web:v1
    ports:
      - "8080:80"
EOF
cat > "$V1/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
  web: "web.${env}.${domain}"
EOF
cat > "$V1/.guarden/.env.schema" <<'EOF'
PORT=3000 @type number
EOF
cat > "$V1/.guarden/widgets/api.yml" <<'EOF'
description: SEAM V1
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cp "$V1/compose.yaml" "$V2/compose.yaml"
sed -i 's/-api:v1/-api:v2/; s/-web:v1/-web:v2/' "$V2/compose.yaml"
cp "$V1/.guarden/bed.yaml" "$V2/.guarden/bed.yaml"
cp "$V1/.guarden/.env.schema" "$V2/.guarden/.env.schema"
cat > "$V2/.guarden/widgets/api.yml" <<'EOF'
description: SEAM V2
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cp "$V2/compose.yaml" "$V3/compose.yaml"
sed -i 's/-api:v2/-api:v3/; s/-web:v2/-web:v3/' "$V3/compose.yaml"
cp "$V2/.guarden/bed.yaml" "$V3/.guarden/bed.yaml"
sed -i 's/web\.${env}/newweb.${env}/' "$V3/.guarden/bed.yaml"
cp "$V2/.guarden/.env.schema" "$V3/.guarden/.env.schema"
cp "$V2/.guarden/widgets/api.yml" "$V3/.guarden/widgets/api.yml"

assert_exit 2 weedr bed plow seam --env staging --from "$V1" --sha "not-a-sha"
assert_output_has "malformed sha" weedr bed plow seam --env staging --from "$V1" --sha "not-a-sha"
assert_no_file "$BEDS/bed-staging-seam"

assert_exit 0 weedr bed plow seam --env staging --from "$V1" --sha "$SHA1"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-staging-seam/meta"
assert_exit 0 weedr redeploy seam --env staging --from "$V2" --sha "$SHA2"
assert_output_has "sha=$SHA2" cat "$BEDS/bed-staging-seam/meta"
count=$(grep -c '^sha=' "$BEDS/bed-staging-seam/meta" || true)
if [ "$count" -ne 1 ]; then
  echo "assert: meta must hold exactly one sha= line, got $count"
  failures=$((failures + 1))
fi

assert_exit 0 weedr preview new seam2 --ref feat-1 --from "$V1" --sha "$SHA1"
assert_exit 0 weedr preview new seam2 --ref feat-2 --from "$V1"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-preview-seam2/feat-1/meta"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr redeploy seam2 --env preview --ref feat-1 --from "$V2" --sha "$SHA2"
assert_output_has "example/seam-api:v2" cat "$BEDS/bed-preview-seam2/feat-1/compose.yaml"
assert_output_has "example/seam-api:v1" cat "$BEDS/bed-preview-seam2/feat-2/compose.yaml"
assert_output_has "example/seam-web:v1" cat "$BEDS/bed-preview-seam2/feat-2/compose.yaml"
assert_output_has "sha=$SHA2" cat "$BEDS/bed-preview-seam2/feat-1/meta"
if grep -q '^sha=' "$BEDS/bed-preview-seam2/feat-2/meta"; then
  echo "assert: a per-ref redeploy must not touch a sibling ref's meta"
  failures=$((failures + 1))
fi
assert_output_has "SEAM V1" cat "$BEDS/bed-preview-seam2/.guarden/widgets/api.yml"
assert_call_log_has "systemctl --user start api-feat-1.service"
assert_call_log_lacks "feat-2"

assert_exit 1 weedr redeploy seam2 --env preview --ref nope --from "$V2"
assert_output_has "no such preview instance" weedr redeploy seam2 --env preview --ref nope --from "$V2"
assert_exit 2 weedr redeploy seam2 --env staging --ref feat-1 --from "$V2"
assert_output_has "--ref targets a preview instance" weedr redeploy seam2 --env staging --ref feat-1 --from "$V2"

assert_exit 0 weedr bed plow seam3 --env production --from "$V1"
assert_exit 2 weedr redeploy seam3 --env production --from "$V2"
assert_output_has "refusing to redeploy production bed without --yes" weedr redeploy seam3 --env production --from "$V2"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 weedr redeploy seam3 --env production --from "$V2" --yes
assert_call_log_has "systemctl --user stop"
assert_call_log_has "systemctl --user start"

assert_file "$ROOTS/bed-staging-seam.yml"
cp "$ROOTS/bed-staging-seam.yml" "$WORK/routes.before"
: > "$GUARDEN_CALL_LOG"
got=0
out="$(env GUARDEN_FAIL_UNIT=api.service weedr redeploy seam --env staging --from "$V3" 2>&1)" || got=$?
if [ "$got" -eq 0 ]; then
  echo "assert: a failing unit start must exit non-zero"
  failures=$((failures + 1))
fi
if ! grep -qF "leaving unit failed and routes unchanged" <<< "$out"; then
  echo "assert: failing start must name the failure"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
assert_call_log_has "systemctl --user start api.service"
if grep -q "start web.service" "$GUARDEN_CALL_LOG"; then
  echo "assert: a failed start must not start later units"
  printf '  | %s\n' "$GUARDEN_CALL_LOG"
  failures=$((failures + 1))
fi
assert_output_has "example/seam-api:v2" cat "$BEDS/bed-staging-seam/compose.yaml"
if ! cmp -s "$WORK/routes.before" "$ROOTS/bed-staging-seam.yml"; then
  echo "assert: a failing start must leave the route config unchanged"
  failures=$((failures + 1))
fi
if grep -q "newweb" "$ROOTS/bed-staging-seam.yml"; then
  echo "assert: the old route target must stay until the unit is healthy"
  failures=$((failures + 1))
fi

assert_exit 0 weedr redeploy seam --env staging --from "$V3" --sha "$SHA3"
assert_output_has "sha=$SHA3" cat "$BEDS/bed-staging-seam/meta"
assert_output_has "newweb.staging.example.com" cat "$ROOTS/bed-staging-seam.yml"

finish
