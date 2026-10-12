#!/usr/bin/env bash
# One package list, and nothing from PyPI.
#
# (ticket 130, spec 6.1, AGENTS.md "Conventions")
#
# **The packages are distribution packages and there is exactly one list of
# them.** It is `packages/packages.toml`, and the cloud-init user-data is
# rendered from the same file — a second copy in code would be a second copy that
# drifts, and a host would install three things and converge on a fourth while
# both machines reported success. The assertion that matters below is therefore a
# comparison: every package the phase converges is a package the rendered
# document carries, read out of the two real outputs.
#
# `python3-yaml` and `python3-jinja2` are the only imports outside the standard
# library, which is what keeps the host installable on a distribution nobody has
# tried yet. There is no `pip install` at deploy time, no wheels checked in, and
# nothing in the user-data that would fetch from PyPI.
#
# **The converge runs against the real machine.** There is no staged
# `/var/lib/dpkg/status` and no `dpkg-query` that answers from a file: the
# question "is this package installed" is asked of the distribution's own
# database, so a test that seeded a status file was asking a stand-in what it had
# been asked. Which packages are missing from a fresh golden is the golden's
# business, so each absence is asked of the machine and the converge is checked by
# asking the phase again.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014). `.venv/bin` is kept first because it is the checkout's interpreter
# and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
arch=$(uname -m)
mkdir -p /etc/guarden

# The one list, and the two of its entries this file is about. Read with `soil`
# rather than out of the TOML, because the question is what the phase converges and
# not what a file says.
run soil packages --list
assert_exit 0
assert_stdout_has "python3-yaml"
assert_stdout_has "python3-jinja2"
# The names are the part that is not portable, and that is the claim: the same
# list has different names per family, and the query is the family's own rather
# than a second opinion about it. `python3-yaml` on Debian, `python3-pyyaml` on
# Fedora, `python-yaml` on Arch — so asking the wrong family for a package would
# report a package that is installed as absent.
run soil packages --list --family fedora
assert_exit 0
assert_stdout_has "family   fedora"
assert_stdout_has "python3-pyyaml"
assert_stdout_lacks "python3-yaml"
run soil packages --list --family arch
assert_exit 0
assert_stdout_has "family   arch"
assert_stdout_has "python-yaml"
run soil packages --list --family debian
assert_exit 0
# Captured here, while it is the answer, because `$GUARDEN_STDOUT` belongs to
# whichever command ran last and the comparison below is twenty lines further
# down. Reading it there compared the *rendered* document's summary — a `phases`
# line and nothing else — against the package list, and the fake tier's silent
# `--render-user-data` is why that never showed up before.
cp "$GUARDEN_STDOUT" "$GUARDEN_FIXTURES/list-stdout"
assert_stdout_has "family   debian"
assert_stdout_has "python3-yaml"
# A family the table has no row for is exit 2 and names the families it does have,
# because a host on an unknown family would otherwise install nothing and report
# that as success.
run soil packages --list --family gentoo
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "fedora"

# The rendered user-data. This is the second copy of the list, and the point of
# the file is that it is rendered from the first rather than typed out again.
run soil packages --render-user-data "$GUARDEN_FIXTURES/user-data.yaml" --family debian
assert_exit 0
assert_file_exists "$GUARDEN_FIXTURES/user-data.yaml"
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "python3-yaml"
assert_file_has "$GUARDEN_FIXTURES/user-data.yaml" "python3-jinja2"
# Nothing from PyPI: no `pip`, no `venv`, no `.whl`, and no index. The document is
# a cloud-init one and a machine that fetched from PyPI at boot would be a machine
# whose state depends on a network nobody controls.
assert_file_lacks "$GUARDEN_FIXTURES/user-data.yaml" "pip"
assert_file_lacks "$GUARDEN_FIXTURES/user-data.yaml" ".whl"
assert_file_lacks "$GUARDEN_FIXTURES/user-data.yaml" "pypi"
assert_file_lacks "$GUARDEN_FIXTURES/user-data.yaml" "index-url"
# The two lists agree, and that is the whole claim. A package added to one and
# forgotten in the other is a host that installs three things and converges on a
# fourth while both machines report success, so the comparison is made between the
# two real outputs rather than against a third copy written here.
#
# Only the **substrate** half is compared, and that is the point of the two roles
# in `packages.toml`: the document also carries a `harness:` list, which is the
# throwaway machine's check tooling and no host's dependency. Comparing the whole
# document against `soil packages`' list would report every harness package as a
# disagreement, and the two lists are meant to differ exactly there — so the
# substrate is cut out of the document and the comparison is between the two
# halves that are supposed to be one.
#
# `--list` prints a conditional role as a PROSE HEADER followed by its packages
# indented under it (`conditional zram: installed only when the configuration
# asks` then `  systemd-zram-generator`). **Both halves are excluded here, and
# that is the design rather than a convenience:** `userdata.package_block`
# renders the substrate and harness roles only, because a machine being
# provisioned is not yet a configured host. A conditional package is in neither
# list by intent, so including it would fail the comparison in whichever
# direction it was left. Dropping the whole block keeps the comparison between
# the two halves that ARE supposed to be one.
grep -vE '^(family|install|query) ' "$GUARDEN_FIXTURES/list-stdout" \
    | sed '/^conditional /,/^[^ ]/d' | sort >"$GUARDEN_FIXTURES/list-packages"
