#!/usr/bin/env bash
# soil packages: the distribution's packages, and the one fetch that is not a
# distribution package.
#
# podlet is that fetch, and it is pinned: a release, an artefact's SHA256 and the
# installed program's SHA256 recorded in the repository, and a row per host
# architecture so the pin can be correct on more than one machine. There is no
# "latest" and no unpinned fallback, because "one third-party binary, verified" is
# the whole claim and a convenient fetch would make it false.
#
# **What this file claims and what `t20-podlet.sh` claims are different questions.**
# Here the phase's own behaviour: the record the repository ships, the drift a host
# that has not fetched reports, the install, the re-check, a tampered program, and
# the three refusals. There, the artefact itself — that what lands is an ELF program
# and running it answers, which is the state this ticket exists to make impossible
# and cannot be told apart with an existence assertion. So the archive installed
# below is staged rather than fetched: it is a real program off the machine in a
# real archive, the digest really is compared, and the network is not part of this
# file's claim.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins in fixtures/bin. `lib.sh` puts that
# directory on PATH for the fake tier, and both the assertions below and the
# programs under them have to reach the real `getent`, `dpkg-query`, `systemctl`,
# `snapper`, `sysctl` and `install` -- otherwise this file is asking a fake what
# it had been asked to do, which is the whole thing the rewrite exists to stop.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
mkdir -p /etc/guarden

record=/etc/guarden/podlet.release
binary=/usr/lib/guarden/bin/podlet
archive=$GUARDEN_FIXTURES/podlet.tar.xz
arch=$(uname -m)

digest() {
    sha256sum "$1" | cut -d' ' -f1
}

# seed_record <format> <url> <artefact-digest> <program-digest>
seed_record() {
    seed "$record" \
        'version = "1.4.0"' \
        "[artefacts.$arch]" \
        "format = \"$1\"" \
        "url = \"$2\"" \
        "sha256 = \"$3\"" \
        "binary_sha256 = \"$4\""
}

# The pin is a shipped template, so it exists on a host `soil install` has run.
# The apply exits 1 because the measured alias is the one thing `install` cannot
# produce on any machine; everything else it converges has already converged.
run soil install --apply
assert_exit 1
assert_file_exists "$record"

# The image now ships all eight, so the first half of this file is the new fact and
# the second is the phase. That is the shape ticket 200 asks for: a golden that
# carries its substrate is a different machine, and a suite that still claimed the
# packages were missing would be claiming a fact about an image that no longer
# exists.
assert_dpkg btrfs-progs
assert_dpkg snapper
assert_dpkg python3-yaml
assert_dpkg python3-jinja2

# **The other three are removed here, so their absence is a fact about this machine
# rather than a fact about an old image.** Asking `dpkg-query` after an
# `apt-get remove` is a claim about `apt-get`; asking it on a provisioned golden
# would be a claim about nothing at all, because the answer is the answer whatever
# the phase does. The apply below puts all three back and the end of the file asks
# again, so both directions are the machine's answer in this one file.
#
# `podman` is one of the three on purpose. Its absence from the old image is why
# `t70-fork.sh` could not reach a single one of its data-movement success paths,
# and `t60-secrets.sh` had to install it for itself.
apt-get remove -y ferm fail2ban podman
assert_no_dpkg ferm
assert_no_dpkg fail2ban
assert_no_dpkg podman
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the ferm package is installed"
assert_stderr_has "drift: the fail2ban package is installed"
assert_stderr_has "drift: the podman package is installed"

# The two python packages above are the runtime dependencies and the only imports
# outside the standard library, which is what keeps the host installable on a
# distribution nobody has tried yet -- and the only reason the list is not a single
# `apt-get install` of everything.

# **The record the repository ships, in full.** Not "it has a sha256 key" — that
# was true of a placeholder — but a release, a row for *this* machine's
# architecture, a format the unpack knows, an https url and two 64-character
# digests. A pin that cannot be read on the machine it is installed on is not a
# pin, and every value here is checked for being a value.
assert_file_has "$record" "[artefacts.$arch]"
assert_file_has "$record" 'url = "https://'
grep -qE '^sha256 = "[0-9a-f]{64}"$' "$record" ||
    _fail "the record's artefact digest is not 64 hex characters"
grep -qE '^binary_sha256 = "[0-9a-f]{64}"$' "$record" ||
    _fail "the record's program digest is not 64 hex characters"

# A host that has not fetched the pin reports it as not installed, which is exit 1
# and not 2: nothing is wrong with the record, the host simply does not have the
# program yet. This is the claim that replaced "an unfilled record refuses".
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the pinned podlet is installed"
assert_file_missing "$binary"

