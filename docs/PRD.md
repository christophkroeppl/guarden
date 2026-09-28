# guarden — Technical PRD

Status: draft, 2026-09-27. Product name **guarden** (garden + guard). Repo: `infra`.

Companion docs: [`CONTEXT.md`](../CONTEXT.md) is the glossary (source of truth for names). Decisions that are hard to reverse are recorded in [`docs/adr/`](./adr/).

---

## 1. Problem

We run several early projects on one VPS. There is no real deployment story: branches are ad-hoc compose stacks, there is no way to place a project into a running slot by hand, no story for shared state that does not cost one database container per app, no protection for production data against snapshot pruning, and no gate that stops a production service from starting with an empty secret. We need a small, honest platform that:

1. turns a fresh Ubuntu VPS into a runnable host,
2. lets an operator place a project into a running slot by hand,
3. optionally reconciles those slots from git,
4. offers shared state as an optional primitive, so a typical project never ships its own database container,
5. protects production data with btrfs snapshot ladders and pins,
6. exposes services through Traefik and dashboards through Homepage.

Constraints: one human, one VPS, KISS, UNIX-flavoured, loosely coupled parts, no secrets in git, must not block future SELinux/AppArmor hardening.

---

## 2. Goals / non-goals

### Goals (v1)

- **soil** converges a fresh Ubuntu (cloud-init → btrfs convert → firewall → podman/quadlet → snapper ladders) and is testable in a golden VM. cloud-init performs most host prep by inlining the install scripts; the scripts-based install remains for hosts without cloud-init.
- **weedr** creates and removes **beds** (project × environment) with their user, units, volumes, hyphae names, optional pond database, and secrets. No web UI.
- **Explicit environments.** The track is always named: `production | staging | preview | fence`. `weedr bed plow` requires `--env`, and a git manifest declares its environment. There is no implicit default.
- **pond** is a primitive, not a fixture: optional named instances (Postgres first) on the bed schema with the class prefix swapped — `pond-production-postgres`, `pond-staging-postgres`. Verbs: `weedr pond dig <name>` create, `weedr pond fill <bed>` provision, `weedr pond drain <bed>` remove. Default host prep never creates a pond.
- **fence**: Traefik runs as its own bed (`bed-fence-traefik`) in the `fence` environment track with its own user and quadlet dir; its `bed.yaml` declares ports 80/443 plus safe defaults. The auth bed (`bed-fence-authelia`, ADR-0009) shares the track and starts with it. The shared dynamic-config dir `/var/lib/roots/dynamic/` is written by unprivileged **roots** and read by the traefik bed through the `fence` group, so a roots bug cannot run containers.
- **roots** accumulates route config from beds and writes Traefik dynamic config. Traefik is a separate process in a separate user.
- **stakes** holds snapshot pins as sets of holders so ladders cannot prune data a bed still needs.
- **hose** (addon) reconciles beds from CI pokes (`project ref sha` + source over ssh) and, when the remote is readable, a `hose check` drift pass; the same manifest `weedr` reads, over an explicit project list, through the deploy queue (ADR-0010).
- **twig** (addon) renders Homepage config from per-service widgets.
- Production/fence gate: refuse to start a production or fence service whose required env value is empty or still an example value — evaluated before the old container is stopped.

### Non-goals (v1)

- Rolling deploys / blue-green. We stop then start.
- Migrations as a separate step. Apps migrate on start.
- Multi-host, k8s, Docker Swarm.
- SELinux/AppArmor policy (architecture must not block it).
- Debian/Arch/Nix install paths (cloud-init is Ubuntu-only for now).
- A web UI of any kind.
- A shared podman network across bed users; rootless podman networks are per-user (§5).
- Per-bed database containers as the default. A self-contained bed may own its own service, database, subvolume, ladder, and state — allowed, but not the default.

### Backlog

