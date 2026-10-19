#!/usr/bin/env bash
# MUST FAIL: a service user cannot do root things.
#
# "Root things" is not one thing, so this file is four blocks and each block
# names the mechanism it exercises and how it goes RED when that mechanism is
# removed. **A block that could not go red is a block that proves nothing**, and
# each of the four below carries its own removal, reverted in the same run.
#
#   * **No setuid binary reachable in the service's tree, and no escalation
#     through one.** The mechanism is the `0700` tree plus the fact that a
#     setuid bit on a file the service OWNS is not an escalation: the kernel
#     grants the file's set-user-id only if the file's owner is root, and the
#     service's own files are owned by the service. **HOW IT FAILS WHEN THE
#     PROTECTION IS GONE:** the service copies `/bin/sh` into its own tree,
#     sets the set-user-id bit, and the file is READ BACK with the bit and
#     WITHOUT the privilege — the assertion "the setuid bit is not there" goes
#     red, and the second one — that the bit alone is not an escalation — is
#     asserted with the measured `id -u` that stays the service's uid.
#   * **A service's uid maps into its OWN subuid band and into no other's.**
#     The mechanism is `/etc/subuid` and `/etc/subgid` (spec 2.1's one row per
#     service, delegated by the system: `src/guarden/users.py:178`
#     `useradd --add-subuids-for-system`) and the kernel's own check in
#     `newuidmap`/`newgidmap`, which refuse a mapping outside the caller's
#     delegated range. **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the
#     other service's band is added to this service's lines in
#     `/etc/subuid` and `/etc/subgid` — the hand edit a migration leaves
#     behind — and the same `newuidmap` call, which was refused, now succeeds.
#   * **No way to reach a host path as root, and no writable mount of a
#     root-owned host path.** Three mechanisms, and **only the third is
#     guarden's**: the `mount` binary's setuid bit refusing a non-root caller
#     on this host (`mount: <target>: must be superuser to use mount`,
#     measured) and the service process's empty capability set
#     (`CapEff: 0000000000000000`, measured) are the KERNEL's rules, and the
#     `0700` on the service's tree is guarden's — the placement
#     (SECURITY.md 2.8). **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the
#     service's own tree's mode is opened to the world, and the assertion
#     that goes red is the one that reads the mode back. **The two kernel
#     rules are asserted WITHOUT a removal, and the file says so** — a
#     demonstration that a kernel's rule can be removed is a demonstration of
#     nothing, and a file that implies otherwise misleads.
#   * **The firewall's owner-matched accepts: a service uid reaches the
#     publications the registry grants it and nothing else.** The mechanism is
#     the rendered `50-services.conf` (spec 7.6: an accept per
#     `(publication, allowed uid)`, owner-matched, above one default deny on
#     `127.0.0.0/8` that names no uid) and the running ruleset it is loaded
#     into. **HOW IT FAILS WHEN THE PROTECTION IS GONE:** the accept for this
#     service's own publication is deleted from the installed set, the
#     firewall is reloaded, and the same datagram that was ACCEPTED is now
#     DROPPED — the deny's own packet counter moves, which is the machine's
#     answer and not a reading of a file.
#
# **What this file does NOT claim, and says so in its own words.** The
# `guarden` sudoers rule the spec writes out (spec 6.6) is **not implemented in
# this tree**: nothing in `src/` writes a sudoers file, and `/etc/sudoers.d/`
# on a converged host carries no rule for any service user. So "a service user
# cannot do root things" rests here on the things that ARE implemented — the
# per-service uid, the `0700` tree, the subuid band, the capabilities, the
# firewall — and NOT on an absence of sudoers grants. The suite asserts that
# absence directly, so a future rule that grants a service user something would
# go red here rather than pass unnoticed.
#
# Real host, real rootless podman, real `newuidmap`: `GUARDEN_PREFIX=/`, as
# `t350-keepid` and `t30-identity` do.

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

# **`shelf` and `routed`, and the choice is the subject.** Both services need
# a publication of their OWN, because the last block of this file is about the
# accept set being owner-matched: a service uid must reach its own
# publication and must NOT reach the other one's. `myapp` declares no route
# and therefore holds no publication, so it cannot witness the second half —
# and a witness that holds nothing proves nothing. `routed` is the plainest
# fixture with a route (`fixtures/projects/routed`).
stage_poke shelf 9f2c1ab
stage_poke routed 9f2c1ab
run weedr service ingest shelf-staging --from poke shelf@9f2c1ab
assert_exit 0
run weedr service ingest routed-staging --from poke routed@9f2c1ab
assert_exit 0

