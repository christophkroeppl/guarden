# guarden v1 — spec

Status: ready-for-agent.
Source: `docs/PRD.md`, `CONTEXT.md`, `docs/adr/0001`–`0005`.
Test seam model: **A** (one seam, two harnesses).

## Problem Statement

The operator runs three early projects (nutristack, daily-dose, klimafit) on one VPS and has no real deployment story. `main` and `develop` are docker-compose home-lab stacks. `next` is a dirty prototype. The demo server is a half-installed third-party quadlet UI. There is no way to place a project into a running slot by hand, no way to share one Postgres across projects without one container per app, no way to protect production data from snapshot pruning, and no safe gate that stops a production service from starting with an empty secret.

The operator wants one small platform, **guarden**, that turns a fresh Ubuntu VPS into a host with beds, shared ponds, pins, routes, and dashboards — and that still works when only one human is at the keyboard.

## Solution

**guarden** is a monorepo of two layers.

**base** is enough for manually assisted deployments:

- **soil** converges a fresh Ubuntu: cloud-init, ext4 → btrfs convert, ferm + fail2ban, snapper ladders, rootless podman + quadlet, sysctl for unprivileged ports.
- **weedr** is the one privileged mutator. It creates and drops **beds**, converts `compose.yaml` to quadlet units, mints pond roles, plants secrets, and refuses to start a production service whose required env is empty or still an example value.
- **stakes** is the pin registry. It holds snapshot pins so ladders cannot prune pinned data.
- **roots** collects route configs from services in beds and writes Traefik dynamic config. Traefik is a separate process in a separate user.

**addons** sit on top of base:

- **pond** runs exactly two Postgres instances: `pond-production` (snapshotted) and `pond-staging` (rebuildable). A bed gets a database and a role, never its own pond.
- **twig** renders one dashboard widget per service into Homepage config.
- **hose** reconciles beds from git, by calling `weedr`.

The operator creates a bed with `weedr bed new`, sets production secrets with `weedr secret set`, and sees routes appear at the **hyphae** names (`pond.internal`, `bed-<name>.internal`) on the host loopback.

## User Stories