sed -n '/^  # harness:/,$d; s/^  - //p' "$GUARDEN_FIXTURES/user-data.yaml" |
    sort >"$GUARDEN_FIXTURES/rendered-packages"
comm -23 "$GUARDEN_FIXTURES/list-packages" "$GUARDEN_FIXTURES/rendered-packages" \
    >"$GUARDEN_FIXTURES/only-in-the-list"
[ ! -s "$GUARDEN_FIXTURES/only-in-the-list" ] || _fail "converged but not rendered: $(tr '\n' ' ' <"$GUARDEN_FIXTURES/only-in-the-list")"
# And the other direction, which is the one that would put a substrate package on
# a machine the phase never asked to install.
comm -13 "$GUARDEN_FIXTURES/list-packages" "$GUARDEN_FIXTURES/rendered-packages" \
    >"$GUARDEN_FIXTURES/only-in-the-render"
[ ! -s "$GUARDEN_FIXTURES/only-in-the-render" ] || _fail "rendered but not converged: $(tr '\n' ' ' <"$GUARDEN_FIXTURES/only-in-the-render")"

# The python packages are already on the golden, because the harness's own
# substrate needs them, and that is asserted first as the precondition it is: a
# golden that had stopped shipping one would make the drift this file is about a
# different drift rather than none.
assert_dpkg python3-yaml
assert_dpkg python3-jinja2
# And `.venv` is not the reason: the host carries its own copies, which is the
# property the list exists to deliver. Asked with the checkout's venv off PATH
# entirely, so a `.venv` answering would be the stand-in this ticket removed.
run env -u PYTHONPATH PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    python3 -c "import yaml, jinja2; print('the host carries both')"
assert_exit 0
assert_stdout_has "the host carries both"

# **The image now ships the whole list, so the absence is created here rather than
# inherited.** The golden is provisioned at build time (ticket 200), which is what
# finally put a container runtime on this machine, and it makes the old claim —
# that a fresh cut has no `ferm`, `fail2ban` or `podman` — a claim about an image
# that no longer exists. Asserting they are absent now is a claim about `apt-get`,
# which is the only thing the three drift lines below can be about, and it is
# re-derived from the machine rather than remembered from a list.
#
# The removal is real dpkg work and the install below puts every package back, so
# the same three are asked of the machine in both directions in one file. What this
# does **not** do is leave the machine as it found it: the re-install is the apply's
# job and is asserted at the end.
apt-get remove -y ferm fail2ban podman
assert_no_dpkg ferm
assert_no_dpkg fail2ban
assert_no_dpkg podman

# The pinned podlet is the last item of the phase, and it is the only fetch in it,
# so it is what decides this suite's exit codes rather than the packages. Two facts
# about this machine make the sequence below deterministic rather than incidental.
# `soil install` is what seeds the record from the template and this suite ran no
# `install`, so the record is absent rather than half-filled. And being last,
# everything before it converges first, which is what the `dpkg-query` answers
# after the apply record.
assert_file_missing /etc/guarden/podlet.release
assert_file_missing /usr/lib/guarden/bin/podlet
run soil packages --check
assert_exit 1
assert_stderr_has "drift: the ferm package is installed"
assert_stderr_has "drift: the fail2ban package is installed"
assert_stderr_has "drift: the podman package is installed"
assert_stderr_has "drift: the pinned podlet is installed"

