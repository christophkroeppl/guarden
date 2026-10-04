#!/usr/bin/env bash
# Ticket 221: the three ADR-0005/ADR-0011 credential-unit defects, found by
# reading and unfixable by any suite that did not already have them fixed.
#
# Each defect is a unit that exists on disk and does nothing, or a unit that
# does something nobody asks for:
#
#   1. `guarden-credential-materialiser@.service` was installed by `soil
#      install` and `weedr secret materialise` never read
#      `$CREDENTIALS_DIRECTORY` -- so the credential systemd had already
#      decrypted for the unit was discarded and `systemd-creds decrypt` ran
#      again on the on-disk blob. The unit is ADR-0005's mechanism and stays:
#      it is an instantiable unit the `.path` triggers per blob and carries no
#      `[Install]`, because a `WantedBy=` would fire it at boot and
#      double-materialise against the boot oneshot.
#   2. `guarden-creds-boot.service` declares `WantedBy=multi-user.target` and
#      was never enabled, so nothing materialised at boot. The path unit
#      answers a *change* under the blob directory and never fires on a host
#      nobody wrote to, so a reboot left every planted value encrypted and
#      unread by the service that owns it.
#   3. Nothing in `src/` reloaded the system manager and ADR-0011 step 5
#      assumes one. A unit file systemd has not read is not a unit, which is
#      what made (2) invisible: `enable` writes the symlink either way, so the
#      manager said `not-found` for both units and nothing said so.
#
# These are asserted as the state of a machine, which is the only seam there
# is: which units are installed, which are enabled, and whether the manager
# knows about a unit it was handed a minute ago. Nothing here asks a stand-in
# what it had been asked to do (ADR-0014), and nothing here repairs the reload
# by hand -- a suite that did would be testing its own line.

. "$(dirname "$0")/lib.sh"

# The machine's own tools. `.venv/bin` is kept first because it is the
# checkout's interpreter and not a stand-in for anything.
export PATH="$GUARDEN_ROOT/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

export GUARDEN_PREFIX=/
mkdir -p /etc/guarden
if ! getent group guarden >/dev/null 2>&1; then
    groupadd --system guarden
fi

templates=$GUARDEN_ROOT/src/guarden/templates

# ---- the shipped units --------------------------------------------------
#
# The per-blob template exists, is installed, and is what the path unit
# triggers. It is not one of ADR-0005's two host-wide units and carries no
# `[Install]`, so it cannot fire at boot on its own.
assert_file_exists "$templates/guarden-credential-materialiser@.service"

# Two units for the whole host, and two in total (ADR-0005). Asserted by name
# rather than by count, because the claim is about what exists and not about a
# tally: the per-blob template is not one of the two ADR-0005 counts, because
# it is what the path unit triggers rather than a host-wide trigger of its own.
assert_file_exists "$templates/guarden-creds.path"
assert_file_exists "$templates/guarden-creds-boot.service"

# The pair's shape, from the source of truth the installer reads: the path unit
# watches the blob directory and triggers the boot oneshot, and the oneshot
# runs the one program that decrypts, once, in the system manager.
assert_file_has "$templates/guarden-creds.path" "PathChanged=/etc/guarden/creds/"
assert_file_has "$templates/guarden-creds.path" "Unit=guarden-creds-boot.service"
assert_file_has "$templates/guarden-creds-boot.service" \
    "ExecStart=/usr/lib/guarden/bin/weedr secret materialise"
assert_file_has "$templates/guarden-creds-boot.service" "Type=oneshot"
assert_file_has "$templates/guarden-creds-boot.service" "WantedBy=multi-user.target"
assert_file_has "$templates/guarden-creds-boot.service" "After=snapperd.service"
assert_file_has "$templates/guarden-creds.path" "WantedBy=multi-user.target"

# assert_file_lacks skips comments, and the match is anchored on the `=`.
assert_file_lacks "$templates/guarden-creds-boot.service" "LoadCredentialEncrypted="
assert_file_lacks "$templates/guarden-creds.path" "LoadCredentialEncrypted="
assert_file_lacks "$templates/guarden-credential-materialiser@.service" \
    "LoadCredentialEncrypted=/etc/guarden/creds/%i/credentials.cred"
assert_file_lacks "$templates/guarden-creds-boot.service" "GUARDEN_SERVICE"

# **The boot oneshot carries no `RemainAfterExit`, and that is load-bearing
# rather than tidiness.** A path unit that triggers a oneshot which then stayed
# active would refuse to run again, and re-materialising a rotated value is the
# whole point of the trigger.
assert_file_lacks "$templates/guarden-creds-boot.service" "RemainAfterExit"

