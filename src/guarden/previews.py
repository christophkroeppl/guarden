"""Previews: instances of one service, forked, capped, and removed by one verb.

spec 5.2, 5.3 step 12 and 9. Everything about a preview is a fact about a
workload rather than about a repository, and four of those facts are the whole
of this module.

**A ref is raw on the way in and escaped on the way to disk.** `names.systemd_escape`
turns `/` into `-` and a literal `-` into `\\x2d`, so `feature/x` and `feature-x`
are `feature-x` and `feature\\x2dx` and never collide. No verb ever shows the
escaped form: every caller in this package passes the raw `resolved.ref` and gets
the raw ref back in every line it prints.

**Lineage is the track's `fork_from` field.** Nothing here branches on the words
`production`, `staging` and `preview`; a fourth track forking from a fourth row
is a configuration change.

**The cap is counted per service.** `record.instances` belongs to one registry
entry and one entry is one workload on one track, so two repositories declaring
the same project name cannot spend each other's budget. The eviction runs to
completion and the new entry is written inside one `preview-cap` hold, before
`create` touches the volumes, so the count is never observable above the cap and
a failure part-way through creation cannot leave it there.

**Bulk volumes are empty subvolumes on every path.** They are created by
`volumes.create_bulk`, which is `btrfs subvolume create` and never a `mkdir`, and
the fork does not touch them. A plain directory here is a real defect that looks
correct.
"""

from __future__ import annotations

import shutil
import time
from datetime import UTC, datetime, timedelta

from guarden import conf, errors, names, paths, registry, users

# A stamp tied with one already held orders the cap by spelling, not by age.
_STAMP = "%Y-%m-%dT%H:%M:%S.%fZ"
_SECONDS = "%Y-%m-%dT%H:%M:%SZ"
_ONE_MICROSECOND = timedelta(microseconds=1)


def moment() -> str:
    """The instant an instance is created, at microsecond resolution."""
    return time.strftime(_STAMP, time.gmtime())


def stamp(now: str, held) -> str:
    """`now`, moved forward until it is the newest `created` this service holds.

    An unparseable `created` — a hand-edited registry — is ignored rather than
    fatal: that instance keeps whatever order it already had, and the new one
    takes `now`.
    """
    wanted = _parse(now)
    if wanted is None:
        return now
    newest = max(
        (seen for seen in (_parse(item.created) for item in held) if seen is not None),
        default=None,
    )
    if newest is not None and newest >= wanted:
        wanted = newest + _ONE_MICROSECOND
    return wanted.strftime(_STAMP)


def _age(instance):
    """`created` as an instant: `'.'` sorts before `'Z'`, so strings invert the age."""
    return _parse(instance.created) or datetime.max.replace(tzinfo=UTC)


def _parse(value: str):
    try:
        return datetime.strptime(value, _STAMP).replace(tzinfo=UTC)
    except ValueError:
        pass
    try:
        return datetime.strptime(value, _SECONDS).replace(tzinfo=UTC)
    except ValueError:
        return None


def escaped(resolved) -> str:
    """The instance's directory key, from the raw ref and never shown to a caller."""
    return str(names.systemd_escape(str(resolved.ref)))


def admit(resolved, record, now: str) -> list[str]:
    """spec 9: hold the cap for one service, evicting the oldest **first**.

    One `preview-cap` hold covers the counting, every eviction and the new
    instance's own entry, so a concurrent create of the same service waits here
    rather than racing the count. `registry` is taken first because that is the
    order every other holder in this package takes it in.
    """
    cap = resolved.track.cap
    if cap is None or cap < 1:
        raise errors.GuardenError(
            f"the {resolved.track.name!r} track carries cap={cap}, and a cap below one "
            f"bounds nothing",
            errors.HOST_NOT_AS_ASSUMED,
        )
    with conf.lock("registry", "preview-cap"):
        printed: list[str] = []
        while len(record.instances) + 1 > cap:
            oldest = min(
                record.instances.values(), key=lambda item: (_age(item), item.escaped_ref)
            )
            printed += forget(
                names.Resolved(
                    name=resolved.name,
                    track=resolved.track,
                    ref=oldest.ref,
                    escaped_ref=oldest.escaped_ref,
                    defaulted=resolved.defaulted,
                ),
                record,
            )
        record.instances[escaped(resolved)] = registry.Instance(
            ref=str(resolved.ref),
            escaped_ref=escaped(resolved),
            created=stamp(now, tuple(record.instances.values())),
        )
        registry.save(record, _root_owner())
    return printed


def register(resolved, record, now: str) -> None:
    """The first instance of a service that is itself new.

    No cap arithmetic and no eviction: the service holds no instances and `cap` is
    at least one, so there is nothing to count and nothing to evict. The entry is
    still written **here** and not at the end of `create`, because the fork in
    spec 5.3 step 12 reads the instance out of the registry to record its seed.
    """
    record.instances[escaped(resolved)] = registry.Instance(
        ref=str(resolved.ref), escaped_ref=escaped(resolved), created=now
    )


def forget(resolved, record) -> list[str]:
    """spec 5.3: what one instance's removal does, and the lines that say so.

    Both callers come through here — the cap's eviction above and
    `weedr service remove <name>/<ref>` — because a second removal path for the
    same event is a second thing to get wrong, and because the journal then shows
    the same verb the operator would have typed. The units are stopped before the
    tree moves, and the seed is released by *naming it no more*: `stakes` derives
    the mark from every seed any registry holds, so a sibling still forked from
    the same snapshot keeps it and nothing here touches a snapshot.
    """
    instance = instance_of(resolved, record)
    key = escaped(resolved)

    printed = [f"removed the instance {resolved.ref} of {resolved.name}"]
    _stop(resolved.name, key)
    _drop(paths.instance_tree(resolved.name, key))
    _drop(paths.instance_home(resolved.name, key))
    del record.instances[key]

    released = ", ".join(
        f"{container}={port}" for container, port in sorted(instance.publication.items())
    )
    printed.append(f"released the instance's publications ({released or 'none'})")
    seeds = ", ".join(
        f"{volume}={seed.service}:{seed.volume}@{seed.number}"
        for volume, seed in sorted(instance.seed.items())
    )
    printed.append(f"released the seed ({seeds or 'none'})")
    return printed


def instance_of(resolved, record):
    if resolved.track.kind != "instance":
        raise errors.GuardenError(
            f"{resolved.name} is on track {resolved.track.name!r}, which is kind "
            f'"{resolved.track.kind}", so it has no instances'
        )
    instance = record.instances.get(escaped(resolved))
    if instance is None:
        raise errors.GuardenError(
            f"{resolved.name} has no instance {resolved.ref!r}", errors.HOST_NOT_AS_ASSUMED
        )
    return instance


def _root_owner() -> tuple[int, int]:
    return (0, users.group_id("guarden"))


# `service` imports this module, so importing it at module scope is a cycle.
def _stop(name: str, key: str) -> None:
    from guarden import service

    service.stop_units(name, key)


def _drop(path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()