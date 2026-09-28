#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEDS="$GUARDEN_STATE/beds"
STAGING="$GUARDEN_STATE/staging"
SHA1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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
tar -czf "$WORK/src1.tar.gz" -C "$WORK/src" .
sed -i 's/nutristack-api:v1/nutristack-api:v2/' "$WORK/src/compose.yaml"
tar -czf "$WORK/src2.tar.gz" -C "$WORK/src" .

assert_exit 2 hose poke nutristack 'bad ref' "$SHA1" < /dev/null
assert_exit 2 hose poke nutristack '../evil' "$SHA1" < /dev/null
assert_exit 2 hose poke nutristack 'feat!1' "$SHA1" < /dev/null
assert_exit 2 hose poke nutristack -x "$SHA1" < /dev/null
assert_exit 2 hose poke nutristack . "$SHA1" < /dev/null
assert_exit 2 hose poke nutristack feat-1 'not-a-sha' < /dev/null
assert_exit 2 hose poke nutristack feat-1 'deadbeef' < /dev/null
assert_exit 2 hose poke nutristack feat-1 "$SHA1" extra < /dev/null
assert_exit 2 hose poke nutristack feat-1 < /dev/null
assert_exit 2 hose poke '_bad' feat-1 "$SHA1" < /dev/null
assert_call_log_empty
assert_no_file "$BEDS/bed-staging-nutristack"
assert_no_file "$BEDS/bed-production-nutristack"
assert_no_file "$BEDS/bed-preview-nutristack"
assert_no_file "$STAGING"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA1" < "$WORK/src1.tar.gz"
STAGE1="$STAGING/bed-staging-nutristack/$SHA1"
assert_file "$STAGE1/compose.yaml"
assert_file "$STAGE1/.guarden/bed.yaml"
assert_file "$STAGE1/.guarden/widgets/api.yml"
mode="$(stat -c %a "$STAGE1")"
if [ "$mode" != "755" ]; then
  echo "assert: staging dir must be mode 0755, got $mode"
  failures=$((failures + 1))
fi
assert_call_log_has "sudo weedr preview new nutristack --ref develop --from $STAGE1 --sha $SHA1"
assert_call_log_lacks "git"
assert_call_log_lacks "sudo [^w]"
assert_file "$BEDS/bed-staging-nutristack/meta"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-staging-nutristack/meta"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA1" < "$WORK/src1.tar.gz"
assert_call_log_empty

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack develop "$SHA2" < "$WORK/src2.tar.gz"
STAGE2="$STAGING/bed-staging-nutristack/$SHA2"
assert_call_log_has "sudo weedr redeploy nutristack --env staging --from $STAGE2 --sha $SHA2"
assert_output_has "sha=$SHA2" cat "$BEDS/bed-staging-nutristack/meta"
assert_call_log_lacks "git"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack main "$SHA1" < "$WORK/src1.tar.gz"
assert_call_log_has "sudo weedr bed plow nutristack --env production --from $STAGING/bed-production-nutristack/$SHA1 --sha $SHA1"
assert_file "$BEDS/bed-production-nutristack/meta"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-production-nutristack/meta"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack master "$SHA2" < "$WORK/src2.tar.gz"
assert_call_log_has "sudo weedr redeploy nutristack --env production --from $STAGING/bed-production-nutristack/$SHA2 --sha $SHA2 --yes"
assert_output_has "sha=$SHA2" cat "$BEDS/bed-production-nutristack/meta"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack feat-1 "$SHA1" < "$WORK/src1.tar.gz"
assert_call_log_has "sudo weedr preview new nutristack --ref feat-1 --from $STAGING/bed-preview-nutristack/$SHA1 --sha $SHA1"
assert_file "$BEDS/bed-preview-nutristack/feat-1/meta"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-preview-nutristack/feat-1/meta"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack feat-1 "$SHA1" < "$WORK/src1.tar.gz"
assert_call_log_empty

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack feat-2 "$SHA1" < "$WORK/src1.tar.gz"
assert_call_log_has "sudo weedr preview new nutristack --ref feat-2"

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose poke nutristack feat-1 "$SHA2" < "$WORK/src2.tar.gz"
assert_call_log_has "sudo weedr redeploy nutristack --env preview --ref feat-1 --from $STAGING/bed-preview-nutristack/$SHA2 --sha $SHA2"
assert_output_has "sha=$SHA2" cat "$BEDS/bed-preview-nutristack/feat-1/meta"
assert_output_has "sha=$SHA1" cat "$BEDS/bed-preview-nutristack/feat-2/meta"
if grep -q '^sha=bbbb' "$BEDS/bed-preview-nutristack/feat-2/meta"; then
  echo "assert: a per-ref redeploy must not touch a sibling ref's meta"
  failures=$((failures + 1))
fi

: > "$GUARDEN_CALL_LOG"
assert_exit 0 hose drop nutristack feat-1
assert_call_log_has "sudo weedr preview drop nutristack --ref feat-1"
assert_no_file "$BEDS/bed-preview-nutristack/feat-1"
assert_file "$BEDS/bed-preview-nutristack/feat-2/meta"
assert_call_log_lacks "git"

: > "$GUARDEN_CALL_LOG"
assert_exit 2 hose drop nutristack develop
assert_exit 2 hose drop nutristack main
assert_exit 2 hose drop nutristack master
assert_exit 2 hose drop nutristack '../evil'
assert_call_log_lacks "weedr"
assert_call_log_lacks "git"

SUDOERS="$GUARDEN_SYSROOT/etc/sudoers.d/hose-weedr"
assert_file "$SUDOERS"
assert_output_has "weedr bed plow" cat "$SUDOERS"
assert_output_has "weedr preview new" cat "$SUDOERS"
assert_output_has "weedr preview drop" cat "$SUDOERS"
assert_output_has "weedr redeploy" cat "$SUDOERS"
bad=0
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    *'weedr bed plow '*|*'weedr preview new '*|*'weedr preview drop '*|*'weedr redeploy '*) ;;
    *)
      echo "assert: sudoers rule must list only hose's weedr verbs"
      printf '  | %s\n' "$line"
      bad=1
      ;;
  esac
done < "$SUDOERS"
if [ "$bad" -ne 0 ]; then
  failures=$((failures + 1))
fi

finish
