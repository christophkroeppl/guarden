#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PINS="$GUARDEN_STATE/stakes/pins"
HOOK="$ROOT/stakes/snapper-cleanup"
assert_exit 0 stakes pin snap-90 --holder bed-a
assert_exit 0 stakes pin snap-90 --holder bed-b
: > "$WORK/q.log"
(
  for i in $(seq 1 100); do
    stakes query snap-90 >> "$WORK/q.log" 2>&1
  done
) &
reader=$!
stakes unpin snap-90 --holder bed-a > "$WORK/u1" 2>&1 &
stakes unpin snap-90 --holder bed-b > "$WORK/u2" 2>&1 &
wait "$reader"
wait
qlines=0
qbad=0
while IFS= read -r line; do
  qlines=$((qlines + 1))
  case "$line" in
    holders=0|holders=1\ bed-a|holders=1\ bed-b|holders=2\ bed-a\ bed-b) ;;
    *) qbad=$((qbad + 1)) ;;
  esac
done < "$WORK/q.log"
if [ "$qlines" -lt 10 ] || [ "$qbad" -ne 0 ]; then
  echo "assert: query during concurrent unpin must be well-formed (lines=$qlines bad=$qbad)"
  failures=$((failures + 1))
fi
assert_output_has "holders=0" stakes query snap-90
cat "$WORK/u1" "$WORK/u2" > "$WORK/uall"
frees=$(grep -c "holders=0" "$WORK/uall")
left=$(grep -c "snap-90" "$PINS")
if [ "$frees" -ne 1 ] || [ "$left" -ne 0 ]; then
  echo "assert: concurrent unpins must free the pin exactly once (frees=$frees left=$left)"
  failures=$((failures + 1))
fi
stakes pin snap-91 --holder bed-c > "$WORK/p1" 2>&1 &
stakes pin snap-91 --holder bed-d > "$WORK/p2" 2>&1 &
wait
assert_output_has "holders=2" stakes query snap-91
assert_output_has "holders=2 bed-c bed-d" stakes query snap-91
assert_exit 0 stakes pin snap-keep --holder bed-k
assert_exit 0 env TMPDIR="$WORK/no-such-tmp" stakes pin snap-atomic --holder bed-a
assert_output_has "holders=1 bed-a" stakes query snap-atomic
assert_exit 0 stakes unpin snap-atomic --holder bed-a
assert_output_has "holders=0" stakes query snap-atomic
for i in {1..20}; do
  (
    stakes pin snap-92 --holder "h$i" > /dev/null
    stakes unpin snap-92 --holder "h$i" > /dev/null
  ) &
done
assert_exit 0 "$HOOK" 1 snap-keep
out="$("$HOOK" 1 snap-keep 2>&1)" || true
wait
assert_output_has "holders=0" stakes query snap-92
left=$(grep -c "snap-92" "$PINS")
if [ "$left" -ne 0 ]; then
  echo "assert: stress loop must free the pin"
  failures=$((failures + 1))
fi
if ! grep -qx "1" <<< "$out"; then
  echo "assert: id 1 must be prunable during a concurrent update"
  failures=$((failures + 1))
fi
if grep -qx "snap-keep" <<< "$out"; then
  echo "assert: pinned id must be skipped during a concurrent update"
  failures=$((failures + 1))
fi
finish
