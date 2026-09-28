# guarden

Glossary. Single-VPS deployment platform. Product name: **guarden**.

## Language

**soil**:
The host converger: phase scripts and timers that turn a fresh Ubuntu into a runnable host — cloud-init, btrfs conversion, snapper ladders, ferm/fail2ban, rootless podman/quadlet.
_Avoid_: base, hostlayer, platform

**roots**:
The routes accumulator: collects route configs from services in beds and writes Traefik dynamic config into the shared dynamic-config directory. Traefik itself lives in its own bed, in a separate user.
_Avoid_: trellis, traefik routes generator

**weedr**:
The admin CLI and the only privileged mutator: it plows and removes beds, digs, fills, and drains ponds, plants secrets, applies ferm ports.
_Avoid_: rake, svc, trowel, orchestrator

**stakes**:
The pin registry: snapshot pins held as snapshot id → holders (which beds), plus a listing of ladders and pins. Lives in base, separate from weedr.
_Avoid_: pin registry, pin-registry

**twig**:
The dashboard generator that merges each bed's per-service widget files into Homepage config.
_Avoid_: arbor, dashboard service

**pond**:
A named shared-state instance offered to beds — Postgres first, others later — named `pond-<env>-<name>`, such as `pond-production-postgres` or `pond-staging-postgres`, the same schema as a bed with the class prefix swapped. A pond runs as its own user of that same name, created by `weedr pond dig`, like a bed. Ponds are optional: a bed that needs no shared state simply has none.
_Avoid_: bed, shared pg, shared services, database

**project**:
A deployable product family — the thing you promote through environments.
_Avoid_: app, repo

**service**:
One process/container inside a bed (`api`, `worker`, `web`).
_Avoid_: container, microservice, unit

**environment**:
The four explicit tracks a bed declares: `production`, `staging`, `preview`, `fence`. Always stated, never assumed; preview refs are nested instances inside the one preview bed, not environments of their own.
_Avoid_: stage, env

**hose**:
The gitops reconciler that waters beds from CI pokes — `project ref sha` plus the source tree over ssh — and, when it can read the remote, from a drift check (`hose check`); calls `weedr` and nothing else, and keeps no git state on the VPS.
_Avoid_: canal, gitops service, fetchit

**poke**:
The one message a project's GitHub Action sends to the VPS over ssh: `hose poke <project> <ref> <sha>` with the source tree as a tarball on stdin, or `hose drop <project> <ref>` without source. One ed25519 key per project, bound to that project by a forced command.
_Avoid_: webhook, callback, push event

**base**:
soil together with roots, weedr, and stakes. Enough for manually assisted deployments.
_Avoid_: core, platform

**addons**:
Optional layer on base: twig, pond, hose.
_Avoid_: plugins, modules

**bed**:
A runtime slot for one workload in one environment: the user `bed-<env>-<name>`, where `<name>` is the project for a project bed and the workload name otherwise — `traefik` for the fence bed — plus its home, its units, and whatever state it owns. Beds usually take their state from a shared pond; a bed may instead own its subvolume, ladder, and state — allowed, but not the default.
_Avoid_: compartment, stack, slot

**fence**:
The boundary layer: the traefik bed `bed-fence-traefik` and the auth bed `bed-fence-authelia`, both running in the `fence` environment, plus the `fence` system group and the shared dynamic-config directory that `roots` writes and the traefik bed reads. Both are beds like any other — their own users, their own quadlet dirs — and `roots` stays a separate unprivileged service.
_Avoid_: perimeter, gateway, front door

**auth**:
The optional sign-in layer: an auth bed (Authelia or Authentik) that Traefik consults at the fence before a protected request reaches its service. It runs in the `fence` track (`bed-fence-authelia`) and carries its own state. A bed opts in with `auth: true` in `bed.yaml` and `roots` renders the forward-auth rule into its routes; the auth bed itself is plowed like any bed.
_Avoid_: sso, login service, authelia, authentik

**hyphae**:
The optional connectivity contract: loopback-published ports plus stable host names (`<pond>.internal`, `bed-<env>-<name>.internal`). Each pond group gets its own loopback block that only its members (the pond user and its member bed users) can reach — never a shared podman network.
_Avoid_: mycelium, mycellia, shared network

**ladder**:
A snapper ladder owned by the subvolume it protects — a pond's subvolume, or a bed's own subvolume when it has one — with its config living beside that owner. `stakes` lists ladders and their pins.
_Avoid_: retention, prune schedule, snapshot policy

## Resolved notes

Naming facts only:

- Bed user and home: `bed-<env>-<name>` — `bed-production-bitcoin`, `bed-staging-myapp`,
  `bed-preview-myapp`, `bed-fence-traefik`, `bed-fence-authelia`. `<name>` is the project,
  or the workload name otherwise (`traefik`, `authelia` on the fence).
- Environments are always explicit: `production`, `staging`, `preview`, `fence`.
- Pond names: `pond-<env>-<name>` — `pond-production-postgres`, `pond-staging-postgres`.
- Pond user and home: the same `pond-<env>-<name>`, created by `weedr pond dig` — no
  shared `pond` user.
- One preview bed per project; each ref is a nested instance inside it.
