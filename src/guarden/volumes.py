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
empty directory: a container mounts it by a `Volume=` line naming that path —
there is no `.volume` unit (spec 6.3) — and the path has to resolve to the same
kind of thing on the create path and the fork path or a mounted bulk volume is
a mount of something else afterwards. The fork is ticket 70's; what belongs here
is that creation and creation-as-a-fork are the same call, so a later ticket
cannot get it wrong by writing a different one.

A configuration's name is opaque and nothing parses it (spec 8.1), because
workload and volume names may both contain `-`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from guarden import conf, errors, paths, snapper, tool

# The two kinds and the directories they live under are `paths`' to state (spec 2):
# `state/` and `bulk/` are split precisely so a snapshotted subvolume is never a
# parent of an unsnapshotted one, and that is a layout fact rather than a volume
# fact, so the constants live with the rest of the layout.
SUBVOLUME = paths.STATE
BULK = paths.BULK

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
        # The creation-time set is the same fixed set `soil storage` converges
        # (spec 8.1), and this one has to be here as much as there: snapper's
        # default is `yes`, and the distribution's `snapper-timeline.timer`
        # would start taking snapshots guarden never made the moment a service
        # was ingested -- before any storage apply reached the configuration.
        # The EROFS of 2026-10-12 was written by exactly such a snapshot.
        ("TIMELINE_CREATE", "no"),
        ("TIMELINE_LIMIT_HOURLY", "0"),
        ("TIMELINE_LIMIT_DAILY", f"0-{retention.keep_last}"),
        ("TIMELINE_LIMIT_WEEKLY", f"0-{retention.weekly}"),
        ("TIMELINE_LIMIT_MONTHLY", f"0-{retention.monthly}"),
        ("TIMELINE_LIMIT_QUARTERLY", f"0-{retention.quarterly}"),
        ("TIMELINE_LIMIT_YEARLY", "0"),
        ("NUMBER_LIMIT", NUMBER_LIMIT),
        ("NUMBER_LIMIT_IMPORTANT", NUMBER_LIMIT_IMPORTANT),
        ("FREE_LIMIT", percentage(retention.free_limit)),
    ]


def percentage(value: float) -> str:
    """One spelling for a percentage, whichever writer reaches it.

    `snapper set-config` compares strings, so `0.20` and `0.2` are different
    values to it -- and `soil storage --check` would report a staging volume
    it had converged itself as drifted, because the create path normalised
    through this function while the converge path read the row raw (measured
    and fixed 2026-10-12; the template's rows are plain TOML floats now, and
    both paths call this).
    """
    return repr(float(value)) if not float(value).is_integer() else str(int(value))


