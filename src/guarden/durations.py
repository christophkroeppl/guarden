"""A duration, in one syntax, in one place.

Two spellings of "how long" meet in this design and they are not the same
language, so the conversion lives here rather than at either call site:

- **guarden's own syntax**, what an operator types and what `guarden.toml` holds:
  one or more `<number><unit>` terms, units `s`, `m`, `h`, `d`, `w`. `7d` and
  `168h` are the same duration and either may be written.
- **the vendor's Go duration syntax**, what an Access policy's `session_duration`
  accepts: `ns`, `us`, `ms`, `s`, `m`, `h`, and **no `d` or `w`**. So a maximum
  an operator wrote as `7d` has to become `168h` in the request body, and that
  conversion is the whole reason this module exists.

A duration is stored as an **absolute deadline** wherever it matters (spec: a
root-owned wall clock that can move backwards must not be able to extend a
grant), so nothing here keeps a duration as state. It parses one to a number of
seconds and renders seconds back out.
"""

from __future__ import annotations

import re

from guarden import errors

# The units guarden accepts, largest first so a rendered form is as short as the
# operator's own would be. `d` and `w` are guarden's; the vendor has neither.
UNITS = {
    "s": 1,
    "m": 60,
    "h": 3600,
    "d": 86400,
    "w": 604800,
}

# A term is a number and a unit, and a duration is one or more of them: `90m`,
# `1h30m`, `7d`. A bare number is refused — `--until 7` names no unit and a
# missing unit is exactly the mistake that turns seven hours into seven seconds.
_TERM = re.compile(r"(\d+)([smhdw])")
_WHOLE = re.compile(r"^(?:\d+[smhdw])+$")

GO_ORDER = (("h", 3600), ("m", 60), ("s", 1))


def parse(text: str, what: str = "duration") -> int:
    """A duration in guarden's syntax, as a whole number of seconds.

    A value that is not a duration is a rejected input: it is a caller's
    argument, or an operator's line in `guarden.toml`, and either way it is
    something a person typed that the grammar does not accept.
    """
    stripped = text.strip()
    if not _WHOLE.match(stripped):
        raise errors.GuardenError(
            f"{what} {text!r} is not a duration; it is one or more <number><unit> terms "
            f"with the units {', '.join(UNITS)}, as in `7d` or `12h30m`"
        )
    total = 0
    for amount, unit in _TERM.findall(stripped):
        total += int(amount) * UNITS[unit]
    if total <= 0:
        raise errors.GuardenError(
            f"{what} {text!r} is zero, and a grant that lasts no time is not one"
        )
    return total


def go(seconds: int) -> str:
    """The same duration in the vendor's Go syntax: `168h`, never `7d`.

    Go has no `d` or `w`, so days are carried as hours. The terms are emitted
    largest-first and a zero term is dropped, which is the form the vendor's own
    examples take (`2h45m`).
    """
    if seconds <= 0:
        raise errors.GuardenError(f"{seconds} is not a duration the vendor would accept")
    parts: list[str] = []
    remaining = seconds
    for unit, size in GO_ORDER:
        if remaining >= size:
            parts.append(f"{remaining // size}{unit}")
            remaining %= size
    return "".join(parts)
