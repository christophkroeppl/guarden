"""A snapshot id: `<service>:<volume>@<number>`, and nothing else.

spec 6.8 and CONTEXT.md. A colon cannot appear in a service name or a volume
name, so the id is unambiguous in a way a dash is not:
`other-app-production-pgdata-41` could be a service called `other-app` with a
volume called `production-pgdata`. The dash form is never emitted — not on a
command line, not in a pin file, not in a diagnostic and not in a registry
field.

The same id is what `stakes pin` takes, what `weedr service immutable` takes,
and what the pin file is named. It names **one snapshot of one volume**: a
service with several state volumes has a different number in each
configuration, and no single number names the whole set (spec 8.4, 8.6), so
nothing here pretends to.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from guarden import errors, names
from guarden.manifest import VOLUME_RE

SEPARATOR = ":"
AT = "@"

_NUMBER = re.compile(r"^[0-9]+$")


@dataclass(frozen=True)
class SnapshotId:
    service: str
    volume: str
    number: int

    def __str__(self) -> str:
        return f"{self.service}{SEPARATOR}{self.volume}{AT}{self.number}"


def format_id(service: str, volume: str, number: int) -> str:
    return str(SnapshotId(service=service, volume=volume, number=number))


def parse(value: str, what: str = "snapshot id") -> SnapshotId:
    """The one form, refused by name.

    Every part is checked against the rule the name itself would have to satisfy
    anyway: an id is typed by a human at a terminal, and a pin file named for a
    service that could never exist is a file nobody can act on.
    """
    head, at, tail = value.partition(AT)
    if not at or not tail:
        raise errors.GuardenError(
            f"{what} {value!r} is not <service>:<volume>@<number>; the colon is what makes "
            f"it unambiguous, because a dash is legal in both a service name and a volume name"
        )
    service, colon, volume = head.partition(SEPARATOR)
    if not colon or not volume or SEPARATOR in volume or AT in volume:
        raise errors.GuardenError(
            f"{what} {value!r} is not <service>:<volume>@<number>; there is exactly one colon "
            f"and one '@', and neither the service nor the volume may carry one"
        )
    if not _NUMBER.match(tail):
        raise errors.GuardenError(
            f"{what} {value!r} names the number {tail!r}, which is not a number"
        )
    names.validate(service, f"the service in {what} {value!r}")
    if not VOLUME_RE.match(volume):
        raise errors.GuardenError(
            f"the volume {volume!r} in {what} {value!r} must match {VOLUME_RE.pattern}"
        )
    return SnapshotId(service=service, volume=volume, number=int(tail))
