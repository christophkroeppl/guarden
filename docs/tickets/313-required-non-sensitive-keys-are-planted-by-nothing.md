# 313 — a schema-required, non-sensitive key is planted by nothing: the deploy dies at podman with "no such secret"

**Status:** implemented on `fix/secret-gate` and green in the VM
(`ok t490-secret-gate.sh`, `ok t120-deploy.sh`). **The decision, and where it
comes from:** a `@required`-not-`@sensitive` key is **not a credential** (spec
4: `@sensitive` is what marks a value one), so spec 5.3 step 9's mint — which
is for `@sensitive` keys and only those — does not reach it, and a minted
token would be the wrong value for a key like `LOG_LEVEL`. It is also not a
value the repository ships, so there is no default to take. **It is the
operator's to plant**, and the documented plant step is `weedr secret set`
(spec 6.2) — so the side implemented is the **refusal one-liner**: the gate
names the key (a `warning:` on an ungated track, a `blocked` gate with a
`[gate] reason` on a gated one) and `weedr service start` refuses with the
key and the command that plants it, on either track. The gate's own state is
unchanged — `not-required` on an ungated track is the track's difference
(spec 6.6 step 3) and it did not move.

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
