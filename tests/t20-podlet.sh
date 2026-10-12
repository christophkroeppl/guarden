#!/usr/bin/env bash
# The pinned artefact installs as a **program**: the release the repository pins,
# unpacked out of its archive, in place of its name, and running.
#
# (ticket 20, spec 6.1 and 3.5, ADR-0014)
#
# **The failure this file exists to prevent is a file that is present, executable
# and not runnable.** `soil packages` fetched, verified a digest and `os.replace`d,
# and every published podlet artefact is an archive — so a pin filled in without an
# unpack step installed an XZ file named `podlet` under `/usr/lib/guarden/bin`, and
# `loom` would have found it: present, `os.access(X_OK)` true, and `exec` refusing.
# `assert_file_exists` and `assert_executable` both pass on that file. Neither
# distinguishes it from a program, so neither is asserted here: what separates them
# is the ELF header and the fact that the kernel can run what was installed, and
# both are asserted instead.
#
# **The payload of the staged archives is a real program off this machine**, not a
# stand-in for anything: a real ELF executable is copied into an archive, and the
# assertions are that the copy runs and answers. Nothing here shadows a tool,
# nothing is put on `PATH`, and there is no call log — the claim is about the file
# that came out. `/bin/echo` was the first choice here and it is **wrong** on this
# image: coreutils is one multicall binary, so a copy of it dispatches on the name
# it was invoked as and refuses any other. A copy installed as `podlet` answers
# `coreutils: unknown program 'podlet'` and exits 1, which is a fact about
# coreutils and not about the install. So the payload is asked to answer under the
# name it will be installed as before it is put in an archive, and the payload is
# whatever the machine has that does.
#
# The last block is the real release from the shipped record, over the network,
# because "the pin this repository ships installs" is a claim about this
# repository's pin and a staged archive is not it — and it is also where both
# digests in that record are measured rather than believed.

. "$(dirname "$0")/lib.sh"

# The machine's own tools. `.venv/bin` is kept first because it is the checkout's
# interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

record=/etc/guarden/podlet.release
binary=/usr/lib/guarden/bin/podlet
bindir=/usr/lib/guarden/bin
archive=$GUARDEN_FIXTURES/podlet.tar.xz
payload=$GUARDEN_FIXTURES/payload
canary=$GUARDEN_FIXTURES/podlet-canary
arch=$(uname -m)

digest() {
    sha256sum "$1" | cut -d' ' -f1
}

# pinfield <arch|-> <key>: one value out of the record, read as TOML. The record
# carries a row per architecture, so a line-matching read of `sha256` is a value
# from whichever row comes first rather than the one this host installs.
pinfield() {
    python3 "$GUARDEN_ROOT/tests/pinfield.py" "$record" "$1" "$2"
}

# seed_record <format> <url> <artefact-digest> <program-digest>
#
# The four keys the record's row carries, written the way `soil install` seeds the
# real one. Every refusal below is a different key or a different value, which is
# why this is one function rather than nine `seed` calls.
seed_record() {
    seed "$record" \
        'version = "0.3.2"' \
        "[artefacts.$arch]" \
        "format = \"$1\"" \
        "url = \"$2\"" \
        "sha256 = \"$3\"" \
        "binary_sha256 = \"$4\""
}

# assert_unchanged <digest> <what it should say>: the program this host already
# has is byte-for-byte the one the previous run left.
#
# Every refusal below asserts this, because a refusal that half-installed would
# leave behind a file an operator could run — the exact state this file is about.
# The digest is read into its own variable first: the program is megabytes, two
# assertions are two reads otherwise, and a command substitution inside a
# continued `[` line is more syntax than the assertion needs.
assert_unchanged() {
    local now
    now=$(digest "$binary")
    [ "$now" = "$1" ] || _fail "$2"
}

# The other direction: `--check` must NOT change what is on disk. Asserting only
# that a check restored the pinned bytes would pass a check that acted while being
# asked to report, so the tamper is expected to survive it.
assert_check_changed_nothing() {
    local now
    now=$(digest "$binary")
    [ "$now" != "$1" ] || _fail "$2"
}