1. As an admin, I want cloud-init to bring up a fresh Ubuntu with my SSH keys, so that I can log in without a console.
2. As an admin, I want `soil` to convert the root filesystem from ext4 to btrfs with one reboot, so that snapshots work later.
3. As an admin, I want `soil` to keep `/boot` on ext4, so that the machine still boots.
4. As an admin, I want `soil` to make a `@home` subvolume and fix fstab, so that home is snapshotted separately from root.
5. As an admin, I want `soil` to disable the preinstalled firewall and install ferm + fail2ban, so that one policy covers the host.
6. As an admin, I want `soil` to install rootless podman, quadlet, and pasta, so that beds run without root.
7. As an admin, I want `soil` to set `net.ipv4.ip_unprivileged_port_start=0`, so that Traefik can bind :80/:443 without root.
8. As an admin, I want `soil` to configure snapper ladders for root, home, and `pond-production`, so that I can roll back.
9. As an admin, I want `soil` to snapshot root on apt install and upgrade, so that a bad package is recoverable.
10. As an admin, I want `soil` to skip snapper on `pond-staging`, so that rebuildable data does not eat disk.
11. As an admin, I want every `soil` phase to support `--check` and `--apply`, so that I can see drift before I change the host.
12. As an admin, I want `soil` to install root-owned copies of anything root runs, so that root never runs deploy-writable code.
13. As an admin, I want a sysadmin readme with the most important commands, so that I can operate the box at 3am.
14. As an admin, I want `weedr bed new <project> --env production` to create one Linux user, one unit directory, volumes, and hyphae names, so that a bed exists in one command.
15. As an admin, I want the bed user to be `bed-<project>-<env>` with linger on, so that services run without me logging in.
16. As an admin, I want `weedr` to allocate subuid and subgid ranges, so that rootless podman works in the bed.
17. As an admin, I want `weedr` to read `compose.yaml` and write quadlet units, so that the project repo stays pure Compose.
18. As an admin, I want `weedr` to write `.volume` units for bare named volumes, so that volumes are explicit.
19. As an admin, I want `weedr` to keep my overrides in unit drop-ins, so that regeneration cannot clobber them.
20. As an admin, I want `weedr bed drop` to stop units, remove the user, and free hyphae names, so that a bed is really gone.
21. As an admin, I want `weedr` to refuse to drop a production bed without confirmation, so that I cannot fat-finger a prod outage.
22. As an admin, I want `weedr secret set <bed> KEY` to plant one value into the bed, so that production secrets never touch git or CI.
23. As an admin, I want `weedr` to plant into a materialized `.env` or a podman secret and then forget the value, so that `weedr` holds no long-term secret store.
24. As an admin, I want `weedr` to generate staging secrets at bed create and keep them stable until the bed is dropped, so that previews work out of the box.
25. As an admin, I want a local override file to win over generated values, so that I can put a real value on staging when I need one.
26. As an admin, I want `weedr` to refuse to start a production service if a `@required` key is empty, so that a missing secret cannot reach production.
27. As an admin, I want `weedr` to refuse to start a production service if a value still looks like `EXAMPLE-` or `changeme`, so that placeholder values cannot reach production.
28. As an admin, I want the gate to warn only on staging and previews, so that previews are cheap.
29. As an admin, I want `weedr` to mint one Postgres role and one password per bed, so that beds do not share credentials.
30. As an admin, I want `weedr` to create the bed database in the right pond, so that production data and staging data stay apart.
31. As an admin, I want `weedr pond drop` to require explicit confirmation for `pond-production`, so that production data cannot vanish by accident.
32. As an admin, I want preview databases to drop automatically, so that a merged PR does not leak state.
33. As an admin, I want `weedr` to reassign dump ownership to the new role on restore, so that staging never reuses a production password.
34. As an admin, I want `stakes pin <snapshot> --holder <bed>` to hold a snapshot, so that a ladder cannot prune data I still need.
35. As an admin, I want `stakes` to refcount holders, so that one snapshot can serve many beds and is freed only when the last holder is gone.
36. As an admin, I want `stakes query` to print the holders, so that I can see who blocks a prune.
37. As an admin, I want `stakes unpin` to release one holder, so that dropping one preview does not free a snapshot another preview still uses.
38. As an admin, I want the snapper cleanup hook to read the pin state file and skip pinned ids, so that pins survive pruning.
39. As an admin, I want `stakes` to never block snapper, so that a stuck pin cannot wedge the host.
40. As an admin, I want space-aware pruning to keep my priority order (home and agents first, root, `pond-production` last), so that the pond is the last thing to shrink.
41. As an admin, I want `roots` to read `bed.yaml` from every bed and write Traefik dynamic config, so that routes appear without me editing Traefik.
42. As an admin, I want `roots` to run in its own user and share only one directory with the `traefik` user through the `edge` group, so that a bug in `roots` cannot control Traefik.
43. As an admin, I want default routes `staging.<domain>` and `preview.<domain>/<ref>`, so that previews are predictable.
44. As an admin, I want per-project route overrides in `bed.yaml`, so that a project can pin a hostname.
45. As an admin, I want hyphae names like `pond.internal` in `/etc/hosts`, so that a bed can open the pond without a shared podman network.
46. As an admin, I want `weedr` to write and remove those names with the bed, so that the map cannot rot.
47. As an admin, I want `twig` to merge `widgets/<service>.yml` into Homepage config, so that every service gets one dashboard card.
48. As an admin, I want exactly one widget per service, so that the dashboard cannot grow without bound.
49. As an admin, I want `twig` to add a link per project to its staging dashboard and its repo, so that I can jump between environments.
50. As an admin, I want `hose` to `git pull` a list of project repos and call `weedr`, so that git is the source of truth without a second mutator.
51. As an admin, I want `hose` to restart only changed services, so that a deploy does not bounce the world.
52. As an admin, I want deploys to stop then start, so that v1 is simple and honest about the short downtime.
53. As an admin, I want migrations to run in-app on start, so that I do not have to remember a second step.
54. As an admin, I want `weedr redeploy <bed>` to ask before touching production, so that redeploys are deliberate.
55. As an admin, I want a staging bed for `nutristack/develop` to restore one project database from a pinned `pond-production` snapshot into `pond-staging`, so that staging has realistic data.
56. As an admin, I want that staging bed to get a new role and a new password, so that staging cannot authenticate against production.
57. As a developer, I want a preview bed for my PR to appear at `preview.<domain>/<ref>`, so that I can show work before merge.
58. As a developer, I want that preview to be dropped when the PR merges, so that the box does not fill with dead beds.
59. As a developer, I want dropping my preview to release my share of the pin, so that the snapshot can be pruned when nothing else needs it.
60. As a developer, I want `compose.yaml` in my project repo to stay pure Compose, so that local `podman compose` still works.
61. As a developer, I want `bed.yaml` next to it for routes and pond databases, so that the infra contract is visible in my repo.
62. As a developer, I want one `widgets/<service>.yml` per service, so that my service gets a dashboard card without a ticket.
63. As a developer, I want a tracked `.env.schema` that names every key and marks what is sensitive, so that I know what to set.
64. As a developer, I want a generated `.env.example` with safe dummies, so that staging starts without me inventing values.
65. As a developer, I want gitignored local overrides, so that I can put a real value on one environment without committing it.
66. As a developer, I want three microservices in one bed, so that `api`, `worker`, and `web` share one project × environment slot.
67. As a developer, I want my bed to open `pond.internal:5432` from a rootless container, so that I can use the shared Postgres.
68. As an admin, I want every part to talk over files and paths and not over an internal HTTP API, so that I can debug with `ls` and `cat`.
69. As an admin, I want `weedr` to be the only privileged mutator, so that sudo is one narrow door.
70. As an admin, I want `hose` to call `weedr` through a narrow sudoers rule, so that gitops cannot become root.
71. As an admin, I want `stakes`, `roots`, `twig`, and `pond` to run unprivileged, so that a bug is not a root bug.
72. As an admin, I want tests at one seam — the command line — so that refactors do not break the suite.
73. As an admin, I want fake `snapper`, `btrfs`, `systemctl`, and `podman` on `PATH` for fast tests, so that CI finishes in seconds.
74. As an admin, I want the same commands on a golden VM with real tools, so that I know the host survives btrfs convert and a reboot.
75. As an admin, I want `--check` to report drift without changing the host, so that I can audit before I act.
76. As an admin, I want a lockout drill that restores firewall access on a dead-man timer, so that I cannot lock myself out for good.
77. As an admin, I want an evidence tarball after the golden VM run, so that a failure is debuggable from journals and call logs.
78. As an admin, I want the demo server's `qm-*` layout replaced by `bed-<project>-<env>`, so that names match the glossary.
79. As an admin, I want no secret ciphertext in git and none in GH Actions, so that a repo leak is not a credential leak.
80. As an admin, I want the offline copy of production secrets to be mine to keep, so that snapshot restore is possible without a secrets service.

