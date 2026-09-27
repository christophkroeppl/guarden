# 50: pond + stakes

**What to build:** Beds share exactly two Postgres instances, and snapshot pins survive ladders. An operator runs `weedr pond mint <bed>` and gets one role and one database in the right pond with the credential planted in the bed; `weedr pond drop` protects production behind explicit confirmation and drops previews automatically; `stakes pin` / `unpin` / `query` hold a snapshot for one or many beds and the snapper cleanup hook refuses to prune pinned ids.

**Blocked by:** T20 (Bed lifecycle + secrets + prod gate), T40 (soil: btrfs convert + snapper ladders)

**Status:** ready-for-agent

- [ ] `pond-production` and `pond-staging` run as user `pond` with ports published on `127.0.0.1`
- [ ] The hyphae name `pond.internal` resolves and a bed can open `pond.internal:5432` through the host loopback
- [ ] `weedr pond mint <bed>` creates one Postgres role and one database in `pond-production` for production beds and in `pond-staging` otherwise
- [ ] `weedr` mints the password (never human-chosen) and plants it into the bed, then forgets it
- [ ] `weedr pond drop` on production requires explicit confirmation; on previews it runs automatically
- [ ] Restoring a dump reassigns ownership to a freshly minted role so staging never reuses a production password
- [ ] `stakes pin <snapshot> --holder <bed>` holds a snapshot and `stakes query` prints `holders=N`
- [ ] Two beds pinning one snapshot each keep `holders=2`; dropping one leaves `holders=1`; dropping the second frees the pin
- [ ] The snapper cleanup hook reads the pin state file and skips pinned ids
- [ ] `stakes` never blocks snapper: a stuck pin delays pruning of that id only
- [ ] `stakes` state lives in one root-readable file; no long-lived daemon is required for one operator
- [ ] All of the above is verified at the CLI seam with the fast harness; pond and pins are also exercised on the golden VM
