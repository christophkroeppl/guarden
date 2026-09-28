#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PINS="$GUARDEN_STATE/stakes/pins"
HOOK="$ROOT/stakes/snapper-cleanup"

mkdir -p "$GUARDEN_SYSROOT/etc/snapper/configs"
touch "$GUARDEN_SYSROOT/etc/snapper/configs/root"
touch "$GUARDEN_SYSROOT/etc/snapper/configs/home"

assert_exit 0 stakes --help
assert_output_has "usage:" stakes --help
assert_output_has "every ladder and its pins" stakes --help
help="$(stakes --help 2>&1)" || true
if grep -qi "refcount" <<< "$help"; then
  echo "assert: help must not describe a holder refcount"
  failures=$((failures + 1))
fi

assert_exit 0 stakes pin snap-1 --holder bed-a
assert_exit 0 stakes pin snap-1 --holder bed-b
assert_output_has "holders=2" stakes query snap-1
assert_output_has "holders=2 bed-a bed-b" stakes query snap-1
assert_file "$PINS"

perms="$(stat -c %a "$PINS")"
if [ "$perms" != "600" ]; then
  echo "assert: pin state file must be root-readable only (mode=$perms)"
  failures=$((failures + 1))
fi

assert_exit 0 stakes pin snap-1 --holder bed-a
assert_output_has "holders=2 bed-a bed-b" stakes query snap-1

assert_exit 0 stakes unpin snap-1 --holder bed-a
assert_output_has "holders=1" stakes query snap-1
assert_output_has "holders=1 bed-b" stakes query snap-1

assert_exit 0 stakes unpin snap-1 --holder bed-b
assert_output_has "holders=0" stakes query snap-1
out="$(stakes query snap-1 2>&1)" || true
if [ "$out" != "holders=0" ]; then
  echo "assert: a freed pin must query as bare holders=0"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if grep -q "snap-1" "$PINS" 2>/dev/null; then
  echo "assert: pin should be freed after last holder drops"
  failures=$((failures + 1))
fi

assert_exit 0 stakes pin 7 --holder bed-a
assert_exit 0 stakes pin 9 --holder bed-b
assert_output_has "holders=1" stakes query 7
assert_output_has "holders=1" stakes query 9
assert_output_has "holders=1 bed-a" stakes query 7
assert_output_has "holders=1 bed-b" stakes query 9

assert_exit 0 stakes list
assert_output_has "ladder root" stakes list
assert_output_has "ladder home" stakes list
assert_output_has "pin 7 holders=1 bed-a" stakes list
assert_output_has "pin 9 holders=1 bed-b" stakes list
out="$(stakes list 2>&1)" || true
if grep -q "snap-1" <<< "$out"; then
  echo "assert: a freed pin must not appear in stakes list"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi

assert_exit 0 "$HOOK" 1 7 9
out="$("$HOOK" 1 7 9 2>&1)" || true
if ! grep -qx "1" <<< "$out"; then
  echo "assert: unpinned id 1 must be prunable"
  printf '  | %s\n' "$out"
  failures=$((failures + 1))
fi
if grep -qx "7" <<< "$out"; then
  echo "assert: pinned id 7 must be skipped by the cleanup hook"
  failures=$((failures + 1))
fi
if grep -qx "9" <<< "$out"; then
  echo "assert: pinned id 9 must be skipped by the cleanup hook"
  failures=$((failures + 1))
fi

assert_exit 0 stakes unpin 9 --holder bed-b
assert_exit 0 "$HOOK" 1 7 9
out="$("$HOOK" 1 7 9 2>&1)" || true
if grep -qx "7" <<< "$out"; then
  echo "assert: stuck pin 7 only delays its own id"
  failures=$((failures + 1))
fi
if ! grep -qx "9" <<< "$out"; then
  echo "assert: id 9 prunable after unpin"
  failures=$((failures + 1))
fi

assert_output_has "7 holders=1" stakes query
assert_output_has "7 holders=1 bed-a" stakes query

finish