## Implementation Decisions

- Product name is **guarden**. The repo is still named `infra` until a rename; nothing depends on the string.
- Two layers: **base** (soil, roots, weedr, stakes) and **addons** (twig, pond, hose). Base is enough for manually assisted deployments. Addons are optional.
- Parts talk over files and paths. There is no internal HTTP API.
- A **bed** is one **project** in one **environment** (`production` | `staging` | `preview:<ref>`). A bed owns one Linux user `bed-<project>-<env>` (linger on), one user-scope quadlet unit directory, its volume subvolumes, and its hyphae names. A **service** is one container/process inside a bed. See ADR-0001 for the rejected third-party quadlet UI.
- `weedr` is the only privileged mutator. `hose` calls `weedr`. `stakes`, `roots`, `twig`, and `pond` run unprivileged. `roots` and `traefik` never share a user; they share one directory and the `edge` group (`roots` writes, `traefik` reads).
- **hyphae** is a contract, not a network: shared services publish on `127.0.0.1`, `weedr` writes stable names (`pond.internal`, `bed-<name>.internal`) into `/etc/hosts`, beds use `pasta` to reach the host loopback. Rootless podman networks are per-user; a shared L2 network is impossible without giving up rootless. See ADR-0003.
- **pond** is exactly two Postgres instances: `pond-production` (snapshotted) and `pond-staging` (rebuildable, not snapshotted). A bed gets one database and one role inside the right pond; a bed never gets its own pond. Production database drop is manual only. Preview database drop is automatic. See ADR-0002.
- The project repo carries three tracked YAML files and nothing else: `compose.yaml` (pure Compose), `bed.yaml` (routes for `roots`, databases for `pond`, hyphae aliases), `widgets/<service>.yml` (exactly one dashboard widget per service, for `twig`). Both `weedr` and `hose` read the same files. See ADR-0005.
- `weedr` converts `compose.yaml` to quadlet using **podlet** as a pinned binary, plus a small pass that emits `.volume` units for bare named volumes. Bed-specific overrides are written as unit drop-ins so regeneration cannot clobber them.
- Secrets never live in git and never live in GH Actions. SOPS is rejected. A tracked `.env.schema` (varlock syntax: `@required`, `@sensitive`, `@type`, `@example`) is the source of truth for names and types. `.env.example` is generated from the schema. Overrides layer as `.env` → `.env.<env>` → `.env.<env>.local` (gitignored). See ADR-0004.
- Production: the admin sets values by hand with `weedr secret set`. A hard gate refuses to start a production service if a `@required` key is empty or still `EXAMPLE-`/`changeme`. staging: `weedr` generates `@sensitive` values at bed create, stable until the bed is dropped; a local override always wins. `weedr` plants and forgets.
- `stakes` holds pins as snapshot id → set of bed holders. A pin is released only when every holder is gone. The snapper cleanup hook reads the pin state file and skips pinned ids. `stakes` never blocks snapper. The state file is enough for one operator; a socket daemon is deferred until a second writer appears.
- Preview create: `stakes` pins the current `pond-production` snapshot, `weedr` dumps the project database and role, mints a new role and password in `pond-staging`, restores the dump, reassigns ownership, plants the new credential, converts `compose.yaml`, writes routes and widgets, then starts units. Preview drop: stop units, drop database and role, unpin, remove hyphae names, remove user and volumes.
- Restoring a dump brings data, never secrets. `weedr` always mints new credentials on restore. If an app encrypts rows with a key from the secret store, that key stays stable across restores.
- Deploy is stop-then-start. Migrations run in-app on start before the service accepts traffic. Rolling deploys are out of scope.
- Host layout: bed homes under `/home/bed-<project>-<env>` with a user-scope quadlet unit directory; bed volume subvolumes under a `weedr`-owned volumes root; `pond-production` data in its own snapshotted subvolume; `pond-staging` data in a no-snapper subvolume; `roots` writes dynamic config under a shared `edge`-group directory; `stakes` state in a root-readable file; hyphae names in `/etc/hosts`.
- Test seam model **A**: one seam at the command line of `weedr`, `stakes`, and the `soil` convergers (`--check`/`--apply`). Two harnesses on that seam: fake tools on `PATH` (fast) and a golden VM with real tools (slow). No pure-function tests.

