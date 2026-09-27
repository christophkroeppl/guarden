# 80: hose redeploy loop when a manifest file is deleted

**What to build:** A project deletes `.guarden/bed.yaml` (or `.guarden/widgets/api.yml`, or a widget) from its repo. The next `hose sync` notices the deletion, drops the stale copy from the bed, and stops redeploying. Today `weedr` copies manifests into the bed but never mirrors deletions, so the bed keeps a stale `bed.yaml`/widget forever and `hose` keeps seeing drift and redeploying the same bed on every sync.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `weedr` copies `compose.yaml`, `.guarden/bed.yaml`, and `.guarden/widgets/<service>.yml` into the bed and removes any of those three that no longer exist in the source
- [ ] Deleting `.guarden/widgets/api.yml` from a project repo and running `hose sync` removes `widgets/api.yml` from the bed and rewrites the twig dashboard without the `api` widget
- [ ] Deleting `.guarden/bed.yaml` from a project repo and running `hose sync` removes the stale `bed.yaml` and rewrites `roots` routes for that bed
- [ ] Two consecutive `hose sync` runs with no source change produce zero `weedr redeploy` calls in the fake call log (this is the loop regression)
- [ ] A stale file that `weedr` did not write (an admin drop-in, a `.env.<env>.local`) is left alone — only the three manifest paths are mirrored
- [ ] Verified at the CLI seam with the fast harness
