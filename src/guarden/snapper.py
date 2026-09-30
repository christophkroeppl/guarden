"""Reading snapshot state, the one way it is read.

spec 8.2 and AGENTS.md. Two rules, both about the same read:

- **Snapshot state is read with `snapper list --machine-readable json`**, because
  JSON renders a snapshot's `userdata` as an object and `important` is therefore
  a key. CSV renders the whole map as one comma-joined quoted field, so a
  consumer of CSV has to string-match a value it was told was structured.
- **The effective configuration is read with `snapper get-config`**, never by
  parsing `/etc/snapper/configs/<name>`. A configuration's name is opaque
  (spec 8.1) and its file belongs to snapper.

`marked` here is the truth on the filesystem, not a promise: under real disk
pressure a marked snapshot can be reaped, and spec 1.2 says so. What
`weedr pin sync` *will* write is a separate statement, made by `stakes`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from guarden import paths, tool

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
    result = tool.call(["snapper", "--config", config, "list", "--machine-readable", "json"])
    counts = Counts()
    if not result.ok:
        return counts
    try:
        entries = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return counts
    if not isinstance(entries, list):
        return counts

    dates = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        counts.total += 1
        userdata = entry.get("userdata")
        if isinstance(userdata, dict) and userdata.get("important") == "yes":
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
    reports what snapper holds, not what guarden thinks it wrote."""
    result = tool.call(["snapper", "--config", config, "get-config"])
    values: dict[str, str] = {}
    if not result.ok:
        return values
    for line in tool.lines(result):
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    return values


def newest_number(config: str) -> int | None:
    """The newest snapshot number, which the registry records for a state volume."""
    result = tool.call(["snapper", "--config", config, "list", "--machine-readable", "json"])
    if not result.ok:
        return None
    try:
        entries = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return None
    numbers = [
        entry["number"]
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("number"), int)
    ]
    return max(numbers) if numbers else None


def configuration_exists(config: str) -> bool:
    return (paths.SNAPPER_CONFIGS / config).exists()
