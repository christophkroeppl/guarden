# 200: provision the golden, so a cut machine boots without installing anything

**What to build:** The golden VM is built by cloud-init, and a copy of it is a **new instance to
cloud-init**, so every cut machine re-runs that user-data: `package_update: true` and nineteen
packages, which is an `apt-get update` followed by an `apt-get install` holding apt's locks.
The packages are already baked into the golden. The work is to install them **once at build
time** and leave cloud-init nothing to do, so a cut machine boots clean and a suite can start
work in its first seconds.

**Blocked by:** 140 (the golden VM harness)

**Status:** ready-for-agent — **but it needs one golden rebuild, about an hour, so schedule it
deliberately and not alongside other work.**

- [ ] `tools/golden-vm` **provisions** the machine it snapshots: the substrate packages are
      installed during the build, and the cloud-init document it leaves behind either does nothing
      or says plainly that the image is already provisioned
- [ ] The rendered cloud-init document is still generated from the one package list, because
      that list is the contract (spec §6.1, `packages.toml`); what changes is **who installs it**,
      not where it is declared. A second list would be the drift this repository keeps fighting
- [ ] A cut machine reaches a steady state **without running any package transaction**, measured:
      no `apt-get` process during boot, apt's lists lock free, `cloud-init` reaching `done` with
      nothing to install. That measurement is the ticket's evidence, not a passing suite
- [ ] **`--provision` still works on a machine whose cloud-init does nothing**, because the first
      install on a bare host is still `soil install`'s job
- [ ] The one suite that asserts the golden's package inventory is **updated to the new fact**,
      not deleted: a golden that ships its substrate is a different machine, and the claim that
      recorded which packages it did *not* have has to be re-derived rather than remembered
- [ ] Record the full-suite wall clock before and after, in this ticket

## The two limits to state, not discover

- **This does not make the first install on a real host any different.** A host that is not a
  golden still needs `soil packages --apply` to install its packages, and it still needs its
  index refreshed (spec §6.1). The change is entirely about the machine the harness cuts.
- **It does not remove the need to wait for the machine to be ready.** Boot is boot. What it
  removes is the ~11–25 seconds of package transaction inside it, which is the part that also
  made seven suites lose an apt-lock race on 2026-10-01.

## Cost, stated plainly

One `just provision`, about an hour, and the golden's snapshot changes identity. Everything
recorded against the current snapshot is invalidated, so do this when nothing else is in flight.