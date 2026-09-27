# guarden (was: infra)

WIP glossary. Single-VPS deployment platform. Product name: **guarden**.

## Language

**soil**:
The base layer: host prep (btrfs conversion, snapper, ferm/fail2ban, podman/quadlet) plus the base tools that sit on it.
_Avoid_: base, hostlayer, platform

**roots**:
The routes accumulator: collects route configs from services in beds and writes Traefik dynamic config. Traefik itself is a separate process in a separate user.
_Avoid_: trellis, gate, traefik routes generator

**weedr**:
The admin CLI that creates and removes beds and services without gitops.
_Avoid_: rake, svc, trowel, orchestrator

**stakes**:
Standalone pin registry service. Holds snapshot pins so ladders cannot prune pinned data. Lives in base (soil) but separate from weedr.
_Avoid_: pin registry, pin-registry

**twig**:
The dashboard generator that renders and aggregates dashboard config from beds.
_Avoid_: arbor, dashboard service

**pond**:
Shared state services offered to beds (postgres first; others later). Exactly two instances: one production pond (snapshotted) and one staging pond (rebuildable, not snapshotted). Beds get databases inside a pond, never their own pond.
_Avoid_: bed, shared pg, shared services

**project**:
A deployable product family — nutristack, daily-dose, klimafit. The thing you promote through environments.
_Avoid_: app, repo

**service**:
One process/container inside a bed (`api`, `worker`, `web`).
_Avoid_: container, microservice, unit

**environment**:
The runtime track a bed runs in: `production`, `staging`, or `preview:<ref>`. Production beds drink from the production pond; staging and preview beds share the staging pond.
_Avoid_: stage, env

**hose**:
The gitops reconciler that waters beds from a git source of truth.
_Avoid_: canal, gitops service, fetchit

**base**:
soil together with roots, weedr, and stakes. Enough for manually assisted deployments.
_Avoid_: core, platform

**addons**:
Optional layer on base: twig, pond, hose.
_Avoid_: plugins, modules

**bed**:
A runtime slot for one project in one environment: its user, units, volumes, and networks.
_Avoid_: compartment, stack, slot

**hyphae**:
The connectivity contract: loopback-published ports plus stable host names (`pond.internal`, `bed-a.internal`) written by weedr. Not a podman network.
_Avoid_: mycelium, mycellia, shared network

## Unresolved

- Rolling deploys and migrations → decided: stop/start + migrate-on-start (PRD §10)
- Product name → decided: **guarden** (repo still `infra/` until rename)

## Resolved notes (WIP)

**Manifest — three YAML files per project repo:**
- `compose.yaml` — pure Compose app definition (services, volumes, networks). Converted to quadlet units on the server.
- `bed.yaml` — infra contract only: routes for roots, databases for the pond, hyphae aliases.
- `widgets/<service>.yml` — exactly one dashboard widget per service, read by twig.

**Secrets:**
- No secrets in git, none in GH Actions. SOPS rejected (ciphertext-in-repo disliked).
- Tracked `.env.schema` (varlock syntax: `@required`, `@sensitive`, `@type`, `@example`). Generated `.env.example` for staging dummies.
- Layered overrides: `.env` → `.env.<env>` → `.env.<env>.local` (gitignored).
- Production: admin sets values by hand (`weedr secret set`). Hard gate — refuse to start if a `@required` key is empty or still `EXAMPLE-`/`changeme`.
- staging: `weedr` generates `@sensitive` values at bed create (stable until drop). Local override always wins.
- weedr stores nothing long-term; it plants into the bed (materialized `.env` or podman secret). Admin owns the offline copy for snapshot restore.
