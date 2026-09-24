#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

passed=0
failed=0

for t in "$ROOT"/tests/test_*.sh; do
  name="$(basename "$t")"
  if bash "$t"; then
    echo "PASS $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name"
    failed=$((failed + 1))
  fi
done

echo "passed=$passed failed=$failed"

if [ "$failed" -eq 0 ]; then
  exit 0
fi
exit 1
