# Pangolin (fosrl) — networking & privilege reality for an unprivileged, loopback-only single host

Research only. No software downloaded, installed or executed. Every claim carries a URL;
anything I could not confirm from primary source is marked UNVERIFIED.

Repo: /media/data/projects/ACTIVE/guarden — research note, feeds an architecture ticket.
Compiled 2026-10-03.

---

## 0. TL;DR

| Mode | Inbound UDP added | Capabilities | Can dial a 127.0.0.1 backend? |
|---|---|---|---|
| Full stack (gerbil + traefik + control plane) | 51820/udp **and** 21820/udp | `NET_ADMIN` + `SYS_MODULE` | Yes via **newt site**, from the newt container's netns |
| Basic WireGuard site | 51820/udp only | same | LAN-style targets explicitly unsupported |
| **No-tunnelling (Local site)** | **none** | **none** | **Yes — but from Traefik's own netns** |

The single blocking fact: in every local mode, `127.0.0.1` is resolved and dialled by
**Traefik's container network namespace**, not the host's. A loopback-only backend on the
host is therefore unreachable, and there is no configuration knob to change this.

---

## 1. THE LOOPBACK QUESTION

### 1.1 `local` site / no-tunnelling mode — the answer is Traefik's netns

The docs are explicit that no tunnel is created and the Pangolin host must reach resources
over "the local network":

> "Use this to expose resources on the same host as your Pangolin server (self-hosted only).
> No tunnels are created. Required ports must be open on the Pangolin host."
> — https://docs.pangolin.net/manage/sites/understanding-sites

> "**Pangolin and Traefik must now be on the same network as the resources you want to
> proxy to.**" — https://docs.pangolin.net/self-host/advanced/without-tunneling

> "By not installing Gerbil, you will only have the option to choose the 'Local' connection
> method. This means Traefik will use the local network to reach your resources."
> — https://docs.pangolin.net/self-host/advanced/without-tunneling

The code decides it. For a `local` (or `wireguard`) site the control plane writes the target
straight into the Traefik load balancer with **no rewriting and no proxy hop**:

```ts
// https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/loadBalancer.ts
if (target.site.type === "local" || target.site.type === "wireguard") {
    return { url: `${target.method}://${target.ip}:${target.port}` };
} else if (target.site.type === "newt") {
    const ip = target.site.subnet!.split("/")[0];
    return { url: `${target.method}://${ip}:${target.internalPort}` };
}
```

So a `127.0.0.1:20000` target becomes the literal upstream
`http://127.0.0.1:20000` in `dynamic_config.yml`, and **Traefik's container opens the
socket**. Traefik's `127.0.0.1` is the container's own loopback. It is not the host's.

Traefik runs as its own container in every documented deployment
(`install/config/docker-compose.yml`,
https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml), so in the
reference topology "Traefik's loopback" is the loopback of a network namespace that has
nothing listening on 20000.

The documentation's own guidance for reaching the host from a container confirms this is the
mechanism — the host is reached by bridge address, never by loopback:

> "**To access services on the host machine:** Use `172.17.0.1` (Docker bridge gateway) or
> `host.docker.internal` (Docker Desktop). Example: `http://172.17.0.1:3000`"
> — https://docs.pangolin.net/self-host/dns-and-networking

Corroborating user evidence: a local-site target pointed at a Docker gateway address works,
and the reporter uses the bridge IP rather than loopback —
https://github.com/fosrl/pangolin/issues/2238 (comment by MohandL3G, "the resource is
pointing to 172.19.0.1:9090 which is Pangolin Docker Gateway IP").

**Plainly: in no-tunnelling / local-site mode a `127.0.0.1` target does not reach a host
loopback service. It reaches the container's own loopback and will fail with connection
refused.** There is no `host.docker.internal` equivalent in this stack, and nothing in the
config schema alters it.

