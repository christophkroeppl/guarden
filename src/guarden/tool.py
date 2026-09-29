"""Running the external tools, in one place.

Every call out of guarden goes through here, so the argv a program built is the
argv that ran and there is exactly one place to look when a fake's call log says
something unexpected.

The mutator runs these as root and the unprivileged programs run their own; a
non-zero exit is the host not being in the state the request assumed, so it is
exit `1` and the diagnostic names the tool. Nothing here is a shell: the tools
are invoked with an argv, never through a shell, and the only strings guarden
interpolates into a command are a system user's own name.
"""

from __future__ import annotations

import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path

from guarden import errors

log = logging.getLogger("guarden")


@dataclass(frozen=True)
class Result:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def call(argv: list[str] | tuple[str, ...], stdin: str | None = None) -> Result:
    log.debug("ran: %s", " ".join(argv))
    finished = subprocess.run(
        list(argv),
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    return Result(tuple(argv), finished.returncode, finished.stdout, finished.stderr)


def run(argv: list[str] | tuple[str, ...]) -> Result:
    """Run a tool whose success the caller assumes. A failure is exit `1`."""
    result = call(argv)
    if not result.ok:
        detail = result.stderr.strip() or result.stdout.strip()
        raise errors.GuardenError(
            f"{result.argv[0]} exited {result.returncode}" + (f": {detail}" if detail else ""),
            errors.HOST_NOT_AS_ASSUMED,
        )
    return result


def check(argv: list[str] | tuple[str, ...]) -> bool:
    """Run a tool and report whether it worked, for the feature-probe paths.

    `useradd --add-subuids-for-system` needs shadow-utils 4.11 or later, and
    "is this option supported" is answered by running it, not by parsing a
    version string out of a distribution's changelog.
    """
    return call(argv).ok


def lines(result: Result) -> list[str]:
    return [line for line in result.stdout.splitlines() if line.strip()]


def path_argument(value: Path) -> str:
    return str(value)
