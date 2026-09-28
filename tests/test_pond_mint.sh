#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$WORK/project"
BEDS="$GUARDEN_STATE/beds"
HOMES="$GUARDEN_STATE/homes"
PONDS="$GUARDEN_STATE/ponds"
HOSTS="$GUARDEN_STATE/hosts"

mkdir -p "$PROJECT/.guarden/widgets"
cat > "$PROJECT/compose.yaml" <<'EOF'
services:
  api:
    image: example/nutristack-api:latest
    ports:
      - "8081:80"
  web:
    image: example/nutristack-web:latest
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
PORT=3000 @type number
EOF

assert_exit 0 weedr bed list

assert_exit 2 weedr pond dig postgres
assert_output_has "pond-<env>-<name>" weedr pond dig postgres
assert_exit 2 weedr pond dig pond-bogus-postgres
assert_output_has "pond-<env>-<name>" weedr pond dig pond-bogus-postgres

assert_output_has "dug pond: pond-production-postgres" weedr pond dig pond-production-postgres
assert_file "$PONDS/pond-production-postgres/meta"
assert_file "$PONDS/pond-production-postgres/data"
assert_file "$HOMES/pond-production-postgres/.config/containers/systemd/pond-production-postgres.container"
assert_output_has "env=production" cat "$PONDS/pond-production-postgres/meta"
POND_UNIT="$HOMES/pond-production-postgres/.config/containers/systemd/pond-production-postgres.container"
assert_output_has "PublishPort=127.1." cat "$POND_UNIT"
assert_output_has ":5432:5432" cat "$POND_UNIT"
prod_pond_addr="$(sed -n 's/^PublishPort=\([^:]*\):.*/\1/p' "$POND_UNIT")"
assert_output_has "$prod_pond_addr pond-production-postgres.internal" cat "$HOSTS"
assert_output_has "docker.io/library/postgres:17" cat "$POND_UNIT"
assert_output_has "$PONDS/pond-production-postgres/data" cat "$HOMES/pond-production-postgres/.config/containers/systemd/pond-production-postgres.container"
assert_call_log_has "useradd --system --create-home --home-dir"
assert_call_log_has "loginctl enable-linger pond-production-postgres"
assert_call_log_lacks "homes/pond "
assert_call_log_lacks "useradd.*[[:space:]]pond$"

: > "$GUARDEN_CALL_LOG"
assert_output_has "converged pond: pond-production-postgres" weedr pond dig pond-production-postgres
assert_call_log_lacks "useradd"
assert_call_log_has "systemctl --user start pond-production-postgres.service"
assert_output_has "PublishPort=$prod_pond_addr:5432:5432" cat "$POND_UNIT"

assert_output_has "dug pond: pond-staging-postgres" weedr pond dig pond-staging-postgres
staging_pond_addr="$(sed -n 's/^PublishPort=\([^:]*\):.*/\1/p' "$HOMES/pond-staging-postgres/.config/containers/systemd/pond-staging-postgres.container")"
if [ "$staging_pond_addr" = "$prod_pond_addr" ]; then
  echo "assert: ponds must not share a publish address"
  failures=$((failures + 1))
fi
assert_output_has "$staging_pond_addr pond-staging-postgres.internal" cat "$HOSTS"
assert_output_has "pond-production-postgres production" pond list
assert_output_has "pond-staging-postgres staging" pond list

assert_output_has "created bed: bed-staging-myproj" weedr bed plow myproj --env staging --from "$PROJECT"
if grep -q '^pond=' "$BEDS/bed-staging-myproj/meta"; then
  echo "assert: bed without -p must stay unconnected"
  failures=$((failures + 1))
fi
assert_output_has "bed-staging-myproj.internal" cat "$HOSTS"

assert_exit 1 weedr pond fill bed-staging-myproj
assert_output_has "bed is not connected to a pond: bed-staging-myproj" weedr pond fill bed-staging-myproj
assert_output_has "connect one with: weedr pond fill bed-staging-myproj -p <pond>" weedr pond fill bed-staging-myproj

assert_exit 1 weedr pond fill bed-staging-myproj -p pond-unknown-postgres
assert_output_has "weedr: no such pond: pond-unknown-postgres" weedr pond fill bed-staging-myproj -p pond-unknown-postgres
assert_output_has "pond-production-postgres" weedr pond fill bed-staging-myproj -p pond-unknown-postgres

assert_output_has "created bed: bed-production-myproj" weedr bed plow myproj --env production --from "$PROJECT" -p pond-production-postgres
PROD_LOCAL="$HOMES/bed-production-myproj/.env.production.local"
assert_file "$PROD_LOCAL"
assert_output_has "DATABASE_URL=postgres://" cat "$PROD_LOCAL"
assert_output_has "@pond-production-postgres.internal:5432/" cat "$PROD_LOCAL"
assert_output_has "app_bed_production_myproj:" cat "$PROD_LOCAL"
assert_output_has "pond=pond-production-postgres" cat "$BEDS/bed-production-myproj/meta"
assert_output_has "ponddb=app_bed_production_myproj" cat "$BEDS/bed-production-myproj/meta"
assert_output_has "pond-production-postgres.internal" cat "$HOSTS"
assert_output_has "bed-production-myproj.internal" cat "$HOSTS"

