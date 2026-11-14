"""Reading and writing snapshot state, the one way it is done.

spec 8.2, 8.5 and 8.6, and AGENTS.md. Two rules, both about the same read:

- **Snapshot state is read with `snapper --machine-readable json --config
  <config> list`**, because JSON renders a snapshot's `userdata` as an object and
  `important` is therefore a key. CSV renders the whole map as one comma-joined
  quoted field, so a consumer of CSV has to string-match a value it was told was
  structured.
- **The effective configuration is read with `snapper get-config`**, never by
  parsing `/etc/snapper/configs/<name>`. A configuration's name is opaque
  (spec 8.1) and its file belongs to snapper.

Both of those are measured facts about snapper 0.10.6, the version `soil packages`
installs, and both were wrong in the documents until the read was run against the
real tool. `--machine-readable` is a **global** option: written after the command
it is refused with `Unknown option '--machine-readable' for command 'list'` and
exit `1`, which is the shape behind a snapshot that was taken and cannot be read
back. And the JSON document is an **object keyed by the configuration's name**,
whose first entry is `number 0` — the live subvolume, described `current`, with no
date and no cleanup tag. Entry `0` is not a snapshot: nothing snapper's cleaners
count it, and counting it would report a configuration that has never been
snapshotted as holding one.

**No write here passes `--no-dbus`.** Without the snapperd daemon there is no
inter-process coordination at all, so a mark written that way can be lost with
no error anywhere — which is why the whole of this is one lock
(`/run/guarden/locks/snapshots.lock`) around the reconciler and the cleanup.

`marked` here is the truth on the filesystem, not a promise: under real disk
pressure a marked snapshot can be reaped, and spec 1.2 says so. What
`weedr pin sync` *will* write is a separate statement, made by `stakes`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime

from guarden import errors, paths, tool

LIMIT_KEYS = (
    "NUMBER_LIMIT",
    "NUMBER_LIMIT_IMPORTANT",
    "TIMELINE_LIMIT_DAILY",
    "TIMELINE_LIMIT_WEEKLY",
    "TIMELINE_LIMIT_MONTHLY",
    "TIMELINE_LIMIT_QUARTERLY",
    "EMPTY_PRE_POST_CLEANUP",
    "NUMBER_MIN_AGE",
    "FREE_LIMIT",
)


@dataclass
class Counts:
    total: int = 0
    marked: int = 0
    oldest: str | None = None
    newest: str | None = None
    limits: dict[str, str] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {
            "total": self.total,
            "marked": self.marked,
            "oldest": self.oldest,
            "newest": self.newest,
            "limits": dict(self.limits),
        }


def read(config: str) -> Counts:
    """A configuration's snapshot counts and effective limits, or nothing at all
    when the configuration is not there — a removed service's configuration is
    `soil storage`'s to remove, so its absence is not this verb's problem."""
    counts = Counts()
    dates = []
    for entry in entries_of(config) or []:
        counts.total += 1
        if is_marked(entry):
            counts.marked += 1
        date = entry.get("date")
        if isinstance(date, str):
            dates.append(date)
    counts.oldest = min(dates) if dates else None
    counts.newest = max(dates) if dates else None
    counts.limits = limits_of(get_config(config))
    return counts


def limits_of(values: dict[str, str]) -> dict[str, str]:
    """The limit keys out of an effective configuration.

    `SUBVOLUME` and `FSTYPE` are snapper's own settings rather than limits, and a
    field called `limits` that carried a filesystem path would be read as one.
    """
    return {key: values[key] for key in LIMIT_KEYS if key in values}


def get_config(config: str) -> dict[str, str]:
    """The effective values, read back rather than believed: `weedr service list`
    reports what snapper holds, not what guarden thinks it wrote.

    snapper renders `get-config` as a **two-column table**, not as `KEY=value`:

    ```
    Key                    | Value
    -----------------------+------
    EMPTY_PRE_POST_CLEANUP | no
    ```

    with a header row, a rule row, and padded empty values. Parsing `KEY=value`
    here would read nothing at all from the real tool and would report an empty
    configuration for a perfectly converged one — which reads as "no limits" and
    is the answer an operator is most likely to act on.
    """
    result = tool.call(["snapper", "--config", config, "get-config"])
    values: dict[str, str] = {}
    if not result.ok:
        return values
    for line in tool.lines(result):
        key, sep, value = line.partition("|")
        key = key.strip()
        if not sep or not key or key == "Key" or set(key) == {"-"}:
            continue
        values[key] = value.strip()
    return values


def newest_number(config: str) -> int | None:
    """The newest snapshot number, which the registry records for a state volume."""
    entries = entries_of(config) or []
    numbers = [entry["number"] for entry in entries if isinstance(entry.get("number"), int)]
    return max(numbers) if numbers else None


def entries_of(config: str) -> list[dict] | None:
    """One `--machine-readable json` read, and nothing else.

    Three things about the answer, all measured on snapper 0.10.6:

    - **`--machine-readable` is a global option and precedes the command.** After
      `list` it is not an option of `list` at all, and the tool answers
      `Unknown option '--machine-readable' for command 'list'` with exit `1`. The
      shape that produces is a snapshot that was taken and cannot be listed back.
    - **The document is an object keyed by the configuration's name**,
      `{ "<config>": [ ... ] }`, not a list. A reader that expects a list gets a
      type it did not ask for, and the honest answer to that is a failed read.
    - **Entry `number: 0` is the live subvolume**, described `current`, with an
      empty `date` and no `cleanup` tag. It is not a snapshot: snapper issues
      numbers from `1`, its cleaners never consider `0`, and every figure computed
      here is a figure about snapshots. It is dropped, and so is every entry
      without an integer number, because the reconciler and the fork both index
      these by number.

    `None` means the read **failed**, and `[]` means the configuration has no
    snapshots. The reconciler treats those two differently — an unreadable
    configuration is a reason to stop rather than to clear marks (spec 8.5) —
    so this is not collapsed into one empty answer.
    """
    result = tool.call(
        ["snapper", "--machine-readable", "json", "--config", config, "list"]
    )
    if not result.ok:
        return None
    try:
        parsed = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    entries = parsed.get(config)
    if not isinstance(entries, list):
        return None
    return [
        entry
        for entry in entries
        if isinstance(entry, dict)
        and isinstance(entry.get("number"), int)
        and entry["number"] > 0
    ]


def exists(config: str) -> bool:
    """Whether snapper holds a configuration, asked the way spec 8.1 reads one."""
    return tool.call(["snapper", "--config", config, "get-config"]).ok


def is_marked(entry: dict) -> bool:
    """`important=yes` read as a **key** of the userdata object.

    This is the whole reason nothing in guarden parses CSV: the CSV rendering
    joins the whole map into one comma-joined quoted field, so a consumer of it
    ends up string-matching a value it was told was structured.
    """
    userdata = entry.get("userdata")
    return isinstance(userdata, dict) and userdata.get("important") == "yes"


def referencing(entry: dict) -> str:
    userdata = entry.get("userdata")
    if isinstance(userdata, dict):
        value = userdata.get("guarden")
        if isinstance(value, str):
            return value
    return ""


def create(config: str, description: str, algorithm: str) -> None:
    """One snapshot, in the configuration, tagged by its cleanup algorithm.

    **`--no-dbus` is never passed.** Without the snapperd daemon there is no
    inter-process coordination at all, so a write made that way can be lost with
    nothing reporting an error anywhere (spec 8.2, ADR-0007).

    `algorithm` is the whole difference between the two kinds of snapshot: a
    routine one is `timeline` and lives by the ladder, an on-demand one is
    `number` and is what the marks protect. There is no flag that chooses the
    kind, because the kind follows from why the snapshot was taken.

    **A refusal is reported against the configuration and not against the tool.**
    `tool.run` names the program it ran, which for this call is always the same
    string — `snapper exited 1: …` — whether the volume that would not snapshot
    is this service's or the next one's, and `--all` walks every service on the
    host. A diagnostic that cannot say which volume it is about is not one
    (spec 1.3), and the configuration is what `snapper` was working on.

    This is the failure a configuration whose subvolume is not a subvolume any
    more produces: `snapper create` refuses it on its own, before guarden has a
    number to record or a list to read back.
    """
    result = tool.call(["snapper", "--config", config, "create", "--cleanup-algorithm", algorithm,
                        "--description", description])
    if result.ok:
        return
    detail = (result.stderr or result.stdout).strip().splitlines()
    raise errors.GuardenError(
        f"snapper would not take a {algorithm} snapshot of {config}: "
        + (detail[-1] if detail else f"exit {result.returncode}"),
        errors.HOST_NOT_AS_ASSUMED,
    )


def mark(config: str, number: int, service: str) -> None:
    """`important=yes` **and** the `number` cleanup tag, in one call.

    Both halves are load-bearing: `important` is read only by the `number`
    cleaner, and a snapshot is a candidate for that cleaner only when its
    cleanup tag is `number`. `guarden=` is this project's provenance key, so a
    mark written by something else is distinguishable and a human reading
    `snapper list` can see which service wants the snapshot.
    """
    tool.run(["snapper", "--config", config, "modify", "--cleanup-algorithm", "number",
              "--userdata", f"important=yes, guarden={service}", str(number)])


def unmark(config: str, number: int) -> None:
    tool.run(["snapper", "--config", config, "modify", "--cleanup-algorithm", "number",
              "--userdata", "important=no", str(number)])


def newest_at_or_before(config: str, when: datetime) -> int | None:
    """The newest snapshot at or before a moment, which is what a time selects.

    spec 8.6: `--to` is a **time** and never a number, because a service with
    several state volumes has a different number in each configuration and no
    single number can mean the whole set. A time does mean one, because the
    volumes are snapshotted together — each consistently, and possibly
    microseconds apart.

    One list read for the whole search, never one per candidate: `snapper list`
    holds the configuration lock for its whole duration, so a reconciler or a
    rollback that lists in a loop can stall cleanup (spec 8.5).
    """
    best: tuple[datetime, int] | None = None
    for entry in entries_of(config) or []:
        number = entry.get("number")
        date = moment_of(entry.get("date"))
        if not isinstance(number, int) or date is None or date > when:
            continue
        if best is None or (date, number) > best:
            best = (date, number)
    return best[1] if best else None


_DATE_SHAPES = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
)


def moment_of(value) -> datetime | None:
    """A snapper `date`, or an operator's `--to`, as one comparable instant.

    snapper renders `date` as `%c` in local time, so an entry with no zone is
    local; a `--to` with no zone is local for the same reason. A value that
    carries a zone is honoured as written, so an operator who says `Z` means it.

    A **bare number is refused**, and that is the point of the function being
    strict here. `--to 41` is overwhelmingly likely to be a snapshot number, and
    reading it as seconds since the epoch would resolve it to a moment in 1970
    and answer with a confident, wrong set. spec 8.6: a number never names a set.
    """
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.isdigit():
        return None
    for shape in _DATE_SHAPES:
        try:
            naive = datetime.strptime(text, shape)
        except ValueError:
            continue
        return naive.astimezone()
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def configuration_exists(config: str) -> bool:
    return (paths.SNAPPER_CONFIGS / config).exists()
