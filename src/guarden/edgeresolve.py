"""The concrete service a `needs:` entry's logical provider name stands for.

Two tables, and the order between them is this module's whole subject:

    [edge_overrides]        /etc/guarden/overrides.toml    the operator's pin
    [providers.<track>]     /etc/guarden/guarden.toml      the per-track default
    (nothing)                                             the name as written

`guarden.toml` is the common case: every environment gets the right provider
with no operator action. `overrides.toml` is the exception, and it has to win
over the track's own default because that is the only reason to write one — a
staging host that points at the production database for a read-only replica, a
migration held still on one box. An unmapped name is the name as written, which
is why a manifest naming a full service name (`postgres-production`) already
names its provider and needs no entry in either table.

**One function, because the mutator and the renderer must agree.** `edges`
keys the registry record by the concrete name and `render.edge_publications`
looks it up by the same name, so a second copy of this precedence would be a
second answer to which service an edge dials. `resolve` is that one answer.

**The file is written by no program but `soil install`, and only when absent.**
An operator's pin is the thing the file exists to hold, so a converge that
rewrote it would lose the one edit that matters. An absent file is an empty
table, not a failure: `soil install` seeds it once so the path exists for an
operator to edit. Every read is a read and takes no lock (spec 3.5).

**`0640 root:guarden`, and the group bit is load-bearing.** The unprivileged
programs resolve too — `loom` runs as `guarden` and reads this file to write
`AddHost=` — so a `0640 root:root` would make the renderer refuse every host it
had been asked to override.
"""

from __future__ import annotations

from pathlib import Path

from guarden import conf, errors, names, paths

# The one table, and nothing else. A closed key set rather than an open one for
# the reason `overrides.py` gives: a silently ignored key is a pin an operator
# believes is in effect.
TABLE = "edge_overrides"


def resolve(config, environment: str, logical: str) -> str:
    """`logical` as this host resolves it: the pin, else the track's, else itself.

    `environment` is the consumer's track name, because the `[providers]` table
    is keyed by track and a service's own track is what its environment is.
    """
    override = _table(paths.OVERRIDES_TOML).get(logical)
    if override is not None:
        return override
    return config.resolve_provider(environment, logical)


def _table(where: Path) -> dict[str, str]:
    """The `[edge_overrides]` table. An absent file is empty; a bad one is exit 1.

    Both sides are service names and both are validated as such, because both
    sides are compared against service names: a key that is not one can never
    match, and a value that is not one can never resolve. A non-string value is
    named as the shape it is, which is what `config._providers` does for the
    table above it.
    """
    document = conf.read_toml(where)
    for key in sorted(set(document) - {TABLE}):
        raise errors.GuardenError(f"{where}: unknown key {key!r}", errors.HOST_NOT_AS_ASSUMED)
    table = document.get(TABLE, {})
    if not isinstance(table, dict):
        raise errors.GuardenError(f"{where}: [{TABLE}] is not a table", errors.HOST_NOT_AS_ASSUMED)
    out: dict[str, str] = {}
    for logical, concrete in table.items():
        if not isinstance(logical, str) or not isinstance(concrete, str):
            raise errors.GuardenError(
                f"{where}: [{TABLE}] maps a logical provider name to a service name",
                errors.HOST_NOT_AS_ASSUMED,
            )
        try:
            names.validate(logical, "an edge override's logical provider name")
            names.validate(concrete, f"the service name {logical!r} is overridden to")
        except errors.GuardenError:
            raise errors.GuardenError(
                f"{where}: [{TABLE}] maps a logical provider name to a service name",
                errors.HOST_NOT_AS_ASSUMED,
            ) from None
        out[logical] = concrete
    return out
