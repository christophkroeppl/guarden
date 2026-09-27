# guarden v1 — spec

Status: ready-for-agent.
Source: `docs/PRD.md`, `CONTEXT.md`, `docs/adr/0001`–`0009`.
Test seam model: **A** (one seam, two harnesses).

## Problem Statement

The operator runs three demo projects on one VPS and has no real deployment story. Compose stacks are started by hand, there is no slot to place a project into, no way for projects to share database state without each running its own database container, no protection for production data against snapshot pruning, and no gate that stops a production service from starting with an empty or placeholder secret. Firewall openings and host names are hand-maintained, so it is easy to open a port nobody asked for, or to let the wrong bed reach a database.

The operator wants one small platform, **guarden**, that turns a fresh Ubuntu VPS into a host with beds, optional ponds, pins, routes, and dashboards — and that still works when only one human is at the keyboard.

## Solution

**guarden** is a monorepo of two layers.

**base** is enough for manually assisted deployments:

- **soil** converges a fresh Ubuntu: cloud-init inlines the install scripts, ext4 → btrfs convert, ferm + fail2ban, snapper ladders, rootless podman + quadlet, sysctl for unprivileged ports.
- **weedr** is the one privileged mutator. It plows and removes **beds**, digs/fills/drains **ponds**, converts a Compose manifest to quadlet units, mints pond roles, plants secrets, applies ferm port openings, and gates production deploys before the old container is stopped.
- **stakes** is the pin registry. It holds snapshot pins together with their holders so ladders cannot prune pinned data, and it lists ladders and pins.
- **roots** collects route configs from beds and writes Traefik dynamic config, including the forward-auth rule for beds that declare `auth: true`. It runs unprivileged.

**addons** sit on top of base:

- **pond** offers named shared-state instances (Postgres first). A pond is optional, is named `pond-<env>-<name>` like a bed with the class prefix swapped, is created with `weedr pond dig` — which gives it its own user of the same name — and a bed is connected to one at plow time with `--pond`.
- **twig** renders one dashboard widget per service into Homepage config.
- **hose** reconciles beds from git, by calling `weedr`.

Traefik runs as its own bed in the `fence` environment track (`bed-fence-traefik`) and reads the dynamic config that `roots` writes. The operator plows a bed with `weedr bed plow <project> --env <env>`, sets production secrets with `weedr secret set`, and sees routes appear at the **hyphae** names (`<pond>.internal`, `bed-<env>-<name>.internal`) on the host loopback.

## User Stories