## Testing Decisions

- A good test shows **external behavior**: a command, its exit code, the files it writes, and the calls it makes to system tools. A good test does not show internal code: no import of a parser, no assertion on a dict, no call to a helper function.
- One seam: the command line of `weedr`, `stakes`, and the `soil` convergers. This is the existing seam from `next` (`fixtures/bin` fakes on `PATH`, `--check`/`--apply` convergers) and is reused as-is.
- Two harnesses on that seam:
  - **Fast harness (CI, seconds):** `fixtures/bin` provides fake `snapper`, `btrfs`, `systemctl`, `podman`, `useradd`. Each fake appends to a call log. Tests assert on exit code, on files that appeared or disappeared, and on the call log. This harness covers bed create and drop, the prod gate, secret plant, pond role mint, pin refcount, route generation, and widget merge.
  - **Golden VM harness (minutes, manual or nightly):** a throwaway Ubuntu (LXD or QEMU + cloud-init) runs the same commands with real tools. It replays every `soil` phase, reboots, then runs behaviour phases: snapshots, routing with a real Traefik and `curl` on a `Host` header, dashboards, pond, previews, and the lockout drill. It ends in an evidence tarball (journals, `snapper list`, unit states, `curl` traces).
- Modules under test, all at the seam: `soil` convergers (users, firewall, btrfs convert, storage, root-scripts, units), `weedr` (bed lifecycle, secrets, pond, prod gate, compose → quadlet), `stakes` (pin, unpin, query, snapper hook), `roots` (route accumulation), `twig` (widget merge), `hose` (pull + call `weedr` + restart).
- The two data-loss rules are tested as external behavior: the prod gate is `weedr` returning non-zero with `missing: <KEY>` or `example value: <KEY>`; the pin refcount is `stakes query` printing `holders=N` across create and drop of two previews on one snapshot.
- Prior art: `next`'s `smoke.sh` with `fixtures/bin`, and `next`'s LXD harness for install replays. Dokploy's real-install-on-runner is not reusable here because our hard step is a destructive ext4 → btrfs convert plus a reboot.

