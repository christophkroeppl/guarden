#!/usr/bin/env bash
# One state, reached by two roads: the cloud-init document and the scripts.
#
# (ticket 130, spec 6.1)
#
# The cloud-init `user-data` renders from the one package list and carries a
# `runcmd` that calls the same six phases `soil --apply` calls. Two paths, one
# list, one order — and the two cannot drift because both are rendered from
# `packages.toml` and `soil list`, rather than typed out twice.
#
# **The whole run is against the real machine.** There is no staged
# `/etc/apt/sources.list`, no `curl` that reads a fixture, and no `btrfs` that
# records a subvolume it did not make: a converge is asked of the host and
# answered by the host. What replaced the call-log assertions is the state — the
# system units `soil units --apply` installed, the tmpfiles entry `soil install
# --apply` wrote, the programs `soil install --apply` linked, and the package
# database the distribution's own query reads. The one file this suite plants is
# the host configuration, into the machine's real `/etc/guarden`, because that is
# the one value no other file on the host carries and the suite states it rather
# than waiting for the alias to be derived into it.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). `.venv/bin` is kept first because it is the checkout's interpreter
# and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# The rendered document, and the phase list it agrees with. `soil packages
# --render-user-data` is the render path, because the packages are the one list
# and the document is rendered from it rather than written by hand.
run soil packages --render-user-data "$GUARDEN_FIXTURES/user-data.yaml"
assert_exit 0
user_data=$GUARDEN_FIXTURES/user-data.yaml
assert_file_has "$user_data" "#cloud-config"
assert_file_has "$user_data" "runcmd:"

# The `runcmd` calls the same six phases `soil list` names, in the same order, and
# the two are compared rather than transcribed. A phase in one and not the other
# is a machine that converges a different set depending on how it was installed.
run soil list
assert_exit 0
# The phase names are the first column. A `sed` that stripped `^[a-z]*` and kept
# the rest kept the *description* instead, and the comparison below then measured
# the two descriptions against six phase names and reported a disagreement
# between two things that had never disagreed.
phases=$(awk '{print $1}' "$GUARDEN_STDOUT" | tr '\n' ' ')
for phase in packages storage sysctl firewall install units; do
    assert_file_has "$user_data" "soil $phase"
    assert_stdout_has "$phase"
done
# The order in the document is the order in `soil list`. The `runcmd` converges
# every phase and then checks every one, and it is rendered from `soil list` at
# render time, so this comparison is the two of them agreeing rather than a third
# copy written here: a document that converged `units` before `install` would
# render units against a tree that is not there.
document_order=$(grep -oE 'soil (packages|storage|sysctl|firewall|install|units) --apply' \
    "$user_data" | sed 's/soil //; s/ --apply//' | tr '\n' ' ')
[ "$document_order" = "$phases" ] \
    || _fail "the document converges [$document_order], soil list says [$phases]"
# And the check half is in the same command, so a boot that applied everything and
# never asked — a boot that reported success without having looked — is not
# expressible by this document.
check_order=$(grep -oE 'soil (packages|storage|sysctl|firewall|install|units) --check' \
    "$user_data" | sed 's/soil //; s/ --check//' | tr '\n' ' ')
[ "$check_order" = "$phases" ] \
    || _fail "the document checks [$check_order], soil list says [$phases]"
# The apply half comes before the check half, on one line: a check that ran first
# would report drift for everything and never converge any of it.
apply_at=$(grep -boE 'soil packages --apply' "$user_data" | head -1 | cut -d: -f1)
check_at=$(grep -boE 'soil packages --check' "$user_data" | head -1 | cut -d: -f1)
[ "$apply_at" -lt "$check_at" ] || _fail "the document checks before it converges"

# Nothing from PyPI and no wheel: the document is what a machine boots from, and a
# boot that fetched from an index nobody controls is a host whose state depends on
# a network. The packages come from the distribution or not at all.
#
# **`pip install`, not the bare `pip`.** The substrate list carries the
# distribution's own `python3-pip`, which is a package name in a list and not a
# fetch — a bare `pip` assertion fails on it.
assert_file_lacks "$user_data" "pip install"
assert_file_lacks "$user_data" ".whl"
assert_file_lacks "$user_data" "pypi"
assert_file_lacks "$user_data" "index-url"

# **The vps profile, and the same template.** One template renders two documents
# and the vps one is what a real host boots: it installs the substrate, clones
# the repository and hands convergence to `install.sh`, because the btrfs
# conversion reboots twice and a cloud-init `runcmd` that tried to span a reboot
# would be a document that stopped half way. What has to hold is that it renders,
# that it does not carry the golden VM's half, and that the branch a caller names
# is the branch it clones and installs from.
vps=$GUARDEN_FIXTURES/user-data.vps.yaml
run soil packages --render-user-data "$vps" --profile vps --branch feat/testing
assert_exit 0
assert_file_has "$vps" "#cloud-config"
assert_file_has "$vps" "install.sh"
assert_file_has "$vps" 'REPO_BRANCH="feat/testing"'
assert_file_has "$vps" '--branch "feat/testing"'
# The golden VM's half is absent. An evidence directory and a phase sequence are
# the harness machine's; a host that ran them would be a host converging a
# second time on top of install.sh's, which is the double-run the document
# stopped doing.
assert_file_lacks "$vps" "/var/lib/guarden-evidence"
assert_file_lacks "$vps" "soil packages --apply"

