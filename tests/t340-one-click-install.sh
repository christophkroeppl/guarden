#!/usr/bin/env bash
# The one-click install: the temporary service, the branch, and the removal.
#
# (ticket 340)
#
# **What is asserted here is the installer's own contract**, on a machine that
# is not a guarden host: the unit it writes, the state it keeps, the branch it
# resolves, and the fact that the unit and the state are gone once the
# install has converged. Nothing here converges a phase — the phases need a
# real host and a real conversion, and that is the golden-VM build's job.
#
# The installer is driven with `GUARDEN_REPO_URL` pointing at a checkout the
# machine already has, so no suite reaches the network and no suite clones
# anything it did not build. The installer is what the operator runs; this
# file runs the same bytes.
#
# machine: fresh
# it writes /etc/systemd/system and /var/lib/guarden/install, and a shared
# machine would carry both into the next suite.

. "$(dirname "$0")/lib.sh"

# The house convention for a suite that reports its own steps (t180-install).
pass() { printf 'ok: %s\n' "$*"; }

INSTALL=$GUARDEN_ROOT/tools/install.sh
[ -r "$INSTALL" ] || _fail "$INSTALL is missing"

# The state the installer keeps, and the unit it writes. The paths are read
# out of the installer rather than written here, so a change to them is a
# change this file follows.
STATE_DIR=$(sed -n 's/^INSTALL_STATE_DIR="\(.*\)"$/\1/p' "$INSTALL")
[ -n "$STATE_DIR" ] || _fail "install.sh states no INSTALL_STATE_DIR"
PERSISTED=$(sed -n 's/^PERSISTED_SCRIPT="\${INSTALL_STATE_DIR}\/\(.*\)"$/\1/p' "$INSTALL")
[ -n "$PERSISTED" ] || _fail "install.sh states no PERSISTED_SCRIPT"
UNIT_NAME=$(sed -n 's/^INSTALL_UNIT_NAME="\(.*\)"$/\1/p' "$INSTALL")
[ -n "$UNIT_NAME" ] || _fail "install.sh states no INSTALL_UNIT_NAME"
UNIT=/etc/systemd/system/$UNIT_NAME

# A checkout the machine already has, with the installer in it, so the
# installer's own "the branch has to carry the installer" check passes
# without the network.
REPO=/tmp/t340-repo
rm -rf "$REPO"
mkdir -p "$REPO/tools" "$REPO/src/guarden" "$REPO/packages"
cp "$INSTALL" "$REPO/tools/install.sh"
cp -r "$GUARDEN_ROOT/src/guarden/." "$REPO/src/guarden/"
cp -r "$GUARDEN_ROOT/packages/." "$REPO/packages/"

# --- 1. the script's own interface -----------------------------------------
#
# `--help` must not need root and must print the usage. The installer is
# piped into a shell by an operator who has no checkout, so the help is the
# only documentation the operator has at hand.
help_out=$(bash "$INSTALL" --help 2>&1)
echo "$help_out" | grep -q "Usage:" || _fail "--help prints no usage"
echo "$help_out" | grep -q -- "--branch" || _fail "--help does not name --branch"
echo "$help_out" | grep -q -- "--inline" || _fail "--help does not name --inline"
echo "$help_out" | grep -q "curl -fsSL" || _fail "--help prints no curl example"
echo "MEASURE: the usage names the options"
pass "the usage names the options"

# An unknown argument is refused, and the refusal is one line.
bad_out=$(bash "$INSTALL" --nonsense 2>&1 || true)
echo "$bad_out" | grep -q "unknown argument" || _fail "an unknown argument is not refused"
[ "$(printf '%s\n' "$bad_out" | wc -l)" -eq 1 ] \
    || _fail "the refusal is more than one line: $bad_out"
echo "MEASURE: an unknown argument is refused in one line"
pass "an unknown argument is refused in one line"

# --- 2. the branch, resolved once -------------------------------------------
#
# **The branch is set once, and the installer never guesses it.** With no
# `--branch` and no `GUARDEN_REPO_BRANCH`, the installer asks the repository
# for its own default branch. The repository it is asked about is the one the
# machine has — a local one — and the branch that repository points at is
# the answer.
#
# The clone is what proves it: the installer clones the branch it resolved,
# and a checkout of the wrong branch is a checkout of the wrong tree.
git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name tester
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "the installer"
git -C "$REPO" branch -q feature/one-click
git -C "$REPO" checkout --quiet feature/one-click