# **And the apply installs it.** The three distribution packages converge in the
# same run -- the record is the last item, so everything before it has already
# converged -- which is what makes a single exit `0` here a statement about the
# whole phase rather than about the one fetch.
#
# The url is a `file://` path and the scheme is not the claim: curl really fetches
# it, the digest of the artefact really is compared before it is opened, and what
# is unpacked out of it really is written in place of the name. `t20-podlet.sh`
# says the same with the real release and says what came out of it.
cp /bin/echo "$GUARDEN_FIXTURES/payload"
python3 "$GUARDEN_ROOT/tests/pinarchive.py" tar.xz "$GUARDEN_FIXTURES/payload" "$archive"
payload_digest=$(digest "$GUARDEN_FIXTURES/payload")
archive_digest=$(digest "$archive")
seed_record tar.xz "file://$archive" "$archive_digest" "$payload_digest"
run soil packages --apply
assert_exit 0
assert_file_exists "$binary"
assert_executable "$binary"
assert_elf "$binary"
run soil packages --check
assert_exit 0
assert_stderr_empty
assert_dpkg ferm
assert_dpkg fail2ban
assert_dpkg podman

# **The distribution's own apt timers are off, and the same rule `soil storage`
# applies to `snapper-cleanup.timer`.** A packaging timer running on its own
# schedule is the same overlap as any other writer of the index, and `apt-get`
# does not queue for a lock it cannot take: two concurrent real `apt-get update`
# runs on this machine gave one exit 0 and one exit 100 with
# `E: Could not get lock /var/lib/apt/lists/lock`, both inside five seconds. So a
# `soil packages` that met `apt-daily.timer` mid-refresh would fail the run
# rather than wait. "Disabled" means not enabled — the `.service` names are
# `static` and `systemctl disable` cannot act on them, so asking for one exact
# word is a check no real host can satisfy.
for unit in apt-daily.timer apt-daily.service apt-daily-upgrade.timer \
    apt-daily-upgrade.service dpkg-db-backup.timer dpkg-db-backup.service; do
    assert_not_enabled "$unit"
done

# And `--check` re-asks the question rather than trusting that this run put it
# there, which is the shape the pinned artefact is checked with above: put one
# back, the phase names it, the apply takes it away again, and a converged host
# is silent. `unattended-upgrades.service` is deliberately left enabled — it
# installs security updates and that is an operator's decision, not this phase's.
systemctl enable apt-daily.timer
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the distribution's own apt timers are disabled"
run soil packages --apply
assert_not_rejected
assert_not_enabled apt-daily.timer
assert_enabled unattended-upgrades.service

# A body that is not the pinned one is refused, and it is refused before anything
# is unpacked: the installed program is the byte-for-byte one the last run left.
installed=$(digest "$binary")
other_digest=$(digest "$archive")
seed_record tar.xz "file://$archive" "$payload_digest" "$other_digest"
run soil packages --apply
assert_exit 2
assert_stderr_has "the SHA256 does not match"
now=$(digest "$binary")
[ "$now" = "$installed" ] || _fail "a digest mismatch replaced the installed program"

# A program replaced under the pin is drift, and `--check` re-reads the digest
# rather than trusting that it installed it.
seed_record tar.xz "file://$archive" "$archive_digest" "$payload_digest"
run soil packages --apply
assert_exit 0
say "$binary" "tampered"
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the pinned podlet is installed"

# A pin that is filled in is the only thing that makes the fetch reachable, so
# removing the record puts the fetch back out of reach rather than making it
# unpinned -- and it says which of the two faults it is, because an absent record
# and an unfilled one have different fixes. Nothing is fetched and nothing is
# removed: the binary on disk is the byte-for-byte one the previous run left.
installed=$(digest "$binary")
rm -f "$record"
run soil packages --apply
assert_exit 2
assert_stderr_has "the pinned podlet record is absent"
assert_stderr_has "soil install"
now=$(digest "$binary")
[ "$now" = "$installed" ] ||
    _fail "an absent record removed or replaced the installed binary"

# The record is `soil install`'s to seed and this file is not that phase, and the
# staged program is this file's own artefact rather than anything the shipped pin
# installs, so both are put back: the host ends as `soil install` leaves it, with
# the record seeded and the pin not yet fetched. Which of the two that leaves for a
# host to install the real release is `t20-podlet.sh`'s subject, and it is the only
# suite here that reaches the network.
rm -f "$binary"
install -m 0644 /usr/lib/guarden/templates/podlet.release "$record"
assert_file_has "$record" "[artefacts.$arch]"
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the pinned podlet is installed"
assert_file_missing "$binary"
