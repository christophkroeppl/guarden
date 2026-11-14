"""A rejection, and the exit code it carries.

spec 1.2 is the whole of the contract: exit `0` is done or already true, `1` is
the host not being in the state the request assumed, and `2` is a rejected
input. The dividing line is input against host, which is why the code is a
constructor argument rather than something a handler has to remember: a name
that breaks a rule is `2`, and a configuration file that will not parse is `1`,
and both are one `raise` at the point where the distinction is visible.
"""

from __future__ import annotations

HOST_NOT_AS_ASSUMED = 1
REJECTED_INPUT = 2


class GuardenError(Exception):
    """One diagnostic, and the code that carries it."""

    def __init__(self, message: str, code: int = REJECTED_INPUT) -> None:
        super().__init__(message)
        self.message = message
        self.code = code

    def report(self, program: str) -> str:
        """The one stderr line. A diagnostic names the thing it is about."""
        return f"error: {self.message}"


def warn(message: str) -> str:
    """The other diagnostic: one line, prefixed, and not a failure."""
    return f"warning: {message}"


def oneline(message: str) -> str:
    """Collapse a parser's message into the one line a diagnostic is.

    A YAML error carries a mark and a snippet and can be four lines long, and
    AGENTS.md is explicit that a diagnostic is one line prefixed `error:` — so
    the collapsing happens here, once, rather than at each of the places that
    read a document a stranger wrote.
    """
    return " ".join(message.split())