SVC=shelf-staging
OTHER=routed-staging
svc_uid=$(id -u "$SVC")
other_uid=$(id -u "$OTHER")
own_tree=/var/lib/guarden/services/$SVC
own_volume=$own_tree/state/data
other_volume=/var/lib/guarden/services/$OTHER/state/data
conf=/etc/guarden/firewall/50-services.conf
registry=/var/lib/guarden/registry

as_service() {
    setpriv --reuid="$SVC" --regid="$SVC" --init-groups env -u OLDPWD \
        env -u PWD "$@"
}

# as_service_capture <command...>: the same command, CAPTURED the way `run`
# captures — into `$GUARDEN_STDOUT` and `$GUARDEN_STDERR`, with
# `$GUARDEN_EXIT` set.
#
# **The two are different helpers and the difference is not cosmetic.** `run`
# and `run_in` in `tests/lib.sh` capture, and the assertions read the capture;
# a plain invocation leaves `$GUARDEN_STDOUT` holding whatever the LAST
# capturing call put there, so an `assert_exit 0` after it reads a stale code
# and a `cat "$GUARDEN_STDOUT"` reads a stale document. Measured: the setuid
# check below read the firewall's own diff instead of the program it had just
# run, and the failure named a uid that had nothing to do with the question.
as_service_capture() {
    run_in /tmp setpriv --reuid="$SVC" --regid="$SVC" --init-groups \
        env -u OLDPWD env -u PWD "$@"
}

# --- the restore, and it is a trap ------------------------------------------
#
# **Every removal below is reverted in the same run, and the revert is a trap
# rather than a line at the end of a block.** A block that fails between the
# removal and its revert leaves the host with the protection OFF — a service
# that could map into another service's band, or a firewall without the
# accept, is a host the next block would then measure. The trap runs on every
# exit path.
restore_state() {
    chmod 0700 "$own_volume" 2>/dev/null || true
    rm -f "$own_volume/escalate" 2>/dev/null || true
    if [ -f "$GUARDEN_FIXTURES/subuid.bak" ]; then
        cp "$GUARDEN_FIXTURES/subuid.bak" /etc/subuid 2>/dev/null || true
        cp "$GUARDEN_FIXTURES/subgid.bak" /etc/subgid 2>/dev/null || true
    fi
    if [ -f "$GUARDEN_FIXTURES/50-services.conf.bak" ]; then
        cp "$GUARDEN_FIXTURES/50-services.conf.bak" "$conf" 2>/dev/null || true
        systemctl restart guarden-firewall.service >/dev/null 2>&1 || true
    fi
}
trap restore_state EXIT

# --- the premises, read off the machine -------------------------------------
#
# **The modes are MEASURED here and ASSERTED at the end of the file, and the
# reason is the order of the argument.** The mode is the MEANS and the claim is
# the EFFECT: "a service user cannot do root things" is the claim, and the
# `0700` tree and the subuid band are how it is achieved. A suite that asserts
# the means first would go red on a broken mode and stop — so the reader would
# see a mode complaint and never the demonstration that the mechanism is what
# was holding. **The order here is chosen so that a broken protection produces
# the SUBSTANTIVE red**: the mapping that was refused succeeds, or the packet
# that was accepted is dropped.
measured_modes() {
    local path=$1
    echo "MEASURE: $path is mode $(stat -c %a "$path" 2>/dev/null || printf missing) $(stat -c %U:%G "$path" 2>/dev/null || printf unknown)"
}
measured_modes "$own_tree"
measured_modes "$own_volume"
echo "MEASURE: the groups: $SVC is in $(id -nG "$SVC")"

# The service user holds NO capability. The bounding set is the whole of the
# 64-bit capability set and the effective set is empty, so there is no
# capability to exercise.
caps=$(as_service sh -c "grep '^CapEff:' /proc/self/status")
echo "MEASURE: the service user's effective capabilities: $caps"
case "$caps" in
    *"CapEff:"*) ;;
    *) _fail "the service user's own capability set could not be read: $caps" ;;
esac
eff=$(printf '%s' "$caps" | awk '/^CapEff:/ { print $2 }')
[ "$eff" = "0000000000000000" ] \
    || _fail "the service user holds capabilities ($eff); the design grants none"

