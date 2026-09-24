# guarden — Technical PRD

Status: draft, 2026-09-23. Product name **guarden** (garden + guard). Repo working name `infra` until renamed.

Companion docs: [`CONTEXT.md`](../CONTEXT.md) is the glossary (source of truth for names). Decisions that are hard to reverse are recorded in [`docs/adr/`](./adr/).

---

## 1. Problem

We run three early projects (nutristack, daily-dose, klimafit) on one VPS. Today there is no real deployment story: `main`/`develop` are docker-compose home-lab stacks, `next` is a dirty prototype, and the demo server is a half-installed third-party quadlet UI. We need a small, honest platform that:

1. turns a fresh Ubuntu VPS into a runnable host,
2. lets an operator place a project into a running slot by hand,
3. optionally reconciles those slots from git,
4. shares two Postgres instances instead of one DB container per app,
5. protects production data with btrfs snapshot ladders and pins,
6. exposes services through Traefik and dashboards through Homepage.

Constraints: one human, one VPS, KISS, UNIX-flavoured, loosely coupled parts, no secrets in git, must not block future SELinux/AppArmor hardening.

---

## 2. Goals / non-goals

### Goals (v1)

- **soil** converges a fresh Ubuntu (cloud-init → btrfs convert → firewall → podman/quadlet → snapper ladders) and is testable in a golden VM.
- **weedr** creates and removes **beds** (project × environment) with their user, units, volumes, networks, pond database, and secrets — no web UI.
- **roots** accumulates route config from beds and writes Traefik dynamic config. Traefik itself is a separate process.
- **stakes** holds snapshot pins so ladders cannot prune pinned data.
- **pond** runs exactly two Postgres instances (prod, non-prod). Beds get databases, never their own pond.
- **hose** (addon) reconciles beds from git using the same manifest `weedr` reads.
- **twig** (addon) renders Homepage config from per-service widgets.
- Production gate: refuse to start a production service whose required env/secret is empty or still an example value.

### Non-goals (v1)

- Rolling deploys / blue-green. We stop then start.
- Migrations as a separate step. Apps migrate on start.
- Multi-host, k8s, Docker Swarm.
- SELinux/AppArmor policy (architecture must not block it).
- Debian/Arch/Nix install paths (cloud-init is Ubuntu-only for now).
- A web UI (rejected; see ADR-0001).
- SOPS or any secret ciphertext in git (see ADR-0004).
- Per-bed or per-preview Postgres containers (see ADR-0002).

### Backlog

- SQL transforms for preview DBs (anonymize, rewrite critical fields).
- Remote snapshot backup sync with a pin-aware guard.
- Tailscale (or similar) for staging/dashboards exposure.
- Monitoring export (podman/vps stats) as a soil plugin.
- Shared non-pg state services in the pond (redis, minio).
- Rust ports of hot paths once Python/bash has proven the shape.

---

## 3. Domain model

Read [`CONTEXT.md`](../CONTEXT.md). The spine:

```
project                nutristack, daily-dose, klimafit
  └─ bed               project × environment     (the slot)
       └─ service      api, worker, web          (one container)

environment            production | staging | preview:<ref>

base                   soil + roots + weedr + stakes
addons                 twig + pond + hose

hyphae                 loopback ports + host names (not a podman network)
```

A **bed** owns one Linux user, one quadlet unit directory, its volumes, and its hyphae names (see ADR-0001).

---

## 4. Architecture

### 4.1 Parts

| part | layer | kind | job |
|---|---|---|---|
| **soil** | base | converger scripts + timers | host prep: cloud-init, btrfs convert, ferm/fail2ban, snapper ladders, podman/quadlet, sysctl |
| **roots** | base | watcher/timer | read `bed.yaml` route sections from all beds, write Traefik dynamic config |
| **weedr** | base | CLI | create/remove beds, mint pond roles, plant secrets, convert `compose.yaml` → quadlet, prod gate |
| **stakes** | base | tiny service + state file | pin/unpin/refcount snapshot ids; readable by root snapper hooks |
| **twig** | addon | watcher/timer | merge `widgets/<service>.yml` into Homepage config |
| **pond** | addon | 2 containers | `pond-prod` (snapshotted) + `pond-nonprod` (rebuildable); DBs for beds |
| **hose** | addon | timer or path unit | `git pull` a bed source of truth, call `weedr` to apply, restart changed units |

Parts talk over files and paths. There is no internal HTTP API.

### 4.2 Daemon topology and users

| process | user | notes |
|---|---|---|
| bed services | `bed-<project>-<env>` | rootless podman, linger enabled |
| pond-prod, pond-nonprod | `pond` | ports published on `127.0.0.1` |
| roots | `roots` | writes `/var/lib/roots/dynamic/` |
| traefik | `traefik` | reads `/var/lib/roots/dynamic/`, binds :80/:443 |
| stakes | `stakes` | state in `/var/lib/stakes/pins.json`; root snapper hook reads the file |
| twig | `twig` | writes Homepage config |
| hose | `hose` | calls `weedr` through a narrow sudoers rule |
| weedr | admin (sudo) | creates beds, plants secrets, mints pond roles |
| soil scripts | root | install-time convergers + snapper/ferm/fail2ban timers |

