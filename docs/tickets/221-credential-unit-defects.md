# 221: the three ADR-0005/ADR-0011 credential-unit defects

**What to build:** Nothing new. Three defects confirmed by reading and covered by no ticket, all
in the credential materialiser's units, all of the same shape — **a unit that exists on disk and
does nothing, or a unit nobody asks for.** ADR-0005 says "two units for the whole host", ticket 60
says "two units in total, not two per service", and there were three.

**Blocked by:** nothing. 60 and 20 are landed.

**Status:** implemented

The 2026-10-03 status note recommended 220 for these three defects, and it was written under
that number. **A different ticket then took 220** (`220-tunnel-module.md`, the Cloudflare tunnel
module), so this one is renumbered to **221**. Ticket numbers are allocated in tens precisely so a
collision like this can be resolved without renumbering anything else.

## The three defects

- [x] **`guarden-credential-materialiser@.service` reads the credential it was handed.**
      `soil install` writes it to `/etc/systemd/system/`, and it carries
      `LoadCredentialEncrypted=credentials:`, which puts the decrypted blob at
      `$CREDENTIALS_DIRECTORY/credentials`. `credentials.value()` never read that path and
      re-ran `systemd-creds decrypt` on the on-disk blob instead, so the credential systemd had
      already handed the unit was discarded and decrypted a second time. It now prefers the
      staged file. It keeps **no `[Install]`**, and that is correct rather than a defect: it is
      an instantiable unit the `.path` triggers per blob, and giving it a `WantedBy=` would make
      it fire at boot and double-materialise, contradicting ADR-0005's two-unit shape.
      (An earlier revision of this ticket deleted the unit instead of fixing it. ADR-0005 binds
      and the deletion was reverted: the materialiser *is* the mechanism the ADR describes, not a
      redundant third unit.)
      `LoadCredentialEncrypted=credentials:/etc/guarden/creds/%i/credentials.cred` — a blob path
      guarden never writes, since a blob is `<KEY>.cred` — plus `Environment=GUARDEN_SERVICE=%i`,
      which no program in the tree reads, and `RemainAfterExit=yes`, which on a per-service
      instantiated unit means the second `weedr secret set` for that service cannot run it again.
      `weedr secret materialise` never read `$CREDENTIALS_DIRECTORY`, so the credential the
      directive loaded was never consumed by anything. Deleted:
      `src/guarden/templates/guarden-credential-materialiser@.service`, its `text_item` in
      `hostprep.install_items`, and the three assertions in `t20-install.sh` that pinned its
      contents. **The two units ADR-0005 names are the two that remain.**

- [x] **`guarden-creds-boot.service` is enabled.** It carries
      `[Install] WantedBy=multi-user.target` and only `guarden-creds.path` was ever enabled
      (`hostprep.py`, the path item). Nothing pulled the oneshot in at boot, and the path unit
      answers a *change* under `/etc/guarden/creds/` — never a fire on a host nobody wrote to. So
      a box that rebooted with planted blobs had every credential encrypted in a blob with nothing
      to decrypt it, and the gate that reads those values root-side could not tell a planted key
      from an absent one. Added as a second `Item` in `install_items`, `enable` and not
      `enable --now`: the oneshot re-materialises the whole tree, and running it from an item
      whose claim is "this unit is wanted" would be work the item is not about, on services that
      may not exist yet.

- [x] **`soil` reloads the system manager after the phases that write system units.** There was no
      `daemon-reload` anywhere in `src/`, and ADR-0011 step 5 assumes one. This is what made
      defect 2 invisible: `systemctl enable` writes the symlink whether or not the manager has read
      the unit, so the unit was enabled, correct on disk, and absent from the manager — and
      `credentials._load_state`, which `weedr secret set` asks before claiming a value reached a
      service, answered `not-found` for a unit the host had just installed. Added
      `hostprep.finish_for(phase)`, the mirror of the existing `prepare_for`: `--apply` only,
      because there is no file of guarden's to compare a manager's memory against and an item
      asking it would report drift no apply could clear. It runs **after** the phase's items,
      because a reload before the phase writes its units reloads the state that existed before.
      Wired into `soil._apply`; `UNIT_PHASES` is `install` and `units`, the two phases that write
      into the system manager's search path.

## Tests

- [x] **`tests/t221-cred-units.sh`**, new. Asserts the shipped templates (the third absent, the
      pair present, no `LoadCredentialEncrypted=` and no `GUARDEN_SERVICE` on either), then
      converges the real `install` phase on `GUARDEN_PREFIX=/` and asserts the machine: both units
      installed, the third missing, **both enabled**, and the `multi-user.target.wants` symlink the
      next boot follows. For the reload it writes a unit nobody else installs, asks the manager
      `LoadState` (the same question `weedr secret set` asks) before and after an apply that
      converges nothing, and asserts `not-found` → `loaded`. The probe is not a fixture and
      nothing faked is asked anything.
- [x] **`t20-install.sh`** — the removed unit's three content assertions become an assertion that
      it is **absent**, plus the pair's shape and both units enabled.
- [x] **`t60-secrets.sh`** — the shape block now says *two in total* and asserts the third template
      is gone. The enabled state is deliberately **not** asserted there: that suite stages a host
      where `install` has never been applied, so its units are not enabled and their being enabled
      would mean another suite converged them. `t220` is where the converge happens.
- [x] **`t130-scripts.sh`** — asserts both units enabled, next to the existence assertions the
      cloud-init path already made.

## Not done, and why

- **The per-service install leg does not exist.** `render.write`'s docstring says the mutator
  copies out of the render directory and removes it (spec §2), and no verb does: `furrow` is a
  42-line stub and `weedr service start` starts what the home already declares. ADR-0011's
  *user*-manager reload therefore still has nothing to reload after — this ticket fixed the
  *system*-manager reload, which is what the two credential phases needed and all that the tree
  can carry today. Adding the copy step is ticket 90 work.
- **Not executed.** See the note below.

## Verification state

**Nothing here has been run.** No suite, no `soil`, no `just test` — the VM is the only place
anything executes and it was busy with a golden rebuild. The next verification step, in the VM and
in this order:

1. `tests/lxc.sh run t221-cred-units` — the new suite, alone.
2. `tests/lxc.sh run t20-install` — it converged the enable items that its exact-drift-line
   assertions (`wc -l = 1`, twice) now depend on. **This is the suite most likely to need a
   line count adjusted**, because a new item in `install_items` is drift on any host where the pair
   is not enabled yet.
3. `tests/lxc.sh run t130-modules t130-scripts t130-alias t130-paths` — every other suite that
   asserts `soil install --apply` reaching exit `0` with empty stderr. A new item in that phase
   changes what "converged" means for all four.
4. `just test`.

The unexecuted risk is concentrated in (2) and (3): adding an `Item` to `install_items` adds a
drift line to `soil install --check` on any host that has not enabled the boot oneshot, and four
suites assert on the exact set of what `install` reports.