- SQL transforms for preview DBs (anonymize, rewrite critical fields).
- Adaptive build-queue lanes: add or drop parallel lanes from VPS load (the override exists; the automation is backlog).
- Remote snapshot backup sync with a pin-aware guard.
- Tailscale (or similar) for staging/dashboards exposure.
- Monitoring export (podman/vps stats) as a soil plugin.
- Shared non-pg state services in the pond (redis, minio).
- Auth bed (Authelia or Authentik) behind forward-auth at the fence: `roots` renders the rule from `auth: true` in `bed.yaml`, the auth bed is `bed-fence-authelia` in the `fence` track, named in one root-owned file (ADR-0009, ticket 190).
- Per-pond network segregation stronger than loopback blocks plus ferm uid-owner rules (§5).
- Rust ports of hot paths once Python/bash has proven the shape.

---

## 3. Domain model

Read [`CONTEXT.md`](../CONTEXT.md). The spine:

```
project                a deployable product family
  └─ bed               project × environment     (the slot)
       └─ service      api, worker, web          (one container)

environment            production | staging | preview | fence

base                   soil + roots + weedr + stakes
addons                 twig + pond + hose

hyphae                 loopback ports + host names (optional; not a podman network)
```

A **bed** owns one Linux user (`bed-<env>-<name>`), one quadlet unit directory, its volumes, and its hyphae names. The environment is always explicit: `weedr bed plow` requires `--env` and a git manifest declares `environment`.

A **pond** is a named shared-state instance (Postgres first, others later); a member bed gets a database and a role inside one. A pond owns one Linux user `pond-<env>-<name>` of the same name, created by `weedr pond dig`. Ponds are optional — a manifest with no `pond:` section needs none.

A **preview** is one bed per project (`bed-preview-<project>`) with one nested instance directory per ref under its home; the **fence** track holds `bed-fence-traefik` (Traefik for the whole host) and `bed-fence-authelia` (sign-in, ADR-0009). **hyphae** is an optional connectivity contract a bed may declare (§5) — a bed without it has no stable names and no group membership.

---

## 4. Architecture

### 4.1 Parts

| part | layer | kind | job |
|---|---|---|---|
| **soil** | base | converger scripts + timers | host prep: cloud-init, btrfs convert, ferm/fail2ban, snapper ladders, podman/quadlet, sysctl |
| **roots** | base | watcher/timer | read `bed.yaml` route and auth sections from all beds, write Traefik dynamic config |
| **weedr** | base | CLI | `bed plow` / `bed remove`, `pond dig` / `pond fill` / `pond drain`, mint pond roles, plant secrets, convert Compose → quadlet, apply ferm ports, production gate |
| **stakes** | base | tiny service + state file | pin/unpin snapshot ids with holder identity; `stakes query` shows the holders of one id, `stakes list` shows ladders and pins |
| **twig** | addon | watcher/timer | merge `widgets/<service>.yml` into Homepage config |
| **pond** | addon | optional named instances | Postgres first: named `pond-<env>-<name>` (`pond-production-postgres`, `pond-staging-postgres`, …); one database + one role per member bed |
| **hose** | addon | CLI + timer | accept a CI poke (`project ref sha` + source tarball), or run `hose check` against a readable remote; call `weedr` to apply; restart changed units — queued like every other build |

Parts talk over files and paths. There is no internal HTTP API.

Watchers are systemd `.path` units with globs over the `bed-*` / `pond-*` folder schema, recursive so nested preview refs are caught. They trigger `daemon-reload` only — never an automatic restart. No regex.

### 4.2 Daemon topology and users

| process | user | notes |
|---|---|---|
| bed services | `bed-<env>-<name>` | rootless podman, linger enabled |
| pond instances | `pond-<env>-<name>` | one user per pond, created by `weedr pond dig`; ports published on `127.0.0.1` |
| traefik | `bed-fence-traefik` | fence bed; binds :80/:443, reads `/var/lib/roots/dynamic/` |
| roots | `roots` | writes `/var/lib/roots/dynamic/` |
| stakes | `stakes` | state in `/var/lib/guarden/stakes/pins` (root-readable, one line per snapshot: the id then its holder beds); root snapper hook reads the file |
| twig | `twig` | writes Homepage config |
| hose | `hose` | calls `weedr` through a narrow sudoers rule |
| weedr | admin (sudo) | creates beds, plants secrets, mints pond roles |
| soil scripts | root | install-time convergers + snapper/ferm/fail2ban timers |