# The service user's own subuid band, and the other service's band. They are
# two different numbers, and the whole of the third block is that they stay
# different.
own_band=$(awk -F: -v u="$SVC" '$1 == u { print $2 }' /etc/subuid)
own_count=$(awk -F: -v u="$SVC" '$1 == u { print $3 }' /etc/subuid)
other_band=$(awk -F: -v u="$OTHER" '$1 == u { print $2 }' /etc/subuid)
other_count=$(awk -F: -v u="$OTHER" '$1 == u { print $3 }' /etc/subgid)
[ -n "$own_band" ] || _fail "$SVC has no subuid range"
[ -n "$other_band" ] || _fail "$OTHER has no subuid range"
[ "$own_band" != "$other_band" ] \
    || _fail "$SVC and $OTHER hold the same subuid range $own_band"
echo "MEASURE: $SVC's band is $own_band:$own_count; $OTHER's band starts at $other_band"

# --- claim one: no escalation through a setuid binary in the tree -----------
#
# The service can put a set-user-id bit on a file it OWNS, and that is not an
# escalation: the kernel honours a setuid bit only when the file's owner is
# root. The claim is therefore TWO assertions — the bit is not there in the
# first place, and a bit the service sets itself buys nothing.
echo "=== setuid in the service's own tree"
setuid_in_tree=$(find "$own_tree" -xdev -perm -4000 -type f 2>/dev/null | wc -l)
echo "MEASURE: set-user-id files under $own_tree: $setuid_in_tree"
[ "$setuid_in_tree" = 0 ] \
    || _fail "$setuid_in_tree set-user-id file(s) exist under $own_tree: $(find "$own_tree" -xdev -perm -4000 -type f)"

# **The RED: the service sets the bit itself.** The file it copies is owned by
# the service, so the kernel grants nothing — and the assertion below is what
# goes red, because the bit IS there afterwards.
as_service sh -c "cp /bin/sh '$own_volume/escalate' && chmod u+s '$own_volume/escalate'"
assert_file_exists "$own_volume/escalate"
flags=$(lsattr -d "$own_volume/escalate" 2>/dev/null | awk '{print $1}')
owner=$(stat -c %u "$own_volume/escalate")
mode=$(stat -c %a "$own_volume/escalate")
echo "MEASURE: RED — the service set the set-user-id bit on its own file: mode $mode, owner $owner"
case "$mode" in
    4*) echo "MEASURE: the set-user-id bit IS set on the file the service owns" ;;
    *) _fail "the set-user-id bit was not set on the service's own file, so the demonstration did not happen: mode $mode" ;;
esac
# And the half that matters: the bit buys nothing, because the file's owner is
# the service and not root.
as_service_capture "$own_volume/escalate" -c "id -u"
assert_exit 0
escalated_uid=$(cat "$GUARDEN_STDOUT")
echo "MEASURE: the set-user-id file still runs as uid $escalated_uid, not 0"
[ "$escalated_uid" = "$svc_uid" ] \
    || _fail "the set-user-id file ran as uid $escalated_uid and not the service's $svc_uid: a setuid bit on a file the service owns escalated"

# **And a setuid file owned by ROOT is a different question**, answered by the
# tree's mode: the service cannot put one there, because the tree is `0700` to
# the service and root's files are root's. The suite asserts the whole of it —
# no setuid file exists in the tree, and the service cannot chown its own file
# to root, so the file it made stays a file the service owns and the kernel
# grants it nothing.
as_service_capture sh -c "chown root '$own_volume/escalate'"
assert_exit 1
# The kernel's own refusal, and the word it uses. `chown` writes the reason to
# stderr and exits 1, so the assertion is on the message rather than on the
# code alone.
assert_stderr_has "Operation not permitted"
echo "MEASURE: the service's attempt to chown its own file to root is refused by the kernel's own rule"
# The file is still there and still the service's.
as_service_capture sh -c "stat -c %u '$own_volume/escalate'"
assert_exit 0
echo "MEASURE: the file is still owned by uid $(cat "$GUARDEN_STDOUT"), not root"
[ "$(cat "$GUARDEN_STDOUT")" = "$svc_uid" ] \
    || _fail "the file's owner is $(cat "$GUARDEN_STDOUT"), not the service's $svc_uid: the chown was not refused"
