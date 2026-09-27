# 120: explicit environments, naming, boot order, fence bed

**What to build:** The environment track is always explicit: `weedr bed plow` requires `--env production|staging|preview|fence` (no implicit default) and manifests declare `environment`, bed users and homes are `bed-<env>-<project>`, and previews are one shared preview bed per project with instances nested under `/home/bed-preview-<project>/<ref>/` (cap 3 concurrent refs per project, FIFO eviction, overridable). Traefik becomes the fence bed `bed-fence-traefik` in the `fence` track, member of the `fence` system group that shares `/var/lib/roots/dynamic/` (roots writes, the traefik bed user reads). Boot ordering puts production first, with staging and preview starting only after all production units have started plus a fixed delay, enforced by drop-ins written by `weedr`.

**Blocked by:** T20 (Bed lifecycle + secrets + prod gate)

**Status:** ready-for-agent

- [ ] `weedr bed plow <project>` without `--env` exits non-zero and names the required flag; `--env production`, `--env staging`, `--env preview`, and `--env fence` are accepted and any other value is rejected by name
- [ ] A manifest without a declared `environment` fails validation (non-zero exit, file named)
- [ ] Bed users and homes are `bed-<env>-<project>` (the fast harness sees `bed-staging-myapp`, not `bed-myapp-staging`)
- [ ] A project has exactly one preview bed; refs are nested instances under `/home/bed-preview-<project>/<ref>/`
- [ ] Creating a fourth concurrent preview ref for a project evicts the oldest ref (FIFO), and a config override changes the cap of 3
- [ ] `bed-fence-traefik` runs in the `fence` track as member of the `fence` group; `roots` writes `/var/lib/roots/dynamic/` and the traefik bed user reads it through that group, and no other user is a member
- [ ] Boot order: the fake `systemctl` call log shows all production units started before any staging or preview unit, with the fixed delay present as a drop-in written by `weedr`
- [ ] Re-running the ordering converge on an already-ordered host exits 0 with no drift
- [ ] All of the above is verified at the CLI seam with the fast harness; boot ordering is also exercised on the golden VM
