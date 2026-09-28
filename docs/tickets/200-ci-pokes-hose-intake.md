# 200: CI pokes — hose intake, per-project keys, production-drop guard

**What to build:** A project's GitHub Action sends one message to the VPS over ssh — `hose poke <project> <ref> <sha>` with the source tree as a `git archive` tar.gz on stdin, or `hose drop <project> <ref>` without source — and the VPS turns it into a bed with no git state anywhere: source stages at `/var/lib/guarden/staging/<bed>/<sha>/` (0755, readable by the bed user) and is handed to `weedr ... --from`. Each project gets its own ed25519 key, installed by `hose grant <project> <pubkey>` as a forced command that hard-binds the key to that project, so one repo's workflow can only touch its own beds and CI holds no registry or GitHub credential. A push to `main` may create and deploy the production bed — first deploy starts an **empty** database (ADR-0002) — but a poke never drops a production bed unless the root-owned override exists (ADR-0010).

**Blocked by:** T70 (preview/staging lifecycle + hose), T80 (manifest deletion mirroring)

**Status:** ready-for-agent

- [x] `hose poke <project> <ref> <sha>` with a tar.gz on stdin extracts to `/var/lib/guarden/staging/<bed>/<sha>/` and the call log shows `weedr ... --from` that directory for a changed sha
- [x] The staged tree is mode 0755 and readable by the bed user (the build context depends on it)
- [x] A poke whose sha equals the deployed sha in the bed meta makes no `weedr` call and exits 0 (idempotent)
- [x] A poke for an unknown ref creates the bed: `develop` → the staging bed, any other head → the preview bed, `main` → the production bed
- [x] A first poke for `main` creates the production bed with an empty database — no restore call in the log — and the production gate still refuses to start it until secrets are hand-planted (T20 gate, ADR-0004)
- [x] `hose drop <project> <ref>` removes a preview bed through `weedr preview drop` and carries no source
- [ ] `hose drop` against a production bed refuses (non-zero, reason named) and makes no `weedr` call; with `/var/lib/guarden/hose/allow-production-drop` present (root-owned) it proceeds
- [ ] `hose grant <project> <pubkey>` appends a forced-command `authorized_keys` line binding that key to that project; a forced command naming a different project is refused
- [x] A malformed poke (bad sha shape, ref outside `[A-Za-z0-9._/-]`) exits non-zero without touching a bed
- [ ] The shipped workflow template writes the key, runs `git archive --format=tar.gz <sha>`, and pokes — with `concurrency: { group: <project>/<ref>, cancel-in-progress: true }` and the push / pull_request-closed / delete triggers
- [ ] The workflow contains only the poke key as a secret: no registry token, no GitHub credential (ADR-0004)
- [ ] Verified at the CLI seam with the fast harness