Each pond instance runs under its own user `pond-<env>-<name>` — created by `weedr pond dig` with linger, subuid/subgid, and its own quadlet dir, exactly like a bed. Separation between ponds is a real user boundary, on top of the database roles plus the hyphae group rules (§5); there is no shared `pond` user.

The shared surface between `roots` and the traefik bed is **one directory and one group** (`fence`): `roots` writes `/var/lib/roots/dynamic/`, the traefik bed reads it. They never share a user. Traefik binds :80/:443 rootless because soil sets `net.ipv4.ip_unprivileged_port_start=0`.

### 4.3 compose → quadlet

`weedr` converts `compose.yaml` into quadlet units inside the bed: **podlet** (containers org, reference semantics) as a pinned binary behind `weedr`, plus a small Python pass that emits `.volume` units for bare named volumes (podlet only emits `.volume` when the volume carries options). Bed-specific overrides are written by `weedr` as `<unit>.container.d/` drop-ins so they survive regeneration. Units supplied as `.guarden/quadlet/` are kept as they are (§6).

---

## 5. Connectivity (hyphae)

Rootless podman networks are **per-user**. A bed cannot join another bed's or a pond's podman network. This is a podman rule (ADR-0003), and no shared network exists in this design.

**hyphae** is an optional contract a bed declares, not a network:

- Shared services publish on loopback (pasta).
- Each group of members gets its own loopback block: `127.1.<g>.<n>` — a pond and its member beds talk inside their block, nobody else reaches it.
- `weedr` writes stable names into `/etc/hosts`: `<pond>.internal`, `bed-<env>-<name>.internal`.
- ferm OUTPUT rules with `uid-owner` match allow only the group's members — the pond user and its member bed users — to reach a group's block.

```
                internet
                   |
          [ bed-fence-traefik ]    :80/:443 declared in the
                   |               fence bed's bed.yaml
        +----------+-----------+
        |       loopback       |
        |                      |
  [ pond group ]          [ bed group ]
   127.1.0.<n>             127.1.1.<n>
   [ pond :5432 ]        [ bed-a :8081 ]
        |                      |
        +----------+-----------+
                   |
             pasta (to host)

 ferm OUTPUT uid-owner: only member users reach their block
```

**ferm** port openings are declared in `.guarden/bed.yaml` `ports:` plus an admin override file. `weedr` applies them and can list the active rules. Traefik's own openings (80/443) live in the fence bed's `bed.yaml`.

---

## 6. Project manifest

The contract between a **project** and **guarden**. Both `weedr` (manual) and `hose` (gitops) read the same files.

```
<repo root>/
  compose.yaml                pure Compose — or, exclusively,
  .guarden/quadlet/           pre-made quadlet units
  .guarden/bed.yaml           infra contract (environment, routes, pond, hyphae, ports)
  .guarden/widgets/<service>.yml
  .guarden/.env.schema        varlock schema
```

Exactly one of `compose.yaml` and `.guarden/quadlet/` must exist; neither is a pre-commit error. `weedr` converts Compose to quadlet (podlet + volume pass, §4.3); given quadlet units it keeps them as they are.

### 6.1 `bed.yaml`

Infra contract only. Routes for **roots**, databases and roles for **pond**, hyphae aliases, ferm ports, the environment, and the forward-auth opt-in for **roots**.

```yaml
# .guarden/bed.yaml
environment: production          # required: production | staging | preview | fence
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
auth: true                       # forward-auth at the fence; roots renders it (ADR-0009)
pond:
  databases:
    app:
      roles:
        - name: app
          grants: ["ALL"]
hyphae:
  aliases: ["myapp.internal"]
ports:
  - 8080/tcp
```

### 6.2 `widgets/<service>.yml`

Exactly one dashboard widget per service. Read by **twig**. File name = service name in `compose.yaml`.

```yaml
# .guarden/widgets/api.yml
description: App API
href: "https://api.${env}.${domain}"
icon: mdi-api
```

### 6.3 Env schema (tracked) and planted values (not tracked)