1. As an admin, I want cloud-init to bring up a fresh Ubuntu with my SSH keys by inlining the install scripts and installing the packages, so that I can log in without a console.
2. As an admin, I want the scripts-based install to remain available for hosts without cloud-init, so that any host can still be prepared.
3. As an admin, I want `soil` to convert the root filesystem from ext4 to btrfs with one reboot, so that snapshots work later.
4. As an admin, I want `soil` to keep `/boot` on ext4, so that the machine still boots.
5. As an admin, I want `soil` to make a `@home` subvolume and fix fstab, so that home is snapshotted separately from root.
6. As an admin, I want `soil` to disable the preinstalled firewall and install ferm + fail2ban, so that one policy covers the host.
7. As an admin, I want `soil` to install rootless podman, quadlet, and pasta, so that beds run without root.
8. As an admin, I want `soil` to set `net.ipv4.ip_unprivileged_port_start=0`, so that the traefik bed can bind :80/:443 without root.
9. As an admin, I want `soil` to configure the snapper ladders it owns — root and home — at install time, so that rollback works from the first boot.
10. As an admin, I want `soil` to snapshot root on apt install and upgrade, so that a bad package is recoverable.
11. As an admin, I want every `soil` phase to support `--check` and `--apply`, so that I can see drift before I change the host.
12. As an admin, I want `soil` to install root-owned copies of anything root runs, so that root never runs deploy-writable code.
13. As an admin, I want a sysadmin readme with the most important commands, so that I can operate the box at 3am.
14. As an admin, I want `weedr bed plow <project> --env <env>` to create one Linux user, one unit directory, the bed files, and hyphae names, so that a bed exists in one command.
15. As an admin, I want `--env` to be required, so that no bed is ever created with an implicit environment.
16. As a developer, I want my git manifest to declare its environment explicitly, so that `hose` never guesses where a project runs.
17. As an admin, I want the bed user and home to be `bed-<env>-<name>` — `bed-production-bitcoin`, `bed-staging-myapp`, `bed-preview-myapp`, `bed-fence-traefik` — with linger on, so that names match the glossary and services run without me logging in.
18. As an admin, I want `weedr` to allocate subuid and subgid ranges, so that rootless podman works in the bed.
19. As an admin, I want `weedr bed remove` to stop units, remove the user, and free hyphae names, so that a bed is really gone.
20. As an admin, I want `weedr` to require explicit confirmation before removing a production bed, so that I cannot fat-finger a prod outage.
21. As an admin, I want the fence bed to start first, then production ponds, then production beds, and staging and preview only after every production service has started plus a fixed delay — with container dependencies ordering units inside each wave — so that a boot never starves production and never starts a bed before its database; the ordering comes from systemd drop-ins written by `weedr`, and the delay is fixed in v1.
22. As an admin, I want bed-scoped, root-owned admin overrides — `/home/bed-<env>-<name>/overrides.yaml` (root:root, 0444: readable by the bed user and the CLIs, writable only by root) plus root-owned drop-ins in the bed's quadlet dir, unit-level via `<unit>.container.d/` — so that my overrides survive regeneration and `hose`.
23. As an admin, I want watchers to be systemd `.path` units with globs over the `bed-*`/`pond-*` folder schema — recursive, so nested preview refs are caught — and to trigger only `daemon-reload`, never an auto-restart.
24. As a developer, I want `compose.yaml` at the repo root or quadlet units in `.guarden/quadlet/`, exactly one of them, so that the unit source is unambiguous.
25. As a developer, I want a pre-commit error when my repo declares neither, so that a manifest without a unit source never lands.
26. As a developer, I want `.guarden/bed.yaml` to hold routes, `pond:` databases with roles and grants, hyphae aliases, `ports:`, the environment, and `auth:`, so that the infra contract is visible in my repo.
27. As a developer, I want `.guarden/bed.yaml` to declare the databases, roles, and grants my services get from a pond, so that the database contract lives next to the code.
28. As a developer, I want `.guarden/widgets/<service>.yml` — exactly one per service — so that my service gets a dashboard card without a ticket.
29. As a developer, I want `.guarden/.env.schema` tracked in varlock syntax (`@required`, `@sensitive`, `@type`, `@example`) with values never tracked, so that I know what to set without putting secrets in git.
30. As a developer, I want a generated `.env.example` with safe dummies, so that staging starts without me inventing values.
31. As a developer, I want gitignored local overrides layered as `.env` → `.env.<env>` → `.env.<env>.local`, so that I can put a real value on one environment without committing it.
32. As a developer, I want `weedr` to read `compose.yaml` and write quadlet units, so that the project repo stays pure Compose.
33. As a developer, I want quadlet units given in `.guarden/quadlet/` to be used exactly as they are, so that a project can ship its own units.
34. As an admin, I want `weedr` to write `.volume` units for bare named volumes, so that volumes are explicit.
35. As a developer, I want three microservices in one bed, so that `api`, `worker`, and `web` share one project × environment slot.
36. As an admin, I want `weedr pond dig <name>` to create a pond named `pond-<env>-<name>` — `pond-production-postgres`, `pond-staging-postgres` — `weedr pond fill <bed>` to provision one database and one role for a bed, and `weedr pond drain <bed>` to take them away, with explicit confirmation when the target is production, so that pond lifecycle is three deliberate commands and every pond name says its class and track.
37. As an admin, I want ponds to be optional and host prep never to create one by default, so that a project without a pond is a normal case.
38. As an admin, I want `weedr bed plow -p <pond>` / `--pond <pond>` to connect a bed's hyphae to a pond, and an unknown name to offer the known ponds plus the option to create one, so that connectivity is declared at create time without aborting and re-running.
39. As an admin, I want shared ponds to be the recommendation for state, so that the host stays small while odd projects stay possible.
40. As an admin, I want a self-contained bed to own its own state service, subvolume, ladder, and data — a bitcoin node, say — so that a project that does not fit the shared model needs no special case.
41. As an admin, I want `weedr` to mint a new role and a new password whenever a dump is restored, so that staging never authenticates with production credentials.
42. As a developer, I want dropping a preview to drain its database and role automatically, so that a merged PR does not leak state.
43. As an admin, I want `weedr secret set <bed> KEY` to plant one value into the bed, so that production secrets never touch git or CI.
44. As an admin, I want `weedr` to plant into a written-out `.env` or a podman secret and then forget the value, so that `weedr` holds no long-term secret store.
45. As an admin, I want `weedr` to generate staging secrets at bed create and keep them stable until the bed is dropped, so that staging and previews work out of the box.
46. As an admin, I want a local override file to win over generated values, so that I can put a real value on staging when I need one.
47. As an admin, I want `weedr` to refuse to start a production service when a `@required` key is empty or still looks like `EXAMPLE-` or `changeme`, so that a missing or placeholder secret cannot reach production.
48. As an admin, I want the gate checked before the old container is shut down, so that a deploy failing the gate leaves the running container running.
49. As an admin, I want the gate to warn only on staging and previews, so that previews are cheap.
50. As an admin, I want no secrets in git and none in GH Actions, so that a repo leak is not a credential leak.
51. As an admin, I want the offline copy of production secrets to be mine to keep, so that snapshot restore is possible without a secrets service.
52. As an admin, I want hyphae names — `<pond>.internal`, `bed-<env>-<name>.internal` — in `/etc/hosts`, so that a bed can reach shared state without a shared podman network.
53. As an admin, I want `weedr` to write and remove those names with the bed, so that the map cannot rot.
54. As an admin, I want each pond group to have its own loopback block (`127.1.<g>.<n>`) with ferm `OUTPUT` rules matching `uid-owner`, so that only that group's members — the pond's own user and its member bed users — can reach the block.
55. As an admin, I want traefik to run as its own bed — `bed-fence-traefik` in the `fence` track, with its own user and quadlet dir — with ports 80/443 declared in its `bed.yaml` plus safe defaults, so that the boundary is configured like any other bed.
56. As an admin, I want `roots` to run unprivileged and write `/var/lib/roots/dynamic/` for the traefik bed to read through the `fence` group, so that a bug in `roots` cannot control traefik.
57. As an admin, I want default routes `staging.<domain>` and `preview.<domain>/<ref>`, so that previews are predictable.
58. As an admin, I want per-project route overrides in `bed.yaml`, so that a project can pin a hostname.
59. As an admin, I want port openings declared in `.guarden/bed.yaml` `ports:` plus a root-owned admin override file, applied by `weedr`, and a `weedr` command that lists the active ferm rules, so that the firewall matches the manifest and is auditable.
60. As an admin, I want a ladder owned by the subvolume it protects — a pond's subvolume, or a bed's own subvolume when it has one — with its config living beside that subvolume's owner, so that snapshot policy follows data ownership.
61. As an admin, I want `stakes pin <snapshot> --holder <bed>` to record a pin as snapshot id → list of bed holders and `stakes query` to print those holders, so that the registry says who pinned what and who blocks a prune.
62. As an admin, I want `stakes unpin` to release one holder, so that dropping one preview does not free a snapshot another preview still uses.
63. As an admin, I want `stakes` to list ladders together with their pins, so that I can audit snapshot policy in one place.
64. As an admin, I want the snapper cleanup hook to read the pin state file and skip pinned ids, so that pins survive pruning.
65. As an admin, I want `stakes` to never block snapper, so that a stuck pin cannot freeze the host.
66. As an admin, I want space-aware pruning to keep my priority order — home and agents first, root, production pond last — so that the pond is the last thing to shrink.
67. As an admin, I want `twig` to merge `.guarden/widgets/<service>.yml` into Homepage config, so that every service gets one dashboard card.
68. As an admin, I want exactly one widget per service, so that the dashboard cannot grow without bound.
69. As an admin, I want `twig` to add a link per project to its staging dashboard and its repo, so that I can jump between environments.
70. As an admin, I want `hose` to `git pull` an explicit list of project repos and call `weedr`, so that git is the source of truth without a second mutator.
71. As an admin, I want `hose` to restart only changed services, so that a deploy does not bounce the world.
72. As an admin, I want deploys to stop then start, so that v1 is simple and honest about the short downtime.
73. As an admin, I want migrations to run in-app on start, so that I do not have to remember a second step.
74. As an admin, I want a deploy queue that allows one container build at a time by default — FIFO, production always prioritized, changes debounced and deduped — respected by gitops (a GH Action pokes `hose`) and by manual redeploys of multi-service beds, so that the VPS never builds in parallel and every path is paced the same.
75. As an admin, I want `weedr redeploy <bed>` to ask before touching production, so that redeploys are deliberate.
76. As an admin, I want `weedr redeploy --now` to bypass the queue, so that I can force a build when I must.
77. As an admin, I want a staging bed for the seedling `main` branch to restore one project database from a pinned production-pond snapshot into the staging pond with a new role and a new password, so that staging has realistic data and cannot authenticate against production.
78. As an admin, I want coldframe to run with a staging bed only and no production bed, so that an unreleased project still has a live environment.
79. As a developer, I want one shared preview bed per project — `bed-preview-<project>` — with each ref nested under `/home/bed-preview-<project>/<ref>/`, so that my PR appears at `preview.<domain>/<ref>`.
80. As a developer, I want my preview instance dropped when the PR merges, so that the box does not fill with dead beds.
81. As a developer, I want dropping my preview to release my holder entry, so that the snapshot can be pruned when nothing else needs it.
82. As an admin, I want at most 3 concurrent refs per project by default, FIFO eviction and overridable, so that previews cannot eat the box.
83. As a developer, I want my bed to open `pond-production-postgres.internal:5432` from a rootless container, so that I can use a shared Postgres.
84. As an admin, I want every part to talk over files and paths and not over an internal HTTP API, so that I can debug with `ls` and `cat`.
85. As an admin, I want `weedr` to be the only privileged mutator, so that sudo is one narrow door.
86. As an admin, I want `hose` to call `weedr` through a narrow sudoers rule, so that gitops cannot become root.
87. As an admin, I want `roots`, `twig`, `stakes`, and the traefik bed to run unprivileged, so that a bug is not a root bug.
88. As an admin, I want templates rendered with jinja2 — the one allowed new runtime dependency — and python kept in separate files and libs, so that shell scripts stay short and auditable.
89. As an admin, I want tests at one seam — the command line — so that refactors do not break the suite.
90. As an admin, I want fake `snapper`, `btrfs`, `systemctl`, and `podman` on `PATH` for fast tests, so that CI finishes in seconds.
91. As an admin, I want the same commands on a golden VM with real tools, so that I know the host survives btrfs convert and a reboot.
92. As an admin, I want `--check` to report drift without changing the host, so that I can audit before I act.
93. As an admin, I want a lockout drill that restores firewall access on a dead-man timer, so that I cannot lock myself out for good.
94. As an admin, I want an evidence tarball after the golden VM run, so that a failure is debuggable from journals and call logs.
95. As an admin, I want the golden VM to exercise a production-named and a staging-named pond alongside the demo projects — seedling (api, worker, web on a pond), coldframe (staging only), and stonecrop (self-contained node with its own subvolume and state, no pond) — so that the reference use-case is proven on a real host.
96. As an admin, I want every pond to run as its own user `pond-<env>-<name>` — created by `weedr pond dig` with linger and allocated subuid/subgid, like a bed — so that ponds are separated from each other by a real user boundary and not only by database roles and ferm rules.
97. As an admin, I want the queue's lane count overridable from its default of 1 with `weedr queue lanes <n>`, applied between builds and never killing an in-flight one, so that I can trade responsiveness for throughput when the box has headroom and drop back to one when it has not.
98. As an admin, I want a bed to opt into forward-auth with `auth: true` in `.guarden/bed.yaml`, so that routes are protected at the fence and no app ever integrates with the auth bed.

