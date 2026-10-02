"""`weedr pin sync`: the mark reconciler, and the whole of the retention story.

spec 8.5, ADR-0007 and AGENTS.md. **Retention is snapper's.** guarden runs no
delete loop, no retention pass and no pruner; what guarden runs is this, a root
reconciler that reads the two things that want a snapshot kept and writes the
marks in the form snapper's own algorithms understand.

It is a separate root action from `stakes` on purpose: `stakes` runs as
`guarden` and writing snapper's metadata is not something an unprivileged
program can do. `stakes` records the intent; this writes it. The division is
what lets the pin store be a directory of files anybody in the group may create
and this stay a thing only root does.

Six rules, and every one of them is load-bearing:

- **One lock for the whole run**: `/run/guarden/locks/snapshots.lock`, held
  across the read, the diff and the writes. `soil storage` installs snapper's
  cleanup under the same key, because snapper takes no lock that
  `snapper modify` participates in and its cleaner reuses one reference to the
  snapshot list across all three passes, so a mark written during a running
  cleanup is silently lost with no error anywhere.
- **Adds before it removes.** A mark is added before any mark is cleared, so
  there is no window in which a snapshot that is wanted is unprotected.
- **Idempotent.** A snapshot that already carries `important=yes` is not
  rewritten, so a second run makes no calls at all.
- **Stops rather than clearing anything when its state is unreadable.** A
  registry directory that is missing or unreadable, or a `snapper list` that
  fails, is exit `1` with every existing mark left exactly where it was. A
  reconciler that cannot see its input releases the snapshots it was protecting
  and then reports success.
- **No write passes `--no-dbus`.** With no daemon there is no inter-process
  coordination at all.
- **One `list` per configuration**, never one per candidate: `snapper list`
  holds the configuration lock for its whole duration, so a reconciler that lists
  in a loop can stall cleanup.

The derived set is exact: a snapshot nothing names is unmarked, so the marks are
what the pin files and the registries say and not what a previous run left
behind.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field

from guarden import conf, errors, paths, pins, snapper


@dataclass
class Configuration:
    """One snapper configuration's current marks, read once."""

    config: str
    entries: list[dict] = field(default_factory=list)

    def marked(self) -> dict[int, dict]:
        return {
            entry["number"]: entry
            for entry in self.entries
            if isinstance(entry.get("number"), int) and snapper.is_marked(entry)
        }

    def numbers(self) -> set[int]:
        return {
            entry["number"] for entry in self.entries if isinstance(entry.get("number"), int)
        }


def run() -> list[str]:
    """Recompute every mark from the pin files and the registries."""
    with conf.lock("snapshots"):
        return _reconcile()


def _reconcile() -> list[str]:
    # The input is read before anything is written, and the warnings it produces
    # come out first: a snapshot nobody names is one the previous run marked, and
    # unmarking it is only correct if the wants are known to be complete.
    if not paths.REGISTRY.is_dir():
        raise errors.GuardenError(
            f"{paths.REGISTRY} is not a directory, so the seed references cannot be read; "
            f"every existing mark is left in place rather than released from a state the "
            f"reconciler could not read",
            errors.HOST_NOT_AS_ASSUMED,
        )
    _warn_stray(pins.stored()[1])
    wants = pins.wants()
    # The configurations a pin **no longer** names are read as well, because a
    # released pin's snapshot is still marked and only a configuration that is
    # read anyway can have that mark cleared.
    configs = sorted({want.config for want in wants} | set(pins.configurations()))
    states = _read_states(configs)
    lines = _add(wants, states)
    lines += _remove(states, wants)
    if not lines:
        return ["nothing to reconcile; every mark is where the pins and the seeds say it is"]
    return lines


def _warn_stray(stray: list[str]) -> None:
    for name in stray:
        _warn(f"the pin file {name} is not a snapshot id, and protects nothing")


def _read_states(configs: list[str]) -> dict[str, Configuration]:
    states: dict[str, Configuration] = {}
    for config in configs:
        entries = snapper.entries_of(config)
        if entries is None:
            raise errors.GuardenError(
                f"snapper would not list the configuration {config}, so its marks cannot be "
                f"recomputed; every existing mark is left in place rather than cleared from a "
                f"state that could not be read",
                errors.HOST_NOT_AS_ASSUMED,
            )
        states[config] = Configuration(config=config, entries=entries)
    return states


def _add(wants: list[pins.Want], states: dict[str, Configuration]) -> list[str]:
    lines: list[str] = []
    done: set[tuple[str, int]] = set()
    for want in wants:
        key = (want.config, want.number)
        if key in done:
            continue
        done.add(key)
        state = states.get(want.config) or Configuration(config=want.config)
        if want.number in state.marked():
            continue
        if state.entries and want.number not in state.numbers():
            # A pin for a snapshot this configuration does not hold. A warning
            # rather than a failure, because the pin is a priority with a budget
            # and not a promise — and the mark is not written, because marking a
            # number snapper has never heard of is a fact only in the registry.
            _warn(
                f"the configuration {want.config} holds no snapshot {want.number}, so "
                f"{want.snapshot} is not marked"
            )
            continue
        snapper.mark(want.config, want.number, want.author)
        lines.append(f"marked {want.snapshot} for {want.author}")
    return lines


def _remove(states: dict[str, Configuration], wants: list[pins.Want]) -> list[str]:
    lines: list[str] = []
    wanted: dict[str, set[int]] = {}
    for want in wants:
        wanted.setdefault(want.config, set()).add(want.number)
    for config, state in sorted(states.items()):
        for number, entry in sorted(state.marked().items()):
            if number in wanted.get(config, set()):
                continue
            snapper.unmark(config, number)
            by = snapper.referencing(entry)
            who = f", which {by} wanted" if by else ""
            lines.append(f"unmarked {config}@{number}, which nothing wants{who}")
    return lines


def _warn(message: str) -> None:
    sys.stderr.write(f"warning: {message}\n")