- `.env.schema` — varlock syntax (`@required`, `@sensitive`, `@type`, `@example`). Source of truth for names and types. Secrets have empty values; only non-secret defaults live here.
- `.env.example` — generated from the schema so it cannot drift. Safe dummies for staging.
- Layered overrides: `.env` → `.env.<env>` → `.env.<env>.local` (gitignored).

---

## 7. Secrets and the production gate

No secrets in git. No secrets in GH Actions.

| environment | who sets secrets | gate |
|---|---|---|
| production, fence | admin by hand: `weedr secret set <bed> KEY` | **refuse to start** if a `@required` key is empty or still `EXAMPLE-`/`changeme` |
| staging / preview | `weedr` generates `@sensitive` values at bed create (stable until drop); local override always wins | warn only |

**Ordering rule: the gate is evaluated before the old container is shut down.** A deploy that fails the gate leaves the running container running — no gap, no restart into a broken config.

- `weedr` stores nothing long-term. It plants into the bed (a written `.env` or a podman secret) and forgets.
- staging values are minted once per bed (`openssl rand`), not per deploy. Dropping a preview instance drops its credentials.
- Pond role passwords are always minted by `weedr`, never human-chosen, never reused across environments. Restoring a DB from a pinned snapshot brings data, not secrets — `weedr` makes a new role and reassigns ownership.
- Admin owns the offline copy of production values for snapshot restore. Acceptable for one operator.
- A production bed created by a push to `main` is planted the same way: the gate names the missing keys, and the bed does not start until the operator sets them (ADR-0010).

---

## 8. Snapshots, ladders, pins

- A **ladder** is a snapper configuration owned by the subvolume it protects: a pond's ladder sits with the pond, a bed's own ladder sits with the bed's subvolume. Config lives with the subvolume owner; **soil** applies generic defaults for ladders it does not find configured.
- **soil** configures ladders for root, home, and the production pond's data. A rebuildable pond's data carries no ladder, at its owner's discretion.
- A ladder prunes oldest first unless a snapshot is pinned.
- **stakes** holds pins as `snapshot_id → holders [bed ids]` — an identity set, never a bare count. A pin is released only when every holder is gone. `stakes query` prints the holders of an id; `stakes list` prints ladders and their pins.
- `weedr`/`hose` call `stakes` to pin before an extract and unpin when the last holder is dropped. Snapper's cleanup hook reads `/var/lib/guarden/stakes/pins` and skips pinned ids. `stakes` never blocks snapper; it only answers queries.
- Space-aware pruning keeps the next-branch priority ladder (home/agents first, root, production pond last).

---

## 9. Staging and preview lifecycle

A staging or preview instance extracts from a **source pond** (normally production) into a **target pond**:

Seeding sources are fixed (ADR-0002): a production bed starts with an **empty** database — its first deploy never forks from staging. A staging bed forks from the production pond's latest snapshot. A preview forks from production by default, and from the staging pond when the project has no production data yet; a project with nothing to fork from starts empty. Every restore mints a new role and password.

```
create staging/preview instance
  1. stakes pin the current source-pond snapshot   (add holder)
  2. pg_dump of the project DB + globals (role)
  3. weedr mint a NEW role + NEW password in the target pond
  4. restore the dump into the target pond
  5. REASSIGN OWNERSHIP to the new role
  6. weedr plant the new credential in the bed
  7. convert compose.yaml -> quadlet, write bed.yaml routes, twig widgets
  8. start units (gate: warn only on staging/preview)

drop instance (merge or `weedr bed remove`)
  1. stop units, remove quadlet files
  2. weedr pond drain <bed>   (production: explicit confirmation)
  3. stakes unpin (remove holder); free the pin when the last holder is gone
  4. remove hyphae names
  5. remove bed user + volumes (previews) or keep (staging, policy)
```

Removing a production instance's database happens only through `weedr pond drain` with explicit confirmation. Preview instance drop is automatic.

Previews: one shared preview bed per project (`bed-preview-<project>`), one nested directory per ref (`/home/bed-preview-<project>/<ref>/`). Cap of 3 concurrent refs per project by default, FIFO eviction, overridable.

Default routes: `staging.<domain>` and `preview.<domain>/<ref>`, overridable per project in `bed.yaml`.

---

## 10. Deploy model

