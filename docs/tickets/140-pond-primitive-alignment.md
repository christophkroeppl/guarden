# 140: align code + tests to the pond primitive

**What to build:** Pond becomes a named primitive everywhere in code and tests: ponds have arbitrary names (`production-postgres`, `staging-postgres`, or anything else), the verbs are `weedr pond dig <name>`, `weedr pond fill <bed>`, and `weedr pond drain <bed>` (replacing the old pond create/mint/drop verbs), and bed verbs are `weedr bed plow` and `weedr bed remove` (replacing bed new/drop). `weedr bed plow -p <name>` / `--pond <name>` connects a bed's hyphae to a pond; an unknown name prints the known ponds to pick from plus an option to create a new pond with that name. Stakes stores holder identities (`snapshot_id → holders [bed ids]`) instead of a refcount. This is the code-and-test alignment ticket for the pond-as-primitive decision; no fixture or call-log assertion may still expect the removed verbs.

**Blocked by:** T40 (soil: btrfs convert + snapper ladders), T50 (pond + stakes)

**Status:** ready-for-agent

- [ ] `weedr pond dig <arbitrary-name>` creates a pond instance at `/var/lib/guarden/ponds/<name>/`; names such as `production-postgres` and `staging-postgres` behave like any other name
- [ ] `weedr pond fill <bed>` and `weedr pond drain <bed>` are the pond verbs for a bed's database; `weedr pond drain` on production data refuses without explicit confirmation (non-zero exit without it)
- [ ] The removed pond verbs exit non-zero with a message naming the replacement, and `weedr pond --help` lists only `dig` / `fill` / `drain`
- [ ] `weedr bed plow <project> --env <env>` and `weedr bed remove <bed>` are the only bed create/remove verbs; the removed bed verbs exit non-zero naming the replacement
- [ ] `weedr bed plow -p <name>` and `--pond <name>` connect the bed's hyphae to that pond and the call log shows the hyphae names appearing
- [ ] `weedr bed plow --pond <unknown>` exits non-zero, prints the known pond names, and offers to create a new pond with the requested name; accepting creates the pond and completes the plow
- [ ] `weedr bed plow` with no `--pond` leaves the bed's hyphae unconnected, so a self-contained bed stays possible
- [ ] `stakes` state records `snapshot_id → holders [bed ids]`; `stakes query <snapshot>` lists the holder identities and a pin is held while any holder remains
- [ ] No test, fixture, or call-log expectation references a removed verb or a fixed two-pond name; old spellings fail the harness
- [ ] Re-running `dig`/`plow`/`fill` on an already-converged state exits 0 (idempotent)
- [ ] All of the above is verified at the CLI seam with the fast harness
