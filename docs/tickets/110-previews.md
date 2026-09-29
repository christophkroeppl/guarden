# 110: previews

**What to build:** A branch becomes an instance inside one preview service, with a clone of
staging's data and throwaway credentials. The branch goes away and the instance goes with it,
releasing its claim on the snapshot — while any other branch forked from the same snapshot keeps
it.

**Blocked by:** 70 (state and snapshots), 80 (edges)

**Status:** ready-for-agent

- [ ] `weedr service ingest <workload>-preview/<ref> --from poke <project>@<sha>` creates one service and one
      instance directory, with the ref taken **raw** by every verb and escaped by
      `systemd-escape` internally so `feature/x` and `feature-x` are distinct
- [ ] A service is created for the workload only if it does not exist; the second ref creates no
      second user, home, or image store
- [ ] The instance is forked from the same workload's service in the track its `fork_from` field
      names (`staging` in the shipped table, read as a field and not as the word), the `seed` is
      recorded, and the call log shows the clone. Its `bulk` volumes are created as **empty subvolumes**,
      never empty directories
- [ ] Instances get generated credentials, and a missing credential warns rather than blocking
- [ ] A preview appears at `preview.$DOMAIN/<ref>` — a **path** on one host, from the track's
      `host_prefix` of `preview.` — with its route and its dashboard card. One host and no
      wildcard certificate, because the ref is a path segment and not a host name
- [ ] The `cap` on the `preview` track in `guarden.toml` bounds concurrent instances **per
      service** — per workload and environment, never per project, because two repositories may
      declare the same project name; exceeding it evicts the oldest
      **before** the new one is created, so the cap is never briefly exceeded and a failure
      during creation cannot leave the count above the cap
- [ ] `cap` lives only on the `[[environments]]` block of a `kind = "instance"` track. A
      `kind = "slot"` track carrying one, or an instance track not carrying one, is exit 2 naming
      the track, and there is no top-level `[preview]` table that could disagree
- [ ] A manual redeploy does not make an instance newer, so the cap cannot be gamed
- [ ] **Removal deletes the instance directory and releases its `seed`; another instance naming
      the same snapshot still protects that snapshot.** `weedr service remove <name>/<ref>`
      removes one instance — it stops that instance's units, deletes its directory, releases its
      `seed` and frees its publications, and leaves the service and its siblings alone. A ref
      naming no instance is refused
- [ ] **The cap's eviction and `furrow preview drop` both call that one verb.** A second removal
      path for the same event is a second thing to get wrong, and the call log shows the same
      verb the operator would type
- [ ] **`weedr service remove <name>` on an instance track is refused while any instance exists,
      naming them**, so the service and every instance are not destroyed in one command by a typo
- [ ] `weedr service purge` is refused for an instance, because an instance's volumes are the service's
      data
- [ ] Removing the last instance leaves the service, and the service is only removed when asked
- [ ] A branch merged away is dropped by `hose drop`, and the drop is available by hand through
      `furrow preview drop <name> <ref>`, which takes the ref raw like everything else
- [ ] The runbook documents that instances of one service are one trust domain — a shared uid, a
      shared home, a shared image store, a shared podman secret store, and each other's
      directories — and that an allowlist of `*` will build one for a fork from outside. The
      remedy is a narrower allowlist for a repository with outside contributors, or making the
      fork its own service
- [ ] **The pre-commit hook has an owner: this ticket.** A repository with neither
      `compose.yaml` at the root nor `.guarden/quadlet/` is refused naming both accepted
      locations; a repository with both is refused as ambiguous, naming each. The hook runs
      offline in seconds, needs no guarden installation, and never reaches the network
- [ ] On the golden VM, two instances forked from one snapshot exist, one is evicted, and the
      snapshot is still protected — verified with `stakes list` and by forking again from it
- [ ] Verified at the CLI seam with the fast harness
