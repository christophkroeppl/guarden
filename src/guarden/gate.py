"""The credential gate: a state, and the two tracks it has one for.

A **gate** is not a moment and not a refusal of a deploy (CONTEXT.md, spec 6.6).
A poke to a gated track with a missing credential creates the service, builds it,
installs its units and does **not** start the container; the deploy exits `0`,
because it did everything it was asked to, and `[gate] reason` in the registry says
why. An operator plants the credential and runs `weedr service start`, which
re-evaluates here every time.

**There are exactly two outcomes and no third.** On a track with `gated = true` a
required key that is missing, empty, still prefixed `EXAMPLE-` or still `changeme`
blocks: the verdict is `blocked` and the verb exits `1` naming the key, because it
was asked whether it could start and it cannot. On a track with `gated = false` the
same condition is one `warning:` line naming the key, the verdict is
`not-required`, and the start proceeds. There is no preview with an override and
nothing in guarden produces a fourth outcome.

**A service with no `[gate]` table has never been evaluated**, and that is `null`
in JSON rather than `ready`: a verdict nobody took is not a passing one.

The three states are the ones spec 3.4 records, and the two paths into them are the
two tracks. A gated track mints no value (spec 5.3 step 9) because a generated
value would hide exactly the condition this exists to catch — and a `via: tunnel`
edge plants nothing on either track for the same reason (ADR-0027).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from guarden import conf, credentials, errors, paths, registry, secretschema, unitsource, users
from guarden import manifest as manifest_mod

READY = "ready"
BLOCKED = "blocked"
NOT_REQUIRED = "not-required"

GUARDEN_GROUP = "guarden"

# A project that declares no `schema:` has no credential shape at all, and a file
# that is not there is not an error: `secretschema.read` says so, and this is the
# path it is asked about.
ABSENT = Path("/nonexistent/guarden/nothing")


@dataclass(frozen=True)
class Verdict:
    state: str
    reason: str | None
    warnings: tuple[str, ...] = ()
    # Every credential the service's units ask for and nothing has planted.
    # This is the list the verdict's state is computed FROM, and it is kept
    # because the two tracks answer it differently: a gated track blocks on it
    # (spec 6.6 step 3), and an ungated track records `not-required` and warns
    # — but a start on EITHER track cannot proceed past it, because the
    # podman secret the unit asks for does not exist and podman would refuse
    # the container with a raw `125 no such secret` (tickets 305 and 313).
    unsatisfied: tuple[str, ...] = ()


def unit_requests(service: str) -> list[str]:
    """Every credential the service's own units ask podman for.

    **The unit is the request, and the schema is not the only thing that can
    make one.** The renderer emits `Secret=<KEY>` for a `@sensitive` or
    `@required` key (spec 6.3), and a **template-created service has no schema
    at all** — a template ships quadlet files and nothing else — so its unit can
    name a key the manifest never declared. Nothing plants that key, podman
    refuses the start with a raw `125 no such secret`, and the operator gets a
    runtime error where spec 6.6 promises a gate state.

    So the gate's subject is the **set of requests the service's units make**,
    not the set of keys its schema declares. A key the units ask for and the
    schema does not declare is a request nobody can satisfy, and it is reported
    as one — the same "missing required key" the schema's own required key
    produces, so there is one answer and not two.

    The units are read from the service's own quadlet directory, which is
    where the install put them and where the start reads them from, so the
    gate and the start are asking the same question of the same files.
    """
    wanted: list[str] = []
    directory = paths.unit_dir(service)
    if not directory.is_dir():
        return wanted
    for path in sorted(directory.glob("*.container")):
        try:
            unit = unitsource.parse(path)
        except errors.GuardenError:
            continue
        for value in unit.get("Container", "Secret"):
            # `Secret=<KEY>,type=mount` — the key is the first comma-separated
            # field, and the type is podman's own spelling (spec 6.3).
            key = value.split(",", 1)[0].strip()
            if key and key not in wanted:
                wanted.append(key)
    return wanted


def evaluate(service: str, schema: secretschema.Schema, gated: bool, now: str) -> Verdict:
    """The verdict for one service, and the lines a caller should print for it."""
    blocked: list[str] = []
    declared = {key.name: key for key in schema.keys}
    # Every key the service's units ask for, whether or not the schema declares
    # it: the request is what podman will refuse, so the request is what the
    # gate has to answer for. A key the schema declares and the units do not
    # ask for is still a required key — the schema alone makes it one.
    asked: list[str] = []
    requested: set[str] = set()
    for key in unit_requests(service):
        requested.add(key)
        if key not in asked:
            asked.append(key)
    for key in schema.keys:
        if key.name not in asked:
            asked.append(key.name)
    unsatisfied: list[str] = []
    for name in asked:
        key = declared.get(name)
        # A key the units ask for and the schema does not declare is required
        # by the request alone: podman cannot resolve it from nothing, so
        # nothing but a planted value satisfies it.
        #
        # **And a request outranks an `@required=false`.** The schema can call a
        # key optional while the renderer still emits `Secret=<KEY>` for it —
        # `@sensitive` is enough, and `@defaultRequired=infer` with a bare
        # `// API_SECRET` gives a key that is sensitive and not required. podman
        # refuses that start with `125 no such secret` whatever the schema says,
        # so a gate that skipped it would report `ready` for a service that
        # cannot start. ADR-0027 makes it reachable: a `via: tunnel` edge plants
        # nothing and step 9 does not mint the key, so nothing satisfies a
        # request this loop had been passing over.
        if key is not None and not key.required and name not in requested:
            continue
        stored = credentials.value(service, name)
        if stored is None:
            blocked.append(f"missing required key: {name}")
            unsatisfied.append(name)
            continue
        if key is None:
            continue
        why = credentials.placeholder(key, stored)
        if why:
            blocked.append(f"required key {name} {why}")
            unsatisfied.append(name)
    if not gated:
        # The whole difference between the two tracks: a warning naming the key,
        # and a start that proceeds. `reason` is absent rather than empty, so a
        # reader can tell a record of a verdict from a verdict nobody took.
        return Verdict(
            state=NOT_REQUIRED,
            reason=None,
            warnings=tuple(
                errors.warn(f"{service}: {reason}, and the track is not gated")
                for reason in blocked
            ),
            unsatisfied=tuple(unsatisfied),
        )
    if blocked:
        return Verdict(
            state=BLOCKED, reason="; ".join(blocked), unsatisfied=tuple(unsatisfied)
        )
    return Verdict(state=READY, reason=None)


def document(verdict: Verdict, now: str) -> dict:
    """The `[gate]` table, which is the whole of what a gate is allowed to write."""
    table: dict = {"state": verdict.state}
    if verdict.state == BLOCKED and verdict.reason:
        table["reason"] = verdict.reason
    table["checked"] = now
    return table


def write(entry: registry.Registry, verdict: Verdict, now: str) -> None:
    """Write the verdict, and nothing else, under the registry lock."""
    entry.gate = document(verdict, now)
    with conf.lock("registry"):
        registry.save(entry, (0, users.group_id(GUARDEN_GROUP)))


def schema_for(service: str) -> secretschema.Schema:
    """The service's own schema, from the copy in its home.

    A poke's staging tree is removed once the deploy returns, so the home is the
    only place the shape of a service's credentials outlives the deploy that
    carried it, and it is the same file the renderer reads.
    """
    manifest_path = paths.manifest_in_home(service)
    if not manifest_path.is_file():
        return secretschema.Schema(path=ABSENT)
    manifest = manifest_mod.read(manifest_path)
    if not manifest.schema:
        return secretschema.Schema(path=ABSENT)
    return secretschema.read(paths.service_home(service) / manifest.schema)


def mint_generated(entry: registry.Registry, schema: secretschema.Schema, now: str,
                   external: tuple[str, ...] = ()) -> list[str]:
    """A value for every `@sensitive` key nothing has been planted for.

    spec 5.3 step 9, and only on a track with `gated = false`: a gated track gets
    none, because there a missing key is a gate failure and generating one would
    hide it. Minted once and stable until the service is removed — the registry's
    `[generated]` table is what makes that stable, and it is also the only record
    that the value was minted rather than planted.

    **`external` names the keys whose value is issued somewhere else** — a `via:
    tunnel` edge's vendor token (ADR-0027). Minting one here would plant exactly
    the unusable value the edge stopped planting, reached through the schema
    instead of the edge, so those keys are left unsatisfied for an operator.
    """
    minted: list[str] = []
    issued = set(external)
    for key in schema.keys:
        if not key.sensitive or key.name in entry.generated or key.name in issued:
            continue
        if credentials.planted(entry.service, key.name):
            continue
        credentials.plant(entry.service, key.name, credentials.generated_value())
        entry.generated[key.name] = now
        minted.append(key.name)
    return minted