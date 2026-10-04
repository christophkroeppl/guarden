# Can Pangolin's bundled Traefik replace an independently-configured file-provider Traefik?

Research only. Nothing downloaded, installed or executed. Every claim carries a URL; anything I
could not confirm from primary source is marked UNVERIFIED.

Repo: /media/data/projects/ACTIVE/guarden — research note, feeds an architecture ticket.
Compiled 2026-10-03. Companion note: `pangolin-unprivileged-loopback.md` (privilege and
networking; this note is about *configuration ownership* and *edge capability*).

---

## 0. TL;DR

**Pangolin's Traefik is a separately-run upstream container that Pangolin feeds over HTTP. It is
not bundled into the `fosrl/pangolin` image, and its dynamic config is generated from Pangolin's
database — so it is the wrong shape for an operator-owned file-provider directory. But the two
providers coexist: an operator's own `file` config is loaded *alongside* Pangolin's `http`
provider, and an operator's Traefik can run the Badger plugin and point it at a reachable
`/api/v1/badger/verify-session`.** So the accurate answer is not "no" — it is "Pangolin cannot
*be* your file-provider Traefik, but it can sit behind or beside one."

The three findings that matter most for guarden:

1. **Ownership is split, not shared.** Pangolin owns a *complete* dynamic config served from its
   DB; the operator's file provider adds to it but cannot remove or reorder it. Generated
   routers are namespaced in the `http` provider (`badger`, `redirect-to-https`,
   `pp-transport-v1@file`), so operator routers and Pangolin routers coexist with no collision —
   but an operator cannot suppress a generated router except by deleting the resource that made
   it.
2. **Badger is not `forwardAuth` and needs no compilation.** It is a Yaegi-interpreted Traefik
   *middleware* configured **in the dynamic config**, and it calls Pangolin's API **per request**
   (two POSTs: `/badger/verify-session`, and `/badger/exchange-session` on a session-token
   request). It reads no env var and no file of its own. This is the one part that ports cleanly.
3. **Auth outside Traefik is a plain HTTP endpoint, undocumented but real.**
   `POST /api/v1/badger/verify-session` takes the whole request as JSON and returns a decision.
   Any reverse proxy could `auth_request` it. Nothing in the docs mentions this — **the capability
   is UNVERIFIED as supported**, and it is the sharpest edge of Pangolin for guarden.

**The blocker for a drop-in replacement is not the config mechanism. It is that a local-site
target is dialled by Traefik's own network namespace** (companion note §1.1), which cannot reach
a host loopback publication.

---

## 1. HOW PANGOLIN CONFIGURES ITS TRAEFIK

### 1.1 It is a separate container, not part of the fosrl/pangolin image

The installer's compose template runs three images. Traefik is the **upstream** image, its own
container, with its own config directory:

```yaml
# https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml
  traefik:
    image: docker.io/traefik:v3.7
    container_name: traefik
    restart: unless-stopped
    {{if .InstallGerbil}}network_mode: service:gerbil # Ports appear on the gerbil service{{end}}
    command:
      - --configFile=/etc/traefik/traefik_config.yml
    volumes:
      - ./config/traefik:/etc/traefik:ro
      - ./config/letsencrypt:/letsencrypt
      - ./config/traefik/logs:/var/log/traefik
```