# A real program, in a real archive, under the name the install matches on. The
# member path is the release's own, one directory deep, so the install is
# exercised against the shape it actually has to handle rather than a flat one.
#
# `curl` rather than anything from coreutils, for the reason in the header: it is
# a program that answers to whatever name it is invoked as.
cp /usr/bin/curl "$payload"
cp "$payload" "$canary"
run_installed "$canary" --version
assert_exit 0
assert_stdout_has "curl"
assert_stderr_empty
python3 "$GUARDEN_ROOT/tests/pinarchive.py" tar.xz "$payload" "$archive"
payload_digest=$(digest "$payload")
archive_digest=$(digest "$archive")

seed_record tar.xz "file://$archive" "$archive_digest" "$payload_digest"

# The converge installs it. The packages in the same list come first — they are
# earlier items in the phase and the record is the last — and a package that would
# not install is drift on a throwaway machine rather than a refusal, so the exit
# asked for here is 0 or 1 and only a 2 would be one. Whether the phase converges
# as a whole is `t20-packages.sh`'s question and not this file's: the golden's
# package index is as old as the golden, and an install refreshes it first
# before resolving, so a converge can fail on a mirror that cannot be reached
# rather than on anything this file asked for. What is asserted
# from here on is the pin, and the pin's own convergence is the ELF header and the
# two digests below rather than a phase's exit code.
run soil install --apply
assert_not_rejected
seed_record tar.xz "file://$archive" "$archive_digest" "$payload_digest"
run soil packages --apply
assert_not_rejected

# **It is a program.** The ELF header first, because the executable bit does not
# distinguish: an XZ file with the bit set passes `assert_executable` and fails
# every one of these three.
assert_file_exists "$binary"
assert_executable "$binary"
assert_mode "$binary" 755
assert_elf "$binary"

# **And it is the member, not the archive.** The digests are what say so, and both
# directions are asserted: equal to the payload's, and not equal to the archive's.
# An install that renamed the downloaded file passes every existence assertion in
# the harness and fails these two.
installed_digest=$(digest "$binary")
[ "$installed_digest" = "$payload_digest" ] \
    || _fail "$binary is not the bytes of the archive's podlet member"
[ "$installed_digest" != "$archive_digest" ] \
    || _fail "$binary is the archive itself, not the program out of it"

# **And running it answers.** An ELF header is a header; this is the kernel
# executing what was installed, which is the state the ticket's failure left
# behind and the only thing that tells the two apart from the outside.
run_installed "$binary" --version
assert_exit 0
assert_stdout_has "curl"

# The write protocol left nothing beside the programs: no half-written temporary
# and no fetched archive, either of which would be a file a reader could mistake
# for an install.
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# A converged pin stays converged, and the phase says nothing about the pin. The
# stderr is asserted to be free of the word rather than to be empty: what is
# converged is the pin, and a package this file never asked about is another
# item in the same phase and says nothing about this one.
run soil packages --check
assert_not_rejected
assert_stderr_lacks "podlet"

# A program replaced under the pin is drift, and `--check` re-reads the digest of
# what is on the host rather than trusting that it put it there. Re-applying
# restores the pinned bytes, which is the second half: the same fetch, the same
# unpack, the same bytes back.
say "$binary" "tampered"
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the pinned podlet is installed"
assert_elf "$binary"
# `--check` reports and changes nothing, so the tampering is still there: the
# digest assertion is the proof that the check re-read the bytes rather than
# trusting that it put them there. The apply that restores them is the second half,
# and the block asserted the ORIGINAL bytes here without issuing one — which could
# only pass if the check had already restored them, the opposite of a check.
assert_check_changed_nothing "$payload_digest" \
    "the check restored the bytes it was asked to report on"
run soil packages --apply
assert_not_rejected
assert_unchanged "$payload_digest" "the re-apply did not restore the pinned bytes"

# **The other format the record may name**, driven through the same claim. The
# record's `format` key is what makes the unpack know what it is reading, so a
# format nobody exercised would be a format nobody can say is unpacked safely.
zip=$GUARDEN_FIXTURES/podlet.zip
python3 "$GUARDEN_ROOT/tests/pinarchive.py" zip "$payload" "$zip"
zip_digest=$(digest "$zip")
seed_record zip "file://$zip" "$zip_digest" "$payload_digest"
run soil packages --apply
assert_not_rejected
assert_elf "$binary"
run_installed "$binary" --version
assert_exit 0
assert_stdout_has "curl"
# And the check agrees with what the zip path installed: the digest compared is
# the program's, so a silent exit is a statement about the bytes on the host.
run soil packages --check
assert_not_rejected
assert_stderr_lacks "podlet"