# The profile is a closed set and not a free string: a name that is neither of
# the two is exit 2 and writes nothing, so a caller cannot boot a document with
# a silently empty half.
run soil packages --render-user-data "$GUARDEN_FIXTURES/bad.yaml" --profile nonsense
assert_exit 2
assert_one_diagnostic "error:"
assert_file_missing "$GUARDEN_FIXTURES/bad.yaml"

# `-` is stdout, which is what a caller piping the document uses. The rendered
# document is what has to come back, so the first line is the one cloud-init
# reads rather than a diagnostic about a file.
run soil packages --render-user-data -
assert_exit 0
assert_stdout_has "#cloud-config"

# A document naming a phase that does not exist is not a phase list. Both entries
# are exit 2, and this is the assertion for the closed set: the document and the
# verb agree about which phases there are.
run soil packages --render-user-data "$GUARDEN_FIXTURES/bad.yaml" --list
assert_exit 2
assert_one_diagnostic "error:"
assert_file_missing "$GUARDEN_FIXTURES/bad.yaml"
run soil nonsense
assert_exit 2

# A path the render cannot write is rejected rather than rendered to somewhere
# else, so a boot never reads a document nobody wrote.
mkdir -p "$GUARDEN_FIXTURES/adir"
run soil packages --render-user-data "$GUARDEN_FIXTURES/adir"
assert_exit 2
assert_one_diagnostic "error:"

# The scripts path, and its claim. `soil --apply` converges a host the same way
# the document does, and a converged host is silent on both — the `--check` exits
# `0` and says nothing, which is what "already true" looks like from outside.
#
# That claim needs a host that *can* converge, and it has one: every item of the
# install phase converges on a machine whose table pins the set — the alias is
# derived from it rather than measured — so the suite plants the one key
# (`ingress.alias`, from the shipped fixture, which is the value `soil install`
# derives and what the edge refuses to start without) and everything below is
# converged by soil on the machine. The exit codes are the phase's own answers
# about state this file set: remove one file the phase owns, and the check must
# report exactly that.
#
# This is where the old `assert_not_called "useradd"` and
# `assert_not_called "groupadd"` went. They were the claim that a second converge
# creates no account and no second group, and it is now the state: the passwd
# database has one `guarden` entry after two converges, the group database has one
# `guarden` group, and no file the phase owns was rewritten — a converge that
# re-ran `useradd` would either fail on the existing entry or add a second one, and
# both are visible in `getent`.
#
# **The count is taken after the first converge, and that is the whole of the fix.**
# `soil install` creates the two program users — `guarden` and `hose`, spec 6.1 — and
# it creates them *once*. A before/after pair taken across the **first** apply is a
# pair taken across the one apply that is supposed to make accounts, so the two
# entries it found were a required effect being read as drift. The claim that is
# actually about idempotence is the one `t20-install.sh` already makes, in this form:
# apply, and only then count; apply again; count again.
stage_config guarden-measured.toml
run soil install --apply
assert_exit 0
assert_stderr_empty
# Both program users now exist, and this is where they come from: `install` is the
# phase that creates them and there is no `soil users` phase.
assert_passwd guarden
assert_passwd hose

accounts_before=$(getent passwd | wc -l)
run soil install --apply
assert_exit 0
assert_stderr_empty
accounts_after=$(getent passwd | wc -l)
[ "$accounts_before" = "$accounts_after" ] \
    || _fail "a converged install created a passwd entry"
# One entry each, not two: the real database rather than a log of a `useradd` that a
# stand-in recorded. Asked again after the second converge, because "the second one
# created no entry" and "the first one created exactly one" are two claims and only
# the pair is the property.
[ "$(getent passwd guarden | wc -l)" = 1 ] || _fail "more than one guarden passwd entry"
[ "$(getent passwd hose | wc -l)" = 1 ] || _fail "more than one hose passwd entry"
[ "$(getent group guarden | wc -l)" = 1 ] || _fail "more than one guarden group entry"
# And a service user is not a program user: there is no `soil users` phase, and the
# only two users `soil install` ever gets are the program's.
assert_no_passwd myapp-production

# The drift-reporting path, on a host whose state this suite chose. One file the
# `install` phase owns goes, and three commands answer for it: the check names it
# and nothing else, the apply puts it back, and the check is then silent. That is
# `soil --check` exiting `1` with the word `drift` (spec 6.1) and `0` on a
# converged host, proved without borrowing an item nobody here can converge.
rm -f /etc/tmpfiles.d/guarden-tmpfiles.conf
run soil install --check
assert_exit 1
assert_stderr_has "drift: the tmpfiles entry recreates /run/guarden at every boot"
assert_one_diagnostic "error:"
run soil install --apply
assert_exit 0
assert_stderr_empty
run soil install --check
assert_exit 0
assert_stderr_empty
assert_file_has /etc/tmpfiles.d/guarden-tmpfiles.conf "/run/guarden/locks"

