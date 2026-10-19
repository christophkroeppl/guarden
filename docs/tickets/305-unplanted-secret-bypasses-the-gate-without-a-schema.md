# 305 — an unplanted Secret= without a schema is refused by podman, not by the gate

**Status:** implemented on `fix/secret-gate` and green in the VM
(`ok t490-secret-gate.sh`). The gate's subject is now the set of credential
REQUESTS the service's units make, read from the service's own quadlet
directory — so a template-created service, which has no schema at all, is
answered from the unit's `Secret=` lines. A key nobody planted is `blocked`
with a `[gate] reason` naming it on a gated track, and `weedr service start`
refuses with the key and the command that plants it. See 313, which is the
same change seen from the required-not-sensitive side.

Blockers: none. Found 2026-10-19 by the sysadmin-vs-code verification run (recorded in
docs/sysadmin.md's templates subsection).

## What happens
Spec's gate promise: a blocked gate is a STATE — deploy exits 0, service installed and
waiting, `[gate] reason` explains, `weedr service start` re-checks. That machinery keys
on the manifest's .env.schema (@required/@sensitive). A service whose schema is absent
(a template-created service ships neither manifest nor schema — see the create gap) has
its gate answer not-required/ready, yet an unplanted `Secret=<KEY>` in the unit makes
PODMAN refuse the start with a raw runtime error — the operator gets a podman failure
instead of the gate state the spec promises.

## What to build
Extend the pre-start gate check to cover unit-level `Secret=` lines whose keys have no
schema (missing from the service's secret store → gate state, not podman error),
red-first: template-created service with an unplanted Secret line starts into a gate
state with `[gate] reason`, exit 0 semantics preserved. Read spec's gate section for
the exact contract first.