Shared surface between `roots` and `traefik` is **one directory and one group** (`edge`): `roots` writes, `traefik` reads. They never share a user. Traefik runs rootless with `net.ipv4.ip_unprivileged_port_start=0` (set by soil).

### 4.3 compose → quadlet

`weedr` converts `compose.yaml` into quadlet units inside the bed. Use **podlet** (containers org, reference semantics) as a pinned binary behind `weedr`, plus a small Python pass that emits `.volume` units for bare named volumes (podlet only emits `.volume` when the volume carries options). Bed-specific overrides are written by `weedr` as `<unit>.container.d/` drop-ins so they survive regeneration.

Alternatives considered: `comquad` (Go library, best engine, needs a helper binary), `quadlet-compose` (Python, pip-installable, dead upstream — fork only if in-process becomes mandatory).

---

## 5. Connectivity (hyphae)

Rootless podman networks are **per-user**. A bed cannot join another bed's or the pond's podman network. This is a podman rule (ADR-0003).

**hyphae** is therefore a contract, not a network:

- Shared services publish on `127.0.0.1` (pasta).
- `weedr` writes stable names into `/etc/hosts` (or a tiny DNS): `pond.internal`, `bed-<name>.internal`.
- Beds reach `pond.internal:5432` and each other through the host loopback.

```
              internet
                 |
             [ traefik ]
                 |
            127.0.0.1
     +-----------+-----------+
     |           |           |
  [ pond ]   [ bed-a ]   [ bed-b ]
   :5432       :8081       :8082
     |           |           |
     +-----------+-----------+
                 |
            pasta (to host)
```

---

## 6. Project manifest

Three tracked YAML files per project repo. This is the contract between a **project** and **guarden**. Both `weedr` (manual) and `hose` (gitops) read the same files.

### 6.1 `compose.yaml`

Pure Compose. Services, volumes, networks. No guarden keys. Converted to quadlet on the server.

### 6.2 `bed.yaml`

Infra contract only. Routes for **roots**, databases for **pond**, hyphae aliases.

```yaml
# bed.yaml
routes:
  api: "api.${env}.${domain}"
  web: "${env}.${domain}"
pond:
  databases: ["app"]          # 1 db per bed by default; name = this
hyphae:
  aliases: ["nutristack.internal"]
```

### 6.3 `widgets/<service>.yml`

Exactly one dashboard widget per service. Read by **twig**. File name = service name in `compose.yaml`.

```yaml
# widgets/api.yml
description: Nutristack API
href: "https://api.${env}.${domain}"
icon: mdi-api
```

### 6.4 Env schema (tracked) and materialized values (not tracked)

- `.env.schema` — varlock syntax (`@required`, `@sensitive`, `@type`, `@example`). Source of truth. Secrets have empty values; only non-secret defaults live here.
- `.env.example` — generated from the schema so it cannot drift. Safe dummies for staging.
- Layered overrides: `.env` → `.env.<env>` → `.env.<env>.local` (gitignored).

---

## 7. Secrets and the production gate

No secrets in git. No secrets in GH Actions. SOPS rejected (ADR-0004).

| environment | who sets secrets | gate |
|---|---|---|
| production | admin by hand: `weedr secret set <bed> KEY` | **refuse to start** if a `@required` key is empty or still `EXAMPLE-`/`changeme` |
| staging / preview | `weedr` generates `@sensitive` values at bed create (stable until drop); local override always wins | warn only |

- `weedr` stores nothing long-term. It plants into the bed (materialized `.env` or a podman secret) and forgets.
- Non-prod values are minted once per bed (`openssl rand`), not per deploy. Dropping a preview bed drops its credentials.
- Pond role passwords are always minted by `weedr`, never human-chosen, never reused across environments. Restoring a DB from a pinned snapshot brings data, not secrets — `weedr` makes a new role and reassigns ownership.
- Admin owns the offline copy of production values for snapshot restore. Acceptable for one operator.

---

## 8. Snapshots, ladders, pins

- **soil** configures snapper ladders for root, home, and `pond-prod` data. `pond-nonprod` is **not** snapshotted (rebuildable by design).
- Volume subvolumes per bed are created by `weedr` and get their own snapper config (custom ladder or disabled, per bed).
- A ladder prunes oldest first unless a snapshot is pinned.
- **stakes** holds pins as `snapshot_id → { holders: [bed ids] }`. A pin is released only when every holder is gone.
- `weedr`/`hose` call `stakes` to pin before a preview extract and unpin when the last holder is dropped. Snapper's root cleanup hook reads `/var/lib/stakes/pins.json` and skips pinned ids. `stakes` never blocks snapper; it only answers a query.
- Space-aware pruning keeps the next-branch priority ladder (home/agents first, root, `pond-prod` last).

---

## 9. Staging and preview lifecycle

