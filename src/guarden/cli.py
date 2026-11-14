"""Shared command-line plumbing.

The programs are Python console scripts, so their argument parsers are the
whole of the seam. What is the same shape in more than one program lives here:
the project's one verb alias, the metavar that prints it beside the long form,
and what a verb whose body a later ticket writes does when it is run.

The contract a skeleton's `--help` keeps: the verbs listed are the verbs the
spec lists, and nothing else. A verb that is not in the spec does not belong in
a parser, and a missing one is a hole in the interface rather than a later
concern.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

# spec 1.3: `remove` is the only verb that has an alias, `rm` is the only alias,
# and neither is derived from the long form. Nothing else will grow one.
ALIASES: dict[str, str] = {"remove": "rm"}

NAME_REF = "NAME[/REF]"

VERB_PAIRS = Sequence[tuple[str, str]]


def verb_metavar(names: Sequence[str]) -> str:
    """`remove (rm),purge,...` — the alias always beside the long form."""
    return ",".join(f"{name} ({ALIASES[name]})" if name in ALIASES else name for name in names)


def add_verb(group, name: str, help_text: str, **kwargs) -> argparse.ArgumentParser:
    """Add one subcommand, aliasing `remove` and nothing else.

    The alias reaches `--help` twice: in the group's metavar, and in the
    command list, because argparse only renders a command's help line when the
    subcommand carries a `help`. It is also recorded in the namespace under the
    long form, so a diagnostic names `remove` whether the caller typed it or
    `rm` — spec 1.3, and the form the sudoers grants name.
    """
    if name in ALIASES:
        subparser = group.add_parser(name, aliases=[ALIASES[name]], help=help_text, **kwargs)
    else:
        subparser = group.add_parser(name, help=help_text, **kwargs)
    subparser.set_defaults(verb=name)
    return subparser


def add_verbs(action, verbs: VERB_PAIRS) -> dict[str, argparse.ArgumentParser]:
    """Add subcommands to an existing subparsers action, by name."""
    return {name: add_verb(action, name, help_text) for name, help_text in verbs}


def add_groups(parser, dest: str, groups) -> dict[str, dict]:
    """Add one level of subcommands, each optionally opening a level of its own.

    `groups` is a sequence of `(name, help, verbs)`, where `verbs` is `None` for
    a leaf. argparse allows exactly one subparsers action per parser, so the
    level is created once here and a group's own verbs go on that group's parser.

    The return value is `{name: {"parser": p, "verbs": {verb: p}}}`: `parser` is
    the verb's own parser, for arguments every invocation of it takes, and
    `verbs` is a leaf's own subcommands, empty when it is a leaf. `leaf`'s dest
    is deliberately not `verb`: `add_verb` records the long form in `verb`, and a
    nested action writing the string the caller typed would put `rm` back in it.
    """
    action = parser.add_subparsers(
        dest=dest,
        metavar="{" + verb_metavar([name for name, _, _ in groups]) + "}",
        required=True,
    )
    out: dict[str, dict] = {}
    for name, help_text, verbs in groups:
        subparser = add_verb(action, name, help_text)
        leaves: dict[str, argparse.ArgumentParser] = {}
        if verbs is not None:
            nested = subparser.add_subparsers(
                dest="leaf",
                metavar="{" + verb_metavar([verb for verb, _ in verbs]) + "}",
                required=True,
            )
            leaves = add_verbs(nested, verbs)
        out[name] = {"parser": subparser, "verbs": leaves}
    return out


def add_name(parser, help_text: str) -> None:
    """A service name, which carries its environment and may carry a ref."""
    parser.add_argument("name", metavar=NAME_REF, help=help_text)


def add_json(parser, help_text: str = "one JSON object on stdout and nothing else") -> None:
    """Offer `--json` only where spec 1.2 lists it.

    A verb that does not take one rejects the flag, so the rejection is
    argparse's exit `2` and needs no code.
    """
    parser.add_argument("--json", action="store_true", help=help_text)


def pending(invocation: str) -> int:
    """A verb whose body a later ticket writes.

    Exit `1`, so no test and no script can read a skeleton as success. Not
    `2`, which would claim the caller's input was rejected: the input is fine,
    this program has not grown the verb's body yet. The diagnostic is one line
    prefixed `error:` and names the verb, per AGENTS.md.
    """
    sys.stderr.write(f"error: {invocation} is not implemented.\n")
    return 1


def invocation(program: str, group: str | None, verb: str | None) -> str:
    return " ".join(part for part in (program, group, verb) if part)
