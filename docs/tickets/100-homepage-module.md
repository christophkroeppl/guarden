# 100: the homepage module and twig

**What to build:** The `homepage` module installs the dashboard service and its renderer. Every
container in a project gets one card, and a project's card links to its environments and its
repository.

**Blocked by:** 40 (loom), 50 (modules)

**Status:** ready-for-agent

- [ ] `/usr/lib/guarden/modules/homepage/module.toml` declares the dashboard service and the
      renderer it switches on
- [ ] `weedr module add homepage` installs the dashboard and the renderer's units, and
      `weedr module remove` reverses it without touching `gate-traefik`
- [ ] `twig sync` merges every service's widgets into the dashboard's configuration
- [ ] Widget files are copied through unparsed, so any YAML the dashboard accepts works
- [ ] `twig` generates only the grouping and the per-project links, from `projects.toml`
- [ ] A widget naming a container that the project's unit source does not define is **exit 2**
      naming the file and the key: the manifest and the unit source are both input
- [ ] A widget entry keyed `service:` rather than `container:` is **exit 2** naming the block.
      Widget entries name a container in the same service; only `needs` names another service
- [ ] Exactly one widget per container, enforced by the dashboard's own configuration shape
- [ ] A card appears when a service appears and disappears when it is removed, with no manual
      step and no restart of the dashboard
- [ ] The dashboard service is reachable through the edge by a route, and its card links to the
      project's production and staging hosts and to its repository from `projects.toml`
- [ ] `twig` runs unprivileged and writes only into the dashboard's configuration directory
- [ ] Verified at the CLI seam, in the VM