# -- refusals, each one a single line and each leaving the installed program alone
#
# The three facts every refusal below shares, asserted once rather than in each
# block: the exit code, that the program already installed is byte-for-byte the one
# the previous run left, and that the temporaries are gone. A refusal that
# half-installed would leave a file an operator could run.

installed=$(digest "$binary")

# A digest the installed program does not have, so every refusal below attempts the
# install instead of reporting the item as already converged. A refusal block whose
# record claims the host already has the program would assert nothing at all.
other_digest=$(digest "$archive")

# A body that is not the pinned one. The digest is compared **before** anything is
# unpacked, so this never reaches the unpack at all.
seed_record tar.xz "file://$archive" "$payload_digest" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the SHA256 does not match"
assert_unchanged "$installed" "a digest mismatch replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# An archive that is not the release: no regular member named `podlet`, and the
# diagnostic names the member that was wanted rather than saying "unpack failed".
nomember=$GUARDEN_FIXTURES/nomember.tar.xz
mkdir -p "$GUARDEN_FIXTURES/a-directory"
python3 "$GUARDEN_ROOT/tests/pinarchive.py" tar.xz "$GUARDEN_FIXTURES/a-directory" \
    "$nomember" "a-directory"
nomember_digest=$(digest "$nomember")
seed_record tar.xz "file://$nomember" "$nomember_digest" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no regular member named podlet"
assert_unchanged "$installed" "a bad archive replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# A directory member called `podlet` is the same fault one step in: it is not a
# regular file, so it is not a candidate, and it is never written out as one.
asdir=$GUARDEN_FIXTURES/adir-member.tar.xz
python3 "$GUARDEN_ROOT/tests/pinarchive.py" tar.xz "$GUARDEN_FIXTURES/a-directory" \
    "$asdir" "podlet"
asdir_digest=$(digest "$asdir")
seed_record tar.xz "file://$asdir" "$asdir_digest" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no regular member named podlet"
assert_unchanged "$installed" "a directory member replaced the installed program"

# **A member that is not a regular file is not a candidate, and each kind is its
# own case.** The record's comment claims it and a comment is not evidence, so
# each of the five a tar archive can carry is built and offered. They are built as
# member headers rather than as files on disk, because the machine has no device
# node to hand a `tar.add` and a test that made one would be making a device.
# What is asserted is the same in all five: the install refuses, names the member
# it wanted, and leaves the program already on the host exactly as it was.
refuse_member() {
    local label=$1 format=$2 archive_path=$3 kind=$4 source=$5
    python3 "$GUARDEN_ROOT/tests/pinarchive.py" "$format" "$source" \
        "$archive_path" podlet "$kind"
    seed_record "$format" "file://$archive_path" "$(digest "$archive_path")" \
        "$other_digest"
    run soil packages --apply
    assert_exit 2
    assert_one_diagnostic "error:"
    assert_stderr_has "no regular member named podlet"
    assert_unchanged "$installed" "a $label member replaced the installed program"
    assert_file_missing "$bindir/podlet.fetch"
    assert_file_missing "$bindir/.podlet.new"
}

refuse_member symlink tar.xz "$GUARDEN_FIXTURES/symlink.tar.xz" symlink "$payload"
refuse_member hardlink tar.xz "$GUARDEN_FIXTURES/hardlink.tar.xz" hardlink "$payload"
refuse_member device tar.xz "$GUARDEN_FIXTURES/device.tar.xz" device "$payload"
refuse_member fifo tar.xz "$GUARDEN_FIXTURES/fifo.tar.xz" fifo "$payload"
refuse_member directory tar.xz "$GUARDEN_FIXTURES/dirmember.tar.xz" directory \
    "$GUARDEN_FIXTURES/a-directory"

