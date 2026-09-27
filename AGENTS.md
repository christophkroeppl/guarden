# AGENTS.md

Working notes for humans and agents modifying this repo. Read [`CONTEXT.md`](CONTEXT.md)
first — the glossary is the vocabulary and the names are not negotiable mid-change.

## Layout

```
soil/     host convergers (users, firewall, sysctl, btrfs, storage)
weedr/    the only privileged mutator (bed plow/remove, pond dig/fill/drain, secrets, redeploy)
stakes/   pin registry + snapper-cleanup hook
roots/    .guarden/bed.yaml -> traefik dynamic config (shared dir, fence group)
twig/     .guarden/widgets/<service>.yml -> homepage config
pond/     optional named pond instances
hose/     optional gitops reconciler (calls weedr via sudoers)
tests/    the one test seam
fixtures/ fake binaries (PATH-first) and example project manifests
docs/     PRD, ADRs, spec, tickets, sysadmin runbook
```

Project repos carry `compose.yaml` at the root or quadlet units in `.guarden/quadlet/` —
exactly one, enforced by pre-commit — plus `.guarden/bed.yaml`, `.guarden/widgets/`, and
`.guarden/.env.schema`.

Parts talk over files and paths. There is no internal HTTP API. `weedr` is the only
thing that mutates state that matters; everything else reads and renders.

## Binding decisions

`docs/adr/0001` through `0009` are binding. Do not re-litigate them in a change. The
short version:

- No web UI, ever. `weedr` is the only thing that creates or rewrites bed units.
- Ponds are optional and named `pond-<env>-<name>` (`pond-production-postgres`,
  `pond-staging-postgres`), the bed schema with the class prefix swapped, each with its
  own user of that name. Prefer a shared pond over a state service per bed. A
  self-contained bed — its own service/DB container, subvolume, ladder, and state — is
  allowed, but it must be an explicit choice, never the default.
- hyphae is loopback ports and host names, not a shared podman network. Rootless podman
  networks are per-user and cannot cross users.
- Auth runs at the fence: a bed opts in with `auth: true` in `bed.yaml` and `roots`
  renders the forward-auth rule at the auth bed named in one root-owned file.
- No secrets in git and none in GH Actions. Production secrets are hand-set via
  `weedr secret set`. staging secrets are generated at bed create and stable until drop.
- The manifest is pure `compose.yaml` or quadlet units in `.guarden/quadlet/` — exactly
  one — plus `.guarden/bed.yaml` and `.guarden/widgets/<service>.yml`. `compose.yaml`
  stays valid Compose.

## Test seam

One seam: the command line of `weedr`, `stakes`, and the `soil` convergers (`--check` /
`--apply`). Two harnesses on that seam:

- **Fast (CI, seconds):** `fixtures/bin` is first on `PATH`. Fakes for `snapper`, `btrfs`,
  `systemctl`, `podman`, `useradd`, `podlet`, `git`, `sudo`, `runuser`, and friends append
  to a shared call log. Tests assert exit code, files that appeared or vanished, and the
  call log. Run with `make test`.
- **Golden VM (minutes, manual):** `tools/golden-vm` replays the soil phases on a throwaway
  Ubuntu, reboots, then runs behaviour phases and writes an evidence tarball.

Rules that hold for every test:

- External behaviour only. No test imports a function. No assertion on an internal dict.
- One command per shell invocation in tests. No `&&`, `|`, or `;` — the permission rules
  reject compound commands and it keeps the call log clean.
- New tests are new files under `tests/`. Do not restructure `tests/run.sh` or
  `tests/lib.sh`; append to `lib.sh` when a shared helper is genuinely shared.
- A failing test first, then the fix. Several red-green cycles, not one big bang.

## Conventions

- Bash and `python3` (stdlib first). **jinja2** is the one allowed new runtime
  dependency. Python lives in separate files and libs, never embedded inside shell
  scripts.
- No code comments unless a decision needs recording. If you need a comment, write the
  decision in `docs/adr/` instead.
- `--check` exits `0` when converged, `1` with the word `drift` when not. `--apply` is
  idempotent: a second `--apply` still exits `0` and a following `--check` exits `0`.
- `weedr` plants secrets and forgets. It never keeps a long-term secret store. The
  production gate refuses to start when a `@required` key is empty or still `EXAMPLE-` /
  `changeme`, and it is checked before the old container is shut down.
- Bed user is `bed-<env>-<name>`. The environment is always explicit: `production`,
  `staging`, `preview`, `fence` — `weedr bed plow` requires `--env` and git manifests
  declare it. Quadlet units live in that user's
  `.config/containers/systemd/`. Bed-specific overrides are unit drop-ins so a regenerate
  cannot clobber them.
- Pond user is `pond-<env>-<name>`, created by `weedr pond dig` — same treatment as a
  bed user. There is no shared `pond` user.
- `stakes` state is one root-readable file. `stakes` never blocks `snapper`; the cleanup
  hook reads the file and exits 0 regardless.

## Tickets

`docs/tickets/10-*` … `90-*` are the work list. Numbering is `10-`, `20-`, … so a
reorder can slot in without renumbering. Each ticket names its blockers. A ticket with no
blockers is on the frontier.

When implementing a ticket:

1. Read `CONTEXT.md`, the ADRs, and every ticket (so you see how they fit together).
2. Implement only the one assigned ticket. Do not fix adjacent bugs in the same change.
3. Finish with `make test` green. The reply is two lines: `DONE` and one paragraph.

## What not to do

- Do not add a web UI. Do not add a shared podman network.
- Do not default a bed to owning its own database — prefer a shared pond; a self-contained
  bed is an explicit choice.
- Do not put secrets in git, in a CI variable, or in a `weedr` database.
- Do not rewrite the harness to make one test pass.
- Do not commit secrets, generated `.env.*`, or golden-VM evidence tarballs.
- Do not commit unless the human asks. Leave the tree dirty and say what is done.
