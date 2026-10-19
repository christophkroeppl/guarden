#!/usr/bin/env bash
# MUST FAIL: a service user cannot change guarden's own files, the soil state,
# or another service's files.
#
# The operator's list is literal and each of its three halves is a different
# mechanism, so this file is three blocks and each block names the mechanism it
# exercises and how it goes RED when that mechanism is removed.
#
#   * **guarden's own files.** `/usr/lib/guarden/` is `root:root` (spec 2: "guarden's
#     own files, root-owned, never written by a deploy"), `/etc/guarden/` is
#     `0751 root:guarden` with every file in it `0640 root:guarden` (spec 2.1),
#     and `/etc/guarden/creds/` is `0700 root` (spec 2.1) with its blobs `0600`.
#     A service uid is in NEITHER group — `id shelf-staging` names only its own
#     group — and is not the owner, so it can neither write nor unlink any of
#     them. **Placemement is the whole mechanism** (SECURITY.md 2.8): none of
#     these files is inside a service's own tree, so there is no directory the
#     service user owns from which to unlink them.
#     **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the file's own mode is
#     `chmod 0666`ed (and the creds directory `chmod 0777`ed), the identical
#     write is retried, and it now succeeds — so the assertion goes red.
#   * **the soil state.** `/var/lib/guarden/soil/` is `0750 root:guarden`
#     (spec 2.1) and holds the btrfs conversion state and the reboot marker
#     (`src/guarden/hostprep.py:79-87` is the row; `_conversion_marker` at
#     `hostprep.py:1144` is the reader). A service uid cannot write it, so a
#     service cannot fake a converged host or arm a reboot it did not ask for.
#     **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the directory's mode is
#     `chmod 0777`ed, the identical write is retried, and it now succeeds.
#   * **another service's files.** `/var/lib/guarden/services/<name>` and
#     everything under it is `0700` to that service's own user (spec 2.1;
#     `src/guarden/service.py:62` `TREE_MODE = 0o700`, applied at
#     `service.py:784`). `/var/lib/guarden/services/` above it is `0711`, so a
#     service user can TRAVERSE to a tree it owns and cannot LIST the others.
#     **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the other tree's mode is
#     `chmod 0777`ed, the identical write is retried, and it now succeeds.
#
# **The ONE thing that is legitimately shared, and the leak it does not have.**
# The registry is `0640 root:guarden` (spec 2.1) — group-readable by `guarden`,
# and the `guarden` group is the unprivileged programs' group, NOT a service
# group. So a service uid reads nothing there, and this file asserts that. The
# one thing that IS shared between two principals is a service's own record
# read by the `guarden` user, and the point the suite pins is that the sharing
# runs one way: `guarden` reads the registry, a service uid reads nothing of
# it, and NOBODY but root writes it — including the `guarden` user, whose
# membership in the group gives it the read and not the write (`0640`, and the
# directory is `0750`, so the group bit on the directory is `r-x`).
# **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the service user is added to
# the `guarden` group — the smallest real change that widens the sharing — and
# the read it must not have appears. The WRITE stays refused even then, and
# that is asserted too, because "readable" and "writable" are two different
# grants and the mode carries both.
#
# Real host, real `useradd`, real group database: `GUARDEN_PREFIX=/`, as
# `t30-identity` and `t80-edges` do.

# machine: fresh

. "$(dirname "$0")/lib.sh"

export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/

ensure_accounts
stage_config guarden-nomodules.toml
stage_podlet_release
run soil packages --apply
assert_not_rejected
run soil install --apply
assert_exit 0
# **The storage phase too, and the reason is which phase owns which row.**
# `/var/lib/guarden/soil/` is `0750 root:guarden` by a row of the STORAGE
# phase's own table (`src/guarden/hostprep.py:86`, `STORAGE_DIRECTORIES`),
# and the install phase's table (`INSTALL_DIRECTORIES`, `hostprep.py:90`) has
# no row for it. So a suite that converges only the install phase never
# exercises the mode the claim rests on — measured: with the storage row
# mutated to `0777` and only `soil install --apply` run, the directory kept
# its old mode and the suite stayed green. **A claim about a mode is a claim
# about the phase that sets it**, and the phase has to run.
run soil storage --apply
assert_not_rejected