# **The other format, where the question is not the same one.** A zip can express
# two of the five, and both are the interesting ones. A tar member declares its
# kind in the header and `isfile()` reads it; a zip member does not — a zip stores
# a **symlink as an ordinary file whose content is the target's name**, and
# `is_dir()` is false for it because the name carries no trailing slash. So a
# reader that asked only `is_dir()` selected it, read `/usr/bin/curl` out of it,
# and installed *that string* as the program: present, executable, and not a
# program, which is the whole state this file is about. The directory case is the
# mirror of it — a member that says it is a directory without saying so in its
# name, whose contents are zero bytes.
refuse_member symlink zip "$GUARDEN_FIXTURES/symlink.zip" symlink "$payload"
refuse_member directory zip "$GUARDEN_FIXTURES/dirmember.zip" directory \
    "$GUARDEN_FIXTURES/a-directory"

# Bytes that are not an archive at all. Every library that reads one raises its own
# error and `curl` writes whatever the remote sent, so this is the case a
# traceback would have come from.
junk=$GUARDEN_FIXTURES/junk.tar.xz
seed "$junk" "this is not an archive"
junk_digest=$(digest "$junk")
seed_record tar.xz "file://$junk" "$junk_digest" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "is not a tar.xz archive this host can unpack"
assert_unchanged "$installed" "an unreadable artefact replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# **A fetch that does not happen is the host, and exits 1.** The network, the url
# and the release server are all host, and spec 1.2's dividing line puts the remote
# on that side of it — so this is not a rejection, and a caller who read 2 would go
# looking for a typo in a record that is correct. Two lines and no more: the first
# says why, the second is the phase reporting the item as still unmet.
seed_record tar.xz "file://$GUARDEN_FIXTURES/not-fetched.tar.xz" "$archive_digest" \
    "$other_digest"
run soil packages --apply
assert_exit 1
assert_stderr_has "fetching podlet 0.3.2 for this host"
assert_stderr_has "file://$GUARDEN_FIXTURES/not-fetched.tar.xz"
assert_stderr_has "drift: the pinned podlet is installed"
assert_unchanged "$installed" "a failed fetch replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# A format the install does not read. A closed set, named by the diagnostic. The
# list is asserted by its two archive formats plus the raw one rather than as the
# whole string, so adding a format does not silently stop this file asserting the
# property — a refusal that names a set this file no longer checks is a vacuous
# assertion the moment the set moves.
seed_record tar.bz2 "file://$archive" "$archive_digest" "$payload_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "names format 'tar.bz2'"
assert_stderr_has "tar.xz, zip, raw"

# A row for another architecture and none for this one. The refusal names both the
# machine and the rows the record carries, because "the pin does not cover this
# host" is the fact and the operator's next question is which rows it does cover.
seed "$record" 'version = "0.3.2"' '[artefacts.sparc64]' 'format = "tar.xz"' \
    "url = \"file://$archive\"" "sha256 = \"$archive_digest\"" \
    "binary_sha256 = \"$payload_digest\""
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "no artefact for this host's architecture ($arch)"
assert_stderr_has "sparc64"

# An unfilled key, named. Every one of these is about the record and none of them
# is about the host, which is what keeps them 2.
seed "$record" 'version = "0.3.2"' "[artefacts.$arch]" 'format = "tar.xz"' \
    "url = \"file://$archive\"" 'sha256 = ""' "binary_sha256 = \"$payload_digest\""
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the pinned podlet record is incomplete"
assert_stderr_has "[artefacts.$arch] has no sha256"

# --------------------------------------------------------------------------
# the pin this repository actually ships
# --------------------------------------------------------------------------
#
# Everything above is the mechanism; this is the claim. The record is copied from
# the checkout exactly as `soil install` seeds it on a host, the fetch is the real
# release, and what lands is a file whose `--version` answers with the release the
# record pins — a statement about the artefact, the unpack and the pin together,
# and the only assertion here that could not be staged.
install -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" "$record"
assert_file_has "$record" "[artefacts.$arch]"
pinned=$(pinfield - version)
run soil packages --apply
assert_exit 0
assert_elf "$binary"
assert_executable "$binary"
run_installed "$binary" --version
assert_exit 0
assert_stdout_has "podlet $pinned"

