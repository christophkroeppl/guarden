# 190: forward-auth at the fence (roots renders bed.yaml auth)

**What to build:** A bed opts into sign-in with `auth: true` in `.guarden/bed.yaml`, and `roots` renders Traefik's forward-auth rule — aimed at the auth bed's hyphae name — into that bed's route files. The auth bed is named once in a root-owned file (0444) beside the dynamic config that `roots` reads; it is a normal bed, plowed like any other. A bed without `auth:` gets exactly the routes it gets today, the auth bed's own routers never carry the rule, and there is no new `weedr` verb and no change to the fence bed. See ADR-0009.

**Blocked by:** T60 (roots + twig)

**Status:** ready-for-agent

- [ ] The auth-bed file is root-owned, mode 0444, and never written by `hose` or by regeneration (visible as such in the harness)
- [ ] A bed with `auth: true` gets a route file containing the forward-auth rule pointed at the auth bed's hyphae name (asserted on the file `roots` writes)
- [ ] A bed without `auth:` produces the same route file as before this change — no middleware appears
- [ ] The bed named in the auth-bed file never gets the rule attached, even when it declares `auth: true`
- [ ] A bed declares `auth: true` while the auth-bed file is missing or empty: `roots` exits non-zero, names the file, and leaves the dynamic config untouched — old routes keep working
- [ ] Re-running `roots` with no manifest change rewrites nothing (idempotent)
- [ ] All of the above is verified at the CLI seam with the fast harness
