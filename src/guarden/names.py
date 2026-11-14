"""Names: a service name, a track, a ref, and what each may contain.

spec 5.1 and 5.2. A service name is `<workload>-<environment>` where the
environment is the last `-`-separated segment and must name a track in the
operator's table. There is no `--env` flag, so a name and an environment cannot
disagree.

The interesting part is what happens when the last segment names no track. spec
5.1 makes that exit `2` with one exception: `weedr service add` resolves a
default, and the default is **the first track in table order with `gated = false`
and `kind = "slot"`** — resolved by that rule and not by the word `staging`,
because the shipped table is a default and an operator who has marked `staging`
gated would otherwise get a documented default that creates a gated service,
which is the one thing the rule exists to prevent. `ingest` does not get the
exception: a poke always names the full service name, and a poke that could
invent its environment would be a poke choosing a track.

The 31-character limit is on the **service name**, after resolution, and not on
`project`: a project name has no limit of its own, and what has to fit is the
Linux user name that ends up holding a uid the firewall matches on.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

from guarden import errors

if TYPE_CHECKING:
    from guarden.config import Track

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
NAME_LIMIT = 31


@dataclass(frozen=True)
class Resolved:
    """A service name after its environment has been resolved, and where it came from."""

    name: str
    track: Track
    ref: str | None
    escaped_ref: str | None
    defaulted: bool


def validate(name: str, what: str = "service name") -> str:
    """The three rules a whole name must satisfy, in the order they are reported."""
    if not NAME_RE.match(name):
        raise errors.GuardenError(f"{what} {name!r} must match {NAME_RE.pattern}")
    if len(name) > NAME_LIMIT:
        raise errors.GuardenError(
            f"{what} {name!r} is {len(name)} characters; the limit is {NAME_LIMIT} "
            f"because it becomes a Linux user name"
        )
    if ".." in name:
        raise errors.GuardenError(f"{what} {name!r} may not contain '..'")
    return name


def split(name_argument: str) -> tuple[str, str | None]:
    """`<name>` or `<name>/<ref>`. The ref is taken raw and may itself contain `/`,
    so the split is on the first one and never on the last."""
    if "/" in name_argument:
        service, ref = name_argument.split("/", 1)
        return service, ref
    return name_argument, None


def environment_segment(name: str) -> str:
    return name.rsplit("-", 1)[-1] if "-" in name else name


def workload_of(name: str, track_name: str) -> str:
    """The name without its environment segment, which is what the registry calls workload."""
    if name == track_name:
        raise errors.GuardenError(f"service name {name!r} is a track name with no workload segment")
    return name[: -(len(track_name) + 1)]


def default_track(tracks: list[Track]) -> Track:
    """The first track in table order with `gated = false` and `kind = "slot"`."""
    for track in tracks:
        if not track.gated and track.kind == "slot":
            return track
    raise errors.GuardenError(
        'no track in /etc/guarden/guarden.toml is ungated and kind = "slot", '
        "so a name with no environment has nothing to resolve to",
        errors.HOST_NOT_AS_ASSUMED,
    )


def resolve(name_argument: str, tracks: list[Track], allow_default: bool) -> Resolved:
    """Resolve `<name>[/<ref>]` to a full service name and its track.

    `allow_default` is `weedr service add` and nothing else; see the module note.
    """
    if not tracks:
        raise errors.GuardenError(
            "guarden.toml has no [[environments]] table, so no service name can be resolved",
            errors.HOST_NOT_AS_ASSUMED,
        )
    known = ", ".join(track.name for track in tracks)
    service, ref = split(name_argument)
    if ref == "":
        # `<name>/` names no instance: the empty string is falsy everywhere the
        # code asks whether there is an instance (spec 5.2), so without this
        # refusal a trailing slash rendered into the SHARED slot and answered 0
        # — review finding 7. A trailing slash is not a name; the ref after the
        # first `/` either exists or the argument does not say what it means.
        raise errors.GuardenError(
            f"{name_argument!r} names an empty ref: in <name>[/<ref>] the ref is "
            f"the part after the first '/', and an empty one names no instance — "
            f"give the ref, or no '/' at all",
            errors.REJECTED_INPUT,
        )
    validate(service)

    segment = environment_segment(service)
    match = next((track for track in tracks if track.name == segment), None)
    defaulted = False
    if match is None:
        if not allow_default:
            raise errors.GuardenError(
                f"service name {service!r} has no environment segment naming a track; "
                f"the tracks are: {known}"
            )
        match = default_track(tracks)
        service = f"{service}-{match.name}"
        defaulted = True
        validate(service, "resolved service name")

    validate(workload_of(service, match.name))
    return Resolved(
        name=service,
        track=match,
        ref=ref,
        escaped_ref=systemd_escape(ref) if ref is not None else None,
        defaulted=defaulted,
    )


def known_tracks(tracks: list[Track]) -> str:
    return ", ".join(track.name for track in tracks)


_SYSTEMD_SAFE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:")


def systemd_escape(ref: str) -> str:
    """`systemd-escape` of a ref, over its UTF-8 bytes.

    spec 5.2: every verb takes the ref raw and the escaping is internal, so
    `feature/x` and `feature-x` can never collide. The same escaped form is used
    for the instance directory, the registry key and the deploy lock name, so one
    rule governs every place a ref becomes part of a path, a key or a filename.
    """
    out: list[str] = []
    for byte in ref.encode("utf-8"):
        char = chr(byte)
        if char in _SYSTEMD_SAFE:
            out.append(char)
        else:
            out.append(f"\\x{byte:02x}")
    return "".join(out)