```
create staging/preview bed
  1. stakes pin the current pond-prod snapshot  (refcount++)
  2. pg_dump of the project DB + globals (role)
  3. weedr mint a NEW role + NEW password in pond-nonprod
  4. restore the dump into pond-nonprod
  5. REASSIGN OWNERSHIP to the new role
  6. weedr plant the new credential in the bed
  7. convert compose.yaml -> quadlet, write bed.yaml routes, twig widgets
  8. start units (gate: warn only on non-prod)

drop bed (merge or manual)
  1. stop units, remove quadlet files
  2. drop the database and role in pond-nonprod
  3. stakes unpin (refcount--); free the pin at zero
  4. remove hyphae names
  5. remove bed user + volumes (previews) or keep (staging, policy)
```

Production database drop is **manual only** (`weedr pond drop --prod` with confirmation). Preview database drop is automatic.

Default routes: `staging.<domain>` and `preview.<domain>/<ref>`, overridable per project in `bed.yaml`.

---

## 10. Deploy model

- `hose` pulls the source of truth, diffs the generated units, writes them, and restarts changed services. **Stop then start.** No rolling (see §2 non-goals).
- Migrations run **in-app on start**, before the service accepts traffic. A failing migration leaves the unit failed and `roots` keeps the old route target until the unit is healthy again (v1: route stays, service is down — simpler).
- `weedr redeploy <bed>` is the manual trigger. Production requires confirmation.

---

## 11. Host layout

```
/home/bed-<project>-<env>/
  .config/containers/systemd/     quadlet units + .d/ drop-ins
  .env, .env.<env>, .env.<env>.local
/var/lib/guarden/volumes/<bed>/…  bed volume subvolumes (btrfs)
/var/lib/pond/prod/…              pond-prod data subvolume (snapshotted)
/var/lib/pond/nonprod/…           pond-nonprod data (no snapper)
/var/lib/roots/dynamic/           traefik dynamic config (group edge)
/var/lib/stakes/pins.json         pin registry state
/etc/hosts                        hyphae names (written by weedr)
```

Bed users are `bed-<project>-<env>`. Linger on. subuid/subgid allocated by `weedr`.

---

## 12. Test strategy

Three tiers. t1 proves wiring, t2 proves rules, t3 proves the host.

| tier | question | how | speed | where |
|---|---|---|---|---|
| **t1 smoke** | do the pieces fit? | `fixtures/bin/` fakes for `snapper`/`btrfs`/`systemctl`/`podman` on `PATH`; assert call logs and `--check`/`--apply` branches | <10s | CI |
| **t2 unit** | does each function behave? | pytest for parse/gate/refcount/route-gen/widget-merge; no external binaries | seconds | CI |
| **t3 golden VM** | does the real host survive? | LXD/QEMU + cloud-init; replay soil phases (users → firewall → btrfs convert → storage → root-scripts → units), **reboot**, behaviour phases (snapshots, routing, dashboards, pond, previews, lockout-drill), evidence tarball | minutes | local / nightly |

The destructive steps (ext4→btrfs convert, reboot) cannot run on a CI runner. That is why t3 is a VM. Pattern references: Dokploy (real `install.sh` on the runner), Coolify (`coolify-testing-host` fake SSH server), Quadletman (Vagrant VMs). We keep `next`'s fixture-fake approach for t1.

---

## 13. Security posture

- Limit sudo: `weedr` is the only privileged mutator; `hose` calls it through a narrow sudoers rule; `roots`/`traefik`/`twig`/`stakes` are unprivileged.
- Root-owned helper copies for anything root executes (`next`'s `install-root-scripts.sh` pattern) so root never runs deploy-writable code.
- Fail2ban + ferm (ufw disabled by soil).
- Future SELinux/AppArmor: no daemon runs as root; users are per bed; drop-in files are the extension point — nothing here requires `unconfined`.
- UNIX security rule: manual and gitops beds share the layout; there is no "privileged mode" in a bed.

---

## 14. Open questions

1. Product/repo rename: `infra` → `guarden` when convenient. No code depends on the string yet.
2. Whether `stakes` is a real daemon or a file + CLI with a root snapper hook reading it. v1: file + CLI, upgrade to a socket if a second writer appears.
3. Preview slot cap (`next` used FIFO `PREVIEW_SLOTS=3`). Keep 3 for v1.
4. Homepage vs a custom dashboard for twig output. v1: Homepage (already in the stack).
5. How `hose` discovers project repos (explicit list in an ops repo vs GitHub App). v1: explicit list.

---

## 15. Implementation order

1. **soil** — convergers + golden VM harness (t1 fixtures first, then t3).
2. **weedr** — bed create/remove, compose→quadlet, pond roles, secrets plant, prod gate.
3. **stakes** — pin file + refcount + snapper hook.
4. **roots** — accumulate `bed.yaml` routes → traefik dynamic config.
5. **pond** — two postgres units + hyphae names.
6. **twig** — widget merge → Homepage config.
7. **hose** — git pull + call `weedr` + restart.
8. Wire t3 behaviour phases for previews end to end.

Each step ships with its tier tests. Do not start the next step with a failing `--check`.
