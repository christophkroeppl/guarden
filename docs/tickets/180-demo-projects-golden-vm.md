# 180: demo projects on the golden VM

**What to build:** Three demo projects exercise the platform on the golden-VM LXD/QEMU harness together with real production- and staging-named ponds as the reference use-case: `seedling` (api + worker + web, needs a pond), `coldframe` (staging-only), and `stonecrop` (a self-contained node that owns its service/DB container, subvolume, ladder, and state, with no pond). Prototype project names are purged from fixtures and tests so the demos are the only named projects.

**Blocked by:** T10 (Skeleton + CLI seam harness), T70 (preview/staging lifecycle + hose)

**Status:** ready-for-agent

- [ ] The golden VM brings up `seedling` with api, worker, and web connected to a pond (a production-named pond and a staging-named pond are created as the reference use-case), and `curl -H 'Host: …'` reaches each service through Traefik
- [ ] `seedling` gets its database and role via `weedr pond fill` and its credential is planted in the bed (present in the bed's files, absent from git)
- [ ] `coldframe` exists only in staging: its manifest declares `environment: staging`, no production bed for it is created, and its units run only under its staging bed user
- [ ] `stonecrop` runs self-contained: it owns its service/DB container, subvolume, ladder, and state; the call log shows no `pond fill` and no pond hyphae names for it
- [ ] The demo set creates at most one preview bed per project with nested refs within the cap of 3
- [ ] Fixtures and tests contain no retired prototype project names, and the fast harness includes a check that fails if one reappears
- [ ] The golden-VM run ends in an evidence tarball containing unit states, `curl` traces, `snapper list`, `stakes query`, and `stakes list` output for all three projects
- [ ] `make test` stays green and stays fast (the demos run only on the golden VM)
