#!/usr/bin/env bash
# soil install: what it creates, and the two things it must not.
#
# It creates the two program users and the one group, and it is the only phase
# that writes outside the host's own storage. It must create no service
# identity of any kind -- no service user, no service directory, no state
# volume, no snapper configuration for anything guarden does not own -- and it
# must create no group beyond `guarden`, because a host with no edge module has
# no `edge` group and the edge's group belongs to `weedr module add gate-traefik`.

. "$(dirname "$0")/lib.sh"

# The machine's own tools, not the stand-ins that used to be in fixtures/bin:
# that directory and its PATH entry were deleted with the fake tier (ticket 35,
# ADR-0014), and both the assertions below and the programs under them have to
# reach the real `getent`, `dpkg-query`, `systemctl`,
# `snapper`, `sysctl` and `install` -- otherwise this file is asking a fake what
# it had been asked to do, which is the whole thing the rewrite exists to stop.
# `.venv/bin` is kept first because it is the checkout's interpreter and not a
# stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/

# This file owns the phase's starting state, because which items drift is
# otherwise a fact about whichever file ran before it on a shared machine: the
# configuration is unseeded and the programs are not installed, so both items
# below are drift this run provably caused rather than inherited. The apply puts
# both back.
rm -f /etc/guarden/guarden.toml
rm -rf /usr/lib/guarden
etcd_before=$(stat -c %y /etc/guarden)

run soil install --check
assert_exit 1
assert_stderr_has "drift: the host configuration exists"
assert_stderr_has "drift: guarden's programs are installed root-owned"

# `--check` changed nothing: no file appeared under the configuration
# directory, and the directory's own mtime is the proof, because every write
# guarden makes into /etc/guarden is a create or a rename inside it.
assert_file_missing /etc/guarden/guarden.toml
[ "$(stat -c %y /etc/guarden)" = "$etcd_before" ] \
    || _fail "--check wrote into /etc/guarden"

# Every item of the phase converges on this machine, and the alias is one of
# them: it is derived from the pinned `[network] pasta_options` in the table the
# phase seeds, so nothing is measured and nothing needs a container image this
# repository does not ship. The apply is exit 0 and silent — a converged host —
# and the drift count the alias item is evidence for comes back below, planted.
run soil install --apply
assert_exit 0
assert_stderr_empty

# The shipped table is seeded, and it is a table and not a list in the code: a
# track is a row, and adding one is appending a block.
assert_file_has /etc/guarden/guarden.toml "[[environments]]"
assert_file_has /etc/guarden/guarden.toml 'name = "production"'
assert_file_has /etc/guarden/guarden.toml 'name = "preview"'
assert_file_has /etc/guarden/guarden.toml 'fork_from = "production"'

# The programs, templates and units are in /usr/lib/guarden, root-owned and
# never written by a deploy.
assert_file_exists /usr/lib/guarden/bin/soil
assert_file_exists /usr/lib/guarden/bin/weedr
assert_file_exists /usr/lib/guarden/bin/hose
assert_file_has /etc/tmpfiles.d/guarden-tmpfiles.conf "d /run/guarden"

# The two program users and the one group, and nothing else. What the account is
# is the claim, not the argv that made it: a system account with no login shell,
# no home and the guarden group as its primary group. `--no-create-home` is
# asserted as the absence of a home directory rather than as the flag, because
# the flag is an intent and the missing directory is the outcome.
guarden_gid=$(getent group guarden | cut -d: -f3)
assert_group guarden
assert_passwd guarden
assert_passwd hose
assert_passwd_field guarden 4 "$guarden_gid"
assert_passwd_field hose 4 "$guarden_gid"
assert_passwd_field guarden 7 /usr/sbin/nologin
assert_passwd_field hose 7 /usr/sbin/nologin
assert_file_missing /home/guarden
assert_file_missing /home/hose
assert_no_group edge

# `admin_user` is the uid allowed to reach the edge's API, so it is recorded
# when it is empty -- and left alone afterwards, which is why the recorded value
# is asserted to be a value rather than the template's empty string.
assert_file_has /etc/guarden/guarden.toml 'admin_user = "'
assert_file_lacks /etc/guarden/guarden.toml 'admin_user = ""'

# No service identity of any kind.
assert_no_passwd myapp-production
assert_file_missing /var/lib/guarden/services/myapp-production
assert_file_missing /var/lib/guarden/services/myapp-production/state

# The render directory is the one the unprivileged programs may write into, and
# the lock directory carries the same owner for the same reason -- unprivileged
# programs take those locks -- plus setgid, so a lock file created by either
# caller is group `guarden` and both can open it (conf.lock states 0664; the
# mode argument of open() is umask-filtered and would be). The group is the
# load-bearing half of both: `root:guarden` on the registry is what makes it
# readable by the programs that run as `guarden`.
assert_mode /var/lib/guarden/render 0770
assert_owner /var/lib/guarden/render guarden:guarden
assert_mode /run/guarden/locks 2770
assert_owner /run/guarden/locks root:guarden