stage_poke shelf 9f2c1ab
stage_poke myapp 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0
run weedr service ingest myapp-staging --from poke myapp@9f2c1ab
assert_exit 0

SVC=shelf-staging
OTHER=myapp-staging
svc_uid=$(id -u "$SVC")
other_uid=$(id -u "$OTHER")
own_tree=/var/lib/guarden/services/$SVC
other_tree=/var/lib/guarden/services/$OTHER
registry=/var/lib/guarden/registry

# `as_service <command...>`: a command as the service user, with the service
# user's REAL supplementary groups.
#
# **`--init-groups`, and the reason it is that and not `--clear-groups`.** The
# service user's own group is what the `0700` trees are keyed on, and the
# `guarden` group is what the registry's group bit is keyed on — so a probe
# that drops the supplementary groups is measuring a principal the box does not
# have. `--clear-groups` would hide the registry leak this file exists to
# demonstrate, and `--keep-groups` needs `--init-groups` to be a valid
# combination at all. `--init-groups` reads the group database for the target
# uid, which is the real thing: it is what the `guarden` group's own members
# get, and what a service user that was added to it would get.
as_service() {
    setpriv --reuid="$SVC" --regid="$SVC" --init-groups env -u OLDPWD \
        env -u PWD "$@"
}

# --- the restore, and it is a trap ------------------------------------------
#
# **Every removal below is reverted in the same run, and the revert is a trap
# rather than a line at the end of a block.** A block that fails between the
# removal and its revert leaves the host with the protection OFF, and every
# assertion after it would then be measuring a host that is not the one this
# suite describes. The trap runs on every exit path, so the revert is a
# property of the run rather than of the run having been lucky.
restore_state() {
    chmod 0640 /etc/guarden/guarden.toml 2>/dev/null || true
    chown root:guarden /etc/guarden/guarden.toml 2>/dev/null || true
    chmod 0751 /etc/guarden 2>/dev/null || true
    chown root:guarden /etc/guarden 2>/dev/null || true
    chmod 0700 /etc/guarden/creds 2>/dev/null || true
    chown root:root /etc/guarden/creds 2>/dev/null || true
    chmod 0750 /var/lib/guarden/soil 2>/dev/null || true
    chown root:guarden /var/lib/guarden/soil 2>/dev/null || true
    chmod 0700 "$other_tree/state/data" "$other_tree/state" "$other_tree" 2>/dev/null || true
    chown "$OTHER:$OTHER" "$other_tree/state/data" "$other_tree/state" "$other_tree" 2>/dev/null || true
    rm -f /etc/guarden/creds/x.cred /etc/guarden/new-file.toml 2>/dev/null || true
    rm -f /var/lib/guarden/soil/reboot-required 2>/dev/null || true
    rm -f "$other_tree/state/data/pwn" 2>/dev/null || true
    gpasswd --delete "$SVC" guarden >/dev/null 2>&1 || true
}
trap restore_state EXIT

# `write_denied <path> <message>`: a write into a path the service user does
# not own must be refused, and the refusal must say so.
#
# The command is run through `sh -c` so the shell's own message reaches the
# assertion; the exit code alone would not say WHY, and a refusal for the wrong
# reason (a missing directory, a full disk) reads the same.
write_denied() {
    local path=$1
    as_service sh -c "echo pwned > '$path'" 2>&1 || true
}

