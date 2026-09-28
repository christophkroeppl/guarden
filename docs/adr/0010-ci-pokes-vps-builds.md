# CI pokes, the VPS builds: no git state, no registry, a throwaway build

A project's GitHub Action sends one message to the VPS over ssh — a **poke** — and
nothing else crosses the wire twice: `hose poke <project> <ref> <sha>` with the source
tree as a `git archive` tar.gz on stdin, or `hose drop <project> <ref>` without source.
Each project gets its own ed25519 key; `hose grant <project> <pubkey>` installs it with
a forced command that binds the key to that project, so one repo's workflow can touch
only its own beds. That key is the only secret CI holds — no registry token and no
GitHub credential, in Actions or on the box (ADR-0004).

The VPS keeps no git state: no clones, no checkouts, no ops-list working trees. Its
state is the beds and the deployed sha in each bed's meta. Source is staged at
`/var/lib/guarden/staging/<bed>/<sha>/` (0755, readable by the bed user) and handed to
`weedr ... --from`.

Convergence is one function with two triggers. `hose check` learns the desired
`{ref → sha}` set with `git ls-remote --heads` — one stateless call that replaces pull,
for-each-ref, and local ref state — fetches what changed, and drops preview beds whose
branch is gone. A 15-minute `hose-check.timer` runs it when the VPS can read the
remote: a public repo over plain HTTPS, or any repo with one fine-grained Contents:Read
PAT stored root-owned beside the ops list — never in git, never in Actions. An
unreadable private repo runs events-only: a lost poke means drift until an empty commit
re-triggers it, and an orphan preview waits for the cap of three or a manual
`weedr preview drop`. Push, PR-close, and delete events are the fast path, ordered by
`concurrency: cancel-in-progress` per project/ref; the timer is the safety net.

Builds run on the VPS inside the deploy queue (ADR-0007), as the bed user, from the
staged tree: `runuser -u <bed> -- podman build -t <image> <staging>`. Every `RUN` step
executes in a throwaway container — that is the temporary container — and the layers
land in that bed's rootless storage, exactly where its quadlet units look, so no
registry and no image copying exist anywhere. The tag is compose's `image:` ref, so
podlet output is untouched. The build runs before the old container stops, extending
ADR-0004's gate-before-stop: a failed build leaves the running service running.

Production: a push to `main` may create and deploy the production bed — the first
deploy starts an **empty** database, never forked from staging (ADR-0002) — but a poke
may never drop a production bed by default. `hose drop` and `hose check` refuse, and a
root-owned override file beside the ops list is the only switch (ADR-0008's pattern);
until it exists, `weedr bed remove` stays out of hose's sudoers grant.

Why: one code path for public and private repos, no image registry, no build on a
shared CI runner, and no second source of truth on the box — the remote stays the
truth, the beds stay the state. The privilege story is unchanged: sudo is one narrow
door, and repo code executes only as a rootless bed user.

Consequences: ADR-0001's "hose pulls a source of truth" becomes "hose receives source
and, when it can read the remote, re-derives the truth"; ADR-0007's dedupe key is
(bed, ref, sha); PRD §4.1, §9, §10, and the spec move with it. A lost poke on an
unreadable private repo is a real, accepted risk — the empty commit is the documented
nudge.