# ADR-0005's two units, plus the instantiable per-blob unit the path triggers,
# which carries no [Install] so it cannot fire at boot and double-materialise.
assert_file_exists /etc/systemd/system/guarden-credential-materialiser@.service
assert_file_lacks /etc/systemd/system/guarden-credential-materialiser@.service "[Install]"
assert_file_has /etc/systemd/system/guarden-credential-materialiser@.service \
    "ExecStart=/usr/lib/guarden/bin/weedr secret materialise %i"
assert_file_exists /etc/systemd/system/guarden-creds.path
assert_file_exists /etc/systemd/system/guarden-creds-boot.service
assert_file_has /etc/systemd/system/guarden-creds-boot.service \
    "ExecStart=/usr/lib/guarden/bin/weedr secret materialise"
assert_file_has /etc/systemd/system/guarden-creds-boot.service "WantedBy=multi-user.target"
assert_file_has /etc/systemd/system/guarden-creds-boot.service "After=snapperd.service"
assert_file_has /etc/systemd/system/guarden-creds.path "PathChanged=/etc/guarden/creds/"

# **Both of the pair are enabled, and the boot oneshot was not.** It carries
# WantedBy=multi-user.target, so `enable` is the only thing that makes boot
# materialisation happen: the path unit answers a *change* under the blob
# directory and never fires on a host nobody wrote to, so without this a reboot
# left every planted value encrypted and unread. Asserted of the machine, not of
# the argv that was supposed to produce it, and after the apply above because
# this is the converge that enables them.
assert_enabled guarden-creds.path
assert_enabled guarden-creds-boot.service

# **The alias item is still the phase's last, and the count is re-derived
# against it.** The old shape could leave one drift line on a converged host
# because the probe could not run; the new one holds on any host whose table
# pins the set, so the evidence is planted: an alias the table does not name —
# empty, the state a host whose converge has not run is in — is drift, and
# exactly one line of it, because every other item on this host has converged.
# One line and no other is the whole of the claim that the item is last, and the
# enable items above are converged, so they are not the extra line a new item
# would otherwise add here.
sed -i 's/^alias = .*/alias = ""/' /etc/guarden/guarden.toml
run soil install --check
assert_exit 1
# The line count is read with wc and not with lib.sh's assert_one_diagnostic,
# whose `grep -c` prints 0 for no match while exiting 1 -- so its `|| true` turns
# an empty stderr into a pass.
[ "$(wc -l < "$GUARDEN_FIXTURES/stderr")" = 1 ] \
    || _fail "expected exactly one drift line, got $(wc -l < "$GUARDEN_FIXTURES/stderr")"
assert_stderr_has "drift: ingress.alias"
assert_stderr_has "the edge does not start without it"
# And the converge puts the derived address back: an alias that is not the one
# the pinned set names is repaired, not left, and the host that has it is
# converged again.
run soil install --apply
assert_exit 0
assert_stderr_empty
assert_file_has /etc/guarden/guarden.toml 'alias = "10.0.2.2"'

# guarden.toml has three writers and two of them share a key, so a write takes
# the modules lock and rewrites only the key it owns. The file is otherwise the
# shipped one, with the operator's own tracks intact.
assert_file_exists /run/guarden/locks/modules.lock
assert_file_has /etc/guarden/guarden.toml 'publication_range = [20000, 32767]'
assert_file_has /etc/guarden/guarden.toml 'pasta_options = [ "--map-gw", "--ipv4-only", "-a", "10.0.2.100", "-n", "24", "-g", "10.0.2.2" ]'

# A second apply converges nothing that it can: no account and no group is
# created, and no installed file is rewritten. The counts are the claim, and the
# inode is the proof for the file -- a converge writes through a temporary in the
# same directory and renames, so a rewrite cannot leave the inode it found.
accounts=$(getent passwd | wc -l)
groups=$(getent group | wc -l)
tmpfiles_inode=$(stat -c %i /etc/tmpfiles.d/guarden-tmpfiles.conf)
run soil install --apply
assert_exit 0
[ "$(getent passwd | wc -l)" = "$accounts" ] \
    || _fail "a second apply created an account"
[ "$(getent group | wc -l)" = "$groups" ] \
    || _fail "a second apply created a group"
[ "$(stat -c %i /etc/tmpfiles.d/guarden-tmpfiles.conf)" = "$tmpfiles_inode" ] \
    || _fail "a second apply rewrote guarden-tmpfiles.conf"
assert_passwd guarden
assert_passwd hose
assert_no_group edge

# And the host still answers exactly the same question, which is the same claim
# asked from the other side and is stronger than a run that made no calls: a
# converged host is silent, the alias among the rest — it holds the address the
# pinned set names, so there is nothing left for the phase to say.
run soil install --check
assert_exit 0
assert_stderr_empty