# --- the modes are the mechanism, and they are MEASURED before they are used -
#
# A denial measured against a mode that is not there is a denial for the wrong
# reason, so each mode the claim rests on is read off the machine first. The
# numbers are the spec's own (spec 2.1).
#
# **They are READ here and ASSERTED at the end of the file, and the reason is
# the order of the argument.** The mode is the MEANS and the claim is the
# EFFECT: "a service user cannot change guarden's own files" is the claim, and
# the `0640 root:guarden` is how it is achieved. A suite that asserts the
# means first would go red on a broken mode and stop — so the reader would see
# a mode complaint and never the demonstration that the mode is what was
# holding. **The order here is chosen so that a broken protection produces the
# SUBSTANTIVE red**: the write that was refused succeeds, which is the fact
# about the security model rather than about a number in a table. The modes
# are asserted at the end, where a drift in them is still a red, and where
# reaching that point means every claim above held.
measured_modes() {
    local path=$1
    echo "MEASURE: $path is mode $(stat -c %a "$path" 2>/dev/null || printf missing) $(stat -c %U:%G "$path" 2>/dev/null || printf unknown)"
}
measured_modes "$own_tree"
measured_modes "$other_tree"
measured_modes /var/lib/guarden/services
measured_modes /var/lib/guarden/registry
measured_modes "$registry/$SVC.toml"
measured_modes /var/lib/guarden/soil
measured_modes /etc/guarden
measured_modes /etc/guarden/guarden.toml
measured_modes /etc/guarden/creds
measured_modes /usr/lib/guarden

# **The service user is in neither of guarden's two groups.** The `guarden`
# group is the unprivileged PROGRAMS' group, and the `edge` group is the edge
# service's; a service user is in neither unless an admin put it there. This is
# the fact every denial below rests on, so it is read off the machine and not
# assumed.
svc_groups=$(id -nG "$SVC")
echo "MEASURE: $SVC's groups: $svc_groups"
case " $svc_groups " in
    *" guarden "*) _fail "$SVC is in the guarden group, so the registry's group bit would name it" ;;
esac
assert_no_supplementary_group "$SVC" guarden
assert_no_supplementary_group "$SVC" edge

# --- the control: the service user CAN write its OWN tree --------------------
#
# **The negative without the positive proves nothing.** If every write below
# were refused because the probe was broken, the file would still be green. So
# the same principal, the same command shape, the same tree it OWNS: it must
# succeed. That is what makes the refusals refusals rather than a broken probe.
as_service sh -c "echo mine > '$own_tree/state/data/mine'"
assert_file_exists "$own_tree/state/data/mine"
owner=$(stat -c %u "$own_tree/state/data/mine")
[ "$owner" = "$svc_uid" ] \
    || _fail "the file $SVC wrote in its own tree is owned by uid $owner, not its own $svc_uid"
rm -f "$own_tree/state/data/mine"
echo "MEASURE: $SVC can write its own tree, and the file it leaves is owned by its own uid"

# --- claim one: guarden's own files -----------------------------------------
#
# Three files and three mechanisms, and the third is the interesting one: the
# creds directory is `0700 root`, so a service uid cannot even LIST it — a
# different denial from "cannot write this file in it".
echo "=== guarden's own files"
out=$(write_denied /usr/lib/guarden/bin/loom)
echo "MEASURE: writing a program under /usr/lib/guarden: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write into /usr/lib/guarden/bin was not refused: $out" ;;
esac

out=$(write_denied /etc/guarden/guarden.toml)
echo "MEASURE: appending to the host configuration: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write into /etc/guarden/guarden.toml was not refused: $out" ;;
esac

# **And the unlink, which is the one a mode on a file does not stop.** The
# file is `0640 root:guarden` and the service user is in neither group and does
# not own it, so it cannot write it — and it cannot unlink it either, because
# unlink needs write permission on the DIRECTORY, which is `0751 root:guarden`.
# This is SECURITY.md 2.8's own point: "Placement is the whole mechanism: a
# mode on a file inside a directory the user owns says nothing about unlinking
# it."
out=$(as_service sh -c "rm -f /etc/guarden/guarden.toml" 2>&1 || true)
echo "MEASURE: unlinking the host configuration: ${out:-<no message: the unlink SUCCEEDED>}"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could unlink /etc/guarden/guarden.toml: ${out:-the unlink succeeded and printed nothing}" ;;
esac
assert_file_exists /etc/guarden/guarden.toml