## Out of Scope

- Rolling deploys, blue-green, and canary. v1 stops then starts.
- Migrations as a separate step. Apps migrate on start.
- A web UI of any kind.
- Any third-party quadlet management UI (ADR-0001).
- Secret ciphertext in git, including SOPS (ADR-0004).
- Per-bed or per-preview Postgres containers (ADR-0002).
- A shared podman network across bed users (ADR-0003).
- Multi-host, Kubernetes, Docker Swarm.
- SELinux and AppArmor policy. The architecture must not block it: no daemon runs as root, users are per bed, drop-in files are the extension point.
- Debian, Arch, and Nix install paths. v1 is Ubuntu + cloud-init.
- SQL transforms for preview databases (anonymize, rewrite fields).
- Remote snapshot backup sync with a pin-aware guard.
- Tailscale or any private overlay for staging and dashboards.
- Monitoring export (podman or host stats).
- Non-Postgres shared state in the pond (redis, minio, and friends).
- Rust ports of hot paths.
- Renaming the repo from `infra` to `guarden`.

## Further Notes

- The demo server (Ubuntu 26.04, ext4 root, ufw on, no snapper/ferm/traefik, a half-installed third-party quadlet UI with idle `qm-production` and `qm-staging` users) confirms that the `soil` btrfs-convert and firewall phases are the critical path. Everything else can be built against fakes first.
- Three projects are early prototypes and can be reworked to fit `compose.yaml` + `bed.yaml` + `widgets/`. Nothing needs to keep the `next` layout.
- If a small feature costs a large amount of new code, it belongs in the backlog, not in v1.
- Preview slots are capped (the `next` prototype used a FIFO of 3). Keep 3 for v1.
- `hose` discovers project repos from an explicit list in an ops file. A GitHub App is deferred.
- Open questions kept deliberately open: whether `stakes` grows a socket when a second writer appears; whether `twig` output stays on Homepage or moves to a custom dashboard.
