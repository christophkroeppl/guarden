# 150: the auth module

**What to build:** Sign-in at the edge. A service declares `auth: true` on a route, `roots`
renders a forward-auth rule aimed at the service named in one root-owned file, and the auth
service itself is an ordinary service in a gated track. No application integrates with it; no new
`weedr` verb; the shared edge directory and its `edge` group are untouched by this ticket.

It is a v1 ticket because the deployments that prompted this design all but one need it: the
cloud vault, both agents and the dashboard sit behind sign-in, and a deployment platform that
cannot put a login in front of a route cannot run them.

**Blocked by:** 50 (gate and the first slice)

**Status:** ready-for-agent

- [ ] `/usr/lib/guarden/modules/auth/module.toml` declares the auth service, the shared program
      it switches on — the existing `roots` — and no new program
- [ ] `/etc/guarden/edge/auth-provider` is root-owned, **`0640 root:guarden`**, and names the
      auth service by its service name. It is written once by `weedr module add auth` and is
      never written by a service, a manifest, a regeneration, or a poke
- [ ] The marker is validated by `roots` on every sync: **the name must resolve to an existing
      service in a track with `gated = true`.** Anything else — a missing service, a service not
      in a gated track — is exit `1` and **no configuration is written**, so the routes that were
      working keep working
- [ ] A route with `auth: true` renders the forward-auth middleware aimed at that name
- [ ] A route without `auth:` renders exactly what it rendered before, byte for byte
- [ ] The auth service's own routes never carry the rule, whatever its manifest declares
- [ ] **With the auth module not installed, `roots` emits the route without a middleware and
      writes one `warning:` line naming the service and the route on every sync.** `auth: true` in
      a manifest is never silently ignored, and the warning repeats rather than being a
      once-ever event somebody missed
- [ ] Re-running `roots sync` with no manifest change writes nothing
- [ ] The auth service's own credentials are gated like any other service in a gated track: an
      empty or example key refuses the start before the old container stops
- [ ] Nothing but the marker file connects the auth module to `roots`. There is no plugin
      interface, no per-module code path, and no new program
- [ ] On the golden VM: an unauthenticated request to a protected route is redirected, a bad
      password is rejected, a good one reaches the service, and an unprotected route is
      unaffected
- [ ] Verified at the CLI seam with the fast harness
