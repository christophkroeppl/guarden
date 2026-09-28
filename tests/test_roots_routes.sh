#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEDS="$GUARDEN_STATE/beds"
DYN="$GUARDEN_SYSROOT/var/lib/roots/dynamic"
OLD_EDGE="$GUARDEN_STATE/edge"

mkdir -p "$BEDS/bed-staging-default-app/.guarden"
cat > "$BEDS/bed-staging-default-app/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-staging-default-app/.guarden/bed.yaml" <<'EOF'
environment: staging
EOF

: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$DYN/bed-staging-default-app.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$DYN/bed-staging-default-app.yml"
assert_output_has "127.0.0.1:8080" cat "$DYN/bed-staging-default-app.yml"
assert_no_file "$OLD_EDGE/bed-staging-default-app.yml"
assert_call_log_empty
assert_call_log_lacks "systemctl.*traefik"

stamp="$(stat -c %y "$DYN/bed-staging-default-app.yml")"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
after="$(stat -c %y "$DYN/bed-staging-default-app.yml")"
if [ "$stamp" != "$after" ]; then
  echo "assert: idempotent re-run rewrote bed-staging-default-app.yml"
  failures=$((failures + 1))
fi
assert_call_log_empty

mkdir -p "$BEDS/bed-staging-nutristack/.guarden"
cat > "$BEDS/bed-staging-nutristack/compose.yaml" <<'EOF'
services:
  api:
    image: example/api:latest
    ports: ["8081"]
  web:
    image: example/web:latest
    ports: ["8080"]
  worker:
    image: example/worker:latest
EOF
cat > "$BEDS/bed-staging-nutristack/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
  worker: "worker.${env}.${domain}"
repo: "https://github.com/example/nutristack"
pond:
  databases:
    app:
      roles:
        - name: app
          grants: ["ALL"]
hyphae:
  aliases: ["nutristack.internal"]
ports:
  - 8080/tcp
EOF

mkdir -p "$BEDS/bed-staging-oldpath"
cat > "$BEDS/bed-staging-oldpath/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "old.${env}.${domain}"
EOF
cat > "$BEDS/bed-staging-oldpath/compose.yaml" <<'EOF'
services:
  api:
    image: example/api:latest
    ports:
      - "8081:80"
EOF

mkdir -p "$BEDS/notabed"
cat > "$BEDS/notabed/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF

: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$DYN/bed-staging-nutristack.yml"
assert_output_has 'Host(`api.staging.example.com`)' cat "$DYN/bed-staging-nutristack.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$DYN/bed-staging-nutristack.yml"
assert_output_has "127.0.0.1:8081" cat "$DYN/bed-staging-nutristack.yml"
assert_output_has "127.0.0.1:8080" cat "$DYN/bed-staging-nutristack.yml"
assert_exit 1 grep -qF 'worker.staging.example.com' "$DYN/bed-staging-nutristack.yml"
assert_file "$DYN/bed-staging-oldpath.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$DYN/bed-staging-oldpath.yml"
assert_exit 1 grep -qF 'old.staging.example.com' "$DYN/bed-staging-oldpath.yml"
assert_no_file "$DYN/notabed.yml"
assert_call_log_empty

cat > "$BEDS/bed-staging-nutristack/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api-v2.${env}.${domain}"
  web: "${env}.${domain}"
repo: "https://github.com/example/nutristack"
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_output_has 'Host(`api-v2.staging.example.com`)' cat "$DYN/bed-staging-nutristack.yml"
assert_exit 1 grep -qF 'Host(`api.staging.example.com`)' "$DYN/bed-staging-nutristack.yml"
assert_call_log_empty

mkdir -p "$BEDS/bed-staging-locked/.guarden"
cat > "$BEDS/bed-staging-locked/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-staging-locked/.guarden/bed.yaml" <<'EOF'
environment: staging
auth: true
routes:
  web: "${env}.${domain}"
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$DYN/bed-staging-locked.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$DYN/bed-staging-locked.yml"
assert_output_has "127.0.0.1:8080" cat "$DYN/bed-staging-locked.yml"
assert_exit 1 grep -qi 'forwardauth' "$DYN/bed-staging-locked.yml"
assert_call_log_empty

mkdir -p "$BEDS/bed-production-apex/.guarden"
cat > "$BEDS/bed-production-apex/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-production-apex/.guarden/bed.yaml" <<'EOF'
environment: production
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$DYN/bed-production-apex.yml"
assert_output_has 'Host(`example.com`)' cat "$DYN/bed-production-apex.yml"
assert_output_has "127.0.0.1:8080" cat "$DYN/bed-production-apex.yml"
assert_call_log_empty

mkdir -p "$BEDS/bed-preview-nutristack/feat-1/.guarden"
cat > "$BEDS/bed-preview-nutristack/feat-1/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-preview-nutristack/feat-1/.guarden/bed.yaml" <<'EOF'
environment: preview
EOF
mkdir -p "$BEDS/bed-preview-nutristack/feat-2"
cat > "$BEDS/bed-preview-nutristack/feat-2/compose.yaml" <<'EOF'
services:
  web:
    image: example/web:latest
    ports:
      - "9090:80"
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_file "$DYN/bed-preview-nutristack.yml"
assert_output_has 'Host(`preview.example.com`) && PathPrefix(`/feat-1`)' cat "$DYN/bed-preview-nutristack.yml"
assert_output_has 'Host(`preview.example.com`) && PathPrefix(`/feat-2`)' cat "$DYN/bed-preview-nutristack.yml"
assert_output_has "127.0.0.1:8080" cat "$DYN/bed-preview-nutristack.yml"
assert_output_has "127.0.0.1:9090" cat "$DYN/bed-preview-nutristack.yml"
assert_call_log_empty

stamp="$(stat -c %y "$DYN/bed-preview-nutristack.yml")"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
after="$(stat -c %y "$DYN/bed-preview-nutristack.yml")"
if [ "$stamp" != "$after" ]; then
  echo "assert: idempotent re-run rewrote bed-preview-nutristack.yml"
  failures=$((failures + 1))
fi
assert_call_log_empty

rm "$BEDS/bed-staging-nutristack/.guarden/bed.yaml"
rm -rf "$BEDS/bed-staging-default-app"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 roots sync
assert_no_file "$DYN/bed-staging-default-app.yml"
assert_file "$DYN/bed-staging-nutristack.yml"
assert_output_has 'Host(`staging.example.com`)' cat "$DYN/bed-staging-nutristack.yml"
assert_output_has "127.0.0.1:8081" cat "$DYN/bed-staging-nutristack.yml"
assert_exit 1 grep -qF 'api-v2.staging.example.com' "$DYN/bed-staging-nutristack.yml"
assert_no_file "$OLD_EDGE"
assert_call_log_empty
assert_call_log_lacks "traefik"

assert_exit 0 roots --help
assert_output_has "usage:" roots --help
assert_exit 2 roots bogus

finish