# The second converge is a no-op for the phases that can converge, and the state
# says so rather than a call log. Nothing the install phase owns is rewritten: a
# program is byte-identical, a symlink still points where it did, and the
# interpreter line is still the first one — which is the check the golden VM found
# and a stand-in could not, because the stand-in had no shebang to lose.
program=/usr/lib/guarden/bin/soil
assert_file_exists "$program"
assert_file_has "$program" "#!/usr/bin/env python3"
installed=$(sha256sum "$program")
run soil install --apply
assert_exit 0
assert_stderr_empty
[ "$(sha256sum "$program")" = "$installed" ] \
    || _fail "a converged install rewrote $program"
assert_link /usr/bin/soil "$program"

# `storage` owns the snapper cleanup timer and the lock directory, and `install`
# owns the tmpfiles entry that recreates `/run/guarden` at every boot. Both are
# **files on the host**, which is what replaced `assert_not_called "apt-get
# install"` and `assert_not_called "curl"`: the packages are the distribution's and
# the only fetch is the pinned podlet, which this host does not have — and neither
# of those is a fact a machine can report after the fact anyway. What it can
# report is whether the files the phases own are there, which is what these are.
assert_file_exists /etc/tmpfiles.d/guarden-tmpfiles.conf
assert_file_has /etc/tmpfiles.d/guarden-tmpfiles.conf "/run/guarden/locks"
assert_file_exists /etc/systemd/system/guarden-creds.path
assert_file_exists /etc/systemd/system/guarden-creds-boot.service
# Both enabled, and the boot oneshot is the one that was not: without the
# symlink a reboot pulled in nothing, so a planted value stayed encrypted with
# nothing to decrypt it (ticket 221).
assert_enabled guarden-creds.path
assert_enabled guarden-creds-boot.service
assert_file_exists /etc/guarden/creds
assert_mode /etc/guarden/creds 700
# The seeded pin, and the rule that a converge must not overwrite it. The template
# now carries a real release and both digests, so the record on a fresh host is
# readable — and it is the one file an operator owns from the moment they edit it,
# which is why `soil install` seeds it once and never again.
assert_file_exists /etc/guarden/podlet.release
assert_file_has /etc/guarden/podlet.release "sha256 ="
assert_file_has /etc/guarden/podlet.release "binary_sha256 ="
assert_file_missing /usr/lib/guarden/bin/podlet

# The recurring units, and the cleanup timer that replaces the distribution's:
# the packaged cleanup is **off** and guarden's own oneshot is on, because
# snapper's own timer would delete without the lock the reconciler holds.
#
# Two phases own part of this and the distinction is the point. **`storage` installs
# the cleanup oneshot** — it is the phase that owns snapper's configuration and the
# lock under which cleanup runs — while the **snapshot, pin-sync and pin-path units
# are the `units` phase's**, and `soil storage --apply` will not write them however
# often it is run. Asking storage for a snapshot timer is a question with one
# answer, and this file used to ask it.
run soil storage --apply
assert_exit 0
assert_file_exists /etc/systemd/system/guarden-snapper-cleanup.timer
assert_not_enabled snapper-cleanup.timer
assert_file_exists /run/guarden/locks
run soil units --apply
assert_exit 0
assert_file_exists /etc/systemd/system/guarden-snapshot.service
assert_file_exists /etc/systemd/system/guarden-snapshot.timer
assert_file_exists /etc/systemd/system/guarden-pin-sync.service
assert_file_exists /etc/systemd/system/guarden-pin-sync.timer

# A second converge changes nothing, and the state says so: the units are still
# there and a `--check` on the phase finds nothing to say.
run soil units --check
assert_exit 0
assert_file_exists /etc/systemd/system/guarden-snapshot.timer
# And the install phase is converged on the same machine, both roads ending in the
# same state: the document's runcmd and this file's converge agree, and a `--check`
# on either is silent. The alias was planted at the top already holding the
# derived address, so this exit `0` is about the phase and not about an item the
# machine's own state happened to supply.
run soil install --check
assert_exit 0
assert_stderr_empty

# The scripts path is `tools/golden-vm`, and it is the one program in this
# repository that runs `soil --check` for a human rather than converging: the
# `--print` form writes the plan and stops. It is driven by path, not by PATH,
# which is what the fake tier's `fake` was needed for and what a stand-in for it
# would be.
#
# **The document is asserted in the file the plan names, not in the plan.** The
# runner prints `user-data <path>` and does not echo the document — the artefact is
# the committed `tools/cloud-init/user-data.yaml`, and a plan that reprinted it
# would put a second copy of the document in this suite's output. So the path comes
# out of the plan and the claim about the document is asked of the document.
tool golden-vm --print
assert_exit 0
assert_stdout_has "soil storage --check"
assert_stdout_has "user-data"
document=$(awk '$1 == "user-data" { print $2 }' "$GUARDEN_STDOUT")
[ -n "$document" ] || _fail "the plan names no user-data path"
assert_file_has "$document" "#cloud-config"
