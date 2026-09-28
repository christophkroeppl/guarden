# 110: .guarden/ manifest dir + pre-commit

**What to build:** The project-repo contract files live under `.guarden/`: `.guarden/bed.yaml` (routes, `pond:` with databases plus roles/grants, hyphae aliases, `ports:`), `.guarden/widgets/<service>.yml`, and `.guarden/.env.schema`, while `compose.yaml` stays at the repo root. Repos that ship pre-converted units instead use `.guarden/quadlet/`. Exactly one of root `compose.yaml` or `.guarden/quadlet/` must be present; a repo with neither fails the pre-commit check, and both `weedr` and `hose` read the contract from the new paths.

**Blocked by:** T10 (Skeleton + CLI seam harness), T20 (Bed lifecycle + secrets + prod gate)

**Status:** ready-for-agent

- [ ] A repo with root `compose.yaml`, `.guarden/bed.yaml`, `.guarden/widgets/<service>.yml`, and `.guarden/.env.schema` passes the pre-commit check (exit 0)
- [x] `.guarden/bed.yaml` accepts `routes`, `pond:` with `databases` and roles/grants, `hyphae` aliases, and `ports:`; an unknown top-level key fails validation with the file named (non-zero exit)
- [ ] A repo that ships `.guarden/quadlet/` instead of root `compose.yaml` passes the check
- [ ] A repo with neither `compose.yaml` nor `.guarden/quadlet/` fails the pre-commit check with a message naming both accepted locations (non-zero exit)
- [ ] A repo with both `compose.yaml` and `.guarden/quadlet/` fails the check as ambiguous (non-zero exit)
- [x] `weedr` copies and reads `compose.yaml`, `.guarden/bed.yaml`, and `.guarden/widgets/<service>.yml`; the fast harness call log shows only the new paths
- [x] `.env.schema` is read from `.guarden/.env.schema`; a schema at the old repo-root location is not picked up
- [ ] The pre-commit hook runs offline in seconds and is wired into the repo's existing pre-commit entry point
- [ ] All of the above is verified at the CLI seam with the fast harness