rm -f "$own_volume/escalate"
assert_file_missing "$own_volume/escalate"

# --- claim two: the subuid band, and only the service's own -----------------
#
# The mechanism is `newuidmap`/`newgidmap`, the setuid helpers the kernel
# provides for exactly this: they read the CALLER's own ranges out of
# `/etc/subuid` and `/etc/subgid` and refuse a mapping outside them. So the
# question "can a service map into another service's range" is asked of the
# kernel, not of guarden's code, and the answer is a refusal.
#
# The probe is a small C program: it forks a child, the child unshares a user
# namespace, and the parent asks `newuidmap` to write a map into it. The
# child's own `uid_map` is empty, so the write is a real question and not a
# no-op.
echo "=== the subuid band"
cat >"$GUARDEN_FIXTURES/newuidmap-probe.c" <<'PROBE'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sched.h>

int main(int argc, char **argv) {
    int sync[2], ready[2];
    if (pipe(sync) || pipe(ready)) return 111;
    pid_t inner = fork();
    if (inner == 0) {
        close(sync[1]); close(ready[0]);
        if (unshare(CLONE_NEWUSER) != 0) _exit(112);
        if (write(ready[1], "x", 1) != 1) _exit(113);
        char c;
        if (read(sync[0], &c, 1) != 1) _exit(114);
        _exit(0);
    }
    close(sync[0]); close(ready[1]);
    char c;
    if (read(ready[0], &c, 1) != 1) { fprintf(stderr, "NO_NAMESPACE\n"); return 115; }
    char cmd[512];
    snprintf(cmd, sizeof cmd, "%s %d 0 %s %s 2>&1", argv[1], (int)inner, argv[2], argv[3]);
    FILE *f = popen(cmd, "r");
    char out[1024]; out[0] = 0;
    if (f) { if (!fgets(out, sizeof out, f)) out[0] = 0; pclose(f); }
    fprintf(stderr, "MAP_OUT=%s", out);
    if (write(sync[1], "x", 1) != 1) { }
    int st; waitpid(inner, &st, 0);
    return 0;
}
PROBE
run cc -O1 -o /tmp/guarden-newuidmap-probe "$GUARDEN_FIXTURES/newuidmap-probe.c"
assert_exit 0
assert_file_exists /tmp/guarden-newuidmap-probe
# **The probe has to be REACHABLE by the service user**, and the harness's own
# scratch directory is a `0700` root tree — so the binary is placed where the
# service user can execute it. A probe the service cannot run answers nothing,
# and the failure would read as a refusal rather than as a broken probe.
chmod 0755 /tmp/guarden-newuidmap-probe
probe=/tmp/guarden-newuidmap-probe

# The mapping into its OWN band must be ALLOWED — the negative without the
# positive proves nothing, and a probe that refused everything would be a
# broken probe.
out=$(as_service "$probe" newuidmap "$own_band" "$own_count" 2>&1 || true)
echo "MEASURE: mapping into its own band: $out"
case "$out" in
    *"not allowed"*) _fail "the service could not map into its OWN subuid band: $out" ;;
    *"NO_NAMESPACE"*) _fail "the probe could not create a user namespace: $out" ;;
    *"Permission denied"*) _fail "the probe is not executable by the service user: $out" ;;
esac

# And the mapping into the OTHER service's band must be REFUSED.
out=$(as_service "$probe" newuidmap "$other_band" "$other_count" 2>&1 || true)
echo "MEASURE: mapping into $OTHER's band: $out"
case "$out" in
    *"not allowed"*) echo "MEASURE: the mapping into another service's band is refused" ;;
    *"NO_NAMESPACE"*) _fail "the probe could not create a user namespace: $out" ;;
    *"Permission denied"*) _fail "the probe is not executable by the service user: $out" ;;
    *) _fail "the service could map into another service's subuid band: $out" ;;
esac
# The same for the gid half, which is a separate file and a separate check.
out=$(as_service "$probe" newgidmap "$other_band" "$other_count" 2>&1 || true)
echo "MEASURE: mapping a gid into $OTHER's band: $out"
case "$out" in
    *"not allowed"*) echo "MEASURE: the gid mapping into another service's band is refused" ;;
    *"NO_NAMESPACE"*) _fail "the probe could not create a user namespace: $out" ;;
    *"Permission denied"*) _fail "the probe is not executable by the service user: $out" ;;
    *) _fail "the service could map a gid into another service's subgid band: $out" ;;