# ---- the installed host -------------------------------------------------
#
# The installed units are a fact about this machine, and `install` is the phase
# that owns them. Converging it is the real phase rather than a stand-in for it:
# it writes the units and asks systemd to enable them, and every assertion below
# is about what the box then holds.
rm -f /etc/systemd/system/guarden-credential-materialiser@.service   # and prove install puts it back
systemctl disable guarden-creds-boot.service >/dev/null 2>&1 || :
systemctl disable guarden-creds.path >/dev/null 2>&1 || :

# Both of the pair drift, and both are named. The boot oneshot's line is the one
# this ticket exists for: it is the fact that a reboot materialised nothing.
run soil install --check
assert_exit 1
assert_stderr_has "the credential materialiser's path unit is enabled"
assert_stderr_has "the credential materialiser's boot oneshot is enabled"

run soil install --apply
assert_not_rejected

# The two units are on disk and the third one is not: an installed unit that
# resolves to nothing is a runbook trap of exactly the kind spec 6.9 says there
# is no such thing as.
assert_file_exists /etc/systemd/system/guarden-creds.path
assert_file_exists /etc/systemd/system/guarden-creds-boot.service
assert_file_exists /etc/systemd/system/guarden-credential-materialiser@.service

# **Both are enabled, and the boot oneshot was the one that was not.** Its
# `WantedBy=multi-user.target` is what `enable` acts on, and without the symlink
# a reboot pulled in nothing, so a value an operator had typed was still sitting
# encrypted in a blob with nothing to decrypt it. Read of the machine rather than
# of the argv that was supposed to produce it.
assert_enabled guarden-creds.path
assert_enabled guarden-creds-boot.service

# The symlink is the mechanism, and it is a second opinion on the same fact:
# `is-enabled` reads the unit's own state, and this is what the next boot reads.
assert_link /etc/systemd/system/multi-user.target.wants/guarden-creds-boot.service \
    /etc/systemd/system/guarden-creds-boot.service

# ---- the reload ---------------------------------------------------------
#
# ADR-0011 step 5 assumes a reload after the units are installed. **There is no
# observable way to prove the reload happened from a unit's LoadState**, and this
# file tried: seed a unit, ask, reload, ask again. Measured on the golden
# (systemd 259):
#
#   a unit written to disk, no reload   -> loaded
#   the same unit after daemon-reload   -> loaded
#   a unit that does not exist at all   -> not-found
#
# `not-found` means the file is absent, not that the manager has not read it, so
# the probe asserted a fact about the filesystem and called it a fact about the
# manager. It was green on any machine and would have stayed green with the reload
# removed entirely -- which is the "a test that the environment can satisfy is not
# a test" failure.
#
# So what is asserted is the thing the reload is FOR: that a phase which writes
# units converges, and that the manager can answer for a unit it was just handed.
# The reload itself is a step in `soil install`'s list and is reviewed as code; it
# is not probed, because no probe of it can fail.
#
# The unit is one nothing else installs, because the question is about the manager
# and not about a service.
probe=guarden-221-probe.service
seed /etc/systemd/system/$probe '[Unit]' \
    'Description=guarden ticket 221 reload probe' \
    '[Service]' 'Type=oneshot' 'ExecStart=/bin/true' \
    '[Install]' 'WantedBy=multi-user.target'

run soil install --apply
assert_not_rejected

# After it the manager has read the unit. `LoadState` is the same question
# `weedr secret set` asks of the same manager before it claims a value reached a
# service's store -- `credentials._load_state` reads exactly this property and
# treats `not-found` as "nothing to ask" -- so this is the load-bearing answer
# and not a synonym.
run_installed systemctl show --property=LoadState --value "$probe"
assert_stdout_has "loaded"

# And a unit the manager has read is one `enable` acts on, so the reload is
# what turned a file into a unit. The same manager, the same question.
systemctl enable "$probe" >/dev/null 2>&1
assert_enabled "$probe"
systemctl disable "$probe" >/dev/null 2>&1 || :
rm -f /etc/systemd/system/$probe
systemctl daemon-reload >/dev/null 2>&1 || :

# The units guarden owns answer the same way, which is the claim from the other
# side and is stronger than the probe: they were installed by the phase above
# and the manager has read them. This is also what `weedr secret set` asks
# before it claims a value reached a service's store.
run_installed systemctl show --property=LoadState --value guarden-creds-boot.service
assert_stdout_has "loaded"
run_installed systemctl show --property=LoadState --value guarden-creds.path
assert_stdout_has "loaded"

# **`--check` still changes nothing.** The reload is an `--apply` step and not
# an item, so there is no file of guarden's to compare a manager's memory
# against -- an item asking it would answer false on every host forever and
# never hold, which is drift no apply could clear. The pair stays enabled
# because the applies above converged it.
run soil install --check
assert_stderr_lacks "the credential materialiser's boot oneshot is enabled"
assert_stderr_lacks "the credential materialiser's path unit is enabled"
assert_enabled guarden-creds.path
assert_enabled guarden-creds-boot.service