- **Gate before stop.** The production gate is evaluated before the old container is shut down; a failed gate leaves the old container running (§7).
- `hose` receives the source with a poke (`project ref sha` + tarball), or fetches it in `hose check` when the remote is readable; it diffs the generated units, writes them, and restarts changed services. **Stop then start.** No rolling (§2 non-goals).
- Migrations run **in-app on start**, before the service accepts traffic. A failing migration leaves the unit failed and `roots` keeps the old route target until the unit is healthy again (v1: route stays, service is down — simpler).
- **Build queue.** Never more than one container build at a time on the VPS — by default. FIFO, production always prioritized, debounced and deduped. The queue is respected by gitops (a GH Action pokes `hose`) and by manual redeploys of multi-service beds. `weedr redeploy --now` bypasses queue position for one request; the lane count itself is a root-owned host override (`weedr queue lanes <n>`, default 1) that applies between builds and never kills an in-flight one — more lanes when the box has headroom, back to one when it has not. The build itself is a rootless `podman build` as the bed user from `/var/lib/guarden/staging/<bed>/<sha>/`, tagged with compose's `image:` ref, deduped on (bed, ref, sha), and it runs **before** the old container stops — a failed build leaves the running service running (ADR-0010).
- **Production via poke.** A push to `main` may create and deploy the production bed — the first deploy starts an empty database (§9), and the gate still applies before start (§7). A poke never drops a production bed: `hose drop` and `hose check` refuse, and a root-owned override beside the ops list is the only switch (ADR-0010).
- `weedr redeploy <bed>` is the manual trigger. Production requires confirmation.
- **Boot ordering.** The fence track starts first (traefik, auth), then production ponds, then production beds. Staging and preview start only after ALL production services have started, plus a fixed delay. Container dependencies (`After=`, quadlet dependencies) order units inside each wave — a pond before the beds that consume it. `weedr` writes the systemd ordering drop-ins; the delay is fixed, not configurable in v1.

---

## 11. Host layout

```
/home/bed-<env>-<name>/
  .config/containers/systemd/     quadlet units + <unit>.container.d/ drop-ins
  .env, .env.<env>, .env.<env>.local
  overrides.yaml                  admin overrides: root:root 0444 (root writes)
  <ref>/                          nested preview instances (preview beds only)
/home/pond-<env>-<name>/
  .config/containers/systemd/     pond quadlet units
/var/lib/guarden/beds/<bed>/      bed-owned state (subvolumes when the bed has them)
/var/lib/guarden/ponds/<pond>/    pond data subvolumes
/var/lib/guarden/staging/<bed>/<sha>/   poked source staged for the build (0755)
/var/lib/guarden/hose/            ops list (project → git URL), read credential, production-drop override
/var/lib/roots/dynamic/           traefik dynamic config (group fence)
/var/lib/guarden/stakes/pins   pin registry state: snapshot id → holder beds (root-readable)
/etc/hosts                        hyphae names (written by weedr)
/etc/containers/systemd/users/<uid>/   admin-injected quadlet units
```

Bed users are `bed-<env>-<name>` (`bed-production-bitcoin`, `bed-staging-myapp`, `bed-preview-myapp`, `bed-fence-traefik`). Linger on; subuid/subgid allocated by `weedr`. Pond users are `pond-<env>-<name>`, created by `weedr pond dig` with the same linger and subuid/subgid treatment.

Admin overrides are gitops-proof and bed-scoped: `overrides.yaml` is root-owned and mode 0444 — readable by the bed user and the CLIs, writable only by root — plus root-owned admin drop-ins in the bed's quadlet dir, with unit-level overrides as `<unit>.container.d/` drop-ins. Regeneration and `hose` never touch root-owned paths.

Beds may own subvolumes, ladders, and state of their own — allowed, but not the default.

---

## 12. Test strategy

Three tiers. t1 proves wiring, t2 proves rules, t3 proves the host.