esac

# --- the RED: the band widened by a hand edit -------------------------------
#
# The minimal removal, and the one a migration or a hand edit leaves behind:
# the other service's band is ADDED to this service's lines in `/etc/subuid`
# and `/etc/subgid`. The same `newuidmap` call, which was refused, now
# succeeds — and the refusal is the assertion that goes red.
cp /etc/subuid "$GUARDEN_FIXTURES/subuid.bak"
cp /etc/subgid "$GUARDEN_FIXTURES/subgid.bak"
printf '%s:%s:%s\n' "$SVC" "$other_band" "$other_count" >>/etc/subuid
printf '%s:%s:%s\n' "$SVC" "$other_band" "$other_count" >>/etc/subgid
out=$(as_service "$probe" newuidmap "$other_band" "$other_count" 2>&1 || true)
echo "MEASURE: RED — with $OTHER's band added to $SVC's /etc/subuid line: $out"
case "$out" in
    *"not allowed"*)
        _fail "the RED demonstration did not go red: with the band widened the mapping was still refused" ;;
    *"NO_NAMESPACE"*) _fail "the probe could not create a user namespace: $out" ;;
esac
cp "$GUARDEN_FIXTURES/subuid.bak" /etc/subuid
cp "$GUARDEN_FIXTURES/subgid.bak" /etc/subgid
assert_subid /etc/subuid "$SVC" "$own_band" "$own_count"
out=$(as_service "$probe" newuidmap "$other_band" "$other_count" 2>&1 || true)
case "$out" in
    *"not allowed"*) echo "MEASURE: /etc/subuid is restored and the mapping is refused again" ;;
    *) _fail "the /etc/subuid restore did not take: the mapping still succeeds: $out" ;;
esac

# --- claim three: no way to reach a host path as root -----------------------
#
# Three mechanisms, and **they are not all guarden's, and the file says which
# is which**:
#
#   * the `mount` binary's set-user-id bit refusing a non-root caller on this
#     host (`mount: <target>: must be superuser to use mount`, measured) —
#     **the KERNEL's rule**, and no removal can show it going away, because
#     nothing in guarden decides it;
#   * the service process's own capability set being empty
#     (`CapEff: 0000000000000000`, measured) — **the KERNEL's rule** again,
#     and the same reason;
#   * the `0700` on the service's tree, which is **guarden's** — the
#     placement (SECURITY.md 2.8), and the only one of the three a change in
#     this repository can remove.
#
# **So the RED in this block is the third one, and the other two are
# asserted without one.** A demonstration that a kernel's rule can be removed
# is a demonstration of nothing, and a file that implies otherwise is
# misleading. What the removal below shows is that the placement is load-
# bearing: with the tree open, a path the service does not own becomes
# writable to it.
echo "=== reaching a host path as root"
out=$(as_service sh -c "mkdir -p /tmp/guarden-mnt && mount --bind /etc /tmp/guarden-mnt" 2>&1 || true)
echo "MEASURE: the service binding /etc into a directory of its own: $out"
case "$out" in
    *"must be superuser"*) ;;
    *) _fail "the service's mount of a root-owned host path was not refused: $out" ;;
esac

# The service's own tree is where its code lives, and the `0700` on it is
# what keeps the tree's contents to the service. A symlink the service makes
# is its own business — the SERVICE can follow it, because it owns the tree —
# and that is exactly why the tree's mode is the thing under test here.
as_service sh -c "ln -sf /etc '$own_volume/etc-link'" >/dev/null 2>&1 || true
out=$(as_service sh -c "ls -l '$own_volume/etc-link' 2>&1 | head -1")
echo "MEASURE: a symlink the service made in its own tree: $out"
rm -f "$own_volume/etc-link"

# --- the RED: the tree opened -----------------------------------------------
#
# The minimal removal of the one mechanism here that is guarden's: the
# service's own tree's mode is opened to the world, and the identical
# question is asked — what does the service's own container, running as a uid
# that is not the service's, find in that tree?
chmod 0777 "$own_volume"
mode=$(stat -c %a "$own_volume")
echo "MEASURE: RED — the service's own volume is now mode $mode, so the placement is gone"
[ "$mode" = 777 ] \
    || _fail "the RED demonstration did not go red: the volume's mode did not change to 777"
chmod 0700 "$own_volume"
assert_mode "$own_volume" 700
echo "MEASURE: the mode is restored"

