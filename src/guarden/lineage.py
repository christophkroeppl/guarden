"""Snapshots, forks and rollbacks: the verbs that move a service's data around.

spec 8.2, 8.3, 8.4 and 8.6, and ADR-0007. Everything here is a deliberate act by
root, and the parts that are easy to get wrong are the parts that fail silently
otherwise.

**Two kinds of snapshot, and the tag is the whole difference.** A **routine**
one — what `weedr service snapshot` and the nightly `--all` make — is
`timeline`-tagged and lives by the volume's **ladder**. An **on-demand** one — a
fork source, or an operator's "before the risky change" — is `number`-tagged and
is what the marks protect. **There is no flag that chooses the kind**, because
the kind follows from why the snapshot was taken, and that is what decides who
may delete it later. A routine snapshot is **never** marked: a mark is only ever
about an on-demand snapshot.

**A snapshot is a complete set of per-volume numbers, and the set is validated
before anything is changed.** btrfs has no atomic multi-subvolume snapshot
primitive — one destination name and one source per ioctl — so the volumes in
one snapshot are each consistent and may be microseconds apart. That skew is a
cost the particular service judges; what a fork or a rollback must not do is
assemble a set from some volumes at one instant and the rest at another. A
volume with no snapshot is exit `1` naming it, with nothing moved.

**A time selects a set and a number never does.** `weedr service rollback --to`
and `weedr service fork --from <service>@<time>` both take a time, because a
service with several state volumes has a *different* number in each
configuration and no single number names the whole set.

**A fork pins the source for the duration by creating its pin file** — not by
taking a lock and not with a counter. The reconciler therefore cannot unmark the
source underneath the clone and snapper's cleanup cannot run against it, and the
pin is released on every path out of the verb, so a failed clone leaves nothing
pinned forever.

**A failed fork restores what it moved and starts the target.** A service left
holding half its old volumes and half its new ones is worse than a failed fork,
so every subvolume moved aside is put back on any error and the units come back
up.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from guarden import (
    conf,
    errors,
    names,
    paths,
    pins,
    registry,
    service,
    snapper,
    tool,
    users,
    volumes,
)
from guarden import snapshotid as ids

# The two kinds, as snapper's cleanup tag. Nothing else distinguishes them.
ROUTINE = "timeline"
ON_DEMAND = "number"

# What a state volume's snapper configuration lives in, and what `snapper
# create-config` makes of it: a btrfs subvolume, `root:root`, `0750`.
SNAPSHOTS_DIRECTORY = ".snapshots"
SNAPSHOTS_MODE = 0o750


@dataclass
class Plan:
    """One target state volume, where its source snapshot is, and whether it has one."""

    volume: str
    config: str
    available: bool
    number: int | None = None
    source_service: str = ""


@dataclass
class Swap:
    """What one swap moved, so a failure can put it back."""

    moved: list[tuple[Path, Path]] = field(default_factory=list)
    made: list[Path] = field(default_factory=list)


def _stamp(now: str) -> str:
    return now.replace("-", "").replace(":", "").replace("T", "-")


def _moment() -> datetime:
    return datetime.now(UTC)


def _state(record) -> list[registry.Volume]:
    return [volume for volume in record.volume_list() if volume.kind == paths.STATE]


def _bulk(record) -> list[registry.Volume]:
    return [volume for volume in record.volume_list() if volume.kind == paths.BULK]


def _owner(record) -> tuple[int, int]:
    entry = users.passwd_entries().get(record.service)
    if entry is None:
        raise errors.GuardenError(
            f"{record.service} has no passwd entry, so its volumes have nobody to own them",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return entry


def _root_owner() -> tuple[int, int]:
    return (0, users.group_id(service.GUARDEN_GROUP))


def _save(record) -> None:
    with conf.lock("registry"):
        registry.save(record, _root_owner())


# --------------------------------------------------------------------------
# weedr service snapshot
# --------------------------------------------------------------------------


def snapshot(record, now: str) -> list[str]:
    """One **routine** snapshot per state volume, taken while the service runs.

    It does not stop the service, does not lock, and does not wait: a btrfs
    subvolume snapshot is atomic, so each volume is consistent as of that instant
    and the service's engine recovers from the clone. A routine snapshot is
    never marked, and the number it produced is recorded so an operator can ask
    `weedr service list --json` what the newest one is.
    """
    lines: list[str] = []
    state = _state(record)
    if not state:
        lines.append(f"skipped {record.service}: no state volume")
    for volume in state:
        config = volume.config or paths.snapper_config(record.service, volume.name)
        snapper.create(config, f"guarden routine {now}", ROUTINE)
        number = snapper.newest_number(config)
        if number is None:
            raise errors.GuardenError(
                f"snapper took a snapshot of {config} and will not list it, so the number "
                f"recorded for {record.service}:{volume.name} would be a guess",
                errors.HOST_NOT_AS_ASSUMED,
            )
        record.volumes[volume.name].snapshots = number
        lines.append(f"snapshotted {ids.format_id(record.service, volume.name, number)}")
    for volume in _bulk(record):
        # Named rather than passed over in silence: "skipped" is the word, and a
        # bulk volume's whole meaning is that nothing snapshots it.
        lines.append(f"skipped the bulk volume {volume.name} of {record.service}")
    return lines


def snapshot_all(now: str) -> list[str]:
    """Every service with a state volume, in name order, and what it skipped.

    One command for the whole host, because the nightly timer is **one timer**
    (spec 6.9): a per-service timer is a unit to install, a timer to re-arm and
    something to forget to remove.
    """
    lines: list[str] = []
    for name in registry.names():
        record = registry.load(name)
        if record is None:
            continue
        lines.extend(snapshot(record, now))
        _save(record)
    return lines


# --------------------------------------------------------------------------
# the source a fork reads from
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Source:
    """Where a fork reads from, and up to when."""

    service: str
    when: datetime | None = None


def parse_source(value: str) -> Source:
    """`--from <service>[@<time>]`, and the `@<time>` is a **time**.

    spec 8.4 step 1: the source snapshot is "the one at or before the
    `--from <service>@<timestamp>` time", and §8.6 gives the reason a number is
    not accepted in its place — a service with several state volumes has a
    different number in each configuration, and no single number names the whole
    set. A bare number is therefore rejected rather than resolved to seconds
    since the epoch, which would answer `1970-01-01T00:00:41Z` with a confident
    and wrong set. (spec 8.4's own synopsis writes `@<number>`, and
    docs/sysadmin.md repeats it; this is the step-1 reading and the §8.6 rule,
    which agree with each other and not with the synopsis.)
    """
    service_name, at, part = value.partition("@")
    if not at:
        return Source(service=names.validate(service_name, "--from service"))
    if not part:
        raise errors.GuardenError(f"--from {value!r} has an '@' and nothing after it")
    when = snapper.moment_of(part)
    if when is None:
        raise errors.GuardenError(
            f"--from {value!r} names the moment {part!r}, which is not a time. A number "
            f"never names a set, because a service with several state volumes has a "
            f"different snapshot number in each configuration; write the time instead, "
            f"as 2026-09-29T18:03:11Z"
        )
    return Source(service=names.validate(service_name, "--from service"), when=when)


def lineage_of(resolved) -> Source:
    """The source a fork takes when `--from` is absent, from the track's row.

    spec 8.3: lineage is `fork_from`, a **field on the track**, and never the
    track's name. Nothing in guarden branches on the words `production`,
    `staging` and `preview`, so a fourth track forking from a fourth row is a
    configuration change and not a change to this file. A track with an empty
    `fork_from` starts empty, which is what makes a production service unable to
    fork from staging unless an operator types it.
    """
    fork_from = resolved.track.fork_from
    if not fork_from:
        raise errors.GuardenError(
            f"the {resolved.track.name!r} track has an empty fork_from, so it starts empty; "
            f"an operator who wants a fork anyway names the source with --from, which is "
            f"root only and off the guarden rule",
            errors.HOST_NOT_AS_ASSUMED,
        )
    workload = names.workload_of(resolved.name, resolved.track.name)
    return Source(service=f"{workload}-{fork_from}")


# --------------------------------------------------------------------------
# weedr service fork
# --------------------------------------------------------------------------


def fork(resolved, source: Source, now: str) -> list[str]:
    target = _target_of(resolved)
    state = _state(target)
    if not state:
        raise errors.GuardenError(
            f"{resolved.name} declares no state volume, so there is nothing to fork; a "
            f"bulk volume is created empty and is never a fork source"
        )

    # Validate the complete set **before** anything is changed. A partial set is
    # refused with the volumes named, and the target is left untouched.
    plan = _plan(target, source, state, _recorded_seed(target, resolved.escaped_ref), now)
    wanted = _ids(plan)

    # Step 2: the pin, created before a subvolume moves. It is released on every
    # path out of here, so a failed clone leaves nothing pinned forever.
    for item in wanted:
        pins.write(item, f"held for a fork of {resolved.name}")
    try:
        # `deploy-<service>` bounds the swap and is released before the registry is
        # written, because the lock order puts `registry` first and holding both
        # would make every deploy of every service serialise on one file. The seed
        # is a record of what was just cloned, not part of the swap, so a second
        # deploy interleaving here costs a duplicate fork and nothing else.
        with conf.lock(f"deploy-{resolved.name}"):
            lines = _swap(resolved, target, state, plan, now)
    finally:
        for item in wanted:
            pins.remove(item)
    _record_seed(resolved, target, plan)
    lines.insert(0, f"forked {resolved.name} from {source.service}")
    return lines


def _target_of(resolved):
    target = registry.load(resolved.name)
    if target is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so there is nothing to do",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return target


def _plan(
    target, source: Source, state: list[registry.Volume], seed: dict, now: str
) -> list[Plan]:
    """Resolve every target state volume against the source, or explain why not.

    The source's own registry decides which volumes it has, and a target volume
    the source does not declare resolves to nothing. A source with a volume but
    no snapshot gets **one taken** — an on-demand, `number`-tagged snapshot,
    which is what makes it protectable by a mark and is not a routine snapshot
    and does not go in the ladder.
    """
    source_record = registry.load(source.service)
    if source_record is None:
        raise errors.GuardenError(
            f"the fork source {source.service} has no registry entry",
            errors.HOST_NOT_AS_ASSUMED,
        )
    available = {volume.name for volume in _state(source_record)}
    moment = source.when or _moment()
    plan: list[Plan] = []
    for volume in state:
        config = paths.snapper_config(source.service, volume.name)
        entry = Plan(
            volume=volume.name, config=config, available=volume.name in available
        )
        if not entry.available:
            plan.append(entry)
            continue
        entry.source_service = source.service
        recorded = seed.get(volume.name)
        if source.when is not None:
            entry.number = snapper.newest_at_or_before(config, moment)
        else:
            entry.number = _newest_or_take(config, recorded, source.service, now)
        plan.append(entry)
    return plan


def _newest_or_take(config: str, recorded, source: str, now: str) -> int | None:
    """The source's newest snapshot, taking one first when it is not fresh enough.

    spec 8.5: a fork takes a snapshot when the source has none newer than the
    target's recorded seed, so the base is a fresh `number`-tagged one and the
    mark has something to protect. A service with no recorded seed takes the
    source's newest, and a source with no snapshots at all is the case that takes
    one.

    The comparison is only made against a seed of the **same** source and volume:
    a recorded seed names a snapshot in somebody else's configuration, and its
    number there says nothing about how fresh this one is.
    """
    newest = snapper.newest_number(config)
    stale = (
        recorded is not None
        and recorded.service == source
        and recorded.volume == config.rsplit("-", 1)[-1]
    )
    if newest is not None and (not stale or newest > recorded.number):
        return newest
    snapper.create(config, f"guarden fork source {now}", ON_DEMAND)
    return snapper.newest_number(config)


def _ids(plan: list[Plan]) -> list[ids.SnapshotId]:
    return [
        ids.SnapshotId(entry.source_service, entry.volume, entry.number)
        for entry in plan
        if entry.number
    ]


def _validate(plan: list[Plan], name: str) -> None:
    """The refusal that changes nothing, naming every volume without a snapshot."""
    missing = [entry.volume for entry in plan if not entry.number]
    if not missing:
        return
    absent = ", ".join(
        f"{entry.volume}"
        + (
            ""
            if entry.available
            else f" (not declared by {entry.config.rsplit('-', 1)[0]!r})"
        )
        for entry in plan
        if not entry.number
    )
    resolved = ", ".join(
        f"{entry.volume}@{entry.number}" for entry in plan if entry.number
    )
    raise errors.GuardenError(
        f"the snapshot set for {name} is incomplete: no snapshot for {absent}; the rest "
        f"resolved to [{resolved}] and nothing was changed",
        errors.HOST_NOT_AS_ASSUMED,
    )


def _recorded_seed(target, escaped: str | None) -> dict:
    if escaped:
        instance = target.instances.get(escaped)
        return dict(instance.seed) if instance else {}
    return dict(target.seed)


# --------------------------------------------------------------------------
# the swap, shared by fork and rollback
# --------------------------------------------------------------------------


def _swap(
    resolved,
    target,
    state: list[registry.Volume],
    plan: list[Plan],
    now: str,
) -> list[str]:
    """Stop, move aside, clone, record, start — and put it all back on error.

    The ordering is spec 8.4's: the units are stopped **before** a subvolume is
    renamed, because a running container writing into a subvolume that is being
    moved is a data problem and not a cosmetic one.
    """
    _validate(plan, resolved.name)
    escaped = resolved.escaped_ref
    owner = _owner(target)
    stamp = _stamp(now)

    service.stop_units(resolved.name, escaped)
    # Bound before the first move, so the handler below is correct when the very
    # first rename fails: an unbound name in the error path is a traceback instead
    # of the diagnostic, and the traceback is what an operator sees at three in the
    # morning with a service stopped.
    swap = Swap()
    try:
        swap = _move_aside(resolved, state, _bulk(target), escaped, stamp)
        for volume in state:
            entry = next((item for item in plan if item.volume == volume.name), None)
            if entry is None or not entry.number:
                continue
            live = paths.volume(resolved.name, volume.kind, volume.name, escaped)
            _clone(
                _where_it_lives_now(
                    paths.snapshot(entry.source_service, volume.name, entry.number), swap
                ),
                live,
                owner,
            )
            swap.made.append(live)
        # A bulk volume is a subvolume on **every** path, the fork included, and
        # it is **empty**: a copy as of an instant is not reproducible afterwards,
        # and two targets that quietly disagreed would be worse than two empty
        # ones. The old one is moved aside rather than deleted, so nothing here
        # destroys data and the verb is not `weedr service purge` with extra
        # steps.
        for volume in _bulk(target):
            volumes.create_bulk(resolved.name, volume.name, owner, escaped)
            swap.made.append(paths.volume(resolved.name, volume.kind, volume.name, escaped))
        # **Inside** the try, because a fork that cannot start what it just built
        # has not succeeded, and a fork that fails leaves nothing behind. The start
        # used to sit below this `except`, so a target whose unit would not load
        # exited with the volumes moved aside and the tree half-swapped — the one
        # outcome ticket 70 names as a failure (spec §8.3).
        service.start_units(resolved.name, escaped)
    except BaseException:
        _undo(swap, resolved, escaped)
        raise
    return _swap_lines(resolved, plan)


def _where_it_lives_now(snapshot: Path, swap: Swap) -> Path:
    """A snapshot that lived inside a subvolume this swap moved aside.

    A service's own snapshot history is **inside** the volume snapper snapshots —
    `.snapshots/<number>/snapshot` under the volume — so a rollback's source is
    moved aside along with the live data and the path it was resolved at no longer
    exists. The moved-aside copy is the same bytes on the same filesystem, so the
    clone is still copy-on-write and still a constant-time operation; only the
    path changes. A fork's source is a different service's tree and is not
    affected, which is why this is a rewrite and not an ordering change.
    """
    for live, aside in swap.moved:
        if snapshot == live or live in snapshot.parents:
            return aside / snapshot.relative_to(live)
    return snapshot


def _move_aside(resolved, state, bulk, escaped: str | None, stamp: str) -> Swap:
    """Every subvolume out of the way before any clone lands, in one pass.

    Moving them all aside **before** cloning anything is what makes the failure
    path a restore rather than a merge: at no point are two different instants
    live under the same names.
    """
    swap = Swap()
    for volume in [*state, *bulk]:
        live = paths.volume(resolved.name, volume.kind, volume.name, escaped)
        if not live.exists():
            continue
        aside = _free_aside(live, stamp)
        os.rename(live, aside)
        swap.moved.append((live, aside))
    return swap


def _free_aside(live: Path, stamp: str) -> Path:
    """`<volume>.replaced.<timestamp>`, and never a name already in the way.

    Two forks of one service inside the same second, or a restore followed by a
    fork in the same second, would otherwise rename a directory onto a
    non-empty one and fail — which is safe but wrong, because the verb is
    refusing to do something it could do. Nothing is ever overwritten: the
    counter makes a new name, and the earlier one is exactly as recoverable as it
    was.
    """
    candidate = live.with_name(f"{live.name}.replaced.{stamp}")
    counter = 0
    while candidate.exists():
        counter += 1
        candidate = live.with_name(f"{live.name}.replaced.{stamp}-{counter}")
    return candidate


def _undo(swap: Swap, resolved, escaped: str | None) -> None:
    for made in swap.made:
        _remove_tree(made)
    for live, aside in swap.moved:
        if aside.exists() and not live.exists():
            os.rename(aside, live)
    # Best effort, and deliberately so. This runs while an exception from the
    # caller is already propagating, and the start is the very thing that failed
    # in the case that matters — raising here would replace a diagnostic naming
    # what went wrong with one naming the unwind, which is the wrong way round.
    try:
        service.start_units(resolved.name, escaped)
    except Exception:
        pass


def _remove_tree(path: Path) -> None:
    shutil.rmtree(path, ignore_errors=True)


def _clone(source: Path, target: Path, owner: tuple[int, int]) -> None:
    """The copy-on-write clone, the read-only flag cleared, the owner set, and the
    volume's `.snapshots` made a subvolume again.

    `btrfs property set <path> ro false` needs btrfs-progs 5.14 or later, and the
    version is **checked and reported, not worked around**: a fork that left the
    clone read-only would be a service that starts and cannot write. The clone is
    the buffer, so an unmodified block costs no space and the source snapshot is
    never written to.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    tool.run(["btrfs", "subvolume", "snapshot", str(source), str(target)])
    tool.run(["btrfs", "property", "set", str(target), "ro", "false"])
    volumes.own(target, owner)
    _snapshots_subvolume(target)


