#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEDS="$GUARDEN_STATE/beds"
TWIG_OUT="$GUARDEN_STATE/twig/services.yaml"

mkdir -p "$BEDS/bed-production-nutristack/.guarden/widgets"
cat > "$BEDS/bed-production-nutristack/compose.yaml" <<'EOF'
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
cat > "$BEDS/bed-production-nutristack/.guarden/bed.yaml" <<'EOF'
environment: production
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
repo: "https://github.com/example/nutristack"
EOF
cat > "$BEDS/bed-production-nutristack/.guarden/widgets/api.yml" <<'EOF'
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF
cat > "$BEDS/bed-production-nutristack/.guarden/widgets/web.yml" <<'EOF'
description: Nutristack Web
href: "https://${env}.${domain}"
icon: mdi-web
EOF

mkdir -p "$BEDS/bed-staging-nutristack/.guarden/widgets"
cat > "$BEDS/bed-staging-nutristack/compose.yaml" <<'EOF'
services:
  api:
    image: example/api:latest
    ports:
      - "8081:80"
EOF
cat > "$BEDS/bed-staging-nutristack/.guarden/bed.yaml" <<'EOF'
environment: staging
routes:
  api: "api.${env}.${domain}"
repo: "https://github.com/example/nutristack-staging"
EOF
cat > "$BEDS/bed-staging-nutristack/.guarden/widgets/api.yml" <<'EOF'
description: Nutristack API Staging
href: "https://api.${env}.${domain}"
icon: mdi-api
EOF

mkdir -p "$BEDS/bed-staging-coldframe/.guarden/widgets"
cat > "$BEDS/bed-staging-coldframe/compose.yaml" <<'EOF'
services:
  web:
    image: example/coldframe:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-staging-coldframe/.guarden/bed.yaml" <<'EOF'
environment: staging
repo: "https://github.com/example/coldframe"
EOF
cat > "$BEDS/bed-staging-coldframe/.guarden/widgets/web.yml" <<'EOF'
description: Coldframe Web
href: "https://coldframe.${env}.${domain}"
icon: mdi-web
EOF

mkdir -p "$BEDS/bed-staging-coldframe/widgets"
cat > "$BEDS/bed-staging-coldframe/widgets/api.yml" <<'EOF'
description: Old Path API
icon: mdi-old
EOF

: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
assert_file "$TWIG_OUT"
assert_output_has "- nutristack:" cat "$TWIG_OUT"
assert_output_has "- coldframe:" cat "$TWIG_OUT"
assert_output_has "Nutristack API" cat "$TWIG_OUT"
assert_output_has "https://api.production.example.com" cat "$TWIG_OUT"
assert_output_has "href: https://staging.example.com" cat "$TWIG_OUT"
assert_output_has "https://github.com/example/nutristack" cat "$TWIG_OUT"
assert_output_has "https://coldframe.staging.example.com" cat "$TWIG_OUT"
assert_output_has "https://github.com/example/coldframe" cat "$TWIG_OUT"
assert_output_has "icon: mdi-api" cat "$TWIG_OUT"
assert_exit 1 grep -qF "Nutristack API Staging" "$TWIG_OUT"
assert_exit 1 grep -qF "nutristack-staging" "$TWIG_OUT"
assert_exit 1 grep -qF "Old Path API" "$TWIG_OUT"
assert_call_log_empty

count=$(grep -cF "Nutristack API" "$TWIG_OUT")
if [ "$count" -ne 1 ]; then
  echo "assert: expected exactly 1 Nutristack API widget, got $count"
  failures=$((failures + 1))
fi
count=$(grep -cF -- "- nutristack:" "$TWIG_OUT")
if [ "$count" -ne 1 ]; then
  echo "assert: expected exactly 1 nutristack group, got $count"
  failures=$((failures + 1))
fi

stamp="$(stat -c %y "$TWIG_OUT")"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
after="$(stat -c %y "$TWIG_OUT")"
if [ "$stamp" != "$after" ]; then
  echo "assert: idempotent re-run rewrote services.yaml"
  failures=$((failures + 1))
fi
assert_call_log_empty

mkdir -p "$BEDS/bed-production-fresh/.guarden/widgets"
cat > "$BEDS/bed-production-fresh/compose.yaml" <<'EOF'
services:
  web:
    image: example/fresh:latest
    ports:
      - "8080:80"
EOF
cat > "$BEDS/bed-production-fresh/.guarden/bed.yaml" <<'EOF'
environment: production
repo: "https://github.com/example/fresh"
EOF
cat > "$BEDS/bed-production-fresh/.guarden/widgets/web.yml" <<'EOF'
description: Fresh Web
href: "https://${env}.${domain}"
icon: mdi-web
EOF
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
assert_output_has "- fresh:" cat "$TWIG_OUT"
assert_output_has "Fresh Web" cat "$TWIG_OUT"
assert_call_log_empty

rm -rf "$BEDS/bed-production-fresh"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
assert_exit 1 grep -qF "Fresh Web" "$TWIG_OUT"
assert_exit 1 grep -qF -- "- fresh:" "$TWIG_OUT"
assert_call_log_empty

rm -rf "$BEDS"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
assert_no_file "$TWIG_OUT"
assert_call_log_empty

assert_exit 0 twig --help
assert_output_has "usage:" twig --help
assert_exit 2 twig bogus

finish
