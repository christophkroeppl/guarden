# 286 — the repos review: upheld, corrected, and one framing error of mine

2026-10-14. The adversarial review of the three-repo work ran on
`opencode-go:step-5-preview-free` with no filesystem access. Verdict: NEEDS_WORK.
Every claim below was re-measured here.

## Upheld, and it found something I had wrong

**#1 — the three-database question is the THIRD blocker, not the first.** The review
called my framing an error and it is right: I presented "one edge cannot give three
databases" as the open question for odoo-btc-bcr, while two larger blockers sit in
front of it. Measured since: `build:`/`extends:`/`profiles:` refuse the whole file
(283), and **a container cannot reach a sibling in its own compose at all** (285) —
which is most of that stack's topology. The database count is real (284) and it is
the least of the three.

**#4 — intra-compose connectivity does not exist.** The review reasoned it from the
"`networks:` dropped, one pasta namespace per container" facts and flagged it as
unverified. Measured: a two-service compose where one names the other renders **no
`AddHost=`** for the sibling, because `AddHost` is a guarden-owned key and only an
**edge** produces one. Filed as 285, and it is the finding this review should be
read for.

**#2 — `as:` conflating the local alias with the provider's kind is a design
defect.** Agreed, and this round is its own evidence: `as: s3` had to become
`as: secret`, which renamed the consumer's variables `S3_*` → `SECRET_*` and
produced the degenerate `SECRET_SECRET` — `<KIND>_<KIND>`, because the alias is
*forced* to be the kind. A capability rename (rustfs calling it `secret` rather than
`s3`) is a breaking change across every consumer, which is the opposite of what an
alias is for. The right shape the review names — a consumer-chosen alias plus a
separately declared kind (`as: rustfs, kind: secret` → `RUSTFS_HOST`) — is recorded
here as the design input; it is a vocabulary change and belongs with 284's.

**#5 — bases-mcp: the verdict is right, the wording closes a question that should
stay open.** Recording "NOT a service" makes a platform gap look like an
application property. The accurate statement is **"not a guarden-compatible
service: guarden models only long-running, network-reachable, image-based units."**
That keeps the decision visible, and the review's reason is the one that matters:
the MCP ecosystem is stdio clients spawning subprocesses, so this exclusion recurs
for **every** MCP server, not just this one. Either guarden grows a stdio kind
(with `Restart=no` / on-demand activation semantics) or it stays HTTP-only **by
design and says so**. Ticket 282's bases-mcp section is amended to that wording.

**#3/#6 — the weakest claim is mine, and the word "verified" was doing work it had
not earned.** "Verified by ingesting as `supplements-staging`: all 3 units render"
certifies **syntax for an artifact that cannot be built or booted**. The image tags
are local (`supplements-<app>:latest`), `weedr service build` is unimplemented, and
there is no digest pin — so the first deploy either fails image-not-found or, worse,
satisfies the reference from a stale image already in local storage and boots the
wrong version silently. That is a latent failure I reported as a completed
checklist item. Corrected in 282: the image identity is an **explicit unresolved
input**, and the deploy should fail closed when the tag cannot be produced.

## The review's closing point, kept verbatim because it is the lesson

> An agent's transcript is evidence of intent, not of post-state, and the agent's own
> observation channel can be corrupted.

The two failures in this round — a "bug fix" that was redaction in the agent's own
tool output, and a semantically-refused value marked correct by regex — share that
one cause. The minimum checks the review names are both right and are recorded:
**no post-state assertion without an out-of-band command whose raw output the
reviewer inspects**, and **validation must run the real rejecting component, never a
pattern match on the value's shape.** `as: s3` is well-formed against
`[a-z0-9-]+` and refused by the converter.

## Not verified, ranked (the review's #6, accepted as written)

1. Anything at runtime — no unit started, no port served, no secret read by a live
   entrypoint. Render-only verification hides the unproducible image and the whole
   rootless surface.
2. Secret plumbing end to end — `weedr secret set` planting a value the entrypoint
   actually reads is asserted by design, never exercised. Hides "deployed but cannot
   authenticate", the failure that looks done.
3. The provider side of the edge contract — and this one turned out to be hiding the
   largest defect found all day: **the edge provisions nothing at all** (284).
4. Intra-compose connectivity — now measured as absent (285).
5. The odoo-btc-bcr conversion — blocked on missing capabilities, not in progress.
6. Image supply chain and environment identity.
7. Lifecycle — undeploy, redeploy, rotation, role cleanup.
