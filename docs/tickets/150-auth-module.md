# 150: the authelia module

**What to build:** Sign-in at the edge. A service declares `auth: true` on a route, `roots`
renders a forward-auth rule aimed at the service named in one root-owned file, and the auth
service itself is an ordinary service in a gated track. No application integrates with it; no new
`weedr` verb; the shared edge directory and its `edge` group are untouched by this ticket.

It is a v1 ticket because the deployments that prompted this design all but one need it: the
cloud vault, both agents and the dashboard sit behind sign-in, and a deployment platform that
cannot put a login in front of a route cannot run them.

**Blocked by:** 50 (gate and the first slice)

**Status:** implemented and green in the VM (`ok t150-auth.sh`).
Two boxes stay unticked and say why: the credential gating is ticket 60's
mechanism and the golden-VM round trip needs a running edge, a provider and a
container — which is `t50-slice.sh`'s subject and blocked on the quadlet
generator gap in `docs/notes/quadlet-volume-key-is-not-a-spelling-fix.md`.

- [x] `/usr/lib/guarden/modules/authelia/module.toml` declares the auth service, the shared program
      it switches on — the existing `roots` — and no new program
- [x] `/etc/guarden/edge/auth-provider` is root-owned, **`0640 root:guarden`**, and names the
      auth service by its service name. It is written once by `weedr module add authelia` and is
      never written by a service, a manifest, a regeneration, or a poke
- [x] The marker is validated by `roots` on every sync: **the name must resolve to an existing
      service in a track with `gated = true`.** Anything else — a missing service, a service not
      in a gated track — is exit `1` and **no configuration is written**, so the routes that were
      working keep working
- [x] A route with `auth: true` renders the forward-auth middleware aimed at that name
- [x] A route without `auth:` renders exactly what it rendered before, byte for byte
- [x] The auth service's own routes never carry the rule, whatever its manifest declares
- [x] **With the authelia module not installed, `roots` emits the route without a middleware and
      writes one `warning:` line naming the service and the route on every sync.** `auth: true` in
      a manifest is never silently ignored, and the warning repeats rather than being a
      once-ever event somebody missed
- [x] Re-running `roots sync` with no manifest change writes nothing
- [ ] The auth service's own credentials are gated like any other service in a gated track: an
      empty or example key refuses the start before the old container stops
- [x] Nothing but the marker file connects the authelia module to `roots`. There is no plugin
      interface, no per-module code path, and no new program
- [ ] On the golden VM: an unauthenticated request to a protected route is redirected, a bad
      password is rejected, a good one reaches the service, and an unprotected route is
      unaffected
- [x] Verified at the CLI seam, in the VM
