# 90: stakes unpin can lose a concurrent update

**What to build:** Two previews drop at the same time and both release their hold on the same snapshot. `stakes unpin` must not lose one of the updates, so the snapshot is freed only when every holder is gone. Today the read-modify-write of the pin state file is not serialised, so a concurrent `unpin` can clobber the other and the holder set ends up wrong — either the pin is freed too early (a ladder prunes data a preview still needs) or never (disk fills).

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] `stakes pin` and `stakes unpin` serialise their read-modify-write of the pin state file (a lock file or `flock` around the update is enough for one operator)
- [x] Two concurrent `stakes unpin --holder <a>` and `stakes unpin --holder <b>` on one snapshot leave `stakes query` printing `holders=0` and the pin freed exactly once
- [x] Two concurrent `stakes pin` on one snapshot with different holders leave `holders=2`
- [x] A concurrent `unpin` while `stakes query` is reading never sees a torn or half-written state file
- [x] The `stakes/snapper-cleanup` hook still exits 0 and still skips pinned ids during a concurrent update — `stakes` never blocks `snapper`
- [x] A stress test at the CLI seam runs 20 interleaved `pin`/`unpin` pairs and ends with `holders=0` and the pin freed
- [x] Verified at the CLI seam with the fast harness
