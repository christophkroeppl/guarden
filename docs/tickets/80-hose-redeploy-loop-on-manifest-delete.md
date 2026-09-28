# 80: hose redeploy loop when a manifest file is deleted

**What to build:** A project deletes `.guarden/bed.yaml` (or `.guarden/widgets/api.yml`, or a widget) from its repo. The next reconcile notices the deletion, drops the stale copy from the bed, and stops redeploying. Today `weedr` copies manifests into the bed but never mirrors deletions, so the bed keeps a stale `bed.yaml`/widget forever and `hose` keeps seeing drift and redeploying the same bed on every run (ADR-0010 — the reconcile arrives as a poke or a `hose check`).

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] `weedr` copies `compose.yaml`, `.guarden/bed.yaml`, and `.guarden/widgets/<service>.yml` into the bed and removes any of those three that no longer exist in the source
- [x] Deleting `.guarden/widgets/api.yml` from a source tree and reconciling removes `widgets/api.yml` from the bed and rewrites the twig dashboard without the `api` widget
- [x] Deleting `.guarden/bed.yaml` from a source tree and reconciling removes the stale `bed.yaml` and rewrites `roots` routes for that bed
- [x] Two consecutive reconciles with no source change produce zero `weedr redeploy` calls in the fake call log (this is the loop regression)
- [x] A stale file that `weedr` did not write (an admin drop-in, a `.env.<env>.local`) is left alone — only the three manifest paths are mirrored
- [x] Verified at the CLI seam with the fast harness
