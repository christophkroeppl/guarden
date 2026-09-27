# 100: cloud-init bootstrap

**What to build:** A cloud-init user-data path performs most of soil host prep by inlining the install scripts and installing the required packages, so a fresh Ubuntu instance reaches a converged host with almost no manual phases. The scripts-based install remains for hosts that do not run cloud-init, and both paths converge to the same state. The golden-VM runner switches to booting from cloud-init.

**Blocked by:** T30 (soil: host prep)

**Status:** ready-for-agent

- [ ] A cloud-init user-data file exists in the repo and is what the golden-VM runner passes to the instance; it inlines the soil install scripts and installs the required packages
- [ ] The golden-VM boot from cloud-init reaches converged soil state: every `soil <phase> --check` exits 0 with far fewer manual phases than the scripts path
- [ ] The command-line seam is unchanged: same `--check` / `--apply` commands, same exit codes, `--check` still prints `drift` and exits 1 when drifted
- [ ] Hosts without cloud-init still converge through the scripts-based install, and that path is still exercised (fast harness or a golden-VM variant)
- [ ] Running the cloud-init-derived prep or the scripts install on an already-converged host reports no drift and exits 0
- [ ] Required packages installed by cloud-init match the list the scripts install uses (one shared package list, not two copies that can drift)
- [ ] The fast harness verifies the rendered user-data and package list against fakes; the golden VM proves boot-to-converged and captures an evidence tarball