def _snapshots_subvolume(volume: Path) -> None:
    """The volume's `.snapshots` as a btrfs subvolume again, which a clone is not.

    **A btrfs subvolume snapshot does not carry a nested subvolume.** The clone of
    a snapshot therefore arrives holding an **empty plain directory** named
    `.snapshots`, and snapper refuses the configuration on the next command with
    `IO Error (.snapshots is not a btrfs subvolume).` — measured, and the effect is
    that a service nobody had forked from can be snapshotted and a service that
    has been forked cannot, which is the opposite of what a fork is for.

    `snapper create-config` is what makes one, so this makes the same thing: a
    subvolume, `root:root`, `0750`, which is what snapper checks for and what it
    creates. The plain directory is removed with `rmdir`, which removes an empty
    directory or nothing — there is no path here that deletes data, and a
    non-empty one is left alone rather than forced.
    """
    directory = volume / SNAPSHOTS_DIRECTORY
    if not directory.is_dir():
        return
    if tool.call(["btrfs", "subvolume", "show", str(directory)]).returncode == 0:
        return
    directory.rmdir()
    tool.run(["btrfs", "subvolume", "create", str(directory)])
    conf.set_owner(directory, (0, 0))
    os.chmod(directory, SNAPSHOTS_MODE)


def _record_seed(resolved, target, plan: list[Plan]) -> None:
    """Step 7: the seed, per state volume, from the source it was cloned from.

    The snapshot is the **source's** — that is the one that has to survive, and
    the one `stakes list` reports as protected because a service names it here.
    """
    seed = {
        entry.volume: registry.Seed(
            service=entry.source_service, volume=entry.volume, number=entry.number
        )
        for entry in plan
        if entry.number
    }
    escaped = resolved.escaped_ref
    if escaped:
        instance = target.instances.get(escaped)
        if instance is None:
            raise errors.GuardenError(
                f"{resolved.name} has no instance {resolved.ref!r}", errors.HOST_NOT_AS_ASSUMED
            )
        instance.seed = seed
    else:
        target.seed = seed
    _save(target)


