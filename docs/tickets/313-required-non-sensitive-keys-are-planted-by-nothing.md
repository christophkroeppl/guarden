# 313 — a schema-required, non-sensitive key is planted by nothing: the deploy dies at podman with "no such secret"

Blockers: none. Found 2026-10-19 measured in a VM during the 295/296/302 fix
(instance-start-path report; observed verbatim: `podman run answers 125 no such
secret for LOG_LEVEL`).

## What happens
Spec 5.3 step 9 mints @sensitive keys (materialiser). A key marked @required but NOT
@sensitive is planted by nobody: on an ungated track the gate says not-required/ready,
`weedr service start` proceeds, and podman refuses the unit with a raw `125 no such
secret`. The operator gets a runtime error instead of a gate state or a mint step —
the same class as 305, but from the required-not-sensitive side.

## What to build
Decide from spec 5.3 where required-not-sensitive keys come from on each track
(gate state vs a mint rule vs a documented plant step), implement the decided side
(or the refusal one-liner when planting is owed), red-first: a service whose schema
requires LOG_LEVEL starts into a gate state or mints it — never a raw podman 125.
Coordinate with 305 (same start-path family).