The `fosrl/pangolin` **Dockerfile contains no Traefik at all** — no `traefik` string, no badger,
no plugin; it is a `node:24.18.1-slim` build of the Next.js/Express control plane
(https://github.com/fosrl/pangolin/blob/main/Dockerfile). So "bundled" is misleading: the image
ships the *config files* that make Traefik a Pangolin node, and the Traefik binary is upstream's.

### 1.2 Two providers, and the operator owns exactly one of them

```yaml
# https://github.com/fosrl/pangolin/blob/main/config/traefik/traefik_config.yml
providers:
  http:
    endpoint: http://pangolin:3001/api/v1/traefik-config
    pollInterval: 5s
  file:
    filename: /etc/traefik/dynamic_config.yml
experimental:
  plugins:
    badger:
      moduleName: github.com/fosrl/badger
      version: v1.4.1
```

Identical in the docs
(https://docs.pangolin.net/self-host/manual/docker-compose, and
https://docs.pangolin.net/self-host/manual/podman-quadlets).

**So: yes to "Pangolin generates routers/middlewares/services from its own DB and pushes them",
via an HTTP provider polled every 5s. And yes, an operator-supplied file-provider config
coexists.** The docs' own community guides rely on exactly this — adding a `providers.file.directory`
of extra rules while the `http` provider keeps running
(https://docs.pangolin.net/self-host/community-guides/traefik-hardening,
https://docs.pangolin.net/self-host/community-guides/middlewaremanager).

Provider namespacing is Traefik's, not Pangolin's, and it is what makes coexistence safe:

> "When you declare certain objects in the Traefik dynamic configuration, such as middleware,
> services, TLS options or server transports, they reside in their provider's namespace … then the
> object name should be suffixed by the @ separator, and the provider name."
> — https://doc.traefik.io/traefik/reference/install-configuration/providers/overview/

### 1.3 Who owns the config file — quoted

The static file is unambiguously operator-owned and operator-maintained; the installer generates
it once and hands it over:

> "This guide walks through a manual deployment using the same file layout the installer generates
> from `install/config/*` in the Pangolin source tree. Use it if you want the installer's defaults,
> but you want to create and maintain the files yourself."
> — https://docs.pangolin.net/self-host/manual/docker-compose

The **dynamic** file's ownership is split by *content*, not by *path*. The docs split it explicitly
in "Dynamic Configuration" vs the HTTP provider, and the split is visible in the templates:
`dynamic_config.yml` holds **only** dashboard/API routers; every *resource* router is generated
into the HTTP provider response.

> "This file defines the routers, middleware, and services that send dashboard, API, and WebSocket
> traffic to Pangolin." — https://docs.pangolin.net/self-host/manual/docker-compose

**Answer: the operator owns the Traefik static config and the dashboard half of the dynamic
config. Pangolin owns the resource half of the dynamic config, generated from the database on
every poll. Neither is ignored by the other; they merge.**

### 1.4 What the generated config contains

`getTraefikConfig()` reads `sites ⋈ targets ⋈ resources ⋈ domains ⋈ targetHealthCheck` out of the
database with one query and emits the whole Traefik dynamic document
(https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/getTraefikConfig.ts). Per HTTP
resource it emits a router, a `-redirect` router, a service, and any header/path middlewares:

```ts
config_output.http.routers![routerName] = {
    entryPoints: [ resource.ssl
        ? config.getRawConfig().traefik.https_entrypoint
        : config.getRawConfig().traefik.http_entrypoint ],
    middlewares: routerMiddlewares,          // ["badger", ...additional_middlewares]
    service: serviceName,
    rule: rule,                              // Host(`...`) + optional path match
    priority: priority,
    ...(resource.ssl ? { tls } : {})
};
if (resource.ssl) {
    config_output.http.routers![routerName + "-redirect"] = {
        entryPoints: [ config.getRawConfig().traefik.http_entrypoint ],
        middlewares: [redirectHttpsMiddlewareName],
        service: serviceName, rule: rule, priority: priority
    };
}
```

Two generated config values reference the **`file` provider by name**, proving the merge is
designed, not accidental:

```ts
serversTransport: `${ppPrefix}${resource.proxyProtocolVersion || 1}@file`  // → pp-transport-v1@file
```

`config_output` is returned whole from `GET /api/v1/traefik-config`
(https://github.com/fosrl/pangolin/blob/main/server/routers/traefik/traefikConfigProvider.ts,
route at https://github.com/fosrl/pangolin/blob/main/server/routers/internal.ts:
`internalRouter.get("/traefik-config", traefik.traefikConfigProvider)`).

**The badger middleware config is injected by Pangolin, at response time, and it is
Pangolin-derived** — every value comes from the control plane's own config:

```ts
apiBaseUrl: config.getRawConfig().server.badger_override ||
    new URL("/api/v1", `http://${…server.internal_hostname}:${…server.internal_port}`).href,
userSessionCookieName: …server.session_cookie_name,
resourceSessionRequestParam: …server.resource_session_request_param,
disableDefaultCFIPs: …server.trust_ips.length > 0,
trustip: …server.trust_ips,
```

### 1.5 The one file-based escape hatch — `traefik.file_mode`

There *is* a config flag that makes Pangolin write its dynamic config to a **file** instead:

> "`file_mode` … Whether to use file-based configuration mode for Traefik. … **When enabled, uses
> file-based dynamic configuration instead of API-based updates.**"
> — https://docs.pangolin.net/self-host/advanced/config-file

Default `false` (https://github.com/fosrl/pangolin/blob/main/server/lib/readConfigFile.ts). When
true, `server/index.ts` starts a `TraefikConfigManager` which polls and
`atomicWriteFileSync`s YAML to `traefik.dynamic_router_config_path` (default
`/var/dynamic/router_config.yml`)
(https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/TraefikConfigManager.ts,
https://github.com/fosrl/pangolin/blob/main/server/index.ts).

**This does not help guarden.** It changes the *transport* (HTTP poll → file write); the file's
*content* is still 100% Pangolin-generated from the database, written atomically whenever it
differs, to a path Pangolin owns. It is not an operator-authored dynamic directory. It appears
gated to managed/enterprise deployments (the same doc says `certificates_path` and the
`dynamic_*_path` fields are "used only with managed Pangolin deployments") — **whether `file_mode`
works in Community Edition is UNVERIFIED**; the code path has no build guard on the manager itself,
but the surrounding cert logic is `build != "oss"` gated.

---

## 2. WHAT EXACTLY IS 'badger'?

### 2.1 A Traefik *middleware plugin* — not `forwardAuth`, and not compiled

`.traefik.yml` declares it plainly:

```yaml
# https://github.com/fosrl/badger/blob/main/.traefik.yml
displayName: Pangolin (Badger)
type: middleware
iconPath: .assets/icon.png
import: github.com/fosrl/badger
summary: Middleware auth bouncer for Pangolin
```

It is a **Yaegi plugin**, which corrects a common misconception:

> "Traefik Yaegi plugins are developed using the Go language. It is essentially a Go package.
> Unlike pre-compiled plugins, Yaegi plugins are executed on the fly by Yaegi, a Go interpreter
> embedded in Traefik. … **No compilation required**"
> — https://doc.traefik.io/traefik/extend/extend-traefik/

`go.mod` is four lines — `module github.com/fosrl/badger` / `go 1.25`, no Traefik dependency
(https://github.com/fosrl/badger/blob/main/go.mod). Nothing to build.

**Can an operator's own Traefik load it? Yes**, in the stock upstream image, by adding the
`experimental.plugins.badger` block — Traefik downloads and interprets the module at startup:

> "To add a new plugin to a Traefik instance, you must change that instance's install (static)
> configuration." — https://doc.traefik.io/traefik/plugins/
> `experimental.plugins` accepts `moduleName`, `version`, optional `hash` —
> https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/

`experimental.localPlugins` also exists if you want it from a local directory rather than GitHub.

**Version coupling: loose.** The plugin's tag is independent of Traefik's (`v1.7.0` current per
https://plugins.traefik.io/plugins/676da7c6eaa878daeef9c7e9 and
https://github.com/fosrl/badger/releases). Traefik requires only that the plugin's Go code
interpret under its own Yaegi stdlib; there is no stated "plugin version must equal Traefik
version" rule anywhere in Traefik's docs — I searched for it and found none. Badger's own release
notes couple to *Pangolin*, not Traefik ("Add support for Pangolin (>= 1.22.0) AI Gateway public
resources", https://github.com/fosrl/badger/releases/tag/v1.7.0). **A precise compatibility matrix
between badger tags and Traefik versions is UNVERIFIED** — none published, and Yaegi-version
breakage is a known class of Traefik issue (e.g. https://github.com/traefik/traefik/issues/8450).

### 2.2 What it reads for configuration — the dynamic config, and it calls the API per request

Config is a `Config` struct read from the Traefik **dynamic** config, by JSON tag. Required when
forward auth is on (`https://github.com/fosrl/badger/blob/main/main.go`):

```go
if !config.DisableForwardAuth {
    if config.APIBaseUrl == "" { return nil, fmt.Errorf("apiBaseUrl is required when forward auth is enabled") }
    if config.UserSessionCookieName == "" { … }
    if config.ResourceSessionRequestParam == "" { … }
}
```

Keys: `apiBaseUrl`, `userSessionCookieName`, `resourceSessionRequestParam`, `accessTokenQueryParam`,
`accessTokenIdHeader`, `accessTokenHeader`, `disableForwardAuth`, `trustip`, `disableDefaultCFIPs`,
`customIPHeader`, `realIpHeader`, and the `remote*Header` identity headers.

**No env var, no config file of its own.** Per request it does **two** things:

1. If the request carries the session-request query param, it POSTs to
   `%s/badger/exchange-session` and redirects with a `Set-Cookie`.
2. Always, it POSTs the whole request to `%s/badger/verify-session`:

```go
verifyURL := fmt.Sprintf("%s/badger/verify-session", p.apiBaseUrl)
cookieData := VerifyBody{ Sessions: cookies, OriginalRequestURL: originalRequestURL,
    RequestScheme: &req.URL.Scheme, RequestHost: &req.Host, RequestPath: &req.URL.Path,
    RequestMethod: &req.Method, TLS: req.TLS != nil, RequestIP: &realIP,
    Headers: headers, Query: queryParams, BadgerVersion: version.Version }
resp, err := http.Post(verifyURL, "application/json", bytes.NewBuffer(jsonData))
```

On `data.valid` it injects identity headers (`Remote-User-Id`, `Remote-User`, `Remote-Email`,
`Remote-Name`, `Remote-Role`, `Remote-Virtual-Api-Key-Id`), strips the session cookie/param from
the forwarded request, and calls `p.next.ServeHTTP`. On failure it honours
`data.redirectUrl`, `data.headerAuthChallenged` (emits `WWW-Authenticate: Basic realm="pangolin"`),
or `data.clientError`.

So: **the auth decision is made by Pangolin, per request, over HTTP.** Badger is a transport
adapter, not a policy engine.

### 2.3 Running the auth check OUTSIDE Traefik — yes, the endpoint exists; support is undocumented

The two endpoints are on the **internal** Express server, mounted at prefix `/api/v1`, with **no
auth middleware on the badger routes** (contrast `/resource/:resourceId/get-exchange-token`, which
does carry `verifySessionUserMiddleware`, `verifyResourceAccess`):

```ts
// https://github.com/fosrl/pangolin/blob/main/server/routers/internal.ts
const badgerRouter = Router();
internalRouter.use("/badger", badgerRouter);
badgerRouter.post("/verify-session", badger.verifyResourceSession);
badgerRouter.post("/exchange-session", badger.exchangeSession);

// https://github.com/fosrl/pangolin/blob/main/server/internalServer.ts
const prefix = `/api/v1`;
internalServer.use(prefix, internalRouter);
```

Request schema (Zod, `https://github.com/fosrl/pangolin/blob/main/server/routers/badger/verifySession.ts`):
`sessions?`, `headers?`, `query?`, `originalRequestURL` (url), `scheme`, `host`, `path`, `method`,
`tls`, `requestIp?`, `badgerVersion?`. Response: `{ data: { valid, redirectUrl, redirectPermanent,
userId, username, email, name, role, virtualApiKeyId, responseHeaders, dontStripSession,
headerAuthChallenged, pangolinVersion, clientError } }`.

**This is a conventional auth subrequest contract.** nginx `auth_request`, Caddy `forward_auth`,
HAProxy, or a hand-written shim could each point at it. **But:**

- **No JWKS, no OIDC-validate, no token-introspection endpoint, no `.well-known` anything.** I
  searched the whole repo tree for `jwks` / `wellknown` / `oidc` / `jwt` and the only hits are IdP
  *inbound* config and the enterprise licence JWT — nothing a proxy validates against. So there is
  **no stateless/offline verification path**: every request is a round trip to Pangolin.
- **UNVERIFIED as a supported configuration.** Nothing in docs.pangolin.net documents putting
  nginx/Caddy/HAProxy in front of Pangolin, and repo-wide search for `nginx`, `caddy`, `haproxy`
  turns up only an nginx reference in Docker-container-scanning
  (`server/lib/blueprints/parseDockerContainers.ts`) and nothing else. Badger's own README says
  the opposite of what you'd want: *"This plugin is **required** to be installed alongside Pangolin
> to enforce secure authentication and session management"* (https://github.com/fosrl/badger).
- Caveat: `trust_ips` / `customIPHeader` are Badger-side concepts (it decides `requestIp`). A
  non-Traefik caller must supply `requestIp` correctly itself, or it is trusting the client's word.
- Caveat: badger's Cloudflare IP list is compiled in (`ips/ips.go`, `updateCFIps.sh`), so a
  non-Traefik caller re-implements that trust decision.

**Honest reading: `/badger/verify-session` is a real, reachable, conventionally-shaped endpoint
that would work as an `auth_request` target. Building a production edge on it means depending on
an undocumented internal route whose schema is coupled to Badger's release train. That is a
support-bet, not an integration.**

---

## 3. TRAEFIK VERSION AND PINNING

| Fact | Value | Source |
|---|---|---|
| Pinned image | `docker.io/traefik:v3.7` | https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml, https://docs.pangolin.net/self-host/manual/docker-compose |
| Major version | **Traefik v3** (floating minor within v3) | same |
| Badger pin (repo default config) | `v1.4.1` | https://github.com/fosrl/pangolin/blob/main/config/traefik/traefik_config.yml |
| Badger pin (docs examples) | `v1.4.0`, "Check github.com/fosrl/badger for the latest release" | https://docs.pangolin.net/self-host/manual/docker-compose |
| Badger pin (installer) | `{{.BadgerVersion}}`, resolved from the latest badger tag at build time | https://github.com/fosrl/pangolin/blob/main/install/Makefile, .../install/main.go, .../install/config/traefik/traefik_config.yml |
| Badger current release | `v1.7.0` (2026-08-24) | https://github.com/fosrl/badger/releases |
| In the fosrl/pangolin image? | **No** — no Traefik, no badger, no plugin in the Dockerfile | https://github.com/fosrl/pangolin/blob/main/Dockerfile |

Note the pin inconsistency: the repo's own committed `config/traefik/traefik_config.yml` says
`v1.4.1`, the docs say `v1.4.0`, the installer template interpolates a version, and the installer
*reads back* whatever version it finds in the config it is about to write
(`config.BadgerVersion = traefikConfig.BadgerVersion`,
https://github.com/fosrl/pangolin/blob/main/install/main.go). Which of `v1.4.0`, `v1.4.1` or
`latest` a given install actually lands on is therefore **UNVERIFIED** — it depends on whether you
used the installer, the release tarball, or a hand-copied file.

Also relevant: the quadlet guide uses `Image=docker.io/traefik:latest`, not a pinned tag
(https://docs.pangolin.net/self-host/manual/podman-quadlets).

### What breaks with a different Traefik

| Change | Consequence | Evidence |
|---|---|---|
| Different Traefik major (v2) | Hard break. Config shape is v3 (`experimental.plugins`, `http.tls.options`, `encodedCharacters`); badger's `.traefik.yml` is `type: middleware`, a v3 concept | https://doc.traefik.io/traefik/extend/extend-traefik/ |
| Different v3 minor | Probably fine; badger is interpreted, no compile step. **Exact compat UNVERIFIED** | https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/ |
| Own build / baked-in plugin | Works, and is arguably *safer*: `experimental.localPlugins` avoids the runtime GitHub fetch | https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/ |
| Own dynamic dir **alongside** | Works — this is what the community guides do | https://docs.pangolin.net/self-host/community-guides/traefik-hardening |
| Own dynamic dir **instead of** the http provider | **Loses all resource routing.** No provider, no generated routers, no resource auth | https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/getTraefikConfig.ts |
| Renaming entryPoints | Breaks silently-ish. Generated routers reference `traefik.http_entrypoint` / `https_entrypoint` **by name**; mismatch → routers on nonexistent entrypoints | same, + https://docs.pangolin.net/self-host/advanced/config-file |
| Removing the `file` provider | Breaks TCP/UDP resources: generated config references `pp-transport-v1@file` | getTraefikConfig.ts |
| No egress to github.com | Plugin fetch fails at startup (Yaegi downloads the module). No vendored/cached path documented — `experimental.localPlugins` is the mitigation | https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/ |

Note the last row is load-bearing for guarden's air-gapped-ish posture: **the reference install
reaches out to GitHub at Traefik startup to fetch the auth plugin.**

---

## 4. PUBLIC PORTS AND CERTS

### 4.1 Ports — confirmed, and only two of the four are structural

> "TCP Port 80 — HTTP/SSL Verification: Let's Encrypt domain validation; Non-SSL resources; **Can
> be disabled with wildcard certs**"
> "TCP Port 443 — HTTPS Traffic … Essential for operation"
> "UDP Port 51820 — Site Tunnels. This is the default port for Pangolin Sites to establish tunnels
> to the proxy."
> "UDP Port 21820 — Client Tunnels … **This port is only required for clients.**"
> — https://docs.pangolin.net/self-host/dns-and-networking

80, 443, 51820/udp, 21820/udp confirmed. **443/udp is optional** and is commented out in the docs'
compose (`# - 443:443/udp # Uncomment if you enable HTTP/3 in Traefik`,
https://docs.pangolin.net/self-host/manual/docker-compose) but **uncommented** in the installer's
template (`- 443:443/udp # For http3 QUIC if desired`,
https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml). So an installer
run opens a fourth inbound port that the docs describe as optional. In no-tunnelling mode the two
UDP ports disappear: "Gerbil is not required", only `80:80` and `443:443` go to Traefik
(https://docs.pangolin.net/self-host/advanced/without-tunneling, .../manual/docker-compose).

### 4.2 Certs — Traefik's ACME, HTTP-01 by default, DNS-01 for wildcards

Certificates are **not** obtained by Pangolin; Traefik is the ACME client. Pangolin only names
the resolver and tells Traefik which domains to get certs for:

> "Traefik is the reverse proxy in the self-hosted Pangolin stack. **It receives HTTPS traffic,
> requests certificates from Let's Encrypt**, and routes requests to Pangolin resources."
> — https://docs.pangolin.net/self-host/advanced/wild-card-domains

Default is Let's Encrypt **HTTP-01** on the `web` entryPoint, storage `/letsencrypt/acme.json`
(https://docs.pangolin.net/self-host/manual/docker-compose). Wildcards need **DNS-01**, with
Traefik needing a provider API token in its environment:

> "Wildcard certificates require a DNS-01 challenge. You must control the domain's DNS records and
> have API credentials for a DNS provider supported by Traefik."
> — https://docs.pangolin.net/self-host/advanced/wild-card-domains

> "Cloudflare requires an API token with `Zone:Read` and `DNS:Edit` permissions for every zone
> Traefik needs to solve challenges for."
> — same

So **no**, there is no Cloudflare-issued cert by default: Cloudflare appears only as (a) an ACME
DNS-01 *credential provider* with LE still the CA, or (b) an orange-cloud proxy in front, which is
itself constrained:

> "Pangolin will **not work** with Cloudflare's Full or Automatic SSL/TLS modes. Only Full (Strict)
> mode is supported." — https://docs.pangolin.net/self-host/advanced/cloudflare-proxy

The resolver name is a **contract between two files**: `traefik.cert_resolver` in `config.yml`
must equal the `certificatesResolvers` key in `traefik_config.yml` —

> "Traefik does not automatically apply a resolver just because it exists. Each router must
> reference the resolver with `tls.certResolver`, and Pangolin's `cert_resolver` setting must
> match the Traefik resolver name." — https://docs.pangolin.net/self-host/advanced/wild-card-domains

### 4.3 Public DNS is required — yes

> "You'll need to create A (or AAAA for IPv6) records pointing to your VPS IP address." — wildcard
> record `*` → your IP
> — https://docs.pangolin.net/self-host/dns-and-networking

> "**Self-Hosted**: You point A/AAAA records at your own VPS's IP address. DNS stays with your
> existing provider; Pangolin never needs access to it."
> — https://docs.pangolin.net/manage/domains

So every served hostname needs a public record at the node's own IP (wildcard `A` is the norm).
Consistent with this, Community Edition **auto-verifies wildcard domains with no DNS check at
all** — `verified: type === "wildcard" ? true : false`
(https://github.com/fosrl/pangolin/blob/main/server/routers/domain/createOrgDomain.ts) — so
Pangolin will not catch a missing or wrong record for you; only ACME and the client will.

---

## 5. WHAT REPLACING AN EXISTING EDGE WOULD COST

Against a file-provider Traefik that today does all of the following. "Loopback publication" =
a backend bound to `127.0.0.1:<20000-32767>` on the same host, not on a shared container network.

| # | Capability | Pangolin support | Citation |
|---|---|---|---|
| 1 | HTTP→HTTPS redirect entrypoint | **Yes** | Generated per-resource: an ssl resource emits a `-redirect` router on `http_entrypoint` with `redirect-to-https`; `redirect-to-https` middleware is created in `config_output` (getTraefikConfig.ts). Independently, an operator can set entryPoint-level redirections (https://docs.pangolin.net/self-host/community-guides/traefik-hardening) |
| 2 | TLS termination + SNI routing to many backends | **Yes** | Traefik `websecure` + `tls.certResolver` per router (getTraefikConfig.ts, .../manual/docker-compose). Note: with gerbil installed, Traefik shares gerbil's netns (`network_mode: service:gerbil`) and gerbil's own SNI proxy is the front door — "In single node (self hosted) Pangolin deployments this can be bypassed by using port 443:443 to route to Traefik instead of the SNI proxy at 8443" (https://github.com/fosrl/gerbil/blob/main/README.md) |
| 3 | Per-host / wildcard certs | **Yes** | `prefer_wildcard_cert` + `cert_resolver`; DNS-01 required for `*` (https://docs.pangolin.net/self-host/advanced/wild-card-domains). Multiple resolvers supported |
| 4 | **Backends reachable only on host 127.0.0.1** | **NO** | A local-site target is emitted literally as `${target.method}://${target.ip}:${target.port}` (https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/loadBalancer.ts) and dialled by **Traefik's container netns**. Docs: "**Pangolin and Traefik must now be on the same network as the resources you want to proxy to.**" and "To access services on the host machine: Use `172.17.0.1` (Docker bridge gateway)" (https://docs.pangolin.net/self-host/advanced/without-tunneling, .../self-host/dns-and-networking). No `host.docker.internal`, no host-netns knob |
| 5 | Per-route auth | **Yes, but it is Pangolin's** | Every generated resource router gets `middlewares: ["badger", ...additional_middlewares]` (getTraefikConfig.ts). `additional_middlewares` lets an operator bolt on their own Traefik middlewares by name — "These middlewares must be defined in your Traefik dynamic configuration" (https://docs.pangolin.net/self-host/advanced/config-file). Auth itself is per-request HTTP to Pangolin |
| 6 | Dynamic reload without restart | **Yes** | `pollInterval: 5s` on the http provider (config/traefik/traefik_config.yml). Traefik hot-reloads on provider change (https://doc.traefik.io/traefik/providers/overview/ — "when Traefik detects a change, it dynamically updates the routes"). File provider `watch: true` documented for operator rules (https://docs.pangolin.net/self-host/community-guides/traefik-hardening) |
| 7 | *(bonus)* Raw TCP/UDP passthrough on a host port | Yes, **manually** | Each raw resource needs a static entryPoint named `protocol-port`, a compose port mapping, and a firewall rule, then a restart: "**Always name your entry points in the format `protocol-port`** … This naming is required for Pangolin's dynamic configuration" (https://docs.pangolin.net/manage/resources/public/raw-resources). This is the closest analogue to guarden's publications, and it is all hand-configured per port |

Three costs that are not capability gaps but architecture shifts:

- **Ports move from the kernel to the container runtime.** Guarden's edge is 80/443/443-udp
  DNAT'd to a loopback listener. Pangolin's edge is a container publishing `80:80` / `443:443`
  (https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml). That is
  userspace NAT with its own semantics, replacing the kernel-forwarded publication — directly at
  odds with guarden's ferm/`route_localnet` model. **UNVERIFIED whether it works under the stated
  constraints**; needs the golden VM.
- **One busy listener owns 80/443.** An operator's other routers cannot share the port with
  Pangolin's Traefik; they'd have to be *inside* this Traefik. The community guides' "add my own
  rules" pattern only works because they accept Pangolin's Traefik as their Traefik.
- **The control plane becomes the auth hot path.** Every request on every protected resource is a
  synchronous HTTP POST to Pangolin (badger `main.go`). No stateless verification, no caching
  layer, no degradation story if the control plane is down.

---

## 6. VERDICT

**Could Pangolin replace a file-provider Traefik sitting on the same host as loopback-only
backends? No — but not for the reason usually given, and the distinction matters.**

The commonly-assumed blocker ("Pangolin writes its own dynamic config, so an operator's file
directory is ignored") is **false**. Both providers are configured in the reference stack and the
docs' own community guides extend the file provider while Pangolin runs. An operator-authored
dynamic directory is *merged*, not ignored, and provider namespacing keeps the two halves from
colliding.

The real blockers are these three, in order:

1. **Loopback reachability (fatal for guarden's invariant).** A local-site target becomes a
   literal `http://127.0.0.1:<port>` upstream that **Traefik's container** opens. A host-loopback
   publication is in a different netns and is unreachable. Not a permissions issue — a topology
   issue, with no configuration knob. The newt site-connector mode does resolve loopback in the
   *connector's* netns, but that requires gerbil on the node with `NET_ADMIN` + `SYS_MODULE` and
   two extra public UDP ports (companion note §2.4, §5).

2. **Port ownership (§5).** Guarden's 80/443 are kernel-forwarded publications; Pangolin's are
   container-published ports. Adopting Pangolin means handing the whole ingress path to a
   container runtime, which is precisely what guarden's model replaced with a root mutator and a
   ferm render.

3. **Auth is coupled to an undocumented internal route.** `/api/v1/badger/verify-session` would
   work as an `auth_request` target and is the genuinely interesting finding — but it is
   undocumented, its schema tracks Badger's release train, and there is no JWKS/introspection
   alternative. Betting guarden's entire ingress auth on it is a support-bet.

**Nearest thing that could work, and what it costs:** no-tunnelling mode (no gerbil, no newt, no
new inbound ports) + Local sites + an operator-supplied `providers.file.directory` for the
routers that must not come from Pangolin. That is the only zero-new-port configuration, and it
is explicitly documented as requiring a shared network:

> "All setup remains the same, **except Pangolin and Traefik must now be on the same network as
> the resources you want to proxy to.**"
> — https://docs.pangolin.net/self-host/advanced/without-tunneling

**What that costs guarden: the loopback-only publications property, entirely.** Guarden's
"every service binds 127.0.0.1:20000-32767, nothing else, no shared podman network" would have to
become "every service binds an address reachable on a shared bridge", which is the one thing
guarden's ADR-0012-era connectivity model exists to prevent. Alternatively, keep loopback and put
Traefik in the **host** netns — but every documented deployment runs Traefik in a container
(`network_mode: service:gerbil`, or `Pod=services.pod` with `Network=pasta`), and
`network_mode: host` appears nowhere in the docs or templates. **UNVERIFIED** whether the stack
works at all with Traefik host-networked and gerbil removed; it is not a supported configuration
I found.

**Blunt assessment, as requested.** As a drop-in replacement for an independently-configured
Traefik, Pangolin is a poor fit, for three reasons that are structural rather than fixable:
its edge owns 80/443 and cannot share them; it can only reach backends on a shared network, which
is exactly guarden's forbidden topology; and its only portable asset — the auth check — lives
behind an undocumented internal route with no stateless verification path. What Pangolin *is*
good for is remote-network access via WireGuard site connectors with per-resource identity, and
guarden has no use for that: it is a single-host platform. Also worth weighing: AGPL on the
control plane, five independently versioned components with no published compatibility matrix, no
published podman deployment path despite a documented quadlet page, and a plugin fetch from
GitHub at Traefik startup.

If the *auth* is the actual interest rather than the proxy, the extractable piece is narrow and
clean: point any reverse proxy's subrequest mechanism at `POST /api/v1/badger/verify-session`,
supply `host`/`path`/`method`/`requestIp`/`tls` honestly, and implement the redirect and identity
header contract yourself. That is a rewrite against an undocumented API, not an integration, and
should be scoped as such if it is ever attempted.

---

## URL index

Docs
- https://docs.pangolin.net/self-host/manual/docker-compose
- https://docs.pangolin.net/self-host/manual/podman-quadlets
- https://docs.pangolin.net/self-host/advanced/without-tunneling
- https://docs.pangolin.net/self-host/advanced/config-file
- https://docs.pangolin.net/self-host/advanced/wild-card-domains
- https://docs.pangolin.net/self-host/advanced/cloudflare-proxy
- https://docs.pangolin.net/self-host/dns-and-networking
- https://docs.pangolin.net/self-host/quick-install
- https://docs.pangolin.net/self-host/community-guides/traefik-hardening
- https://docs.pangolin.net/self-host/community-guides/middlewaremanager
- https://docs.pangolin.net/self-host/community-guides/remove-geoblock-plugin
- https://docs.pangolin.net/development/system-architecture
- https://docs.pangolin.net/manage/sites/understanding-sites
- https://docs.pangolin.net/manage/resources/understanding-resources
- https://docs.pangolin.net/manage/resources/public/raw-resources
- https://docs.pangolin.net/manage/resources/public/targets
- https://docs.pangolin.net/manage/domains

fosrl/pangolin
- https://github.com/fosrl/pangolin/blob/main/Dockerfile
- https://github.com/fosrl/pangolin/blob/main/install/config/docker-compose.yml
- https://github.com/fosrl/pangolin/blob/main/install/config/traefik/traefik_config.yml
- https://github.com/fosrl/pangolin/blob/main/install/config/traefik/dynamic_config.yml
- https://github.com/fosrl/pangolin/blob/main/config/traefik/traefik_config.yml
- https://github.com/fosrl/pangolin/blob/main/config/traefik/dynamic_config.yml
- https://github.com/fosrl/pangolin/blob/main/install/Makefile
- https://github.com/fosrl/pangolin/blob/main/install/main.go
- https://github.com/fosrl/pangolin/blob/main/server/index.ts
- https://github.com/fosrl/pangolin/blob/main/server/internalServer.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/internal.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/traefik/traefikConfigProvider.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/traefik/configSchema.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/getTraefikConfig.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/loadBalancer.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/rule.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/middleware.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/traefik/TraefikConfigManager.ts
- https://github.com/fosrl/pangolin/blob/main/server/lib/readConfigFile.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/badger/verifySession.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/badger/index.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/domain/createOrgDomain.ts
- https://github.com/fosrl/pangolin/blob/main/server/routers/target/createTarget.ts

fosrl/badger
- https://github.com/fosrl/badger/blob/main/main.go
- https://github.com/fosrl/badger/blob/main/go.mod
- https://github.com/fosrl/badger/blob/main/.traefik.yml
- https://github.com/fosrl/badger/blob/main/README.md
- https://github.com/fosrl/badger/releases
- https://github.com/fosrl/badger/releases/tag/v1.7.0
- https://plugins.traefik.io/plugins/676da7c6eaa878daeef9c7e9

fosrl/gerbil
- https://github.com/fosrl/gerbil/blob/main/README.md

Traefik
- https://doc.traefik.io/traefik/extend/extend-traefik/ (Yaegi: "No compilation required")
- https://doc.traefik.io/traefik/plugins/
- https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/
- https://doc.traefik.io/traefik/reference/install-configuration/providers/overview/
- https://github.com/traefik/traefik/issues/8450 (Yaegi version breakage example)