## Implementation Decisions

- Two layers: **base** (soil, roots, weedr, stakes) and **addons** (twig, pond, hose). Base is enough for manually assisted deployments; addons are optional.
- Parts talk over files and paths. There is no internal HTTP API.
- A **bed** is one **project** in one **environment**, and a project has one bed per environment. The environment is always explicit — `production` | `staging` | `preview` | `fence` — and never implicit: `weedr bed plow` requires `--env`, and a git manifest declares its environment. A bed owns one Linux user `bed-<env>-<name>` (linger on), one user-scope quadlet unit directory, its files, and its hyphae names. A **service** is one container/process inside a bed. Previews nest instances per ref: one bed per project (`bed-preview-<project>`), each ref under `/home/bed-preview-<project>/<ref>/`, capped at 3 concurrent refs per project by default with FIFO eviction, overridable.
- `weedr` is the only privileged mutator. `hose` calls `weedr` through a narrow sudoers rule. `roots`, `twig`, `stakes`, and the traefik bed run unprivileged, and root executes only root-owned helper copies. ferm and fail2ban cover the host; no daemon runs as root and users are per bed and per pond, so SELinux/AppArmor hardening stays possible.
- **fence**: traefik runs as its own bed — `bed-fence-traefik` in the `fence` track — with its own user and quadlet dir, and its `bed.yaml` declares ports 80/443 for ferm plus safe defaults. `roots` is a separate unprivileged service that writes `/var/lib/roots/dynamic/`; the traefik bed reads that directory through the `fence` group. The two never share a user.
- **auth**: sign-in runs at the fence: a protected bed declares `auth: true` in `bed.yaml` and `roots` renders the forward-auth rule aimed at the auth bed's hyphae name. The auth bed — Authelia or Authentik — is a normal bed, named once in a root-owned file beside the dynamic config; its own routers never carry the rule, and a bed without `auth:` gets today's routes. See ADR-0009.
- **hyphae** is an optional contract, not a network: shared services publish on loopback, `weedr` writes stable names (`<pond>.internal`, `bed-<env>-<name>.internal`) into `/etc/hosts`, and beds use `pasta` to reach the host loopback. Each pond group gets its own loopback block (`127.1.<g>.<n>`), and ferm `OUTPUT` rules with `uid-owner` matching admit only that group's members — the pond's own user and its member bed users. A shared podman network across bed users is not part of the design. See ADR-0003.
- **pond** is a primitive: a named shared-state instance, Postgres first, named `pond-<env>-<name>` (`pond-production-postgres`, `pond-staging-postgres`) — the bed schema with the class prefix swapped. Ponds are optional and host prep never creates one by default. Each pond runs as its own user `pond-<env>-<name>` — created by `weedr pond dig` with linger and subuid/subgid, its own quadlet dir and data directory — so ponds are separated by a real user boundary; there is no shared `pond` user. Verbs: `weedr pond dig <name>` creates a pond, `weedr pond fill <bed>` provisions a database and role for a bed, `weedr pond drain <bed>` removes them — with explicit confirmation when production. `weedr bed plow -p <pond>` / `--pond <pond>` connects a bed's hyphae to a pond; an unknown name offers the known ponds plus the option to create one. Shared ponds are the recommendation for state; a self-contained bed may own its own service or database container, subvolume, ladder, and state. See ADR-0002.
- The project repo declares exactly one unit source: `compose.yaml` at the root (pure Compose) **or** quadlet units in `.guarden/quadlet/`; declaring neither is a pre-commit error. `.guarden/` also holds `bed.yaml` (routes, `pond:` databases with roles/grants, hyphae aliases, `ports:`, environment, `auth:`), `widgets/<service>.yml` (exactly one widget per service), and `.env.schema`. Both `weedr` and `hose` read the same files. See ADR-0005.
- `weedr` converts Compose to quadlet using **podlet** as a pinned binary, plus a small pass that emits `.volume` units for bare named volumes. Units given in `.guarden/quadlet/` are used as they are. Bed-specific overrides are written as unit drop-ins so regeneration cannot clobber them.
- Admin overrides are bed-scoped and root-owned: `/home/bed-<env>-<name>/overrides.yaml` is root:root 0444 — readable by the bed user and the CLIs, writable only by root — plus root-owned admin drop-ins in the bed's quadlet dir (`<unit>.container.d/` for unit-level overrides). Regeneration and `hose` never touch root-owned paths.
- Watchers are systemd `.path` units with globs over the `bed-*`/`pond-*` folder schema, recursive so nested preview refs are caught. A trigger runs `daemon-reload` only; nothing auto-restarts. No regex.
- Boot ordering: the fence bed first, then production ponds, then production beds; staging and preview start only after **all** production services have started, plus a fixed delay. Container dependencies (`After=`, quadlet dependencies) order units inside each wave — a pond before the beds that consume it. `weedr` writes the systemd ordering drop-ins; the delay is fixed in v1.
- Secrets never live in git and never live in GH Actions. A tracked `.env.schema` (varlock syntax: `@required`, `@sensitive`, `@type`, `@example`) is the source of truth for names and types; `.env.example` is generated from the schema. Overrides layer as `.env` → `.env.<env>` → `.env.<env>.local` (gitignored). See ADR-0004.
- Production: the admin sets values by hand with `weedr secret set`, and a hard gate refuses to start a production service when a `@required` key is empty or still `EXAMPLE-`/`changeme`. The gate runs **before** the old container is shut down: a deploy that fails it leaves the running container running. Staging and preview: `weedr` generates values at bed create, stable until the bed is dropped, a local override always wins, and the gate warns only. `weedr` plants and forgets.
- Preview create pins the current production-pond snapshot with the preview as a holder, fills the preview's database in the staging pond with a new role and password, converts the manifest, writes routes and widgets, then starts units. Preview drop stops units, drains the database, releases the holder, removes hyphae names, and removes the instance. Restoring a dump brings data, never secrets.
- `stakes` holds pins as snapshot id → list of bed holders — who pinned what. `stakes query` prints the holders, and `stakes` lists ladders with their pins. The snapper cleanup hook reads the pin state file and skips pinned ids; `stakes` never blocks snapper.
- A ladder belongs to the subvolume it protects — a pond's subvolume, or a bed's own subvolume when it has one — and its config lives with that subvolume's owner.
- Deploys are stop-then-start; migrations run in-app on start before the service accepts traffic. Container builds go through a queue: never more than one build at a time on the VPS by default, FIFO with production always prioritized, changes debounced and deduped. The queue is respected by gitops (a GH Action pokes `hose`) and by manual redeploys of multi-service beds; `weedr redeploy --now` bypasses queue position for one request. The lane count is a root-owned host override (`weedr queue lanes <n>`, default 1) that applies between builds and never kills an in-flight one; with several lanes production still jumps to the next free lane and per-lane order stays FIFO. The queue state and the lane count are plain files, readable with `ls`. Scaling lanes from VPS load is backlog.
- Port openings come from `.guarden/bed.yaml` `ports:` plus a root-owned admin override file; `weedr` applies them and can list the active ferm rules.
- Host layout (fixed schema): `/home/bed-<env>-<name>/` (quadlet dir `.config/containers/systemd/`, env files, `overrides.yaml`, nested `<ref>/` for previews), `/home/pond-<env>-<name>/` (pond quadlet dir), `/var/lib/guarden/beds/<bed>/`, `/var/lib/guarden/ponds/<pond>/`, `/var/lib/roots/dynamic/`, `/var/lib/stakes/pins.json`, `/etc/hosts` (hyphae names), `/etc/containers/systemd/users/<uid>/` (admin-injected quadlet units). A bed may own extra subvolumes and ladders; that is not the default.
- Templates render with **jinja2**, the one allowed new runtime dependency. Python lives in separate files and libs, not embedded in shell scripts.
- Host prep: cloud-init performs most of it by inlining the install scripts and installing the packages; the scripts-based install remains for hosts without cloud-init.
- Test seam model **A**: one seam at the command line of `weedr`, `stakes`, and the `soil` convergers (`--check`/`--apply`). Two harnesses on that seam: fake tools on `PATH` (fast) and a golden VM with real tools (slow). No pure-function tests.

