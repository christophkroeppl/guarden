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
value would hide exactly the condition this exists to catch.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from guarden import conf, credentials, errors, paths, registry, secretschema, users
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


def evaluate(service: str, schema: secretschema.Schema, gated: bool, now: str) -> Verdict:
    """The verdict for one service, and the lines a caller should print for it."""
    blocked: list[str] = []
    for key in schema.keys:
        if not key.required:
            continue
        stored = credentials.value(service, key.name)
        if stored is None or credentials.placeholder(key, stored) is not None:
            blocked.append(f"missing required key: {key.name}")
            continue
        why = credentials.placeholder(key, stored)
        if why:
            blocked.append(f"required key {key.name} {why}")
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
        )
    if blocked:
        return Verdict(state=BLOCKED, reason="; ".join(blocked))
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


def mint_generated(entry: registry.Registry, schema: secretschema.Schema, now: str) -> list[str]:
    """A value for every `@sensitive` key nothing has been planted for.

    spec 5.3 step 9, and only on a track with `gated = false`: a gated track gets
    none, because there a missing key is a gate failure and generating one would
    hide it. Minted once and stable until the service is removed — the registry's
    `[generated]` table is what makes that stable, and it is also the only record
    that the value was minted rather than planted.
    """
    minted: list[str] = []
    for key in schema.keys:
        if not key.sensitive or key.name in entry.generated:
            continue
        if credentials.planted(entry.service, key.name):
            continue
        credentials.plant(entry.service, key.name, credentials.generated_value())
        entry.generated[key.name] = now
        minted.append(key.name)
    return minted