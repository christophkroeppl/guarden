# 304 — harness residuals preserved from the 271/266 closures (runner question + evidence captures)

Blockers: none. Carried 2026-10-19 from ticket 271's implementation report (its ticket
file was then deleted by the backlog purge — these observations live only in the
commit bodies) and ticket 266's closing note.

## What remains open
1. t35-env-schema.sh has NO runner: HOST_ONLY skips it in the VM and no recipe runs it
   on the host (AGENTS.md forbids executing tests on the development machine). This
   needs a DECISION about where repository-hygiene suites run, not a test.
2. On ubuntu:26.04 `Unit cloud-init.service could not be found` — one of 271's three
   systemctl evidence captures reports an absence because cloud-init's unit has another
   name on this image; the evidence block prints a wrong line for it.
3. `fuser -v` prints nothing when nobody holds the locks (misleading evidence line
   when the state is actually free).

## What to build
1: a decided home for hygiene suites (or an explicit "not run" ruling recorded in spec
or an ADR). 2: detect the real cloud-init unit name per image (or capture cloud-init
status instead). 3: make the free-state evidence say "held by: nobody" explicitly.
Red-first for 2/3 against a real cut (t370 owns the probe — coordinate there).
