# 220: on-VPS build step — rootless podman build as the bed user, before stop

**What to build:** `weedr` builds the image before it stops the running one. Wherever a source tree carries a compose `build:`, the deploy path runs `runuser -u <bed> -- podman build -t <image> <src>` as the bed user — every `RUN` step executes in a throwaway container (that is the temporary container), and the layers land in the bed's own rootless storage exactly where its quadlet units look, so no registry and no image copying exist. The tag equals compose's `image:` ref, so podlet output is untouched. The build joins `weedr bed plow`, `weedr redeploy`, and `weedr preview new` **ahead of** the production gate and the stop — a failed build leaves the running container running, extending ADR-0004's gate-before-stop to builds (ADR-0010).

**Blocked by:** T20 (bed lifecycle + secrets + prod gate)

**Status:** ready-for-agent

- [ ] `weedr redeploy <bed> --from <src>` with a `build:` service logs `podman build` as the bed user before any `systemctl stop` entry in the call log
- [ ] The image is tagged with compose's `image:` ref; the generated quadlet units are byte-identical to the no-build case
- [ ] A failing build exits non-zero, restores the previous manifests (existing rollback), and the container that was running before the deploy is still running
- [ ] A compose file with only `image:` (no `build:`) produces no `podman build` entry — prebuilt images still work unchanged
- [ ] The same build runs for preview and staging beds, from the staged tree at `/var/lib/guarden/staging/<bed>/<sha>/`
- [ ] The build goes through the deploy queue once T160 lands: with a build running, a second redeploy waits (call-log entries never overlap)
- [ ] The fast harness asserts the order: build → gate → stop → start
- [ ] Verified at the CLI seam with the fast harness
