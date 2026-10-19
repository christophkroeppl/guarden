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