assert_exit 0 weedr bed plow myproj --env staging --from "$PROJECT" -p pond-staging-postgres
STAGING_LOCAL="$HOMES/bed-staging-myproj/.env.staging.local"
assert_file "$STAGING_LOCAL"
assert_output_has "@pond-staging-postgres.internal:5432/" cat "$STAGING_LOCAL"
assert_output_has "ponddb=app_bed_staging_myproj" cat "$BEDS/bed-staging-myproj/meta"
prod_url="$(sed -n 's/^DATABASE_URL=//p' "$PROD_LOCAL")"
staging_url="$(sed -n 's/^DATABASE_URL=//p' "$STAGING_LOCAL")"
if [ -z "$prod_url" ] || [ "$prod_url" = "$staging_url" ]; then
  echo "assert: each bed gets its own credential"
  failures=$((failures + 1))
fi

assert_exit 1 weedr bed plow myproj --env fence --from "$PROJECT" --pond pond-fence-postgres
assert_output_has "known ponds:" weedr bed plow myproj --env fence --from "$PROJECT" --pond pond-fence-postgres
assert_output_has "dig it with: weedr pond dig pond-fence-postgres (or re-run with --yes)" weedr bed plow myproj --env fence --from "$PROJECT" --pond pond-fence-postgres
assert_output_has "dug pond: pond-fence-postgres" weedr bed plow myproj --env fence --from "$PROJECT" --pond pond-fence-postgres --yes
assert_output_has "converged bed: bed-fence-myproj" weedr bed plow myproj --env fence --from "$PROJECT" --pond pond-fence-postgres --yes
assert_file "$PONDS/pond-fence-postgres/meta"

assert_exit 2 weedr bed plow other --env staging --from "$PROJECT" -p badname
assert_output_has "pond name must be pond-<env>-<name>" weedr bed plow other --env staging --from "$PROJECT" -p badname
assert_no_file "$BEDS/bed-staging-other"

assert_output_has "pond database present: app_bed_staging_myproj in pond-staging-postgres" weedr pond fill bed-staging-myproj

assert_output_has "drained pond database: app_bed_staging_myproj from pond-staging-postgres" weedr pond drain bed-staging-myproj
if grep -q '^DATABASE_URL=' "$STAGING_LOCAL"; then
  echo "assert: drain must clear the planted credential"
  failures=$((failures + 1))
fi
if grep -q '^ponddb=' "$BEDS/bed-staging-myproj/meta"; then
  echo "assert: drain must clear ponddb"
  failures=$((failures + 1))
fi
assert_output_has "nothing to drain: bed-staging-myproj" weedr pond drain bed-staging-myproj
assert_output_has "filled pond database: app_bed_staging_myproj" weedr pond fill bed-staging-myproj
assert_output_has "DATABASE_URL=postgres://" cat "$STAGING_LOCAL"

assert_exit 2 weedr pond drain bed-production-myproj
assert_output_has "refusing to drain production database without --yes: bed-production-myproj" weedr pond drain bed-production-myproj
assert_output_has "ponddb=app_bed_production_myproj" cat "$BEDS/bed-production-myproj/meta"
assert_output_has "DATABASE_URL=postgres://" cat "$PROD_LOCAL"
assert_output_has "drained pond database: app_bed_production_myproj from pond-production-postgres" weedr pond drain bed-production-myproj --yes
if grep -q '^ponddb=' "$BEDS/bed-production-myproj/meta"; then
  echo "assert: production drain with --yes must clear ponddb"
  failures=$((failures + 1))
fi

assert_output_has "filled pond database: app_bed_production_myproj" weedr pond fill bed-production-myproj
assert_exit 0 weedr pond fill bed-production-myproj

assert_exit 2 weedr pond mint bed-staging-myproj
assert_output_has "weedr pond mint was removed; use: weedr pond fill" weedr pond mint bed-staging-myproj
assert_exit 2 weedr pond drop bed-staging-myproj
assert_output_has "weedr pond drop was removed; use: weedr pond drain" weedr pond drop bed-staging-myproj
assert_exit 2 weedr pond restore bed-staging-myproj
assert_output_has "weedr pond restore was removed; use: weedr preview new" weedr pond restore bed-staging-myproj
assert_exit 2 pond up
assert_exit 2 pond down

assert_exit 0 weedr pond --help
assert_output_has "pond dig" weedr pond --help
assert_output_has "pond fill" weedr pond --help
assert_output_has "pond drain" weedr pond --help
help_out="$(weedr pond --help 2>&1)"
for word in mint restore "pond up" "pond down"; do
  if grep -qF "$word" <<< "$help_out"; then
    echo "assert: pond --help must not list removed verb [$word]"
    failures=$((failures + 1))
  fi
done

assert_exit 2 weedr bed new myproj --env staging
assert_output_has "weedr bed new was removed; use: weedr bed plow" weedr bed new myproj --env staging
assert_exit 2 weedr bed drop myproj --env staging
assert_output_has "weedr bed drop was removed; use: weedr bed remove" weedr bed drop myproj --env staging

assert_output_has "bed-production-myproj production" weedr bed list
assert_output_has "bed-staging-myproj staging" weedr bed list
assert_output_has "bed-fence-myproj fence" weedr bed list
assert_output_has 'repo: "https://github.com/example/nutristack"' cat "$BEDS/bed-staging-myproj/.guarden/bed.yaml"

finish