| tier | question | how | speed | where |
|---|---|---|---|---|
| **t1 smoke** | do the pieces fit? | `fixtures/bin/` fakes for `snapper`/`btrfs`/`systemctl`/`podman` on `PATH`; assert call logs and `--check`/`--apply` branches | <10s | CI |
| **t2 unit** | does each function behave? | pytest for parse/gate/holders/route-gen/widget-merge; no external binaries | seconds | CI |
| **t3 golden VM** | does the real host survive? | LXD/QEMU + cloud-init; replay soil phases (users → firewall → btrfs convert → storage → root-scripts → units), **reboot**, behaviour phases (snapshots, routing, dashboards, the pond reference use-case, previews, lockout-drill), evidence tarball | minutes | local / nightly |

The destructive steps (ext4→btrfs convert, reboot) cannot run on a CI runner. That is why t3 is a VM. Pattern references: Dokploy (real `install.sh` on the runner), Coolify (`coolify-testing-host` fake SSH server).

The golden VM's behaviour phases exercise **production- and staging-named ponds** as the reference use-case and deploy three demo projects: **seedling** (api + worker + web, needs a pond), **coldframe** (staging-only, unreleased), **stonecrop** (self-contained node with its own subvolume and state, no pond).

---

## 13. Security posture

- Limit sudo: `weedr` is the only privileged mutator; `hose` calls it through a narrow sudoers rule; `roots`, the traefik bed, `twig`, and `stakes` are unprivileged.
- Root-owned helper copies for anything root executes, so root never runs deploy-writable code.
- Admin overrides are root-owned: `overrides.yaml` (root:root, 0444) and root-owned drop-ins in the bed's quadlet dir. Regeneration and `hose` never write root-owned paths.
- The `fence` group shares exactly one directory: `roots` writes, the traefik bed reads; no two parts share a user.
- Fail2ban + ferm (ufw disabled by soil).
- Future SELinux/AppArmor: no daemon runs as root; users are per bed and per pond; drop-in files are the extension point — nothing here requires `unconfined`.
- UNIX security rule: manual and gitops beds share the layout; there is no "privileged mode" in a bed.
- CI holds one ssh key per project, forced-command-bound to that project's pokes; no registry token and no GitHub credential exists in Actions or on the box (ADR-0010).

---

## 14. Open questions

1. Whether `stakes` is a real daemon or a file + CLI with a root snapper hook reading it. v1: file + CLI, upgrade to a socket if a second writer appears.
2. Homepage vs a custom dashboard for twig output. v1: Homepage (already in the stack).
3. Whether the post-production boot delay for staging/preview should become configurable, and what a sane default would be.
4. Long-term per-pond network segregation beyond loopback blocks and ferm uid-owner rules.

---

## 15. Implementation order

Tickets `10`–`90` are the frontier build; the `100`+ series follows:

1. **10** — skeleton + CLI seam harness.
2. **20** — bed lifecycle + secrets + production gate.
3. **30** — soil host prep (users, firewall, sysctl).
4. **40** — soil btrfs convert + snapper ladders.
5. **50** — pond + stakes.
6. **60** — roots + twig.
7. **70** — preview/staging lifecycle + hose.
8. **80** — hose redeploy loop on manifest delete.
9. **90** — stakes concurrent unpin (lost update).
10. **100** — cloud-init host prep (scripts inlined; scripts install stays for non-cloud-init hosts).
11. **110** — `.guarden/` layout + pre-commit rule.
12. **120** — explicit environment naming, boot ordering, fence bed.
13. **130** — soil storage, directory schema, ladder ownership.
14. **140** — pond primitive alignment (dig/fill/drain, arbitrary names).
15. **150** — ferm ports, admin overrides, path watchers.
16. **160** — deploy queue.
17. **170** — jinja2 templates (the one allowed new runtime dependency) and moving embedded Python into separate files/libs.
18. **180** — demo projects: seedling, coldframe, stonecrop.
19. **190** — forward-auth at the fence (ADR-0009).
20. **200** — CI pokes: `hose poke` / `hose drop` / `hose grant`, staging intake, production-drop guard, workflow template (ADR-0010).
21. **210** — `hose check` + timer + optional read credential (ADR-0010).
22. **220** — the on-VPS build step: rootless `podman build` as the bed user, before stop (ADR-0010).

Each step ships with its tier tests. Do not start the next step with a failing `--check`.