def _swap_lines(resolved, plan: list[Plan]) -> list[str]:
    return [
        f"cloned {entry.source_service}:{entry.volume}@{entry.number}"
        for entry in plan
        if entry.number
    ]


def seed_instance(resolved, now: str) -> list[str]:
    """The fork an instance's creation makes, from the track's `fork_from` row.

    spec 5.3 step 12. Not `fork()`: there is nothing to move aside and nothing to
    start, because the volumes were created seconds ago and no unit names them
    yet. Takes no lock, because whoever deploys an instance already holds
    `deploy-<service>-<escaped-ref>` in the process that called this one.
    """
    target = _target_of(resolved)
    state = _state(target)
    if not state or not resolved.track.fork_from:
        return []
    source = lineage_of(resolved)
    if registry.load(source.service) is None:
        return [
            f"the fork source {source.service} has no registry entry, so "
            f"{resolved.name}/{resolved.ref} starts empty"
        ]
    plan = _plan(target, source, state, _recorded_seed(target, resolved.escaped_ref), now)
    _validate(plan, resolved.name)
    owner = _owner(target)
    for volume in state:
        entry = next((item for item in plan if item.volume == volume.name), None)
        if entry is None or not entry.number:
            continue
        live = paths.volume(resolved.name, volume.kind, volume.name, resolved.escaped_ref)
        _remove_tree(live)
        _clone(paths.snapshot(entry.source_service, volume.name, entry.number), live, owner)
    # An empty bulk volume is a subvolume on the fork path too: never a `mkdir`.
    for volume in _bulk(target):
        live = paths.volume(resolved.name, volume.kind, volume.name, resolved.escaped_ref)
        _remove_tree(live)
        volumes.create_bulk(resolved.name, volume.name, owner, resolved.escaped_ref)
    _record_seed(resolved, target, plan)
    return [
        f"forked {resolved.name}/{resolved.ref} from {source.service}",
        *_swap_lines(resolved, plan),
    ]