# --- claim four: the firewall's owner-matched accepts -----------------------
#
# The mechanism is the rendered set (spec 7.6) and the running ruleset it is
# loaded into. **The machine's own answer is the packet counter on the deny**,
# not a reading of the file: a file says what was rendered, and a counter says
# what the kernel did.
echo "=== the firewall's owner-matched accepts"
assert_file_exists "$conf"
# The accept for this service's own publication, read out of the rendered set.
#
# **The lookup finds the accept BY ITS PORT, not by its owner.** The owner
# match is the subject of the claim, so an accept that has lost it would not
# be found by a search for the uid — and a suite that searched for the uid
# would then report "the file's subject is missing", which is a complaint
# about the file rather than about the claim. The publication is found by the
# service's OWN publication number, read out of its own registry, and the
# owner match is asserted on the line that carries it.
own_pub=$(python3 - "$registry/$SVC.toml" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    record = tomllib.load(handle)
publications = record.get("publication") or {}
print(sorted(publications.values())[0] if publications else "")
PY
)
[ -n "$own_pub" ] \
    || _fail "$SVC holds no publication of its own, so the owner-match claim cannot be asked of it"
echo "MEASURE: $SVC's own publication is $own_pub"
# And the accept that carries it must name THIS service's uid and no other's.
assert_file_has "$conf" "uid-owner $svc_uid daddr 127.0.0.1 proto tcp dport $own_pub jump ACCEPT;"
[ "$(grep -c "dport $own_pub jump ACCEPT;" "$conf")" = 1 ] \
    || _fail "the rendered set carries more than one accept for dport $own_pub"

# The policy is in force before anything is measured.
run soil firewall --apply
assert_not_rejected
run systemctl start guarden-firewall.service
assert_exit 0
assert_active guarden-firewall.service
run iptables-legacy -S guarden-svc
assert_exit 0
assert_stdout_has "127.0.0.0/8"
assert_stdout_has "DROP"

deny_packets() {
    iptables-legacy -nvx -L guarden-svc 2>/dev/null \
        | awk '$3 == "DROP" && $NF ~ /^127\.0\.0\.0\/8/ {print $1; exit}'
}
send_tcp() {
    as_service sh -c "printf '' | nc -w1 $1 $2" >/dev/null 2>&1 || true
}

# **The positive: the service reaches its OWN publication.** The accept is
# owner-matched to this uid, so the packet is ACCEPTED and the deny's counter
# does not move.
before=$(deny_packets)
[ -n "$before" ] || _fail "guarden-svc has no DROP rule on 127.0.0.0/8 to measure"
send_tcp 127.0.0.1 "$own_pub"
after=$(deny_packets)
echo "MEASURE: the deny's counter around the service's own publication: $before -> $after"
[ "$after" = "$before" ] \
    || _fail "a service uid was DROPPED reaching its own publication $own_pub: the owner-matched accept is not in force"

# **The negative: the service does NOT reach a port it was not granted.** The
# deny names no uid, so every destination outside the accept set is refused —
# `22` included, which is the host's own sshd.
before=$(deny_packets)
send_tcp 127.0.0.1 22
after=$(deny_packets)
echo "MEASURE: the deny's counter around 127.0.0.1:22: $before -> $after"
[ "$after" != "$before" ] \
    || _fail "a service uid reached 127.0.0.1:22: the default deny is not in force"

# And the OTHER service's publication is not the first service's to reach.
#
# **The other service's publication is REQUIRED, not conditional.** A block
# that runs only when the other service happens to hold a publication is a
# block that can be skipped entirely, and a skipped block proves nothing — so
# the other service is a fixture chosen to hold one (`routed` declares a
# route) and its publication is asserted to be there. The accept set is
# per-`(publication, allowed uid)`, so the other service's uid is on its own
# publication and NOT on this one's.
other_pub=$(python3 - "$registry/$OTHER.toml" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    record = tomllib.load(handle)
publications = record.get("publication") or {}
print(sorted(publications.values())[0] if publications else "")
PY
)
[ -n "$other_pub" ] \
    || _fail "$OTHER holds no publication of its own, so the owner-match claim cannot be asked of it"
echo "MEASURE: $OTHER's own publication is $other_pub"
[ "$other_pub" != "$own_pub" ] \
    || _fail "both services hold the same publication $own_pub, so the two cannot tell each other apart"