# **The apply converges the list and stops at the record.** One diagnostic is the
# whole of what it said: the three packages were installed by this same run —
# `dpkg-query` is the distribution's own record of that — and the one thing it
# could not do was fetch an artefact nothing had told it how to fetch.
run soil packages --apply
assert_exit 2
assert_one_diagnostic "error:"
assert_stderr_has "the pinned podlet record is absent"
assert_dpkg ferm
assert_dpkg fail2ban
assert_dpkg podman

# Asking again narrows the drift to exactly one item: every package in the one list
# holds now, and the only thing left is the one fetch. The phase is silent about
# the packages and says which single thing it wants.
run soil packages --check
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "drift: the pinned podlet is installed"
assert_stderr_lacks "package is installed"

# **And now the record is there, so the claim this block used to be the opposite of
# becomes the claim.** This is what `soil install` seeds on a host, copied from the
# checkout because running the `install` phase is not this suite's business — the
# seed is a file copy and the file is the one the repository ships.
install -m 0644 "$GUARDEN_ROOT/src/guarden/templates/podlet.release" /etc/guarden/podlet.release
assert_file_has /etc/guarden/podlet.release "[artefacts.$arch]"
# A host that has not fetched it reports the pinned release as not installed, which
# is exit 1: nothing is wrong with the record, the host does not have the program
# yet. That was the old exit-2 refusal's opposite, and it is the exit code the
# specification gives a host rather than an input.
run soil packages --check
assert_exit 1
assert_one_diagnostic "error:"
assert_stderr_has "drift: the pinned podlet is installed"
assert_stderr_lacks "package is installed"
assert_file_missing /usr/lib/guarden/bin/podlet

# **The apply installs it, and what it installs is a program.** Not "a file
# appeared": every published podlet artefact is an archive, so a pin filled in
# without an unpack step leaves an XZ file named `podlet` that exists, is
# executable, and cannot be run — and `assert_file_exists` and `assert_executable`
# both pass on it. The ELF header and the answer to `--version` are what tell that
# from a program, and the answer names the release the record pins.
pinned=$(sed -n 's/^version = "\(.*\)"$/\1/p' /etc/guarden/podlet.release)
run soil packages --apply
assert_exit 0
assert_stderr_empty
assert_file_exists /usr/lib/guarden/bin/podlet
assert_executable /usr/lib/guarden/bin/podlet
assert_elf /usr/lib/guarden/bin/podlet
run_installed /usr/lib/guarden/bin/podlet --version
assert_exit 0
assert_stdout_has "podlet $pinned"
# The fetched archive and the half-written temporary are both gone: what the
# unpack left behind is the program and nothing else.
assert_file_missing /usr/lib/guarden/bin/podlet.fetch
assert_file_missing /usr/lib/guarden/bin/.podlet.new
run soil packages --check
assert_exit 0
assert_stderr_empty

# And a converged host stays converged. This is what replaced
# `assert_not_called "apt-get install"` on a second run — not "no new package was
# installed" as a separate probe, but the phase's own answer on a host that holds
# what it asked for, the absence of any package drift on it, and this time with the
# one fetch already made rather than refused.
run soil packages --apply
assert_exit 0
assert_stderr_empty
assert_dpkg ferm
assert_dpkg fail2ban
assert_dpkg podman

# The harness's own substrate is on the golden and is a precondition rather than a
# claim, so it is asserted as one: a golden that stopped shipping one would make
# the absences above different absences.
assert_dpkg btrfs-progs
assert_dpkg snapper

# **And the image's own new fact, which is what the removals above replaced.** A
# golden that ships its substrate is a different machine from one that did not, and
# the record of which is a fact about the image rather than about this phase. The
# four `dpkg-query` answers above already ask it — the phase re-installed all of
# them — so what is added here is the package whose absence is why the suite could
# not reach a container before, and which no phase in this file installs.
run pasta --version
assert_exit 0
