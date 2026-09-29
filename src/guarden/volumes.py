"""A service's volumes: a subvolume each, and a snapper configuration for the
state ones only.

spec 8.1 and ADR-0003. A `state` volume is snapshotted, a `bulk` volume is not,
and the difference is the whole reason they are **separate directories**
(`state/` and `bulk/`) rather than one list: a snapshotted tree and an
unsnapshotted one in the same directory is how an instance's volumes came to be
nested inside a snapshotted subvolume, which btrfs excludes from the parent
snapshot entirely — so the parent snapshotted cleanly, nightly, forever, while
containing no instance data at all, and the only symptom was an empty restore.

A `bulk` volume is a subvolume on **every** path, including a fork, and never an
empty directory: a container mounts a `.volume` unit, and that has to resolve to
the same kind of thing on the create path and the fork path or a mounted bulk
volume is a mount of something else afterwards. The fork is ticket 70's; what
belongs here is that creation and creation-as-a-fork are the same call, so a
later ticket cannot get it wrong by writing a different one.

A configuration's name is opaque and nothing parses it (spec 8.1), because
workload and volume names may both contain `-`.
"""

from __future__ import annotations

from dataclasses import dataclass

from guarden import conf, paths, tool

SUBVOLUME = "state"
BULK = "bulk"

EMPTY_PRE_POST_CLEANUP = "no"
NUMBER_MIN_AGE = "3600"
NUMBER_LIMIT = "2-10"
NUMBER_LIMIT_IMPORTANT = "8-12"
WEEKLY = 4
MONTHLY = 6
QUARTERLY = 2


@dataclass(frozen=True)
class Retention:
    """The two values that come from the track or the overrides, and the three
    buckets beside them that only the overrides can change."""

    keep_last: int
    free_limit: float
    weekly: int = WEEKLY
    monthly: int = MONTHLY
    quarterly: int = QUARTERLY


def canonical_values(retention: Retention) -> list[tuple[str, str]]:
    """The value set a state volume's configuration carries at creation.

    `TIMELINE_LIMIT_DAILY` and `FREE_LIMIT` come from the track or the service's
    `overrides.toml`; the rest is the fixed set `soil storage` converges into
    every configuration it can see (spec 8.1). `EMPTY_PRE_POST_CLEANUP=no` is in
    here because guarden only ever creates `single` snapshots and never a
    pre/post pair, so switching that cleaner off costs nothing.
    """
    return [
        ("EMPTY_PRE_POST_CLEANUP", EMPTY_PRE_POST_CLEANUP),
        ("NUMBER_MIN_AGE", NUMBER_MIN_AGE),
        ("NUMBER_CLEANUP", "yes"),
        ("TIMELINE_CLEANUP", "yes"),
        ("TIMELINE_LIMIT_HOURLY", "0"),
        ("TIMELINE_LIMIT_DAILY", f"0-{retention.keep_last}"),
        ("TIMELINE_LIMIT_WEEKLY", f"0-{retention.weekly}"),
        ("TIMELINE_LIMIT_MONTHLY", f"0-{retention.monthly}"),
        ("TIMELINE_LIMIT_QUARTERLY", f"0-{retention.quarterly}"),
        ("TIMELINE_LIMIT_YEARLY", "0"),
        ("NUMBER_LIMIT", NUMBER_LIMIT),
        ("NUMBER_LIMIT_IMPORTANT", NUMBER_LIMIT_IMPORTANT),
        ("FREE_LIMIT", _percentage(retention.free_limit)),
    ]


def _percentage(value: float) -> str:
    return repr(float(value)) if not float(value).is_integer() else str(int(value))


def create_subvolume(target, owner: tuple[int, int]) -> None:
    """One btrfs subvolume, owned by the service user. Never a plain directory."""
    target.parent.mkdir(parents=True, exist_ok=True)
    tool.run(["btrfs", "subvolume", "create", str(target)])
    _own(target, owner)


def create_state(
    name: str,
    vol: str,
    retention: Retention,
    owner: tuple[int, int],
    escaped_ref: str | None = None,
) -> str:
    """A subvolume and a snapper configuration of its own, named for this service."""
    target = paths.volume(name, SUBVOLUME, vol, escaped_ref)
    config = paths.snapper_config(name, vol, escaped_ref)
    create_subvolume(target, owner)
    tool.run(["snapper", "--config", config, "create-config", str(target)])
    for key, value in canonical_values(retention):
        tool.run(["snapper", "--config", config, "set-config", f"{key}={value}"])
    return config


def create_bulk(
    name: str, vol: str, owner: tuple[int, int], escaped_ref: str | None = None
) -> None:
    """A subvolume and **no** configuration: not snapshotted, not a fork source,
    and an empty subvolume after a fork."""
    create_subvolume(paths.volume(name, BULK, vol, escaped_ref), owner)


def _own(target, owner: tuple[int, int]) -> None:
    import os

    conf.set_owner(target, owner)
    os.chmod(target, 0o700)


def retention_from(track, overrides) -> Retention:
    return Retention(
        keep_last=overrides.keep_last_or(track.keep_last),
        free_limit=overrides.free_limit_or(track.free_limit),
        weekly=WEEKLY if overrides.weekly is None else overrides.weekly,
        monthly=MONTHLY if overrides.monthly is None else overrides.monthly,
        quarterly=QUARTERLY if overrides.quarterly is None else overrides.quarterly,
    )