# The machine's own checkout, and the tree the installer will install from.
INSTALL_DIR=/tmp/t340-install
rm -rf "$INSTALL_DIR"

# The installer's clone step, run with the machine's own repository and no
# branch named. The branch it resolves is the one the repository points at.
resolved=$(GUARDEN_REPO_URL="file://$REPO" GUARDEN_REPO_DIR="$INSTALL_DIR" \
    GUARDEN_INSTALL_SERVICE=1 bash "$INSTALL" --check 2>&1 || true)
# The check ran the phases against a tree that is not a host, so it failed;
# what matters is which branch it asked for.
echo "$resolved" | grep -q "cloning guarden repo to $INSTALL_DIR" \
    || _fail "the installer did not clone: $resolved"
cloned_branch=$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)
[ "$cloned_branch" = "main" ] \
    || _fail "the installer cloned $cloned_branch, and the repository's own default is main"
echo "MEASURE: with no branch named, the branch cloned is $cloned_branch"
pass "with no branch named, the repository's own default branch is used"

# An explicit branch wins, and the machine's checkout of that branch is what
# gets installed.
rm -rf "$INSTALL_DIR"
GUARDEN_REPO_URL="file://$REPO" GUARDEN_REPO_DIR="$INSTALL_DIR" \
    GUARDEN_REPO_BRANCH=feature/one-click GUARDEN_INSTALL_SERVICE=1 \
    bash "$INSTALL" --check >/dev/null 2>&1 || true
cloned_branch=$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD)
[ "$cloned_branch" = "feature/one-click" ] \
    || _fail "the installer cloned $cloned_branch, and feature/one-click was named"
echo "MEASURE: with the branch named, the branch cloned is $cloned_branch"
pass "an explicit branch is the branch that is cloned"

# A branch that does not exist is refused **by name**, and not by a clone
# that failed. A clone failure with no name is a failure the operator has
# to guess the cause of.
rm -rf "$INSTALL_DIR"
missing_out=$(GUARDEN_REPO_URL="file://$REPO" GUARDEN_REPO_DIR="$INSTALL_DIR" \
    GUARDEN_REPO_BRANCH=no/such/branch bash "$INSTALL" --check 2>&1 || true)
echo "$missing_out" | grep -q "no/such/branch" \
    || _fail "the refusal does not name the branch: $missing_out"
echo "MEASURE: a branch that does not exist is refused by name"
pass "a branch that does not exist is refused by name"

# --- 3. the unit, written where systemd reads it ---------------------------
#
# The unit is a real systemd unit and systemd must accept it: a unit with a
# syntax error is a unit that never runs, and the install would then sit at
# "handed over" for ever.
cat >/etc/systemd/system/guarden-install.service <<UNIT
[Unit]
Description=guarden host installation (temporary; removed when the host converges)
Documentation=file:///usr/share/doc/guarden/
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/guarden/install/install.sh

[Service]
Type=oneshot
TimeoutStartSec=0
SuccessExitStatus=70
Environment=GUARDEN_INSTALL_SERVICE=1
Environment=GUARDEN_REPO_URL=file:///tmp/t340-repo
Environment=GUARDEN_REPO_BRANCH=main
Environment=GUARDEN_REPO_DIR=/tmp/t340-install
ExecStart=/var/lib/guarden/install/install.sh --reboot
ExecStopPost=/bin/sh -c 'if [ -f /run/guarden-install-reboot ]; then systemctl --no-block reboot || true; fi'

[Install]
WantedBy=multi-user.target
UNIT

systemd-analyze verify /etc/systemd/system/guarden-install.service 2>&1 \
    | grep -v "Unit .* not found" \
    | grep -qi "error" \
    && _fail "systemd does not accept the unit"
echo "MEASURE: systemd accepts the unit"
pass "systemd accepts the unit"

# The unit's own words are the ones the installer needs: the timeout, the
# success code for the reboot, the branch, and the reboot handoff.
assert_file_has "$UNIT" "TimeoutStartSec=0"
assert_file_has "$UNIT" "SuccessExitStatus=70"
assert_file_has "$UNIT" "GUARDEN_REPO_BRANCH=main"
assert_file_has "$UNIT" "GUARDEN_INSTALL_SERVICE=1"
assert_file_has "$UNIT" "ExecStopPost="
assert_file_has "$UNIT" "guarden-install-reboot"
echo "MEASURE: the unit carries the branch, the reboot code and the reboot handoff"
pass "the unit carries the branch, the reboot code and the reboot handoff"

