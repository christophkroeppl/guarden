#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TWIG_OUT="$GUARDEN_STATE/twig/services.yaml"

mkdir -p "$WORK/project/widgets"
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

assert_exit 0 weedr bed new nutristack --env production --from "$WORK/project"
cp "$WORK/project/bed.yaml" "$GUARDEN_STATE/beds/nutristack-production/bed.yaml"
cp "$WORK/project/compose.yaml" "$GUARDEN_STATE/beds/nutristack-production/compose.yaml"
cp -r "$WORK/project/widgets" "$GUARDEN_STATE/beds/nutristack-production/widgets"
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
assert_file "$TWIG_OUT"
assert_output_has "Nutristack" cat "$TWIG_OUT"
assert_output_has "Nutristack API" cat "$TWIG_OUT"
assert_output_has "Nutristack Web" cat "$TWIG_OUT"
assert_output_has "https://staging.example.com" cat "$TWIG_OUT"
assert_output_has "https://github.com/example/nutristack" cat "$TWIG_OUT"
assert_call_log_empty

count=$(grep -c "Nutristack API" "$TWIG_OUT" || true)
if [ "$count" -ne 1 ]; then
  echo "assert: expected exactly 1 API widget, got $count"
  failures=$((failures + 1))
fi
count=$(grep -c "Nutristack Web" "$TWIG_OUT" || true)
if [ "$count" -ne 1 ]; then
  echo "assert: expected exactly 1 Web widget, got $count"
  failures=$((failures + 1))
fi

assert_exit 0 weedr bed drop nutristack-production --yes
: > "$GUARDEN_CALL_LOG"
assert_exit 0 twig sync
if grep -qF "Nutristack API" "$TWIG_OUT" 2>/dev/null; then
  echo "assert: API widget should be gone after bed drop"
  failures=$((failures + 1))
fi
assert_call_log_empty

finish