# **Both digests in the record, measured on this machine.**
#
# The one above is the only assertion that could not be staged, and it is also the
# only evidence there is for the record's two numbers — so they are measured here
# rather than believed. The artefact's digest is the harder half: the fetch is
# discarded, so nothing on the host holds the bytes it was compared against. The
# install's refusal names both numbers, which makes a record with one wrong digest
# the way to read what the real artefact actually hashes to. This is the same
# refusal the staged block above asserts, driven at the real release, and it is
# also the strongest form of "nothing is unpacked before the digest matches":
# the record below is the real url with a digest nothing can have, so the fetch
# happens, the comparison fails, and the program already installed is untouched.
pinned_artefact=$(pinfield "$arch" sha256)
pinned_program=$(pinfield "$arch" binary_sha256)
printf 'measured, in this VM, on %s: artefact %s, program %s\n' \
    "$(pinfield "$arch" url)" "$pinned_artefact" "$pinned_program"

real_installed=$(digest "$binary")
printf 'measured, in this VM, sha256 of %s: %s\n' "$binary" "$real_installed"
[ "$real_installed" = "$pinned_program" ] \
    || _fail "the program installed from the real release is $real_installed and the record pins $pinned_program"

seed_record tar.xz "$(pinfield "$arch" url)" \
    "0000000000000000000000000000000000000000000000000000000000000000" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the SHA256 does not match"
measured=$(sed -n 's/.*the artefact fetched from .* is \([0-9a-f]\{64\}\).*/\1/p' \
    "$GUARDEN_STDERR")
printf 'measured, in this VM, sha256 of the artefact the real url served: %s\n' "$measured"
[ "$measured" = "$pinned_artefact" ] \
    || _fail "the real release at $(pinfield "$arch" url) hashes to $measured and the record pins $pinned_artefact"
assert_unchanged "$pinned_program" "a digest mismatch against the real release replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# **The other row, measured the only way that reaches it.** The record carries a
# row per architecture so the pin can be correct on more than one machine, and
# this host can only ever install one of them — so the other row's number would
# otherwise be the one number in the file nobody has checked. The mechanism is the
# one above used the other way round: the other row's url under **this** machine's
# row, with a digest nothing can have. The install fetches it, the comparison
# fails, and its refusal reports what the bytes really hash to. The url is read
# from the template, because `$record` is the seeded one at this point in the file.
#
# The `binary_sha256` of a row this host cannot install is not measurable here, and
# not measurable *should* be: reading it means unpacking a foreign architecture's
# artefact, and the only path the install has writes the member out as **the
# program**, which on this machine would be a file that exists, is executable and
# cannot run — the state this file exists to make unreachable. A wrong number in
# that row fails closed instead: an arm host's install compares it, finds the
# installed program does not match, and says so.
template=$GUARDEN_ROOT/src/guarden/templates/podlet.release
other_arch=aarch64
other_url=$(python3 "$GUARDEN_ROOT/tests/pinfield.py" "$template" "$other_arch" url)
other_pinned=$(python3 "$GUARDEN_ROOT/tests/pinfield.py" "$template" "$other_arch" sha256)
seed_record tar.xz "$other_url" \
    "0000000000000000000000000000000000000000000000000000000000000000" "$other_digest"
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the SHA256 does not match"
other_measured=$(sed -n 's/.*the artefact fetched from .* is \([0-9a-f]\{64\}\).*/\1/p' \
    "$GUARDEN_STDERR")
printf 'measured, in this VM, sha256 of %s: %s\n' "$other_url" "$other_measured"
[ "$other_measured" = "$other_pinned" ] \
    || _fail "the $other_arch release at $other_url hashes to $other_measured and the record pins $other_pinned"
assert_unchanged "$pinned_program" "a digest mismatch against the other row replaced the installed program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"

# The host ends as `soil install` leaves it: the record it seeds, and the pinned
# program it installed, and the phase reporting nothing about the pin.
install -m 0644 "$template" "$record"
run soil packages --check
assert_not_rejected
assert_stderr_lacks "podlet"
assert_unchanged "$pinned_program" "the converged host is not the pinned program"
assert_file_missing "$bindir/podlet.fetch"
assert_file_missing "$bindir/.podlet.new"