Target validation does not catch or flag this. `isTargetValid` accepts any IPv4/IPv6 or
plain domain, with no loopback check
(https://github.com/fosrl/pangolin/blob/main/server/lib/validators.ts):

```ts
export function isTargetValid(value: string | undefined) {
    ...
    const addr = ipaddr.parse(value);
    return addr.kind() === "ipv4" || addr.kind() === "ipv6";
    ...
    return DOMAIN_REGEX.test(value);
}
```

`127.0.0.1` passes validation and fails silently at connect time.

### 1.2 Site-connector (`newt`) mode — loopback works, from the newt container's netns

For a `newt` site the target IP is **not** dialed by Traefik or the control plane. The
control plane allocates an internal port, pushes the target to newt over the websocket, and
newt proxies from inside its own netstack into the tunnel. Traefik only ever addresses the
tunnel address:

```ts
// loadBalancer.ts — newt branch
const ip = target.site.subnet!.split("/")[0];
return { url: `${target.method}://${ip}:${target.internalPort}` };
```

The internal port is allocated per target by `pickPort`, which picks a random free port in
40000–65535 and enforces the site subnet for wireguard sites
(https://github.com/fosrl/pangolin/blob/main/server/routers/target/helpers.ts):

```ts
internalPort = Math.floor(Math.random() * 25535) + 40000;
```

Newt then dials the real target address from its own process namespace — newt runs its
WireGuard stack in user space via netstack, so the proxy's `net.Dial` for the backend target
happens in newt's netns, not the tunnel's
(https://github.com/fosrl/newt/blob/main/README.md, "fully in user space"; dial sites at
https://github.com/fosrl/newt/blob/main/proxy/manager.go).

The docs confirm the mental model:

> "The connector resolves backend targets on the remote network and delivers packets there."
> — https://docs.pangolin.net/development/system-architecture

And for private destinations they spell loopback out explicitly:

> "If the service lives on the same machine as the Pangolin site, you can set the destination
> to `127.0.0.1` or `localhost`. **The site then routes to its own loopback interface**,
> which is where that process is listening." —
> https://docs.pangolin.net/manage/resources/private/destinations

So: in newt mode, `127.0.0.1` means **the newt container's loopback**. That is exactly the
semantics guarden needs — a backend in the same netns as its own connector — but it requires
a per-service connector and a per-service published port, which §5 shows is not free.

### 1.3 Basic WireGuard site — loopback is not offered

> "Basic WireGuard sites do not support: Using LAN-style addresses as targets … NAT is
> required to reach targets on other hosts in the remote network."
> — https://docs.pangolin.net/manage/sites/understanding-sites

Gerbil enforces the subnet at target-creation time; a target outside the peer's subnet is
rejected (https://github.com/fosrl/pangolin/blob/main/server/routers/target/createTarget.ts):

```ts
if (site.type == "wireguard" && !isIpInCidr(targetData.ip, site.exitNodeSubnet!)) {
    return next(createHttpError(HttpCode.BAD_REQUEST, "Target IP is not within the site subnet"));
}
```

**Loopback targets do not work in basic-WireGuard mode.** Cited plainly.

### 1.4 Loopback summary table

| Mode | Which netns resolves/dials `127.0.0.1` | `127.0.0.1:20000` means |
|---|---|---|
| No-tunnelling + Local site | Traefik container | Traefik's container loopback — **not the host's** |
| Site connector (newt) | newt container | newt's container loopback — works for a same-netns backend |
| Basic WireGuard | host, via wg interface | rejected unless inside the peer's subnet; loopback not offered |

---

## 2. ROOTLESS FEASIBILITY, MODE BY MODE

### 2.1 Pangolin control plane (Next.js + Express) — unprivileged, no problem

Plain Node. Listens on 3000/3001/3002 (https://github.com/fosrl/pangolin/issues/1871,
startup log), nothing below 1024, no capabilities declared in
`install/config/docker-compose.yml`. **Rootless-clean.**

### 2.2 Traefik — unprivileged, no problem

Declared with no `cap_add` in the reference compose. Rootless-clean. Two caveats, neither a
capability: it fetches its dynamic config from the control plane by HTTP
(`http://pangolin:3001/api/v1/traefik-config`, per
https://docs.pangolin.net/self-host/manual/docker-compose), and it loads Badger as a Traefik
**plugin**, which Traefik compiles and runs in-process. Under podman rootless this has been
reported flaky — see §2.6.

### 2.3 Badger — unprivileged, no problem

A Go Traefik plugin doing forward-auth HTTP calls to the control plane. No kernel facilities.
(https://github.com/fosrl/badger/blob/main/README.md)

### 2.4 gerbil — the blocker. `NET_ADMIN` is required; `SYS_MODULE` is avoidable

Declared in every official compose:

```yaml
cap_add:
  - NET_ADMIN
  - SYS_MODULE
```

(https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml and
https://github.com/fosrl/gerbil/blob/main/README.md)

What gerbil actually does, from source
(https://github.com/fosrl/gerbil/blob/main/main.go):

1. **Creates a real WireGuard link** — `netlink.LinkAdd` with `LinkType: "wireguard"`
   (`createWireGuardInterface`, line ~920). This is an unconditional kernel-netlink write and
   is the reason for `NET_ADMIN`. It is created in whatever netns the process is in.
2. **Configures it** — `wgClient.ConfigureDevice`, `netlink.AddrAdd`, `LinkSetMTU`,
   `LinkSetUp` (lines 856–899).
3. **Writes its own iptables rules** — `ensureMSSClamping` shells out to
   `/usr/sbin/iptables -t mangle -A INPUT|FORWARD|OUTPUT …` (line ~995), and
   `ensureWireguardFirewall` does the same for the WireGuard firewall (line ~1167). The
   image installs `iptables` and `iproute2` for this
   (https://github.com/fosrl/gerbil/blob/main/Dockerfile).
4. **Optional traffic shaping** — `tc qdisc`/`tc filter` and an IFB device, gated behind
   `do-traffic-shaping`, default `false`; needs root and the `ifb` module (line ~1843,
   `os.Stat("/sys/module/ifb")`).

**Can gerbil run with `NET_ADMIN` inside a rootless user namespace only?** Technically the
capability would be namespaced and confined, so the WireGuard interface and the iptables
rules would land in the container's own netns rather than the host's. `SYS_MODULE` is
provably avoidable: I found **no `modprobe` call anywhere in gerbil's source**. The only
module interaction is the `os.Stat("/sys/module/ifb")` *check*, which gates traffic shaping
and defaults off. So `SYS_MODULE` appears to be cargo-culted for a kernel path gerbil does not
exercise — treat "avoidable in practice" as strongly supported but **UNVERIFIED** as a
supported configuration, since no upstream document states it.

However, this is moot for guarden: **"NO program gains a capability" is a hard constraint**,
and a rootless `cap_add: NET_ADMIN` is still a capability added to a program, even if scoped.
And a WireGuard interface inside the pod's netns is not enough on its own — see §5.

**Can a WireGuard interface be created entirely inside the pod's netns?** Yes as a kernel
matter — `LinkAdd` acts on the calling process's netns — but gerbil still needs the
capability to issue it, and gerbil *additionally* writes iptables rules into that netns, which
is a second privileged operation the constraint forbids. So the answer is: technically yes,
contractually no.

### 2.5 Site connector `newt` — genuinely unprivileged, and the good news here

Newt is explicitly a **user-space** implementation. From its README:

> "Newt is a fully user space WireGuard tunnel client and TCP/UDP proxy … When Newt receives
> WireGuard control messages, it will use the information encoded (endpoint, public key) to
> bring up a WireGuard tunnel using netstack **fully in user space**."
> — https://github.com/fosrl/newt/blob/main/README.md

It also supports bypass route management via netlink when it owns a TUN device
(https://github.com/fosrl/newt/blob/main/network/route.go), but its default netstack mode
needs no interface, no capability and no module. **Newt is the only tunnel component that fits
guarden's constraint model** — provided the backend shares newt's netns.

### 2.6 Rootless podman deployment of the whole stack — reported broken, twice

Two issues, both closed as stale/not-planned, both showing the control plane unreachable from
Traefik/gerbil in rootless podman + podman-compose/pods:

- "Running via rootless Podman not working" — https://github.com/fosrl/pangolin/issues/1871
- "Unable to deploy with rootless podman" (rootless podman + quadlet) —
  https://github.com/fosrl/pangolin/issues/1613 — `dial tcp 127.0.0.1:3001: connect:
  connection refused`

There is also a separate, long-open podman-specific SQLite failure, "SqliteError: unable to
open database file when using podman" (labelled `docker`, `help wanted`,
`needs investigating`) — https://github.com/fosrl/pangolin/issues/1207. I did **not** verify
whether it still reproduces on 1.24.0 — **UNVERIFIED**.

No first-class podman deployment path is documented anywhere on
https://docs.pangolin.net/self-host/manual/docker-compose — Docker Compose only.

---

## 3. WHICH MODE AVOIDS THE MOST PRIVILEGE

Ranked, least privilege first:

1. **No-tunnelling + Local site** — control plane + Traefik + Badger. **No capabilities, no
   WireGuard, no newt, no extra inbound ports.** Genuinely free of WireGuard and gerbil:
   "You can use Pangolin without Gerbil and tunneling. In this configuration, Pangolin acts
   as a normal reverse proxy and authentication manager" —
   https://docs.pangolin.net/self-host/advanced/without-tunneling. *But* it is the mode that
   cannot reach loopback-only backends (§1.1), and it needs a shared network (§3.1).
2. **Basic WireGuard site** — drops the websocket connector, keeps gerbil. Still
   `NET_ADMIN` + `SYS_MODULE`, still 51820/udp.
3. **Site connector (newt) mode** — newt itself is unprivileged, but the *node* side is
   gerbil, so the node still carries `NET_ADMIN` + `SYS_MODULE` and 51820/udp + 21820/udp.
   Full feature set.

### 3.1 What "no tunnelling" requires of the topology — quoted

> "**All setup remains the same, except Pangolin and Traefik must now be on the same network
> as the resources you want to proxy to.**"
> — https://docs.pangolin.net/self-host/advanced/without-tunneling

> "This means Traefik will use the local network to reach your resources."
> — https://docs.pangolin.net/self-host/advanced/without-tunneling

Answering the question directly: **it does not require a shared network namespace, but it does
require a shared network** — a Docker/Podman bridge, a CNI network, or host networking, with
the backend reachable at a non-loopback address on it. The reference deployment is a
user-defined bridge named `pangolin` / `pangolin_frontend`
(https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml). Both of those
are forbidden in guarden: "NO shared container network and NO docker bridge between
backends", and backends listen **only** on 127.0.0.1.

---

## 4. THE DATABASE

**Default is SQLite at `config/db/db.sqlite`, created by Pangolin on first startup**, on a
host bind-mounted volume `./config:/app/config`:

> "`config/db/db.sqlite` is created by Pangolin on first startup." —
> https://docs.pangolin.net/self-host/manual/docker-compose

That volume is persistent (a host bind mount), so it satisfies a persistence requirement — but
it is a bind mount of a directory that also holds `key` (the WireGuard private key), Traefik
config, and ACME `acme.json`. In guarden's model that directory would have to be a `state`
volume of a service, which is workable but means the control plane's home is snapshot alongside
its own database.

Postgres is optional via `server.postgres.connection_string`
(https://github.com/fosrl/pangolin/blob/main/server/lib/readConfigFile.ts); the compose
template adds a `postgres:18` service with its own `./postgres18` volume.

**What it holds** — from the control plane's role description and schema:

> "It stores organization state in a database, exposes the dashboard and REST API, handles
> authentication and authorization, and pushes configuration to every node, site connector, and
> client in real time over WebSocket." — https://docs.pangolin.net/development/system-architecture

Sensitive material, concretely:

- **User credentials.** Admin credentials used to be settable in config; that path is now
  rejected with a warning — "Your admin credentials are still in the config file … this method
  of setting admin credentials is no longer supported"
  (https://github.com/fosrl/pangolin/blob/main/server/lib/config.ts). A setup token is printed
  to the log on first boot (https://github.com/fosrl/pangolin/issues/1871). User password
  storage is in the DB; the exact hashing is **UNVERIFIED** — I did not read the users schema.
- **Sessions — durable and long.** Both session lifetimes default to **720 hours / 30 days**
  (https://github.com/fosrl/pangolin/blob/main/server/lib/readConfigFile.ts):
  `dashboard_session_length_hours` default `720`, `resource_session_length_hours` default
  `720`. Cookie name default `p_session_token`.
- **Site secrets and keys.** `SITE_SECRET` authenticates the connector's websocket
  (https://docs.pangolin.net/manage/sites/configure-site). Target auth tokens are stored
  **encrypted** with `server.secret` — `encrypt(plainToken, config.getRawConfig().server.secret!)`
  (https://github.com/fosrl/pangolin/blob/main/server/routers/target/createTarget.ts).
- **The WireGuard private key**, written by gerbil to `config/key`
  (https://docs.pangolin.net/self-host/manual/docker-compose).
- **Certificates**: ACME `acme.json` in the same tree.

**Sessions on restart:** because both lifetimes are 720h and sessions live in the database,
a control-plane restart does **not** invalidate sessions — provided the DB volume survives.
If the volume is lost (or the DB is re-initialised), every dashboard and resource session is
gone and all users re-authenticate. Traefik in-flight connections are unaffected. Note the
failure mode visible in issue #2238: cookie storms of `p_session_token_s.*` suggest resource
session cookies are numerous and per-resource, not one cookie.

---

## 5. WHAT BREAKS IF PANGOLIN IS THE EDGE

Guarden's edge today is three kernel-forwarded ports with no masquerade: 80/tcp, 443/tcp,
443/udp, all DNAT'd to an unprivileged listener on loopback. Pangolin's documented port
requirements:

> "TCP ports `80` and `443` open; UDP ports `51820` and `21820` open **if you are using
> tunneling**" — https://docs.pangolin.net/self-host/manual/docker-compose

> "**UDP Port 51820** — Site Tunnels … **UDP Port 21820** — Client Tunnels … only required for
> clients." — https://docs.pangolin.net/self-host/dns-and-networking

Precise accounting per mode, against a baseline of exactly three inbound ports:

| Mode | Extra public inbound ports | Count |
|---|---|---|
| No-tunnelling + Local site | none | **0** |
| Basic WireGuard site | 51820/udp (21820 only for clients) | **1** |
| Site connector (newt), full stack | 51820/udp + 21820/udp | **2** |

**Yes — one mode is available with zero additional inbound ports: no-tunnelling with Local
sites.** That is the only mode compatible with the "the only inbound ports are the edge's
three" invariant. It is also, per §1.1, the only mode that cannot dial a loopback backend, and
per §3.1 the only mode that demands a shared container network. The constraint set is
self-contradictory *for Pangolin specifically*: the one mode with zero new ports is the one
mode that requires the shared network guarden forbids.

Two further edge-level costs:

- **The edge is no longer unprivileged-by-default, it is a container in a bridge network.**
  Traefik must be on that network and bind 80/443 itself (compose publishes `80:80`,
  `443:443`), replacing the kernel DNAT to loopback with Docker/podman port publishing —
  which brings its own userspace NAT and its own port-forward semantics into the picture.
- **80/443 publication moves from the host kernel to the container runtime.** Under
  rootless podman with pasta and `route_localnet`, forwarding 80/443 to a *container's*
  namespace rather than to a host-loopback publication is a materially different path from
  guarden's current "DNAT to 127.0.0.1" story. **UNVERIFIED** whether that works under the
  stated constraints — it needs testing in the golden VM, not reasoning.

The docs also warn about exactly guarden's security posture being changed:

> "By tunneling out to the VPS, you are effectively including the VPS in your security
> boundary, so you must secure it as part of your overall network strategy."
> — https://docs.pangolin.net/self-host/dns-and-networking

---

## 6. VERSION / MATURITY SNAPSHOT (2026-10-03)

| Component | Latest | Released | Licence | Issues (open) |
|---|---|---|---|---|
| fosrl/pangolin | **1.24.0** | 2026-09-30 | AGPLv3 (+ per-file Fossorial Commercial) | 68 open |
| fosrl/gerbil | **1.5.2** | 2026-09-18 | AGPLv3 dual | 2 open |
| fosrl/newt | **1.18.1** | 2026-10-02 | AGPLv3 dual | 22 open |
| fosrl/badger | **v1.7.0** | 2026-08-24 | **MIT** | 2 PRs |
| fosrl/cli | **0.18.1** | — | — | 10 open |

Sources: https://github.com/fosrl/pangolin/releases, https://github.com/fosrl/gerbil/releases,
https://github.com/fosrl/newt/releases, https://github.com/fosrl/badger/releases,
https://github.com/fosrl/cli/releases

**Separately versioned: yes, entirely.** Five independent release trains with unrelated
version numbers (pangolin 1.24, gerbil 1.5, newt 1.18, badger v1.7, cli 0.18). There is no
lockstep or compatibility matrix published anywhere I could find — **UNVERIFIED** whether
Fossorial publishes one privately. Badger's release note pins the coupling loosely
("Add support for Pangolin (>= 1.22.0) AI Gateway public resources",
https://github.com/fosrl/badger/releases/tag/v1.7.0), and the compose pins Badger to an
explicit version while `pangolin:latest` floats — https://docs.pangolin.net/self-host/manual/docker-compose.

**Licence:** dual AGPLv3 + Fossorial Commercial is stated for gerbil
("Gerbil is dual licensed under the AGPLv3 and the Fossorial Commercial license",
https://github.com/fosrl/gerbil/blob/main/README.md) and newt (same file, newt repo).
Pangolin's repo lists AGPLv3. Badger is **MIT**
(https://github.com/fosrl/badger). The "per-file commercial licence" claim in the brief is
consistent with a dual AGPL/commercial model, but I did **not** verify any per-file licence
header — **UNVERIFIED**. AGPL matters to guarden: network use is distribution-triggering.

**CVEs / security advisories: none published.** Empty advisories pages for all five repos
(https://github.com/fosrl/pangolin/security/advisories and the equivalents for gerbil, newt,
badger, cli). Security contact is a private email, no bounty or SLA:

> "Send a detailed report to security@pangolin.net … We aim to address the issue as soon as
> possible." — https://github.com/fosrl/pangolin/blob/main/SECURITY.md

No NVD/CVE entries surfaced in my searching — **UNVERIFIED** for NVD specifically (I did not
query NVD directly).

**Support / LTS policy: none published.** No LTS branch, no support matrix, no EOL statement
found in docs or repos — **UNVERIFIED** as a negative, though I searched the docs' enterprise
page and release notes without finding one.

**Maturity signals worth weighing:** 23k stars on the control plane; 1.24.0 shipped 3 days
ago; badger v1.6.0/v1.6.1/v1.7.0 are functionally identical, re-released to work around a
Traefik plugin registry outage that was only resolved 2026-08-27
(https://github.com/fosrl/badger/releases/tag/v1.7.0) — i.e. the auth path could not be
fetched at all for a window. Newt is being retired: "Newt is being phased out in favor of the
Pangolin CLI" (https://github.com/fosrl/newt/blob/main/README.md), so the connector path is
mid-migration.

---

## 7. VERDICT

**Not realistic today for guarden's constraints.** Not because Pangolin is bad software — it is
well-built, actively maintained, and its control plane is genuinely rootless-clean — but
because the two constraints that matter are mutually exclusive *within Pangolin's own design*:

- The only mode with **zero extra inbound ports** (no-tunnelling + Local site) requires
  Traefik to share a network with the backends and resolves `127.0.0.1` in **Traefik's**
  netns. It cannot reach a loopback-only backend. Quote:
  "Pangolin and Traefik must now be on the same network as the resources you want to proxy to."
- The mode that **does** reach loopback backends (newt site connector, resolving `127.0.0.1`
  in newt's netns) requires gerbil on the node — `NET_ADMIN` + `SYS_MODULE` — plus 51820/udp
  and 21820/udp public inbound, breaking the "only the edge's three ports" invariant outright.

**The single biggest technical blocker: there is no rootless, shared-namespace, no-new-port
path to a loopback-only backend.** Any deployment that puts Pangolin's edge in front of a
backend bound to `127.0.0.1:20000` on the host requires either (a) the backend to bind
something other than loopback, or (b) the edge and the backend to share a network namespace.
Guarden forbids both — no non-loopback bind, no shared network — so the blocker is not a
capability we could negotiate down but a **topology that Pangolin's architecture does not
offer**. Even zeroing gerbil's `SYS_MODULE` (which appears avoidable, though unverified)
leaves `NET_ADMIN` and the port delta untouched.

**If guarden ever revisits this**, the narrowest viable shape is: control plane + Traefik +
Badger only (no gerbil, no newt, no new ports), with each backend's *own* service-local
loopback publication fronted by… something that already speaks to it. That is not Pangolin;
that is guarden's existing `roots`/`loom` edge doing the job it already does.

**Secondary risks even if the blocker were solved:** no published podman deployment path with
two open-then-stale reports of it failing (#1613, #1871), a podman SQLite failure (#1207,
reproduce status UNVERIFIED), five independently versioned components with no published
compatibility matrix, AGPL network-use obligations, no CVEs *and* no advisories policy beyond
an email address, and no LTS.

---

## URL index

- https://docs.pangolin.net/manage/sites/understanding-sites
- https://docs.pangolin.net/self-host/advanced/without-tunneling
- https://docs.pangolin.net/self-host/dns-and-networking
- https://docs.pangolin.net/self-host/manual/docker-compose
- https://docs.pangolin.net/development/system-architecture
- https://docs.pangolin.net/manage/resources/understanding-resources
- https://docs.pangolin.net/manage/resources/public/targets
- https://docs.pangolin.net/manage/resources/private/destinations
- https://docs.pangolin.net/manage/sites/configure-site
- https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/loadBalancer.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/getTraefikConfig.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/target/createTarget.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/target/helpers.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/validators.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/readConfigFile.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/config.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/traefik/traefikConfigProvider.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/site/createSite.ts
- https://github.com/fosrl/pangolin/blob/main/SECURITY.md
- https://github.com/fosrl/gerbil/blob/main/main.go
- https://github.com/fosrl/gerbil/blob/main/Dockerfile
- https://github.com/fosrl/gerbil/blob/main/README.md
- https://github.com/fosrl/newt/blob/main/README.md
- https://github.com/fosrl/newt/blob/main/proxy/manager.go
- https://github.com/fosrl/newt/blob/main/network/route.go
- https://github.com/fosrl/badger/blob/main/README.md
- https://github.com/fosrl/pangolin/issues/1613
- https://github.com/fosrl/pangolin/issues/1871
- https://github.com/fosrl/pangolin/issues/2238
- https://github.com/fosrl/pangolin/issues/1207
- https://github.com/fosrl/badger/releases/tag/v1.7.0
- https://github.com/fosrl/{pangolin,gerbil,newt,badger,cli}/releases
- https://github.com/fosrl/{pangolin,gerbil,newt,badger,cli}/security/advisories
