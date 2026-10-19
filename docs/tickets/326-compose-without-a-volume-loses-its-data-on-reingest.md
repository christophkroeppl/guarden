# 326 — a compose that declares no volume for its data directory loses the data on every re-ingest

Blockers: none. Found 2026-10-19 by the operator's Phase A snapshot-clone testrun
(phase-a-snapshot-clone-testrun.md, finding F4).

## What happens
The staging postgres's compose declares **no volume** for
`/var/lib/postgresql/data`. Podman therefore creates an ANONYMOUS volume for
the path, and podman's garbage collector removed it mid-run — taking 96 MB of
database with it:

    $ ls -d .../volumes/2a4c367f*
    ls: cannot access '.../volumes/2a4c367f*': No such file or directory

The re-ingest re-rendered the unit, the container was recreated, and the data
volume was gone with the old container. A service whose data lives in an
anonymous volume is not durable at all, and `weedr service rollback` cannot
restore it, because there is nothing to roll back TO.

## What to build
A compose that names a data path must have a durable volume for it: either the
manifest declares a `state:` volume (which is also what makes it snapshot-able
and what Phase A needs), or guarden refuses the service with one line saying
the data path has no volume. The refusal is the honest answer for a repository
input — a compose that names a data directory and no volume is a request for
ephemeral data, and the operator should hear it at deploy time rather than
discover it when the data is gone.

Read spec 5.x/6.x for where a volume is declared and what the existing rules
say about a service with a data path but no volume; then implement the
spec-conformant side (red-first: a compose with a data path and no volume is
refused with a named one-line, or gets a durable volume, per the spec's rule).
