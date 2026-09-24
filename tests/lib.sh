#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GUARDEN_STATE="$WORK/state"
export GUARDEN_CALL_LOG="$WORK/calls.log"
mkdir -p "$GUARDEN_STATE"
: > "$GUARDEN_CALL_LOG"

export PATH="$ROOT/fixtures/bin:$ROOT/soil:$ROOT/weedr:$ROOT/stakes:$ROOT/roots:$ROOT/twig:$ROOT/pond:$ROOT/hose:$ROOT/tools:$PATH"

failures=0

assert_exit() {
  local want="$1"
  local got=0
  local out=""
  shift
  out="$("$@" 2>&1)" || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "assert_exit: want=$want got=$got: $*"
    printf '  | %s\n' "$out"
    failures=$((failures + 1))
  fi
}

assert_output_has() {
  local want="$1"
  local out=""
  shift
  out="$("$@" 2>&1)" || true
  if ! grep -qF -- "$want" <<< "$out"; then
    echo "assert_output_has: missing [$want]: $*"
    printf '  | %s\n' "$out"
    failures=$((failures + 1))
  fi
}

assert_file() {
  if [ ! -e "$1" ]; then
    echo "assert_file: missing $1"
    failures=$((failures + 1))
  fi
}

assert_no_file() {
  if [ -e "$1" ]; then
    echo "assert_no_file: exists $1"
    failures=$((failures + 1))
  fi
}

assert_call_log_has() {
  if ! grep -q -- "$1" "$GUARDEN_CALL_LOG"; then
    echo "assert_call_log_has: missing [$1]"
    printf '  | %s\n' "$(cat "$GUARDEN_CALL_LOG")"
    failures=$((failures + 1))
  fi
}

assert_call_log_empty() {
  if [ -s "$GUARDEN_CALL_LOG" ]; then
    echo "assert_call_log_empty: not empty"
    printf '  | %s\n' "$(cat "$GUARDEN_CALL_LOG")"
    failures=$((failures + 1))
  fi
}

finish() {
  if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    exit 1
  fi
  exit 0
}

export GUARDEN_SYSROOT="$WORK/sysroot"
mkdir -p "$GUARDEN_SYSROOT"

assert_call_log_lacks() {
  if grep -qE -- "$1" "$GUARDEN_CALL_LOG"; then
    echo "assert_call_log_lacks: present [$1]"
    printf '  | %s\n' "$(cat "$GUARDEN_CALL_LOG")"
    failures=$((failures + 1))
  fi
}