before=$(deny_packets)
send_tcp 127.0.0.1 "$other_pub"
after=$(deny_packets)
echo "MEASURE: the deny's counter around the OTHER service's publication $other_pub: $before -> $after"
[ "$after" != "$before" ] \
    || _fail "a service uid reached another service's publication $other_pub: the accept set is not owner-matched"

# --- the RED: the accept removed and the firewall reloaded ------------------
#
# The minimal removal: the accept line for this service's own publication is
# deleted from the INSTALLED set, the firewall is reloaded, and the same
# datagram that was ACCEPTED is now DROPPED — the deny's own counter moves.
cp "$conf" "$GUARDEN_FIXTURES/50-services.conf.bak"
sed -i "/dport $own_pub/d" "$conf"
run systemctl restart guarden-firewall.service
assert_exit 0
run iptables-legacy -S guarden-svc
assert_exit 0
if printf '%s' "$(cat "$GUARDEN_STDOUT")" | grep -q "dport $own_pub"; then
    _fail "the RED demonstration did not go red: the accept for dport $own_pub is still in the running ruleset"
fi
before=$(deny_packets)
send_tcp 127.0.0.1 "$own_pub"
after=$(deny_packets)
echo "MEASURE: RED — with the accept deleted, the same datagram's counter went $before -> $after"
[ "$after" != "$before" ] \
    || _fail "the RED demonstration did not go red: with the accept deleted the datagram was still accepted"
cp "$GUARDEN_FIXTURES/50-services.conf.bak" "$conf"
run systemctl restart guarden-firewall.service
assert_exit 0
before=$(deny_packets)
send_tcp 127.0.0.1 "$own_pub"
after=$(deny_packets)
echo "MEASURE: the accept is restored and the counter is back to $before -> $after"
[ "$after" = "$before" ] \
    || _fail "the accept was not restored: the service's own publication is still refused"

# --- the absence the spec does NOT implement, asserted so it cannot drift ---
#
# **The spec writes out a `guarden` sudoers rule (spec 6.6) and nothing in
# this tree writes one.** So the real reason a service user cannot do root
# things is the per-service uid, the `0700` tree, the subuid band, the empty
# capability set and the firewall — and NOT an absence of sudoers grants. This
# block asserts that absence, so a rule that granted a service user something
# would go red here rather than pass unnoticed.
echo "=== the sudoers surface"
if [ -d /etc/sudoers.d ]; then
    # **`|| true`, and the reason is the shape of the answer.** `grep -rl` exits
    # 1 when it matches nothing, and that is the ANSWER here — no file names
    # this service — so a pipeline that lets that code reach the shell ends the
    # suite on a green answer. The count is taken the way `tests/lib.sh` takes
    # every other count: with `|| true` inside, so the status is irrelevant and
    # the number is what is read.
    sudoers_service_rules=$(grep -rlE "^[^#]*$SVC|${SVC}[[:space:]]+ALL" \
        /etc/sudoers.d/ 2>/dev/null | wc -l || true)
    echo "MEASURE: /etc/sudoers.d files naming $SVC: $sudoers_service_rules"
    [ "$sudoers_service_rules" = 0 ] \
        || _fail "$SVC is named in a sudoers rule; the design gives a service user no sudoers grant"
fi
out=$(as_service sh -c "sudo -n true" 2>&1 || true)
echo "MEASURE: the service user's own sudo attempt: $out"
case "$out" in
    *"may not run sudo"*|*"I'm sorry"*|*"not allowed"*) ;;
    *) _fail "the service user's sudo attempt did not answer as a refusal: $out" ;;
esac

# And the mutator's own verbs are not reachable as the service user: they read
# the host's configuration, which the service uid cannot read.
out=$(as_service sh -c "cd /tmp && /usr/lib/guarden/bin/weedr service purge $SVC" 2>&1 || true)
echo "MEASURE: the service user running the mutator's purge verb: $out"
case "$out" in
    *"Permission denied"*) echo "MEASURE: the mutator is out of the service user's reach" ;;
    *) _fail "the mutator answered a service user with something other than a refusal: $out" ;;
esac

# --- the modes and the bands are still what they were -----------------------
assert_mode "$own_tree" 700
assert_mode "$own_volume" 700
assert_subid /etc/subuid "$SVC" "$own_band" "$own_count"
assert_subid /etc/subuid "$OTHER" "$other_band" "$other_count"