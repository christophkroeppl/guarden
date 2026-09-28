#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHA1="cccccccccccccccccccccccccccccccccccccccc"

mkdir -p "$WORK/src/.guarden/widgets"
cat > "$WORK/src/compose.yaml" <<'EOF'
services:
  api:
    image: example/nutristack-api:v1
    ports:
      - "8081:80"
EOF
cat > "$WORK/src/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
EOF
cat > "$WORK/src/.guarden/.env.schema" <<'EOF'
PORT=3000 @type number
EOF
cat > "$WORK/src/.guarden/widgets/api.yml" <<'EOF'
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
tar -czf "$WORK/src.tar.gz" -C "$WORK/src" .

assert_exit 0 hose --help
assert_output_has "hose poke" hose --help
assert_output_has "hose drop" hose --help

assert_exit 2 hose sync
assert_output_has "hose sync was removed" hose sync
assert_exit 2 hose frobnicate

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA1" < "$WORK/src.tar.gz"
assert_exit 0 hose poke nutristack feat-x "$SHA1" < "$WORK/src.tar.gz"
assert_exit 0 hose drop nutristack feat-x
assert_call_log_lacks "git"
assert_call_log_lacks "sudo [^w]"
assert_call_log_lacks "runuser -u root"
assert_no_file "$GUARDEN_STATE/repos"
assert_no_file "$GUARDEN_STATE/hose/ops"

finish