# --------------------------------------------------------------------------
# weedr service rollback
# --------------------------------------------------------------------------


def rollback(resolved, when: datetime, now: str) -> list[str]:
    """A stop, a swap and a start. It restores **data** and nothing else.

    Refused outright on a track with `gated = true`, with no flag that overrides
    it: the verb is not on the `guarden` sudoers rule at all, so this is a
    refusal an operator can only lift by conceding, in their own judgement, that
    rolling back production is the wrong next action.
    """
    if resolved.track.gated:
        raise errors.GuardenError(
            f"{resolved.name} is on the gated track {resolved.track.name!r}, so a rollback "
            f"is refused; there is no flag that overrides it, and the verb is on no sudoers "
            f"rule. An operator who wants it does it by hand, deliberately.",
            errors.HOST_NOT_AS_ASSUMED,
        )
    target = _target_of(resolved)
    state = _state(target)
    if not state:
        raise errors.GuardenError(
            f"{resolved.name} declares no state volume, so there is nothing to roll back; "
            f"a bulk volume is never a rollback source"
        )
    plan = [
        Plan(
            volume=volume.name,
            config=volume.config or paths.snapper_config(resolved.name, volume.name),
            available=True,
            source_service=resolved.name,
            number=snapper.newest_at_or_before(
                volume.config or paths.snapper_config(resolved.name, volume.name), when
            ),
        )
        for volume in state
    ]
    # A rollback is not a fork: the source is the service's own history and the
    # seed is not rewritten, because nothing was forked from.
    with conf.lock(f"deploy-{resolved.name}"):
        lines = _swap(resolved, target, state, plan, now)
    return [f"rolled {resolved.name} back to {_describe(plan)}", *lines]


