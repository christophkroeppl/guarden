#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BED="$GUARDEN_STATE/beds/bed-staging-nutristack"
UNITS="$GUARDEN_STATE/homes/bed-staging-nutristack/.config/containers/systemd"
ENV_LOCAL="$GUARDEN_STATE/homes/bed-staging-nutristack/.env.staging.local"

mkdir -p "$WORK/repo/.guarden/widgets"
printf 'services:\n  api:\n    image: example/api:v1\n    ports:\n      - "8081:80"\n' > "$WORK/repo/compose.yaml"
printf 'environment: staging\nroutes:\n  api: "api.${env}.${domain}"\n' > "$WORK/repo/.guarden/bed.yaml"
printf 'description: Nutristack API\nhref: "https://api.${env}.${domain}"\nicon: mdi-api\n' > "$WORK/repo/.guarden/widgets/api.yml"
cp "$ROOT/fixtures/projects/nutristack/.guarden/.env.schema" "$WORK/repo/.guarden/.env.schema"
git -C "$WORK/repo" init -b develop
git -C "$WORK/repo" add -A
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m init
printf 'nutristack %s\n' "$WORK/repo" > "$WORK/ops"

assert_exit 0 weedr bed plow nutristack --env staging --from "$WORK/repo"
assert_file "$BED/compose.yaml"
assert_file "$BED/.guarden/bed.yaml"
assert_file "$BED/.guarden/widgets/api.yml"

mkdir -p "$UNITS/api.container.d"
echo keep > "$ENV_LOCAL"
echo keep > "$UNITS/api.container.d/zz-admin.conf"

git -C "$WORK/repo" rm -q .guarden/widgets/api.yml
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m drop-widget
assert_exit 0 weedr redeploy nutristack --env staging --from "$WORK/repo"
assert_no_file "$BED/.guarden/widgets/api.yml"
assert_no_file "$BED/.guarden/widgets"
assert_exit 1 grep -qF "Nutristack API" "$GUARDEN_STATE/twig/services.yaml"
assert_file "$ENV_LOCAL"
assert_file "$UNITS/api.container.d/zz-admin.conf"

git -C "$WORK/repo" rm -q .guarden/bed.yaml
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m drop-bed
assert_exit 0 weedr redeploy nutristack --env staging --from "$WORK/repo"
assert_no_file "$BED/.guarden/bed.yaml"
assert_file "$BED/.guarden/.env.schema"
assert_output_has 'Host(`staging.example.com`)' cat "$GUARDEN_SYSROOT/var/lib/roots/dynamic/bed-staging-nutristack.yml"
assert_file "$ENV_LOCAL"
assert_file "$UNITS/api.container.d/zz-admin.conf"

tar -czf "$WORK/repo.tar.gz" -C "$WORK/repo" --exclude=.git .
SHA="dddddddddddddddddddddddddddddddddddddddd"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA" < "$WORK/repo.tar.gz"
assert_call_log_has "weedr redeploy nutristack --env staging --from"
assert_call_log_lacks "git"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA" < "$WORK/repo.tar.gz"
assert_exit 0 hose poke nutristack develop "$SHA" < "$WORK/repo.tar.gz"
assert_call_log_lacks "weedr redeploy"
assert_call_log_empty
assert_file "$ENV_LOCAL"
assert_file "$UNITS/api.container.d/zz-admin.conf"
finish
