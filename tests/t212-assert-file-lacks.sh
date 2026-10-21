#!/usr/bin/env bash
# A negative assertion that cannot fail is not a negative assertion (card t1732).
#
# machine: shared
# it writes files under GUARDEN_FIXTURES and calls one helper; it converges
# nothing and starts no machine.

. "$(dirname "$0")/lib.sh"

NEEDLE='the needle a large file must name'
BIG="$GUARDEN_FIXTURES/large-with-needle"
CLEAN="$GUARDEN_FIXTURES/large-without-needle"
SMALL="$GUARDEN_FIXTURES/small-with-needle"
COMMENTED="$GUARDEN_FIXTURES/large-commented-needle"
ALLCOMMENT="$GUARDEN_FIXTURES/all-comment"
BINARY="$GUARDEN_FIXTURES/binary-with-needle"
BINARY_CLEAN="$GUARDEN_FIXTURES/binary-without-needle"
DIRECTORY="$GUARDEN_FIXTURES/a-directory"

{
    printf '%s\n' "$NEEDLE"
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line " i " of a file far larger than one pipe buffer" }' </dev/null
} >"$BIG"

awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line " i " of a file far larger than one pipe buffer" }' </dev/null >"$CLEAN"

printf '%s\n' "$NEEDLE" >"$SMALL"

{
    printf '# %s\n' "$NEEDLE"
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "filler line " i " of a file far larger than one pipe buffer" }' </dev/null
} >"$COMMENTED"

printf '# %s\n# another comment\n' "$NEEDLE" >"$ALLCOMMENT"

printf 'cipher\0text %s\n' "$NEEDLE" >"$BINARY"

printf 'cipher\0text filler\n' >"$BINARY_CLEAN"

mkdir -p "$DIRECTORY"

lacks() {
    local rc=0
    ( assert_file_lacks "$1" "$2" ) 2>"$GUARDEN_FIXTURES/lacks-stderr" || rc=$?
    printf '%s' "$rc"
}

# The needle is the first line of a ~1 MB file, so a producer in a pipeline
# would still be writing when `grep -q` exits: the case the pipe answered wrongly.
rc=$(lacks "$BIG" "$NEEDLE")
[ "$rc" -ne 0 ] \
    || _fail "assert_file_lacks passed on a needle in a $(stat -c %s "$BIG")-byte file"
grep -qF -- "names $NEEDLE" "$GUARDEN_FIXTURES/lacks-stderr" \
    || _fail "the refusal does not name the needle it found"

rc=$(lacks "$SMALL" "$NEEDLE")
[ "$rc" -ne 0 ] || _fail "assert_file_lacks passed on a small file that names the needle"

rc=$(lacks "$CLEAN" "$NEEDLE")
[ "$rc" -eq 0 ] || _fail "assert_file_lacks refused a large file that does not name the needle"
rc=$(lacks "$COMMENTED" "$NEEDLE")
[ "$rc" -eq 0 ] || _fail "assert_file_lacks refused a needle that appears only in a comment"
rc=$(lacks "$ALLCOMMENT" "$NEEDLE")
[ "$rc" -eq 0 ] || _fail "assert_file_lacks refused an all-comment file"

# A systemd-creds blob is binary: `grep -v` without -a answers on stderr and
# leaves stdout empty, which is the empty filter that used to pass.
rc=$(lacks "$BINARY" "$NEEDLE")
[ "$rc" -ne 0 ] || _fail "assert_file_lacks passed on a needle in a binary file"
grep -qF -- "names $NEEDLE" "$GUARDEN_FIXTURES/lacks-stderr" \
    || _fail "the refusal of a binary file does not name the needle"

rc=$(lacks "$BINARY_CLEAN" "$NEEDLE")
[ "$rc" -eq 0 ] || _fail "assert_file_lacks refused a binary file that does not name the needle"

rc=$(lacks "$DIRECTORY" "$NEEDLE")
[ "$rc" -ne 0 ] || _fail "assert_file_lacks passed on a directory it cannot search"
grep -qF -- "not a regular file" "$GUARDEN_FIXTURES/lacks-stderr" \
    || _fail "the refusal of a directory does not say it is not a regular file"

# A regular file whose read fails: /proc/self/mem is unmapped at offset 0.
rc=$(lacks /proc/self/mem "$NEEDLE")
[ "$rc" -ne 0 ] || _fail "assert_file_lacks passed on a file grep cannot read"
grep -qF -- "could not be searched for $NEEDLE" "$GUARDEN_FIXTURES/lacks-stderr" \
    || _fail "the refusal of an unreadable file does not name the needle"
