# 210: hose check + timer + optional read credential

**What to build:** `hose check [<project>]` learns the desired `{ref → sha}` set with one stateless `git ls-remote --heads` — replacing pull, for-each-ref, and local ref state — compares it with the deployed shas in bed meta, fetches tarballs to staging for what changed, and drops preview beds whose branch is gone; it never drops a production bed. A `hose-check.timer` runs it every 15 minutes when the remote is readable: a public repo over plain HTTPS, or any repo with one fine-grained Contents:Read PAT stored root-owned under `/var/lib/guarden/hose/`. An unreadable private repo is events-only — `check` logs `unreadable` and exits 0, and a lost poke is nudged with an empty commit (ADR-0010).

**Blocked by:** T200 (CI pokes — deployed shas and the staging path come from there)

**Status:** ready-for-agent

- [ ] `hose check <project>` against a readable remote prints `ref deployed remote status` and exits 0 when converged
- [ ] Remote sha ahead of the deployed sha: the call log shows the tarball fetched to `/var/lib/guarden/staging/<bed>/<sha>/` and `weedr ... --from` for that bed
- [ ] Deployed sha equal to remote sha: no `weedr` call (idempotent)
- [ ] A preview bed whose branch no longer appears in `ls-remote --heads` is dropped via `weedr preview drop`
- [ ] `main` missing from the remote never drops the production bed; `hose check` refuses production drops the same way `hose drop` does (root-owned override is the only switch)
- [ ] An unreadable remote (no credential, private repo) logs `unreadable`, exits 0, and makes no `weedr` call — a following `--check`-style second run behaves identically (idempotent skip)
- [ ] `hose-check.timer` exists, fires every 15 minutes, and invokes `hose check`
- [ ] The credential is read from a root-owned 0600 file under `/var/lib/guarden/hose/`; a public repo works with no credential file at all
- [ ] The ops file maps each project to its git URL — no local clones exist anywhere on the box (the repo dir is absent after `check`)
- [ ] Lost-poke recovery: skip the poke, run the timer, and the bed converges to the remote sha
- [ ] Verified at the CLI seam with the fast harness (`git` fake answers `ls-remote`)
