# 20: Bed lifecycle + secrets + prod gate

**What to build:** The admin makes a real bed appear and disappear from a project repo's `compose.yaml`, and production cannot start with a missing or placeholder secret. An operator runs `weedr bed plow myapp --env staging` and gets a bed user, quadlet units, hyphae names, and generated staging secrets; `weedr bed start` brings services up (or refuses on production with a clear reason); `weedr bed remove` leaves nothing behind. This is the tracer bullet — it cuts through manifest → `weedr` → units → runtime in one path.

**Blocked by:** T10 (Skeleton + CLI seam harness)

**Status:** ready-for-agent

- [ ] `weedr bed plow <project> --env <env>` reads `compose.yaml` and creates the bed user `bed-<env>-<name>` with linger, a user-scope quadlet unit directory, and allocated subuid/subgid
- [ ] `compose.yaml` converts to quadlet units; bare named volumes also get `.volume` units; per-bed overrides land in unit drop-ins so regeneration cannot clobber them
- [ ] `weedr` writes and removes hyphae names (`bed-<env>-<name>.internal` and peers) with the bed
- [ ] `weedr bed start` / `stop` / `restart` drive the bed's units as the bed user (visible in the fake `systemctl` call log)
- [ ] `weedr secret set <bed> KEY` plants one value into the bed and keeps no long-term copy inside `weedr`
- [ ] staging beds get generated `@sensitive` values at create, stable until the bed is removed; a local override file always wins
- [ ] A tracked `.env.schema` is the source of truth for names and types; `.env.example` is generated from it
- [ ] `weedr bed start` on production exits non-zero and names the missing key when a `@required` key is empty
- [ ] `weedr bed start` on production exits non-zero when a value still looks like `EXAMPLE-` or `changeme`
- [ ] The same two conditions only warn on staging and previews
- [ ] On production the gate runs before the old container is stopped: a failed gate exits non-zero and leaves the currently running container up (no `stop` for it in the fake `systemctl` call log)
- [ ] `weedr bed remove` stops units, removes the user, removes hyphae names, and is refused on production without confirmation
- [ ] All of the above is verified at the CLI seam with the fast harness
