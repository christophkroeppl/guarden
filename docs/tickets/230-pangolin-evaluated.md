# 230: Pangolin — evaluated, and not adopted

**What to build:** Nothing. This ticket records an evaluation and closes it, so the reasoning
survives the conversation that produced it and nobody re-runs it in two years.

Pangolin ([fosrl/pangolin](https://github.com/fosrl/pangolin)) is the only serious alternative to
ticket 220's egress tunnel that was found to offer credential-free, expiring, per-resource
access — and on that axis it is genuinely *better* than the vendor in 220. It loses on three
things guarden will not trade, and **two of the three are settled in the source code** rather than
in judgement.

**Status:** evaluated — closed, not implemented

## The finding, in one line

**Pangolin can front guarden's services only if the backends stop being loopback-only, and
guarden's publications are loopback by construction.** The blocker is topological, not a matter
of privilege, configuration, or maturity.

## Why

Three findings, each verified against the repository rather than the documentation, because the
documentation is where this would have gone wrong.

### 1. A loopback target resolves in the wrong namespace, and fails silently

Pangolin writes a site connector's targets into Traefik's dynamic configuration **verbatim, with
no rewriting**:

```ts
url: `${target.method}://${target.ip}:${target.port}`
```

— [`server/lib/traefik/loadBalancer.ts`](https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/loadBalancer.ts),
verified against `main` on 2026-10-03.

So a target of `127.0.0.1:20134` is opened by **Traefik's own container**, and means the
container's loopback, not the host's. The same applies to a `local` site, which is the mode that
would otherwise have fitted: "expose resources on the same host as your Pangolin server, no
tunnels are created"
([understanding-sites](https://docs.pangolin.net/manage/sites/understanding-sites)).

Worse than being wrong: `isTargetValid` performs **no loopback check**, so `127.0.0.1` *validates*
and then fails at connect time. An operator configuring this by hand gets a configuration the tool
accepts and the proxy cannot serve, with no diagnostic pointing at the namespace.

The documentation's own guidance is to reach the host by its **bridge gateway** —
"Use `172.17.0.1` (Docker bridge gateway)"
([dns-and-networking](https://docs.pangolin.net/self-host/dns-and-networking)) — which is a
non-loopback address, and guarden has no bridge to offer.

### 2. Revoking a grant does not terminate a live session

This is the finding that matters most, because "revocable" was the requirement.

`invalidateAllSessions(resourceId, { whitelistId })` **exists and takes a `whitelistId`**
([`server/auth/sessions/resource.ts`](https://github.com/fosrl/pangolin/blob/main/server/auth/sessions/resource.ts),
verified). The handler that removes an address from a resource's whitelist
([`server/routers/resource/removeEmailFromResourceWhitelist.ts`](https://github.com/fosrl/pangolin/blob/main/server/routers/resource/removeEmailFromResourceWhitelist.ts))
contains **zero** calls to it.

Consequence: removing a customer's address deletes the *grant* and leaves their *session* open.
By default Pangolin "keeps extending a session indefinitely if a user is actively using it", and
an idle one expires only after 30 days (`server.resource_session_length_hours`, default `720`).
Session-length **enforcement** — forcing a re-login at an interval — is an **Enterprise-only**
feature ([session-length](https://docs.pangolin.net/manage/access-control/session-length)) — so on
the edition that is freely available, "revoke this person now" can mean "this person keeps access
for as long as they keep using it", and the shortening is a paid feature.

And there is **no expiry on any grant at all.** Across the whole API, four duration-shaped fields
exist: `validForSeconds` on an access token, `validHours` (≤168) on an org invite, `validUntil` on
a site-provisioning key, and an EE-only org-wide session cap. There is **no `expiresAt`** on a
whitelist entry, a role assignment, or a user→resource grant. The only time-bounded primitive is a
share link — and a link is a **bearer credential carrying no per-user identity**
([links](https://docs.pangolin.net/manage/access-control/links)), so revoking it for one person
revokes it for everyone holding it.

**So the customer requirement — time-bounded, per-person, instantly revocable — is not reachable
with stock Pangolin.** An external program could hold the schedule itself and call
`whitelist/remove` on a timer, accepting that the visitor's already-open session survives until it
lapses. That is a workable system; it is not one where the vendor holds the truth, and it is the
mirror image of the problem ticket 220 solves with `--until` being mandatory.

Audit logs — "who had access when" — are **Enterprise-only**
([access](https://docs.pangolin.net/manage/analytics/access)), so on CE the failure above is not
even observable after the fact.

### 3. The one deployment with zero extra inbound ports is the one guarden cannot use

Against a host whose design says the only public inbound ports are the edge's three:

| Mode | Extra public inbound ports | Usable here |
| --- | --- | --- |
| No tunnelling + local sites | **0** | **No** — needs a shared container network |
| Basic WireGuard site | 1 (`51820/udp`) | No — loopback not offered |
| Newt site connector (full stack) | 2 (`51820/udp`, `21820/udp`) | No — dials targets from its own netns |

([dns-and-networking](https://docs.pangolin.net/self-host/dns-and-networking),
[podman-quadlets](https://docs.pangolin.net/self-host/manual/podman-quadlets))

The zero-port mode is available **only** to a deployment that shares a podman/docker network with
its backends, which guarden forbids: there is no shared podman network, no name map, and no
per-group address space. Every other mode adds public UDP the kernel does not forward today.

Privilege, for the record, was **not** the obstacle. The control plane, Traefik, Badger and Newt
run unprivileged; Newt is a fully userspace WireGuard client. Only `gerbil` needs `NET_ADMIN`
(`netlink.LinkAdd` plus `iptables -t mangle` writes). The compose file grants `SYS_MODULE` as well,
but no `modprobe` call exists anywhere in the codebase — the only module check is `/sys/module/ifb`,
gating traffic shaping that defaults off — so **`SYS_MODULE` appears avoidable** (no
documentation says so; treat as UNVERIFIED). None of that matters while finding 1 stands.

## The edge-replacement question, answered

The brief asked specifically whether Pangolin's bundled Traefik could replace guarden's, and
whether `roots` could drive it. Both answers are no, for reasons worth recording:

- **There is no bundled Traefik.** The `fosrl/pangolin` image contains no Traefik at all; it runs
  as a separate upstream container (`docker.io/traefik:v3.7` in the installer template).
- **Pangolin generates Traefik's dynamic configuration from its own database** and serves it over
  an HTTP provider polled every 5s. An operator's `file` provider *coexists* — so the merge is
  technically possible — but the content is 100% Pangolin-generated, and a `traefik.file_mode`
  flag only changes HTTP-poll into an atomic file write. It does not change authorship. A
  `file`-provider Traefik that `roots` owns would be a second Traefik, not a configured one.
- **`badger` is loadable without compilation** (Traefik's Yaegi interpreter, `experimental.plugins`),
  which is genuinely good news — but it configures from the dynamic config only, and authenticates
  by POSTing the whole request to `/badger/verify-session` per request. There is no JWKS and no
  introspection endpoint, so **the auth decision cannot be moved out of Traefik** into something
  guarden owns. It also means the reference install **fetches the auth plugin from GitHub at
  Traefik startup**.
- **Serving loopback-only backends is the capability being asked for, and it is the one missing.**

## Cost, if it were adopted anyway

For completeness, since the alternative is not "free": a second always-on service owning its own
database (SQLite by default), five independently-versioned components with **no published
compatibility matrix** (pangolin 1.24.0, gerbil 1.5.2, newt 1.18.1, badger 1.7.0 — all as of
2026-10-03), **zero published CVEs and no security policy beyond an email address** with
disclosure by private mail only, and no LTS. Two rootless-podman reports are closed as stale
([#1613](https://github.com/fosrl/pangolin/issues/1613),
[#1871](https://github.com/fosrl/pangolin/issues/1871)). Licence is **not** plain AGPL: the root
`LICENSE` is dual AGPL-3 / Fossorial Commercial with **per-file headers**, and there are separate
OSS, Enterprise and SaaS TypeScript builds.

Against a project whose stated test seam is "one harness and it is a real machine, and there are
no fakes", a five-component dependency with no compatibility matrix and a private disclosure
channel is a standing liability. That is a reason, not the reason.

## Why not just wire around it

Two options were considered and rejected:

- **Put Pangolin on a second VPS in front of this one**, with a site connector dialling back. This
  sidesteps finding 1 and is how the vendor intends it to run. It also means a second
  always-on control plane to operate, patch and back up, a second place a customer's access to
  this box is granted, and two public hostnames to reason about — for a single-VPS platform whose
  entire premise is one box.
- **Have `weedr` own the expiry schedule** and treat Pangolin as a dumb projection. This works,
  and it is precisely the shape ticket 220 already implements against a vendor that does not
  invalidate sessions on removal anyway. Adopting Pangolin to get it would add five components to
  avoid writing one reconciler that already has to exist.

**Reconsider if, and only if, all three become true:** a published statement or code path that
resolves a connector target against the **host's** loopback namespace; `whitelist/remove`
invalidating live sessions; and a stable, documented release line with a compatibility matrix.

## What this ticket does not do

- It does not forbid a future evaluation, and it does not claim Pangolin is a bad project — its
  access-control primitives are better than the alternative's. It records **which three facts
  about it are incompatible with this platform**, so that a future reader can check whether they
  still hold rather than re-deriving them
- It does not change the edge, `roots`, `gate`, or any port. Ticket 220 is unaffected by this
  ticket's closure
- It does not add a dependency, a module, a fetch, or a service. Nothing is installed

## Notes

The underlying research is written up in full, with a citation index, at
`docs/notes/pangolin-traefik-ownership.md` and `docs/notes/pangolin-unprivileged-loopback.md`.
Every source claim above was verified against `fosrl/pangolin` at `main` on 2026-10-03.