## Testing Decisions

- A good test shows **external behavior**: a command, its exit code, the files it writes, and the calls it makes to system tools. A good test does not show internal code: no import of a parser, no assertion on a dict, no call to a helper function.
- One seam: the command line of `weedr`, `stakes`, and the `soil` convergers. `--check` exits `0` when converged and `1` with the word `drift` when not; `--apply` is idempotent — a second `--apply` still exits `0`, and a following `--check` exits `0`.
- Two harnesses on that seam:
  - **Fast harness (CI, seconds):** `fixtures/bin` provides fake `snapper`, `btrfs`, `systemctl`, `podman`, `useradd`, `podlet`, `git`, `sudo`, and friends. Each fake appends to a call log. Tests assert on exit code, on files that appeared or disappeared, and on the call log. This harness covers bed plow and remove, the prod gate including its ordering, secret plant, pond dig/fill/drain, stake holder lists, route generation, widget merge, and queue order.
  - **Golden VM harness (minutes, manual or nightly):** a throwaway Ubuntu (LXD or QEMU + cloud-init) runs the same commands with real tools. It replays every `soil` phase, reboots, then runs behaviour phases: snapshots, routing with a real Traefik and `curl` on a `Host` header, dashboards, previews, and the lockout drill. It exercises a production-named and a staging-named pond as the reference use-case and runs the three demo projects — **seedling** (api + worker + web, needs a pond), **coldframe** (staging-only, unreleased), and **stonecrop** (self-contained node with its own subvolume and state, no pond). It ends in an evidence tarball (journals, `snapper list`, unit states, `curl` traces).
