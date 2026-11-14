#!/usr/bin/env python3
"""Walk every rendered file of every fixture project and check two properties of
the renderer that belong to it rather than to any one service:

1. **no rendered unit, from any manifest, references a host path outside the
   service's own volumes, `/etc/guarden` and the admin allow list**; and
2. **every rendered port is a loopback publication.**

The first is asserted once over every fixture project rather than per service,
because a repository obtains a host mount by adding a line to a file and a
per-service test would pass as long as somebody remembered to write one. The
second is the same shape of claim: publications are the only ports anything in
guarden binds, a granted public port is a translation onto one of them written
by the mutator, and nothing in a rendered unit may name a non-loopback address
(spec 7.5).

A host path in a rendered unit can only arrive in the places podman reads one
from — the source side of a `Volume=`, a `.volume` unit's `Source=`, or one of
the bind directives the refusal list exists to keep out — so those are the keys
this walks. Anything else in a unit is either a container path, a name, or a
number.

    t40-hostpaths.py <colon-separated allowed prefixes> <rendered file>...

Run by tests/t40-mounts.sh. Exits 0 when every path and port is allowed, 1 with
one line per violation.
"""

from __future__ import annotations

import sys
from pathlib import Path

# The keys whose value can name a path on the host. The first field of each value
# is the source for the two bind forms, which is the one that matters.
HOST_KEYS = {
    "Volume",
    "Source",
    "Mount",
    "BindPaths",
    "BindReadOnlyPaths",
    "ImageMounts",
    "Tmpfs",
}
BIND_KEYS = {"BindPaths", "BindReadOnlyPaths", "ImageMounts"}
MOUNT_SOURCES = ("Volume", "Source", "Mount", "Tmpfs", "ImageMounts")
LOOPBACK = "127.0.0.1"
FINDINGS: list[str] = []


def under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def sources_of(key: str, value: str) -> list[str]:
    if key in BIND_KEYS:
        return [value.split(":", 1)[0]]
    if key == "Mounts":
        fields = dict(part.split("=", 1) for part in value.split(",") if "=" in part)
        return [fields["src"]] if "src" in fields else []
    return [value.split(":", 1)[0]]


def check_file(path: Path, allowed: list[str]) -> None:
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        key, separator, value = stripped.partition("=")
        if not separator:
            continue
        if key == "PublishPort":
            # `PublishPort=<address>:<publication>:<container port>`. A
            # publication with no address binds every interface, which is the
            # one thing a rendered unit may never do.
            if not value.startswith(f"{LOOPBACK}:"):
                FINDINGS.append(f"{path}:{number}: PublishPort is {value!r}, not a loopback one")
            continue
        if key not in HOST_KEYS:
            continue
        for source in sources_of(key, value):
            if not source.startswith("/") or source.endswith(".volume"):
                continue
            if any(under(source, root) for root in allowed):
                continue
            FINDINGS.append(f"{path}:{number}: {key} names the host path {source}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: t40-hostpaths.py <allowed prefixes> <file>...\n")
        return 2
    allowed = [prefix for prefix in argv[0].split(":") if prefix]
    for name in argv[1:]:
        path = Path(name)
        if path.is_file():
            check_file(path, allowed)
            continue
        for child in sorted(path.rglob("*")):
            if child.is_file():
                check_file(child, allowed)
    for finding in FINDINGS:
        sys.stderr.write(f"error: {finding}\n")
    return 1 if FINDINGS else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
