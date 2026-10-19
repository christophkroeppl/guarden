# 292 — default basic auth for every new service, generated with the gate module

Blockers: none. Filed 2026-10-19 from `BACKLOG-default-basic-auth.md`
(wave 4). Operator decisions (binding): basic auth is the **default** for all
new services; the login material is generated at traefik-module installation
and the per-service credential goes through the **existing** credential /
materialiser machinery — never a second secrets path, never one fleet-wide
password; existing services are grandfathered; **a manifest can never disable
auth** (repository input rule, same class as the refused directives).

## What is being asked

Installing the gate module puts every service created after that installation
behind a per-service basic-auth credential at the edge, without a manifest
change. Removing it must be a conscious root-side act — and, per this ticket's
spec citation, no act a repository can perform at all.

## Spec citations for the chosen mechanism

- **Where the policy lives** — spec 3.1 and 10: `guarden.toml`, root-owned,
  "decides … the host's policy … the module set". The policy is in force
  exactly while `gate-traefik` is an enabled module, and it is **written at
  `weedr module add gate-traefik`** as `/etc/guarden/edge/basicauth`, the same
  shape and the same directory as the auth-authelia marker
  `/etc/guarden/edge/auth-provider` (spec 6.4, `edgeconf.write_marker`). A
  marker file rather than a new table: spec 3.1's table set and spec 3.3's
  "nothing else is overridable" are both closed, so a `[defaults]` table would
  be an invented one.
- **Where the credential lives** — spec 6.2: `/etc/guarden/creds/<name>/<KEY>.cred`,
  mode `0600`, encrypted `--with-key=host`, materialised by the credential
  materialiser (spec 6.9), minted with the same `generated_value()` a poke
  plants (`credentials.plant`). One credential per service, key
  `GUARDEN_BASICAUTH`; never a value in a rendered unit (spec 6.3).
- **Where the htpasswd entry lives** — root-side output of the mutator, the
  same way a grant's rule text is an output: `/etc/guarden/edge/basicauth/<service>.htpasswd`,
  mode `0640 root:edge`, read by the edge container through `GroupAdd=keep-groups`
  (ADR-0017) from a `Volume=` on the shipped edge unit. The password is hashed
  `{SHA}` (base64 of SHA-1), which traefik's BasicAuth middleware documents as
  an accepted format; the input is a 32-byte `token_urlsafe` mint, so the hash
  protects a value no dictionary carries.
- **How the middleware attaches** — the edge's file provider, one definition
  per service inside that service's own route file (spec 6.4: `roots` writes
  one file per service into `/var/lib/guarden/edge/dynamic/` and nothing else).
  Routes are the renderer's slice (spec 6.3, `shared/routes.toml`), so the flag
  travels `registry -> loom -> slice -> roots`, and no program re-reads a
  manifest to learn it.
- **Grandfathering** — the registry (spec 3.4) records `basicauth = true` at
  creation while the policy is in force. A service created before the marker
  exists carries no flag, and no flag means no middleware: a re-render of a
  grandfathered service is byte-identical to what it rendered before.
- **A manifest cannot disable it** — spec 10: "A repository cannot widen any of
  2, 3 or 4", and spec 4's closed key sets (`routes` takes `container`, `port`,
  `host`, `auth`). The basic-auth flag is read from the registry and the slice
  only; a route's `auth:` key continues to mean forward-auth and nothing else,
  so there is no key that reaches this middleware — the same reason
  `published_ports` is refused by name.

## What happens if it stays out

Every new service is reached through the edge with no credential in front of
it unless a manifest remembers to ask (`auth: true`) *and* the auth-authelia
module is installed — and a manifest that forgets is a service the internet can
reach. The default is currently "protected only when the repository opts in",
which inverts who holds the decision.

## What to build

1. `weedr module add gate-traefik` writes the root-owned marker
   `/etc/guarden/edge/basicauth` (mode `0640`, dir `0750`), beside the
   auth-authelia marker. The module's own `[[switches]]`/`[[services]]` handling
   is untouched; the marker is one more file that module install generates.
2. On service creation, when the marker exists **and** the manifest declares
   `routes:`, the mutator mints `GUARDEN_BASICAUTH` through
   `credentials.plant`, writes the service's htpasswd entry root-side, and
   records `basicauth = true` in the registry. Creation of an existing service
   (re-ingest, an instance of an already-flagged service) never re-mints: the
   first mint is the login.
3. `loom` writes `basicauth = true` into the service's route slice when the
   registry says so.
4. `roots` emits a per-service `basicAuth` middleware with `usersFile:` aimed
   at that service's htpasswd and attaches it to that service's edge routers
   (edge-destination routes; a tunnel route is dialled by cloudflared straight
   at the publication and never passes the edge — see the gap note).
5. The shipped `traefik.container` gains one `Volume=` for
   `/etc/guarden/edge/basicauth` mounted read-only into the container.
6. Root-side retrieval of the generated login is `systemd-creds decrypt
   /etc/guarden/creds/<service>/GUARDEN_BASICAUTH.cred` (root only); no verb
   prints a value (`weedr secret list` prints names, spec 6.2).

## Known gaps (reported, not invented)

- **No opt-out yet.** The backlog's acceptance seed wants a root-owned
  per-service "no auth" setting. Neither spec surface admits one: spec 3.3
  closes overrides.toml ("nothing else is overridable") and spec 3.1's
  `guarden.toml` table set carries no defaults table. Adding either would be
  inventing a table, which the dispatch decision forbids. The honest current
  state: the flag is on and no repository can remove it; an operator who needs
  one service without it needs a spec decision first.
- **Password rotation does not rewrite the htpasswd.** `weedr secret set`
  replaces the blob and the materialiser re-pushes the podman secret, but the
  edge reads the htpasswd file minted at creation. Rotating means re-running
  the htpasswd write; wiring that to `secret set` is follow-up work.
- **Tunnel routes carry no middleware**, because cloudflared dials the
  service's publication directly (spec-adjacent: the tunnel ingress the
  renderer writes names `http://<name>:<publication>`). Protecting a tunnel
  route is Cloudflare-side, not traefik-side.

## Status: ready-for-agent

- [ ] Marker written by `weedr module add gate-traefik`, root-owned, and a
      service created afterwards with `routes:` carries
      `basicauth = true` in its registry and a `basicAuth` middleware on its
      edge routers, with **no manifest change**.
- [ ] Credentials are root-owned, per service, `0640 root:edge` htpasswd plus
      the encrypted blob in `/etc/guarden/creds/`, re-materialisable (t60-secrets
      patterns).
- [ ] A manifest cannot disable auth: a route with `auth: false` on a flagged
      service still renders the basic-auth middleware.
- [ ] A service created **before** the marker (grandfathered) re-renders with
      no basic-auth middleware.
- [ ] Red first: `tests/t450-basicauth.sh` (reserved range t450–t459).