# The creds directory: `0700 root`, so the service user cannot enter it at all.
out=$(as_service sh -c "ls /etc/guarden/creds" 2>&1 || true)
echo "MEASURE: listing the credential directory: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could list /etc/guarden/creds: $out" ;;
esac
out=$(write_denied /etc/guarden/creds/x.cred)
echo "MEASURE: writing a credential blob: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write into /etc/guarden/creds was not refused: $out" ;;
esac
assert_file_missing /etc/guarden/creds/x.cred

# --- the RED: guarden's own files opened ------------------------------------
#
# The minimal removal, and it is reverted in the same run. **Two grants, and
# they are two grants:** a new file in `/etc/guarden` needs the DIRECTORY's
# write bit, and a change to `/etc/guarden/guarden.toml` needs the FILE's own
# write bit. SECURITY.md 2.8 says the placement is the whole mechanism, and
# these are the two halves of it: the directory is `0751 root:guarden` and the
# file is `0640 root:guarden`, and a service user is in neither group.
#
# **The evidence is the FILE, not the command's output.** `echo pwned >> f`
# sends the text into the file and prints nothing to stdout, so a check on
# stdout reads "the write was refused" for a write that succeeded — which is
# the exact false negative a RED demonstration must not have.
cp /etc/guarden/guarden.toml "$GUARDEN_FIXTURES/guarden.toml.bak"
chmod 0666 /etc/guarden/guarden.toml
as_service sh -c "echo pwned >> /etc/guarden/guarden.toml" >/dev/null 2>&1 || true
if grep -q "^pwned$" /etc/guarden/guarden.toml; then
    echo "MEASURE: RED — with the host configuration at 0666 the very same write SUCCEEDED"
else
    _fail "the RED demonstration did not go red: with the host configuration at 0666 the same write was still refused"
fi
cp "$GUARDEN_FIXTURES/guarden.toml.bak" /etc/guarden/guarden.toml
chmod 0640 /etc/guarden/guarden.toml
chown root:guarden /etc/guarden/guarden.toml
assert_mode /etc/guarden/guarden.toml 640
assert_owner /etc/guarden/guarden.toml root:guarden
assert_file_lacks /etc/guarden/guarden.toml "pwned"
echo "MEASURE: the host configuration is restored"

# And the DIRECTORY's half: creating a NEW file under /etc/guarden needs the
# directory's write bit, and the directory is `0751` — so even a service user
# in the `guarden` group could not create one.
chmod 0777 /etc/guarden
as_service sh -c "echo pwned > /etc/guarden/new-file.toml" >/dev/null 2>&1 || true
if [ -e /etc/guarden/new-file.toml ]; then
    echo "MEASURE: RED — with the configuration directory at 0777 the very same creation SUCCEEDED"
else
    _fail "the RED demonstration did not go red: with the configuration directory at 0777 the same creation was still refused"
fi
rm -f /etc/guarden/new-file.toml
chmod 0751 /etc/guarden
chown root:guarden /etc/guarden
assert_mode /etc/guarden 751
assert_owner /etc/guarden root:guarden
assert_file_missing /etc/guarden/new-file.toml
echo "MEASURE: the configuration directory's mode is restored"

# The creds directory's own RED: `chmod 0777` on the directory, and the same
# write of a blob.
chmod 0777 /etc/guarden/creds
out=$(as_service sh -c "echo pwned > /etc/guarden/creds/x.cred" 2>&1 || true)
if [ -e /etc/guarden/creds/x.cred ]; then
    echo "MEASURE: RED — with the credential directory at 0777 the very same write SUCCEEDED"
else
    _fail "the RED demonstration did not go red: with the credential directory at 0777 the same write was still refused: $out"
fi
rm -f /etc/guarden/creds/x.cred
chmod 0700 /etc/guarden/creds
assert_mode /etc/guarden/creds 700
assert_owner /etc/guarden/creds root:root
assert_file_missing /etc/guarden/creds/x.cred
echo "MEASURE: the credential directory's mode is restored"

