# 70: preview/staging lifecycle + hose

**What to build:** A PR opens and a new ref appears inside the project's one shared preview bed, with a copy of production data and throwaway credentials; the PR merges and that ref disappears, releasing its snapshot pin. The same path serves `develop` as a staging bed. `hose` keeps all of this true from git alone. This is the end-to-end ticket that proves the platform.

**Blocked by:** T20 (Bed lifecycle + secrets + prod gate), T50 (pond + stakes), T60 (roots + twig)

**Status:** ready-for-agent

- [ ] Creating a preview ref pins the current production-pond snapshot through `stakes` (the ref becomes a holder)
- [ ] The project database and role are dumped from the production pond into the staging pond under a freshly minted role and password
- [ ] The new credential is planted in the preview bed; the production password is never reused
- [ ] The preview bed comes up at `preview.<domain>/<ref>` with its routes and dashboard widgets
- [ ] Preview create warns only (never blocks) on the prod gate
- [ ] Dropping a preview ref stops its units, drops the database and role in the staging pond, unpins (releases the ref as holder), and frees hyphae names
- [ ] Dropping one of two preview refs sharing a snapshot leaves `holders=1`; the snapshot is not freed early
- [ ] A preview drop is automatic on merge and available manually
- [ ] Staging for `develop` follows the same path and lands at `staging.<domain>`
- [ ] There is exactly one preview bed per project with refs nested under `/home/bed-preview-<project>/<ref>/`; concurrent refs are capped at 3 per project by default, FIFO eviction of the oldest on overflow, and the cap is overridable
- [ ] `hose` pulls an explicit ops list of project repos, calls `weedr` through a narrow sudoers rule, and restarts only changed services (stop-then-start)
- [ ] `hose` holds no privilege beyond calling `weedr`; gitops cannot become root
- [ ] A failing in-app migration leaves the unit failed and the old route target unchanged
- [ ] `weedr redeploy <bed>` asks before touching production
- [ ] The full preview lifecycle runs on the golden VM and ends in an evidence tarball (journals, `snapper list`, `stakes query` traces, unit states, `curl` traces)
