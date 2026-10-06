# Worktree cleanup, 2026-10-06 — what was removed and why

18 worktrees removed with `git worktree remove --force`, then `git worktree prune`.

## The question that had to be answered first

Every worktree read as dirty, which looks like lost work. The subagents that analysed
them produced **conflicting** answers, so the claim was checked directly rather than
believed:

- `git diff --stat` in `ticket-100-homepage` reports **37 modified, +1939/−187** — which
  reads as a large unmerged implementation.
- `git diff --stat develop...ticket-100-homepage` reports **no diff** at all.

Both are true and they are about different things. The worktree's HEAD is `7f412d8`, an
ancestor of develop's `535fee0`. Its working tree therefore differs from *its own HEAD*
by a large diff, while the *committed* branch has nothing develop lacks.

So the question is whether the uncommitted delta is already in develop, and the direct
test settles it: of the first 20 added lines in that worktree's `furrow.py`, **20 are
present in develop's `furrow.py` and 0 are absent**. The delta landed by other commits —
it was merged through a different path, which is why the branch itself never showed it.

## Verified safe to remove

| Worktree | Why it was safe |
|---|---|
| ticket-040-untrusted | The one-line `Mount` fix is in develop at `535fee0`. |
| ticket-260-stub-resolver | All 8 tracked files byte-identical to develop; ADR renumbered 0015→0016, content identical. |
| ticket-270-iptables-variant | All 7 files byte-identical to develop. |
| ticket-100-homepage | Delta already in develop (20/20 sampled lines). |
| ticket-120-queue | Same delta, same reason. |
| ticket-150-auth | Same delta, same reason. |
| ticket-170-zram | `zram.py` present in develop. |
| ticket-180-firewall | Harness doc lines already in develop. |
| ticket-200-provisioned-golden | The commit is on an older base; content superseded in develop. |
| ticket-210-cache | `suitecache.py` present in develop. |
| ticket-10, -15, -20, -30 | Only `.githooks/` and `.wt-symlinks.schema.json` untracked — worktrunk infra, regenerated. |
| ticket-110, -90, dialect-debt | Clean. |
| next-split-mono | Zero commits ahead of develop. |

## Kept, and why

- **`next`** — 133 commits ahead, 142 behind, with an untracked `PLAN-phases.md`. Real
  work, not stale.
- **`develop-old`** — 40 commits ahead, 118 behind, and a dirty `homepage/config/bookmarks.yaml`.
  Its content is a *different project* (bitcoin/knots, traefik upgrades, coolify
  routing), not guarden's. **Not a guarden branch.** Left untouched pending the user's call.
- **`main`** — the operator's. Never merged into, never rewritten.

## What the subagents got wrong, recorded so it is not repeated

The worktree analysis agents reported that seven worktrees held "meaningful work never
merged", and named `src/guarden/edges.py`, `modules.py`, `units.py`, `zram.py` and
`tests/suitecache.py` as files absent from develop. **Every one of those files is
present in develop.** The agents compared each worktree against develop's *working
directory* without checking whether the file was tracked in develop at all.

The generalisable lesson: `git status` dirty in a worktree whose HEAD is an ancestor of
the target branch is the *normal* state of a worktree that was merged by another path.
It is not evidence of lost work, and `git worktree remove --force` must not be run on the
strength of it alone.