def create_subvolume(target, owner: tuple[int, int]) -> None:
    """One btrfs subvolume, owned by the service user. Never a plain directory.

    Idempotent, because ingest is a reconcile verb: the second ingest of a service
    whose volumes exist is the ordinary case, and `btrfs subvolume create` on a
    path that is already a subvolume answers "File exists" and exits 1. Ownership
    is still applied, so a re-ingest converges the owner too.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        tool.run(["btrfs", "subvolume", "create", str(target)])
    own(target, owner)


def create_state(
    name: str,
    vol: str,
    retention: Retention,
    owner: tuple[int, int],
    escaped_ref: str | None = None,
) -> str:
    """A subvolume and a snapper configuration of its own, named for this service.

    **The subvolume carries a payload directory, and the container mounts that
    rather than the subvolume** (ADR-0020). The payload is where the data
    lives, one level down, so the container never sees snapper's `.snapshots`
    subtree and the image's own recursive chown never reaches it.

    The payload is a plain directory inside the subvolume, and it is created
    here rather than by the container: the container's root is the service uid
    through `/etc/subuid`, so a directory the container has to create is a
    directory it may not be able to create.
    """
    target = paths.volume(name, SUBVOLUME, vol, escaped_ref)
    config = paths.snapper_config(name, vol, escaped_ref)
    create_subvolume(target, owner)
    if not snapper.configuration_exists(config):
        tool.run(["snapper", "--config", config, "create-config", str(target)])
    for key, value in canonical_values(retention):
        tool.run(["snapper", "--config", config, "set-config", f"{key}={value}"])
    _payload(name, vol, owner, escaped_ref)
    return config


def _payload(
    name: str, vol: str, owner: tuple[int, int], escaped_ref: str | None
) -> None:
    """The payload directory inside a `state` volume, and the one refusal that
    says the data is somewhere else (ADR-0020).

    **Three shapes, and only three.** A payload directory that is already
    there is the ordinary case -- the second ingest of a service whose volumes
    exist is the ordinary case, and the payload is what the first ingest
    created. A subvolume whose root holds nothing but snapper's own subtree is
    a volume that has never had data in it, and the payload is created empty.
    A subvolume whose root holds anything else is a volume whose data is at
    the ROOT, and that is the case the refusal is for.

    **The check comes before the payload is created**, and it comes whether or
    not a payload is already there: a volume with a payload AND something at
    its root has its data in two places, and only the payload is mounted.
    """
    subvolume = paths.volume(name, SUBVOLUME, vol, escaped_ref)
    payload = paths.mount_source(name, SUBVOLUME, vol, escaped_ref)
    if subvolume.is_dir():
        refuse_root_data(name, vol, escaped_ref)
    payload.mkdir(parents=True, exist_ok=True)
    own(payload, owner)


def refuse_root_data(name: str, vol: str, escaped_ref: str | None = None) -> None:
    """Refuse a `state` volume whose data is at the root, and say what to do
    (ADR-0020).

    **The refusal is one line and it moves nothing.** Guarden does not move
    the data down a level: a move renames live data under a running process, it
    cannot skip `.snapshots` without a second rule, and it is not atomic
    across a service's several volumes. The rule the spec already states for
    a newly declared volume is the same one here -- **the volume starts EMPTY
    and the operator moves the data across deliberately** -- and the refusal
    says so, because a refusal that names the volume and not the work leaves
    the operator believing the data followed the change.

    The exit is `1` and not `2`: the host is not in the state the request
    assumed (spec 1.2), and it is the same shape as every other "the host is
    not what you expected" answer.

    **The check is "is there data at the root", and not "is the payload
    there".** A volume with a payload and something else at its root is still a
    volume whose data is in two places, and the container would mount only the
    payload — so the data at the root would be invisible to the service and
    would still be walked by anything that chowns the whole volume. A volume
    whose root holds nothing but snapper's own subtree is the ordinary case
    and is silent.
    """
    subvolume = paths.volume(name, SUBVOLUME, vol, escaped_ref)
    payload = paths.mount_source(name, SUBVOLUME, vol, escaped_ref)
    if not subvolume.is_dir():
        return
    for entry in sorted(subvolume.iterdir()):
        if entry.name == paths.SNAPSHOTS or entry == payload:
            continue
        raise errors.GuardenError(
            f"the state volume {vol} of {name} holds data at the root of "
            f"{subvolume}, and guarden mounts the data one level down in "
            f"{payload} so that the container never sees snapper's "
            f"{paths.SNAPSHOTS} subtree (ADR-0020); stop the service and move "
            f"everything except {paths.SNAPSHOTS} into {payload} yourself -- the "
            f"volume starts EMPTY and the data does not follow the change",
            errors.HOST_NOT_AS_ASSUMED,
        )


def create_bulk(
    name: str, vol: str, owner: tuple[int, int], escaped_ref: str | None = None
) -> None:
    """A subvolume and **no** configuration: not snapshotted, not a fork source,
    and an empty subvolume after a fork."""
    create_subvolume(paths.volume(name, BULK, vol, escaped_ref), owner)


def own(target, owner: tuple[int, int]) -> None:
    """A clone or a subvolume handed to the service's user, `0700` to it.

    The `0700` is the isolation boundary rather than tidiness: a service's tree
    is not readable by any other unprivileged uid, which is why `stakes` cannot
    read a volume's size and asks `weedr service list --json` instead.
    """
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
