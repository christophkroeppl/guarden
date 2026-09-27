# AGENTS.md

Working notes for humans and agents modifying this repo. Read [`CONTEXT.md`](CONTEXT.md)
first — the glossary is the vocabulary and the names are not negotiable mid-change.

## Layout

```
soil/     host convergers (users, firewall, sysctl, btrfs, storage)
weedr/    the only privileged mutator (beds, secrets, pond, preview, redeploy)
stakes/   pin registry + snapper-cleanup hook
roots/    bed.yaml -> traefik dynamic config
twig/     widgets/<service>.yml -> homepage config
pond/     bring up pond-production and pond-staging
hose/     optional gitops reconciler (calls weedr via sudoers)
tests/    the one test seam
fixtures/ fake binaries (PATH-first) and example project manifests
docs/     PRD, ADRs, spec, tickets, sysadmin runbook
```

Parts talk over files and paths. There is no internal HTTP API. `weedr` is the only
thing that mutates state that matters; everything else reads and renders.

## Binding decisions

`docs/adr/0001` through `0005` are binding. Do not re-litigate them in a change. The
short version:

- No third-party quadlet UI. No web UI at all.
- Two ponds (prod snapshotted, nonprod rebuildable). Never a Postgres per bed.
- hyphae is loopback ports and host names, not a shared podman network. Rootless podman
  networks are per-user and cannot cross users.
- No secret ciphertext in git. Production secrets are hand-set via `weedr secret set`.
  staging secrets are generated at bed create and stable until drop.
- The manifest is pure Compose plus `bed.yaml` plus `widgets/<service>.yml`. `compose.yaml`
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

- Bash and `python3` (stdlib first). No new runtime dependencies.
- No code comments unless a decision needs recording. If you need a comment, write the
  decision in `docs/adr/` instead.
- `--check` exits `0` when converged, `1` with the word `drift` when not. `--apply` is
  idempotent: a second `--apply` still exits `0` and a following `--check` exits `0`.
- `weedr` plants secrets and forgets. It never keeps a long-term secret store. The
  production gate refuses to start when a `@required` key is empty or still `EXAMPLE-` /
  `changeme`.
- Bed user is `bed-<project>-<env>`. Quadlet units live in that user's
  `.config/containers/systemd/`. Bed-specific overrides are unit drop-ins so a regenerate
  cannot clobber them.
- `stakes` state is one root-readable file. `stakes` never blocks `snapper`; the cleanup
  hook reads the file and exits 0 regardless.

## Tickets

`docs/tickets/10-*` … `90-*` are the work list. Numbering is `10-`, `20-`, … so a
reorder can slot in without renumbering. Each ticket names its blockers. A ticket with no
blockers is on the frontier.

When implementing a ticket:

1. Read `CONTEXT.md`, the ADRs, and every ticket (so you see the edges).
2. Implement only the one assigned ticket. Do not fix adjacent bugs in the same change.
3. Finish with `make test` green. The reply is two lines: `DONE` and one paragraph.

## What not to do

- Do not add a web UI. Do not add a third Postgres. Do not add a shared podman network.
- Do not put secrets in git, in a CI variable, or in a `weedr` database.
- Do not rewrite the harness to make one test pass.
- Do not commit secrets, generated `.env.*`, or golden-VM evidence tarballs.
- Do not commit unless the human asks. Leave the tree dirty and say what is done.