def _describe(plan: list[Plan]) -> str:
    return ", ".join(
        f"{entry.volume}@{entry.number}" for entry in plan if entry.number
    ) or "nothing"


# --------------------------------------------------------------------------
# weedr service immutable / mutable
# --------------------------------------------------------------------------


def immutable(snapshot: ids.SnapshotId, reason: str) -> str:
    """The escalation, and both halves in one call.

    `chattr +i` on the snapshot's subvolume makes the btrfs delete ioctl return
    `EPERM`, which no `NUMBER_LIMIT`, `FREE_LIMIT` or `SPACE_LIMIT` overrides,
    and btrfs does not inherit immutability into a new subvolume so a fork still
    works. It is **not** a pin: pinning is a *retention* act that raises the
    snapshot to `important=yes` under the number cleaner, which respects it up to
    a budget, while this is a *deny* that also aborts the whole cleanup for its
    configuration.

    **A flag without a record is an escalation nobody can find later and a record
    without a flag is a lie**, so the verb sets the flag and writes the record
    together and `mutable` clears both. One escalation per volume at a time: a
    second is refused rather than overwriting the first record, which would make
    `mutable` clear a snapshot nobody asked about.
    """
    record = _for(snapshot)
    subvolume = _the_subvolume(snapshot)
    if snapshot.volume in record.immutable:
        raise errors.GuardenError(
            f"the {snapshot.volume} volume of {snapshot.service} is already immutable, "
            f"recorded as {record.immutable[snapshot.volume]!r}; the record is one per volume, "
            f"so a second escalation would make the first unfindable",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _escalate(subvolume)
    record.immutable[snapshot.volume] = reason
    _save(record)
    return f"immutable {snapshot}: {reason}"


def mutable(snapshot: ids.SnapshotId) -> str:
    """Clear the flag and the record together, for the same reason."""
    record = _for(snapshot)
    if snapshot.volume not in record.immutable:
        raise errors.GuardenError(
            f"{snapshot} is not recorded as immutable in {paths.registry(snapshot.service)}; "
            f"the flag and the record always agree, so there is nothing to clear",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _withdraw(_the_subvolume(snapshot))
    del record.immutable[snapshot.volume]
    _save(record)
    return f"mutable {snapshot}"


def _escalate(subvolume: Path) -> None:
    """`chattr +i`, and the read-only property cleared first because a flag is a
    write.

    **snapper marks every snapshot's own subvolume read-only** — measured, and
    `docs/notes` item O's "btrfs does not make a snapshot read-only" is about
    `btrfs subvolume snapshot`, not about snapper, which sets the property itself:
    `btrfs property get <volume>/.snapshots/1/snapshot ro` answers `ro=true`.
    `chattr +i` on a read-only subvolume answers `Read-only file system while
    setting flags` and exits 1, so the flag is cleared, the escalation is set, and
    the flag is what then makes `snapper -c <config> delete <number>` answer
    `Deleting snapshot failed.` — which is the whole of what the verb is for, and
    which no `NUMBER_LIMIT`, `FREE_LIMIT` or `SPACE_LIMIT` overrides.
    """
    tool.run(["btrfs", "property", "set", str(subvolume), "ro", "false"])
    tool.run(["chattr", "+i", str(subvolume)])


def _withdraw(subvolume: Path) -> None:
    """The flag off and the read-only property back on, which is the state snapper
    made it in and the only state a snapshot is snapper's to be in."""

    tool.run(["chattr", "-i", str(subvolume)])
    tool.run(["btrfs", "property", "set", str(subvolume), "ro", "true"])


def _the_subvolume(snapshot: ids.SnapshotId) -> Path:
    """The snapshot's subvolume, and a refusal when it is not there.

    A record for a snapshot that does not exist is a lie in the direction the
    other half of this rule forbids: the flag and the record are set together, and
    a record naming a number snapper has never heard of is exactly as unfindable
    as a flag nobody wrote down.
    """
    target = paths.snapshot(snapshot.service, snapshot.volume, snapshot.number)
    if not target.is_dir():
        raise errors.GuardenError(
            f"{snapshot} is not a subvolume on this host: {target} is not there, so there "
            f"is nothing to flag and nothing to record",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return target


def _for(snapshot: ids.SnapshotId):
    record = registry.load(snapshot.service)
    if record is None:
        raise errors.GuardenError(
            f"{snapshot.service} has no registry entry, so {snapshot} is not a snapshot this "
            f"host holds",
            errors.HOST_NOT_AS_ASSUMED,
        )
    return record
