#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EDGE="$GUARDEN_STATE/edge"

mkdir -p "$WORK/project"
cat > "$WORK/project/compose.yaml" <<'EOF'
services:
  api:
    image: example/api:latest
    ports:
      - "8081:80"
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$WORK/project/bed.yaml" <<'EOF'
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
pond:
  databases: ["app"]
hyphae:
  aliases: ["nutristack.internal"]
repo: "https://github.com/example/nutristack"
EOF

mkdir -p "$WORK/project-default"
cat > "$WORK/project-default/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$WORK/project-default/bed.yaml" <<'EOF'
pond:
  databases: ["app"]
repo: "https://github.com/example/nutristack"
EOF

assert_exit 0 weedr bed new default-app --env staging --from "$WORK/project-default"
cp "$WORK/project-default/bed.yaml" "$GUARDEN_STATE/beds/default-app-staging/bed.yaml"
cp "$WORK/project-default/compose.yaml" "$GUARDEN_STATE/beds/default-app-staging/compose.yaml"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$EDGE/default-app-staging.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$EDGE/default-app-staging.yml"
assert_output_has "127.0.0.1:8080" cat "$EDGE/default-app-staging.yml"
assert_call_log_empty

assert_exit 0 weedr bed new default-app --env preview:feat-1 --from "$WORK/project-default"
cp "$WORK/project-default/bed.yaml" "$GUARDEN_STATE/beds/default-app-preview-feat-1/bed.yaml"
cp "$WORK/project-default/compose.yaml" "$GUARDEN_STATE/beds/default-app-preview-feat-1/compose.yaml"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$EDGE/default-app-preview-feat-1.yml"
assert_output_has 'Host(`preview.example.com`)' cat "$EDGE/default-app-preview-feat-1.yml"
assert_output_has 'PathPrefix(`/feat-1`)' cat "$EDGE/default-app-preview-feat-1.yml"
assert_call_log_empty

assert_exit 0 weedr bed new nutristack --env staging --from "$WORK/project"
cp "$WORK/project/bed.yaml" "$GUARDEN_STATE/beds/nutristack-staging/bed.yaml"
cp "$WORK/project/compose.yaml" "$GUARDEN_STATE/beds/nutristack-staging/compose.yaml"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$EDGE/nutristack-staging.yml"
assert_output_has 'Host(`api.staging.example.com`)' cat "$EDGE/nutristack-staging.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$EDGE/nutristack-staging.yml"
assert_output_has "127.0.0.1:8081" cat "$EDGE/nutristack-staging.yml"
assert_output_has "127.0.0.1:8080" cat "$EDGE/nutristack-staging.yml"
assert_call_log_empty

cat > "$GUARDEN_STATE/beds/nutristack-staging/bed.yaml" <<'EOF'
routes:
  api: "api-v2.${env}.${domain}"
  web: "${env}.${domain}"
repo: "https://github.com/example/nutristack"
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_output_has 'Host(`api-v2.staging.example.com`)' cat "$EDGE/nutristack-staging.yml"
assert_call_log_empty

assert_exit 0 weedr bed drop nutristack-staging
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_no_file "$EDGE/nutristack-staging.yml"
assert_call_log_empty

finish
