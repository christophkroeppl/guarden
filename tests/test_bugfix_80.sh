#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BED="$GUARDEN_STATE/beds/nutristack-staging"
UNITS="$GUARDEN_STATE/homes/bed-nutristack-staging/.config/containers/systemd"

mkdir -p "$WORK/repo/widgets" "$UNITS/api.container.d"
printf 'services:\n  api:\n    image: example/api:v1\n    ports:\n      - "8081:80"\n' > "$WORK/repo/compose.yaml"
printf 'routes:\n  api: "api.${env}.${domain}"\nrepo: "https://github.com/example/nutristack"\n' > "$WORK/repo/bed.yaml"
printf 'description: Nutristack API\nhref: "https://api.${env}.${domain}"\nicon: mdi-api\n' > "$WORK/repo/widgets/api.yml"
git -C "$WORK/repo" init -b develop
git -C "$WORK/repo" add -A
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m init
printf 'nutristack %s\n' "$WORK/repo" > "$WORK/ops"
assert_exit 0 weedr bed new nutristack --env staging --from "$WORK/repo"
cp "$WORK/repo/compose.yaml" "$BED/compose.yaml"
cp "$WORK/repo/bed.yaml" "$BED/bed.yaml"
cp -r "$WORK/repo/widgets" "$BED/widgets"
echo keep > "$BED/.env.staging.local"
echo keep > "$UNITS/api.container.d/zz-admin.conf"

git -C "$WORK/repo" rm -q widgets/api.yml
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m drop-widget
assert_exit 0 hose sync --ops "$WORK/ops"
assert_no_file "$BED/widgets/api.yml"
assert_exit 1 grep -qF "Nutristack API" "$GUARDEN_STATE/twig/services.yaml"

git -C "$WORK/repo" rm -q bed.yaml
git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -m drop-bed
assert_exit 0 hose sync --ops "$WORK/ops"
assert_no_file "$BED/bed.yaml"
assert_output_has 'Host(`staging.example.com`)' cat "$GUARDEN_STATE/edge/nutristack-staging.yml"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose sync --ops "$WORK/ops"
assert_exit 0 hose sync --ops "$WORK/ops"
assert_call_log_lacks "weedr redeploy"
assert_file "$BED/.env.staging.local"
assert_file "$UNITS/api.container.d/zz-admin.conf"
finish