# --- claim two: the soil state ----------------------------------------------
#
# `/var/lib/guarden/soil/` holds the conversion state and the reboot marker —
# the two files that decide whether the host converger believes the box is
# converged. A service that could write them could fake a converged host, or
# arm a reboot it did not ask for.
echo "=== the soil state"
assert_file_exists /var/lib/guarden/soil/state
out=$(write_denied /var/lib/guarden/soil/state)
echo "MEASURE: writing the conversion state: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write into /var/lib/guarden/soil was not refused: $out" ;;
esac
out=$(write_denied /var/lib/guarden/soil/reboot-required)
echo "MEASURE: arming the reboot marker: ${out:-<no message: the write SUCCEEDED>}"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write of the reboot marker was not refused: ${out:-the write succeeded and printed nothing}" ;;
esac
assert_file_missing /var/lib/guarden/soil/reboot-required

# --- the RED: the soil state opened -----------------------------------------
chmod 0777 /var/lib/guarden/soil
out=$(as_service sh -c "echo pwned > /var/lib/guarden/soil/reboot-required" 2>&1 || true)
if [ -e /var/lib/guarden/soil/reboot-required ]; then
    echo "MEASURE: RED — with the soil state at 0777 the very same write SUCCEEDED"
else
    _fail "the RED demonstration did not go red: with the soil state at 0777 the same write was still refused: $out"
fi
rm -f /var/lib/guarden/soil/reboot-required
chmod 0750 /var/lib/guarden/soil
assert_mode /var/lib/guarden/soil 750
assert_owner /var/lib/guarden/soil root:guarden
assert_file_missing /var/lib/guarden/soil/reboot-required
echo "MEASURE: the soil state's mode is restored"

# --- claim three: another service's files ------------------------------------
#
# The `0711` on `services/` above is a TRAVERSE grant, not a LIST grant: the
# service user can walk to a tree it owns and cannot enumerate the others.
# That distinction is asserted, because "the service user cannot see the other
# services" is only half of it and the half that would break the box if it
# were true.
echo "=== another service's files"
out=$(as_service sh -c "ls /var/lib/guarden/services" 2>&1 || true)
echo "MEASURE: listing the services directory: $out"
case "$out" in
    *"$OTHER"*) _fail "listing /var/lib/guarden/services named the other service: $out" ;;
esac
out=$(write_denied "$other_tree/state/data/pwn")
echo "MEASURE: writing into the other service's volume: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a write into another service's tree was not refused: $out" ;;
esac
assert_file_missing "$other_tree/state/data/pwn"

out=$(as_service sh -c "rm -f '$other_tree/state/data'" 2>&1 || true)
echo "MEASURE: unlinking the other service's volume: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could unlink another service's volume: $out" ;;
esac
assert_file_exists "$other_tree/state/data"

# --- the RED: the other service's tree opened -------------------------------
chmod 0777 "$other_tree" "$other_tree/state" "$other_tree/state/data"
out=$(as_service sh -c "echo pwned > '$other_tree/state/data/pwn'" 2>&1 || true)
if [ -e "$other_tree/state/data/pwn" ]; then
    echo "MEASURE: RED — with the other service's tree at 0777 the very same write SUCCEEDED"
    echo "MEASURE: the file it left is owned by host uid $(stat -c %u "$other_tree/state/data/pwn"), not the other service's $other_uid"
else
    _fail "the RED demonstration did not go red: with the other service's tree at 0777 the same write was still refused: $out"
fi
rm -f "$other_tree/state/data/pwn"
chmod 0700 "$other_tree/state/data" "$other_tree/state" "$other_tree"
assert_mode "$other_tree" 700
assert_owner "$other_tree" "$OTHER:$OTHER"
assert_file_missing "$other_tree/state/data/pwn"
echo "MEASURE: the other service's tree's modes are restored"

