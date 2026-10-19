# 327 — the snapshot-clone chain has no guarden verbs: 12 manual steps for a real-life operation

Blockers: none. Found 2026-10-19 by the operator's Phase A snapshot-clone testrun
(the operator's requirement: "this will be part of real life deployment and
needs to be possible in guarden").

## What the operator asked for
"a manual testrun of pinning a snapshot from pg and clone prod odoo db on
staging pg and spin it up with staging odoo (spin up prod pg snapshot with tmp
pg container, dump and push to staging pg)".

## What was measured
The chain WORKS — every step was performed and proved on a real box
(phase-a-snapshot-clone-testrun.md, 986 lines, per-step commands and verbatim
output). But it took TWELVE manual steps that guarden has no verb for:

    G1  the postgres template declares no volumes
    G2  the renderer must set PGDATA to a subdir
    G3  no "tmp container from a snapshot" verb      ← the operator's own step
    G4  no dump verb
    G5  no transform/scrub verb                       ← "deleting email settings"
    G6  no load verb                                  ← "bulk volume"
    G7  no edge-credential re-provision verb
    G8  start must materialise secrets
    G9  remove destroys the admin wiring
    G10 no file handoff (podman cp cannot write into /var/lib/guarden)
    G11 `stakes pin` accepts a non-existent snapshot, breaking `weedr pin sync`
        host-wide
    G12 no home for the scrub rule (where does "what to strip" live?)

## What to build
Design the chain's verbs (an ADR, since this changes the program surface),
starting with the three the operator named: a tmp container from a snapshot, a
dump, and a load into a bulk volume — plus the scrub rule's home (G12: the
transformation is a POLICY, and policy that lives in an operator's head does
not survive a handover; it belongs beside the manifest or in a named
root-owned config, and it must be reviewable).
G11 is a small, independent defect worth taking first: a pin that names a
snapshot that does not exist breaks `weedr pin sync` for the whole host.

**G11 IS FIXED** (`859321e`, 2026-10-19). Measured on a live host, before the
fix:

    $ stakes pin nosuch-service:nosuchvolume@999
    pinned nosuch-service:nosuchvolume@999
    $ ls -la /var/lib/guarden/stakes/
    -rw-rw---- 1 root root 0 nosuch-service:nosuchvolume@999
    $ weedr pin sync
    error: snapper would not list the configuration
    nosuch-service-nosuchvolume, so its marks cannot be recomputed; every
    existing mark is left in place rather than cleared from a state that
    could not be read

`pins.write` now reads snapper's own list — the same read the reconciler
uses — and refuses the pin where the operator is, with a line that names the
snapshot and what to check, and writes **no file**:

    $ stakes pin nosuch-service:nosuchvolume@999
    error: the configuration nosuch-service-nosuchvolume could not be read,
    so whether nosuch-service:nosuchvolume@999 exists is unknown;
    `weedr service list` names the services this host holds
    $ ls /var/lib/guarden/stakes/      # empty — nothing was written

Two refusals, because they are two different answers: a configuration that
cannot be READ means whether the snapshot exists is unknown, and a
configuration that reads but does not hold the number means it does not
exist. `t70-pins` asserts both.

Red-first per verb, and the chain's own end-to-end test (a snapshot pinned, a
tmp pg cut from it, a dump, a scrub, a load, a staging service answering).