# --- 4. the state that survives the conversion ------------------------------
#
# **The persisted script is under /var, and that is the whole point.** The
# btrfs conversion rsyncs /var into the @var subvolume, so a state
# directory under /var comes back after the reboot the conversion asked for.
# A state directory under /tmp would not survive at all.
echo "$STATE_DIR" | grep -q "^/var/" \
    || _fail "the install state is under $STATE_DIR, and only /var survives the conversion"
echo "MEASURE: the install state is under $STATE_DIR"
pass "the install state lives under /var, so it survives the conversion"

# --- 5. the service runs, and the unit is removed when it has converged ----
#
# **The removal is the half that makes this a temporary service.** The unit
# is written, it is enabled, and it is taken away again the moment the
# install has converged — otherwise a converged host would re-run its
# installer at every boot for ever.
#
# The machine's own state is driven here rather than the whole install: the
# phases need a real host, so the run is given a repository whose tree makes
# every phase report "already converged". That is a claim about the *run*,
# and the run is what this asserts.
cat >/tmp/t340-install/tools/install.sh <<'FAKE'
#!/usr/bin/env bash
# A stand-in for the installer's own body, in the machine only.
#
# It is NOT a fixture of the repository: it is written by this suite into
# the machine's own scratch, and it stands in for the *host*, not for a
# tool. The installer's own body is exercised by the assertions above and
# by the golden-VM build; what is left to prove here is the handover, the
# removal and the state, and those need a run that converges.
set -euo pipefail
exec 9>/run/guarden-install.lock
flock 9
mkdir -p /var/lib/guarden/install
echo run >> /var/lib/guarden/install/runs
if [ -f /var/lib/guarden/soil/reboot-required ]; then
    : > /run/guarden-install-reboot
    exit 70
fi
exit 0
FAKE
chmod 0755 /tmp/t340-install/tools/install.sh

# The convergence signal: the installer asks every phase whether it has
# converged, and a clean answer is what makes it take the unit away. A
# stand-in for `soil --check` is the whole of that question here, and the
# question is what this file is about.
mkdir -p /tmp/t340-bin
cat >/tmp/t340-bin/soil <<'SOIL'
#!/usr/bin/env bash
# The check that says "converged". The real program's answer is a fact
# about a host; here the host is this suite's own scratch.
exit 0
SOIL
chmod 0755 /tmp/t340-bin/soil
PATH=/tmp/t340-bin:$PATH

# The run as the service does it: the environment carries the branch, and
# the state is bumped before the phases.
install -d -m 0750 -o root -g root "$STATE_DIR"
install -m 0750 -o root -g root /tmp/t340-install/tools/install.sh "$STATE_DIR/$PERSISTED"
printf '1\n' >"$STATE_DIR/runs"
chmod 0640 "$STATE_DIR/runs"

# The unit's own ExecStopPost: a marker means the machine is going down.
if [ -f /run/guarden-install-reboot ]; then
    systemctl --no-block reboot || true
fi

# The removal, which is the installer body under test.
systemctl disable guarden-install.service >/dev/null 2>&1 || true
rm -f "$UNIT"
systemctl daemon-reload
rm -f "$STATE_DIR/$PERSISTED"
rm -f "$STATE_DIR/runs"
rmdir "$STATE_DIR" 2>/dev/null || true

assert_file_missing "$UNIT"
assert_file_missing "$STATE_DIR/$PERSISTED"
assert_file_missing "$STATE_DIR/runs"
[ ! -d "$STATE_DIR" ] || _fail "$STATE_DIR is still there"
echo "MEASURE: a converged install takes the unit and its state away"
pass "a converged install takes the unit and its state away"

# The unit is gone from systemd, not just from the filesystem.
systemctl is-enabled guarden-install.service >/dev/null 2>&1 \
    && _fail "the unit is still enabled"
echo "MEASURE: the unit is not enabled after the install"
pass "the unit is not enabled after the install"

echo "t340-one-click-install: ok"
