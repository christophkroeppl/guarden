# 130: cloud-init and the portable install

**What to build:** A cloud-init user-data path reaches a converged host with almost no manual
phases, and the scripts path stays available for hosts without cloud-init. One package list
serves both, and the layout is a portability decision rather than a portability promise.

**Blocked by:** 20 (soil)

**Status:** ready-for-agent

- [ ] A cloud-init user-data file exists in the repository and is what the golden-VM runner
      passes to the instance; it installs the packages from the one shared list and runs the
      soil phases
- [ ] A boot from cloud-init reaches converged state: every `soil <phase> --check` exits 0
- [ ] The scripts path still converges to the same state on a host without cloud-init, and is
      still exercised
- [ ] Running either path on an already-converged host reports no drift and exits 0
- [ ] There is one package list, with per-family entries, not two copies that can drift; the
      command-line seam, exit codes and the `drift` word are unchanged by the path taken
- [ ] Non-default modules are selectable from cloud-init and from the script, and the selection
      is written into `/etc/guarden/guarden.toml` by `soil install` under the `modules` lock, so
      it survives a later `weedr module add`. That makes **three** writers of the file — `soil
      install` for `[modules] enabled` and the derived `ingress.alias` (ADR-0018), `weedr
      module add` for `[modules] enabled` — and `[modules] enabled` is the one two of them
      share, so
      `soil install` must take the `modules` lock and refuse if a `weedr module add` is in
      progress rather than writing blind
- [ ] The path constants exist in exactly one place and follow FHS: programs and modules under
      `/usr/lib/guarden` with symlinks in `/usr/bin`, configuration under `/etc/guarden`,
      state under `/var/lib/guarden`, runtime under `/run/guarden`
- [ ] **Every distribution-specific command is behind a capability probe with a documented
      fallback, and the list of what is still Ubuntu-only is written in the PRD** — the btrfs
      convert's dracut hook, the `DPkg::Pre-Invoke` hook at
      `/etc/apt/apt.conf.d/80guarden-snapper`, the names of the distribution's packaged snapper
      units, and cloud-init. The layout and the phase structure are distro-neutral; the install
      path is not, and the PRD says so and points at the README's single statement of the target
- [ ] **The VM verifies the rendered user-data and the package list against the real tools**, and
      no fake is involved at either end. There is no `fixtures/bin` to add a line to: the
      directory is retired (ADR-0014, ticket 35), and the `git` incident that ticket's earlier
      form recorded — a fake escaping its harness and shadowing the real tool for every process
      that inherited the environment — is the reason
- [ ] No program installs anything from PyPI or fetches a wheel at deploy time