# --- the ONE shared thing, and the leak it does not have --------------------
#
# The registry is `0640 root:guarden` and the `guarden` group is the
# unprivileged PROGRAMS' group — so a service user is not in it, and reads
# nothing there. The sharing that IS legitimate runs from `guarden` to the
# registry (the renderer and the mutator read the records), and from nobody to
# a service uid.
echo "=== the registry"
out=$(as_service sh -c "cat '$registry/$SVC.toml'" 2>&1 || true)
echo "MEASURE: a service user reading its OWN record: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could read its own registry record: $out" ;;
esac
out=$(as_service sh -c "cat '$registry/$OTHER.toml'" 2>&1 || true)
echo "MEASURE: a service user reading ANOTHER service's record: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could read another service's registry record: $out" ;;
esac
out=$(write_denied "$registry/$SVC.toml")
echo "MEASURE: a service user writing its OWN record: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "a service user could write its own registry record: $out" ;;
esac

# **And the direction that IS shared, asserted from the other side:** the
# `guarden` user reads the records, because the group bit on the file is the
# read grant and the `guarden` group is its holder. A suite that only ever
# denies would not notice a mode that had been tightened to `0600` and broken
# the renderer.
out=$(setpriv --reuid=guarden --regid=guarden --init-groups env -u OLDPWD \
    cat "$registry/$OTHER.toml" 2>&1 || true)
echo "MEASURE: the guarden user reading a record: $(printf '%s' "$out" | head -1)"
case "$out" in
    *"Permission denied"*) _fail "the guarden user cannot read a registry record, so the registry's group bit is not doing what it is for" ;;
    *"service = "*) ;;
    *) _fail "the guarden user's read of a registry record returned nothing: $out" ;;
esac
# And the group bit is a READ, not a write: the directory is `0750`, so the
# group cannot create a file in it, and the file is `0640`, so the group cannot
# rewrite it.
out=$(setpriv --reuid=guarden --regid=guarden --init-groups env -u OLDPWD \
    sh -c "echo pwned > '$registry/$OTHER.toml'" 2>&1 || true)
echo "MEASURE: the guarden user rewriting a record: $out"
case "$out" in
    *"Permission denied"*) ;;
    *) _fail "the guarden user could rewrite a registry record: $out" ;;
esac
assert_file_lacks "$registry/$OTHER.toml" "pwned"

# --- the RED: the sharing widened -------------------------------------------
#
# The smallest real change that widens the sharing: the service user is added
# to the `guarden` group, which is what the group's `r` bit on a `0640` file
# is for. The read it must not have appears — and the write stays refused,
# because `0640` and a `0750` directory are two different grants.
usermod --append --groups guarden "$SVC"
assert_supplementary_group "$SVC" guarden
out=$(as_service sh -c "cat '$registry/$OTHER.toml'" 2>&1 || true)
if printf '%s' "$out" | grep -q "service = "; then
    echo "MEASURE: RED — with $SVC in the guarden group it reads another service's record, which is the leak the group membership opens"
else
    _fail "the RED demonstration did not go red: with $SVC in the guarden group the read was still refused: $out"
fi
out=$(as_service sh -c "echo pwned > '$registry/$OTHER.toml'" 2>&1 || true)
case "$out" in
    *"Permission denied"*) echo "MEASURE: the widened grant is a READ only: the write is still refused, as the 0640 and the 0750 directory make it" ;;
    *) _fail "with $SVC in the guarden group it could also WRITE another service's record: $out" ;;
esac
assert_file_lacks "$registry/$OTHER.toml" "pwned"

# Reverted in the same run.
gpasswd --delete "$SVC" guarden >/dev/null 2>&1
assert_no_supplementary_group "$SVC" guarden
out=$(as_service sh -c "cat '$registry/$OTHER.toml'" 2>&1 || true)
case "$out" in
    *"Permission denied"*) echo "MEASURE: the group membership is removed and the read is refused again" ;;
    *) _fail "the group membership was not removed: the read still succeeds: $out" ;;
esac

# --- and the modes are still what they were ---------------------------------
assert_mode "$own_tree" 700
assert_mode "$other_tree" 700
assert_mode /var/lib/guarden/registry 750
assert_mode "$registry/$SVC.toml" 640
assert_mode /var/lib/guarden/soil 750
assert_mode /etc/guarden 751
assert_mode /etc/guarden/guarden.toml 640
assert_mode /etc/guarden/creds 700
assert_mode /usr/lib/guarden 755
