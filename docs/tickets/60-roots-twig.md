# 60: roots + twig

**What to build:** A bed's `.guarden/bed.yaml` and `.guarden/widgets/<service>.yml` become live routes and a live dashboard. An operator starts a bed and `roots` writes Traefik dynamic config so a `curl` with the right `Host` header reaches the service; `twig` writes Homepage config so every service shows exactly one card with links to the project's staging and repo.

**Blocked by:** T20 (Bed lifecycle + secrets + prod gate)

**Status:** ready-for-agent

- [ ] `roots` reads `.guarden/bed.yaml` from every bed and writes Traefik dynamic config under the shared `fence`-group directory
- [ ] The `traefik` bed user reads that directory through the `fence` group; `roots` and `traefik` never share a user
- [ ] Default routes are `staging.<domain>` and `preview.<domain>/<ref>`
- [ ] A project can override routes in `.guarden/bed.yaml`
- [ ] Microservice routes are generated per service from `.guarden/bed.yaml` and the service ports in `compose.yaml`
- [ ] Route changes appear without restarting Traefik (dynamic config reload)
- [ ] On the golden VM, `curl -H 'Host: …'` reaches a bed service through Traefik
- [ ] `twig` merges `.guarden/widgets/<service>.yml` into Homepage config, exactly one widget per service
- [ ] The dashboard groups production apps and links to each project's staging dashboard and source repo
- [ ] Dashboards update when a bed appears or disappears, without a manual step
- [ ] All of the above is verified at the CLI seam with the fast harness; routing is also exercised on the golden VM
