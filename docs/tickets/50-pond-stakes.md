# 50: pond + stakes

**What to build:** A pond is an optional named shared-state instance (Postgres first): beds get databases inside a pond, never a database container of their own, and a host with no ponds is a valid host. An operator runs `weedr pond dig <name>` to create a pond instance, `weedr pond fill <bed>` and gets one role and one database in the pond that bed is connected to with the credential planted in the bed, and `weedr pond drain <bed>` which requires explicit confirmation for production data and runs automatically for previews; `stakes pin` / `unpin` / `query` hold a snapshot for a set of holder beds and the snapper cleanup hook refuses to prune pinned ids.

**Blocked by:** T20 (Bed lifecycle + secrets + prod gate), T40 (soil: btrfs convert + snapper ladders)

**Status:** ready-for-agent

- [x] `weedr pond dig <name>` creates a named pond instance under the fixed pond directory schema; default host prep creates no ponds (ticket 130)
- [x] `weedr pond dig` also creates the pond user `pond-<env>-<name>` with linger, allocated subuid/subgid, its home and quadlet dir, and the data directory owned by it; no shared `pond` user exists anywhere in the call log
- [x] A pond publishes its ports on `127.0.0.1` and its hyphae name resolves so a connected bed can open `:5432` through the host loopback
- [x] `weedr pond fill <bed>` creates one Postgres role and one database in the pond that bed is connected to
- [x] `weedr` mints the password (never human-chosen) and plants it into the bed, then forgets it
- [x] `weedr pond drain <bed>` on production data requires explicit confirmation; on previews it runs automatically
- [x] Restoring a dump reassigns ownership to a freshly minted role so staging never reuses a production password
- [x] `stakes pin <snapshot> --holder <bed>` holds a snapshot for that holder and `stakes query` prints `holders=N` from the holder identities (no stored refcount)
- [x] Two beds pinning one snapshot each keep `holders=2`; dropping one leaves `holders=1`; dropping the second frees the pin
- [x] The snapper cleanup hook reads the pin state file and skips pinned ids
- [x] `stakes` never blocks snapper: a stuck pin delays pruning of that id only
- [x] `stakes` state lives in one root-readable file; no long-lived daemon is required for one operator
- [ ] All of the above is verified at the CLI seam with the fast harness; pond and pins are also exercised on the golden VM