- Modules under test, all at the seam: `soil` convergers (users, firewall, btrfs convert, storage, root-scripts, units), `weedr` (bed lifecycle, secrets, ponds, prod gate, compose → quadlet, ferm, queue), `stakes` (pin, unpin, query, ladder listing, snapper hook), `roots` (route accumulation), `twig` (widget merge), `hose` (pull + call `weedr` + restart).
- The two data-loss rules are tested as external behavior: (1) the prod gate runs before the old container stops — `weedr` returns non-zero with `missing: <KEY>` or `example value: <KEY>` **and** the container that was running before the deploy is still running; (2) holder sets across the create and drop of two previews on one snapshot — `stakes query` prints the holder list at every step, and the snapshot is only free once the last holder is dropped.

## Out of Scope

- Rolling deploys, blue-green, and canary. v1 stops then starts.
- Migrations as a separate step. Apps migrate on start.
- A web UI of any kind.
- Secrets in git or in CI.
- A shared podman network across bed users.
- A database container per bed as the default choice. Shared ponds are the recommendation; a self-contained bed may own its own state service by declaring it.
- Multi-host, Kubernetes, Docker Swarm.
- SELinux and AppArmor policy. The architecture must not block it: no daemon runs as root, users are per bed and per pond, drop-in files are the extension point.
- Debian, Arch, and Nix install paths. v1 is Ubuntu + cloud-init.
- SQL transforms for preview databases (anonymize, rewrite fields).
- Remote snapshot backup sync with a pin-aware guard.
- Tailscale or any private overlay for staging and dashboards.
- Monitoring export (podman or host stats).
- Non-Postgres shared state services in the pond. v1 ponds are Postgres; other shared state types are a later pond capability.
- Rust ports of hot paths.
- Renaming the repo from `infra` to `guarden`.

## Further Notes

- If a small feature costs a large amount of new code, it belongs in the backlog, not in v1.
- Preview slots are capped at 3 concurrent refs per project by default, FIFO eviction, overridable per host.
- `hose` pulls an explicit list of project repos from an ops file. A GitHub App is deferred.
- Open questions kept deliberately open: whether `stakes` grows a socket when a second writer appears; whether `twig` output stays on Homepage or moves to a custom dashboard; whether the fixed boot-ordering delay becomes configurable; and whether per-group loopback blocks plus ferm `uid-owner` rules remain sufficient long term, or a deeper per-group network segregation is wanted.
