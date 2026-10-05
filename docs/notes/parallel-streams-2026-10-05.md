# Three parallel streams, partitioned by file ownership

Fanned out 2026-10-05 from `develop @ 5741261`. Three agents, three LXD runners, one
worktree each. **Partitioned by FILE OWNERSHIP before dispatch** — two agents that
touch one file are one worktree or a sequence, never parallel.

| stream | worktree | runner | owns |
|---|---|---|---|
| A | `ticket-260-stub-resolver` | `guarden-a` | `docs/adr/00XX-stub-resolver.md`, `src/guarden/rules.py`, `docs/spec.md`, `tests/t180-firewall-rules.sh` |
| B | `ticket-270-iptables-variant` | `guarden-b` | `src/guarden/hostprep.py`, `src/guarden/packagelist.py`, `packages/packages.toml`, `tools/cloud-init/user-data.yaml`, `docs/notes/iptables-variant-must-be-stated.md` |
| C | `ticket-040-untrusted` | `guarden-c` | `tests/t40-untrusted.sh`, `tests/lib.sh` (append only) |

Each was told its siblings' file lists and told explicitly: if the fix needs a file you
do not own, **describe it, do not edit it**. That is the failure mode worth naming —
two agents each "just fixing" a shared file is one worktree, and the integration
conflict surfaces as a silent overwrite rather than a conflict.

## None of them commits

Each leaves its tree dirty. I integrate. A subagent that commits or merges is a
subagent whose work I have to unpick before I can read it.

## What each is doing

**A — ticket 260.** The loopback deny refuses `127.0.0.53`, so `podman pull` cannot
complete and no first deploy succeeds. Measured: the deny's own packet counter goes 0
then 1 across one UDP send from a service uid. The ADR comes first, because ADR-0013
removed `[loopback] allow` for a reason and this must not walk it back through a side
door.

**B — the iptables variant.** `/usr/sbin/iptables` is nft on the golden and guarden's
rules are in the legacy table, because `ferm` invokes `iptables` by name. Fail-open on
a host that agrees with nft: the rules exist where no operator tool reads them. **This
one may require a golden rebuild** — it touches `tools/cloud-init/user-data.yaml` — and
that is why the brief asks for it loudly rather than assuming.

**C — `t40-untrusted`.** Red for a while, verified pre-existing by stashing. The brief
says the fault may be in the test rather than the code, and forbids weakening an
assertion to get green.

## The machine was already loaded

Load average 23 on 8 cores when they were dispatched, from other work on the box (odoo,
postgres) — not from guarden. 18 GB RAM free, so memory was not the constraint. Each
brief carries the rule that matters here: **run the suite as one background command
writing to a file, and never treat a failure count that changes between identical runs
as a finding** — that is contention, and this box will manufacture it.

## Verification is mine, not theirs

Each agent reports what its suite said. None of that is evidence until I re-run it, and
per the standing rule an agent's green suite does not mean its change works. The three
streams touch disjoint files, so the merges should be mechanical — and if two of them
turn out to need the same file, the merge order becomes a sequence and I say so rather
than forcing it.
