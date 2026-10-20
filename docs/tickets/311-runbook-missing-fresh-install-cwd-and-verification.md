# 311 — the operator runbook has no fresh-install section, no cwd, and no way to see a service answer

Blockers: none. Found 2026-10-19 by the from-scratch acceptance run
(deploy-verify-fresh-boxes.md findings 2, 3, 4).

## What happens
- docs/sysadmin.md:281 / examples/README.md:19 give `cp -r examples/services/…` with
  no cwd; it only resolves from the repo root, which on a real host is
  /usr/local/src/guarden — a path the runbook never names.
- The runbook ends at `weedr service start` (docs/sysadmin.md:237-371): grep for
  pg_isready across README/docs/examples = 0 hits, and to prove the postgres example
  answers the operator had to install postgresql-client by hand. No verification
  subsection exists.
- No operator document mentions tools/install.sh: `curl … | sudo bash` lives only in
  the script's own header and exit-75 banner. README.md:57-74 documents the
  phase-by-hand flow; sysadmin.md:33-42 only documents UPDATING an installed host.

## What to build
A fresh-install section in docs/sysadmin.md (canonical curl command, the 75/75/0
three-run contract, pointing at README for the phase-by-hand alternative), an explicit
`cd /usr/local/src/guarden` (or a variable) before the template cp, and a
verification subsection per service example (what to run — pg_isready/psql — and what
a healthy answer looks like; name any client tooling the operator needs). Examples
README cross-referenced. Red-first where doc suites assert (t260 pins the examples).

## Closed 2026-10-19 (fix/ticket-wave-a)

- **The fresh-install section** is `docs/sysadmin.md`'s **Installing a fresh host**:
  the canonical `curl … | sudo bash`, the **75/75/0** three-run contract with the
  table of what each run does and what the operator does between them, the installer's
  own exit-75 banner quoted verbatim, and a pointer to README for the phase-by-hand
  alternative. README's Install section gained the same canonical command, so the two
  documents agree.
- **The cwd** is `cd /usr/local/src/guarden`, stated in both `docs/sysadmin.md` and
  `examples/README.md`, with the reason (the path is relative to the repository root)
  and the failure it prevents (`cp: cannot stat 'examples/services/postgres'`).
- **The verification subsection** is **verifying a service answers**, one per example,
  each with the command, the healthy answer, and the client tooling:
  - postgres: `pg_isready -h 127.0.0.1 -p 5432` → `accepting connections`, exit 0;
    the `psql` variant needs the planted password and answers
    `fe_sendauth: no password supplied` without it — which is the *client* refusing,
    and is what a planted-but-unmaterialised credential looks like. The
    `postgresql-client` package is named, because the host does not ship it and the
    acceptance run had to apt-install it by hand.
  - vaultwarden: `curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8082/alive`
    → `200`, and the volume refusal (`[ERROR] No persistent volume!`) is named because
    it is the one thing that bites on this example.
  - The container-internal form is given too (`podman exec systemd-postgres
    pg_isready -U postgres`), which needs no client package — and the container's
    name is the unit's name, `systemd-postgres`, not `postgres`.
  - **What a healthy answer is not** is stated: a loopback check proves the service
    serves on the box, not that anything outside it can reach it.

## The doc-assertion mechanism (did one exist?)

**No.** Every other suite in this repository asserts on a machine — a program's exit
code, a file on a disk, a rule in a ruleset — and the documents had no keeper at all,
which is why a runbook could name a path that does not exist and nothing said so
until an operator followed it on a fresh box.

So one was built: **`tests/t480-doc-claims.sh`** (in the reserved t480-t489 range),
plus the seam it needed in `tests/suitecache.py` — a suite names the tree it reads
(`# reads: <path>`), so a doc-assertion suite's green is not inherited over an edited
document. `docs/` stays out of every other key, and a doc enters the key of the one
suite that names it.

The suite asserts the claims these tickets fix, and it asserts them against the
program where one exists: the phase order is compared with `soil list` and with
`install.sh`'s own `PHASE_ORDER`, and the package list with `soil packages --list`
and with the **rendered** `vps` document rather than with a copy of the list.

`tests/t260-examples.sh` was left alone: it pins the example templates themselves
(what `create` makes of them), not the prose about them, and it is not the mechanism
for a document claim.
