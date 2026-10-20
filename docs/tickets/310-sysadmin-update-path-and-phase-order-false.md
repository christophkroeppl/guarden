# 310 — sysadmin.md contradicts the actual host: update path is not a git repo, phase order differs

Blockers: none. Found 2026-10-19 by the from-scratch acceptance run
(deploy-verify-fresh-boxes.md findings 1 and 5; measured on both fresh boxes).

## What happens
1. docs/sysadmin.md:36 says `git -C /usr/lib/guarden pull  # the programs live
   root-owned under /usr/lib/guarden`. Measured on both boxes:
   `fatal: not a git repository` — install.sh clones to /usr/local/src/guarden
   (tools/install.sh:39 REPO_DIR, userdata.py:46 DEFAULT_REPO_DIR). Two documented
   locations for "the checkout"; the sysadmin one does not exist on an install.sh host.
2. docs/sysadmin.md:55 gives the phase order `packages, storage, sysctl, firewall,
   install, units` while README.md:58-64 and tools/install.sh:43 put `install` FIRST
   (README:53-55 explains why — it seeds what `packages` resolves against). Following
   the sysadmin line verbatim on a fresh box is not the working flow.

## What to build
Fix both lines to the code's reality (or unify the order in code if two orders are
really meant — decide from install.sh, the only implementer). Red-first where a doc
assertion exists (docs suite), otherwise the doc diff plus a grep-proof no second
location remains (a test asserting the one REPO_DIR constant would be ideal).

## Measured correction (2026-10-19)

**There are two orders, not one, and the spec says which is which.**

- The **phase list** — the order `soil list` prints and the spec states
  (docs/spec.md:1364) — is `packages, storage, sysctl, firewall, install, units`.
  It is the order the phases are *described* in. Ticket 268 recorded the reason
  explicitly: "the spec's phase list is unchanged — it describes the phases, not a
  bootstrap."
- The **bootstrap order** — the order a FRESH host runs them in — is `install` first,
  and that is `tools/install.sh:43`'s `PHASE_ORDER`, the only implementer of the
  fresh-host flow. `install` goes first because `soil packages` resolves the pinned
  `podlet` release against a record `soil install` writes, and `soil install` is
  what puts the programs on `PATH` at all.

So the runbook was wrong in a specific way: it stated the phase list and an operator
following it verbatim on a bare host got `soil packages --apply` refusing with "the
pinned podlet record is absent" — by design, and the fix is to run `install` first.
**The fix states both orders and says which is which**, rather than replacing one
with the other: the phase list still matches `soil list` (so the runbook and the
program agree), and the bootstrap order is stated with its reason beside it.

The update path is one location now: `/usr/local/src/guarden`, read out of
`install.sh`'s own `REPO_DIR` constant, with `/usr/lib/guarden` named as what it
actually is (guarden's own root-owned files, not a checkout).

## Closed 2026-10-19 (fix/ticket-wave-a)

`docs/sysadmin.md` now has an **Installing a fresh host** section and an **Updating
an installed host** section, and the phase section states both orders. The
comparison is against the program, not a copy of it: `tests/t480-doc-claims.sh` reads
`soil list` and compares the runbook's stated order with it, and reads `install.sh`'s
`PHASE_ORDER` and compares that with the bootstrap order the runbook states. A
runbook that drifts from either fails against the thing it drifted from.
