"""A quadlet unit file, read the way systemd reads one and no further.

**A unit source is input** (spec 1.2), so everything this parser refuses is exit
`2` and names the file and the line. There is no "best effort" here: a unit
`loom` misreads is a unit that binds something the design says nothing binds.

Three things about the format are load-bearing and are therefore in the parser
rather than in the caller:

- **A section header opens a table and a key belongs to the table above it.** The
  renderer rewrites keys by name, so a key read into the wrong table is a key
  guarden has an opinion about that silently survives.
- **Repeated keys are meaningful.** `AddHost=`, `Volume=`, `PublishPort=` and
  `Secret=` are all repeated, and the opinionated pass removes or replaces
  *every* occurrence, so the values are kept in order rather than collapsed into
  a set or a dict lookup.
- **A line ending in `\\` continues.** podlet emits them, and a joined value read
  as two keys is a unit that systemd would refuse to start.

The parser keeps order everywhere — sections in file order, keys in first-set
order — because the render has to be byte-identical on every run (spec 6.3) and
a set's iteration order is not a thing to hang that on.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from guarden import errors

# Keys whose value may contain a space, and which systemd therefore lets be
# quoted. Anything else with a space in its value is a malformed unit rather than
# something to guess at: `AddHost=a:1 2` has two meanings and neither is written
# down anywhere.
QUOTABLE = frozenset(
    {
        "Description",
        "Environment",
        "EnvironmentFile",
        "Label",
        "Exec",
        "NotifyAccess",
        "SyslogIdentifier",
    }
)

CONTINUATION = "\\"


@dataclass
class Unit:
    """One parsed `.container` or `.volume` file."""

    path: Path
    sections: dict[str, dict[str, list[str]]] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)

    def keys(self, section: str) -> list[str]:
        table = self.sections.get(section)
        return list(table) if table else []

    def get(self, section: str, key: str) -> list[str]:
        table = self.sections.get(section) or {}
        return list(table.get(key, []))

    def one(self, section: str, key: str) -> str | None:
        """The last value, which is the one systemd would apply last."""
        values = self.get(section, key)
        return values[-1] if values else None

    def put(self, section: str, key: str, values: list[str]) -> None:
        """Set a key to exactly these values, in this order, creating the table."""
        if section not in self.sections:
            self.sections[section] = {}
            self.order.append(section)
        self.sections[section][key] = list(values)

    def drop(self, section: str, key: str) -> list[str]:
        table = self.sections.get(section) or {}
        return table.pop(key, [])

    def lines(self, section: str) -> list[tuple[str, str]]:
        """The section as `(key, value)` pairs, in the order they are written."""
        table = self.sections.get(section) or {}
        return [(key, value) for key in table for value in table[key]]

    def stem(self) -> str:
        return self.path.name.split(".", 1)[0]


def parse(path: Path) -> Unit:
    """Read one unit file. A unit source is input, so a broken one is exit 2."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise errors.GuardenError(f"the unit source {path} does not exist") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.GuardenError(
            f"the unit source {path} could not be read: {getattr(exc, 'strerror', exc)}"
        ) from exc
    return loads(text, path)


def loads(text: str, path: Path) -> Unit:
    unit = Unit(path=path)
    table: str | None = None
    for number, line in _logical(text):
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        if stripped.startswith("["):
            if not stripped.endswith("]") or len(stripped) < 3:
                raise _bad(path, number, stripped, "a section header is `[Name]`")
            table = stripped[1:-1]
            if table not in unit.sections:
                unit.sections[table] = {}
                unit.order.append(table)
            continue
        if table is None:
            raise _bad(path, number, stripped, "it is a key before any section header")
        key, separator, value = stripped.partition("=")
        if not separator or not key.strip():
            raise _bad(path, number, stripped, "it is neither a section header nor `Key=value`")
        unit.sections[table].setdefault(key.strip(), []).append(value.strip())
    return unit


def _bad(path: Path, number: int, line: str, why: str) -> errors.GuardenError:
    return errors.GuardenError(f"{path}:{number}: {why}: {line!r}")


def _logical(text: str) -> list[tuple[int, str]]:
    """Lines with the continuations joined, and the line each one started on."""
    out: list[tuple[int, str]] = []
    pending = ""
    start = 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if pending:
            line = pending + line.lstrip()
            pending = ""
        if line.endswith(CONTINUATION):
            pending = line[:-1].rstrip() + " "
            start = number
            continue
        out.append((start or number, line))
    if pending:
        out.append((start, pending))
    return out


def format_line(key: str, value: str, path: Path) -> str:
    """One unit line, quoted only where systemd accepts a quoted value.

    A value with a space in a key that cannot be quoted is refused rather than
    written, because the alternative is a unit file that means one thing and
    parses as another.

    **`Exec=` is never quoted.** It is in `QUOTABLE` because systemd *accepts* a
    quoted `Exec=`, not because quoting means the same thing there -- and for
    `Exec=` it does not. Quadlet splits an unquoted `Exec=` value on whitespace,
    so

        Exec=--a=1 --b=2

    becomes two arguments, while

        Exec="--a=1 --b=2"

    becomes ONE argument holding both, which the process receives as a single
    unrecognised flag and discards with everything after it. Measured by running
    the quadlet generator by hand: the quoted form emits
    `"--a=1\\x20--b=2"` as a single token, and the unquoted form emits two.

    A value that genuinely needs a space inside one argument is therefore refused
    rather than quoted: there is no spelling that carries it, and a unit that
    silently passes one argument instead of two is the failure this whole file
    exists to prevent.
    """
    if " " in value and key not in QUOTABLE:
        raise errors.GuardenError(
            f"{path}: the value of {key}= has a space in it and {key} does not take a "
            f"quoted value: {value!r}"
        )
    if key == "Exec":
        for argument in value.split():
            if " " in argument:
                raise errors.GuardenError(
                    f"{path}: an Exec= argument contains a space: {argument!r}. Quadlet "
                    f'splits Exec= on whitespace, so an argument with a space in it '
                    f"cannot be expressed."
                )
        return f"{key}={value}"
    if key in QUOTABLE and (" " in value or '"' in value):
        return f'{key}="{value}"'
    return f"{key}={value}"
