#!/usr/bin/env python3
"""The `podlet` fake's model: `podlet quadlet --outdir <dir> <compose.yaml>`.

**A translator with no opinion, on purpose.** Every field the design has an
opinion about is translated the way a converter would translate it and no other
way: `ports:` becomes `PublishPort=` verbatim, `network_mode: host` becomes
`Network=host`, `extra_hosts:` becomes `AddHost=`, and a capability becomes a
`PodmanArgs=` flag. A test that renders a Compose file through this and finds
none of them in the installed unit is testing that **loom** is the boundary, which
is exactly the claim spec 4 makes about running a converter rather than trusting
one.

The call is the pinned release's translation entry point, so what a test drives is
the seam and not a shape invented for the harness. An unmodelled subcommand is a
failure, like every other fake here.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


def die(message: str) -> int:
    sys.stderr.write(f"error: podlet: {message}\n")
    return 2


def parse(argv: list[str]) -> tuple[Path, Path]:
    if not argv or argv[0] != "quadlet":
        raise SystemExit(die(f"{' '.join(argv) or 'no arguments'} is not a modelled invocation"))
    outdir: str | None = None
    sources: list[str] = []
    rest = argv[1:]
    index = 0
    while index < len(rest):
        argument = rest[index]
        if argument == "--outdir":
            index += 1
            if index >= len(rest):
                raise SystemExit(die("--outdir has no directory"))
            outdir = rest[index]
        elif argument.startswith("-"):
            raise SystemExit(die(f"{argument} is not a modelled option"))
        else:
            sources.append(argument)
        index += 1
    if not outdir:
        raise SystemExit(die("quadlet without --outdir writes to stdout, which no caller asks for"))
    if not sources:
        raise SystemExit(die("quadlet without a file translates nothing"))
    return Path(outdir), Path(sources[0])


def environment(body: dict) -> list[str]:
    table = body.get("environment")
    if table is None:
        return []
    if isinstance(table, dict):
        return [f"Environment={key}={value}" for key, value in sorted(table.items())]
    return [f"Environment={item}" for item in table]


def ports(body: dict) -> list[str]:
    """Verbatim, which is the whole problem: a Compose `ports:` entry is exactly
    a `PublishPort=` line, and a renderer that did not strip them would make the
    grant ceiling advisory (ADR-0006)."""
    out = []
    for entry in body.get("ports") or []:
        out.append(f"PublishPort={entry if isinstance(entry, str) else entry.get('published', '')}")
    return out


def volumes(body: dict) -> list[str]:
    out = []
    for entry in body.get("volumes") or []:
        if isinstance(entry, str):
            out.append(f"Volume={entry}")
        elif isinstance(entry, dict):
            options = [entry.get("source", ""), entry.get("target", "")]
            if entry.get("read_only"):
                options.append("ro")
            out.append("Volume=" + ":".join(option for option in options if option))
    return out


def podman_args(body: dict) -> list[str]:
    out = []
    if body.get("privileged") is True:
        out.append("PodmanArgs=--privileged")
    for capability in body.get("cap_add") or []:
        out.append(f"PodmanArgs=--cap-add={capability}")
    for capability in body.get("cap_drop") or []:
        out.append(f"PodmanArgs=--cap-drop={capability}")
    for device in body.get("devices") or []:
        out.append(f"PodmanArgs=--device={device}")
    if body.get("pid") == "host":
        out.append("PodmanArgs=--pid=host")
    if body.get("userns_mode"):
        out.append(f"PodmanArgs=--userns={body['userns_mode']}")
    for flag in body.get("podman_args") or []:
        out.append(f"PodmanArgs={flag}")
    return out


def network(body: dict) -> list[str]:
    mode = body.get("network_mode")
    if not mode:
        return []
    if mode == "host":
        return ["Network=host"]
    if str(mode).startswith("container:"):
        return ["Network=container:ignore"]
    return [f"Network={mode}"]


def unit_for(name: str, body: dict, source: Path) -> str:
    lines = [
        f"# podlet fixture: a mechanical translation of the {name!r} service of {source.name}",
        "[Container]",
    ]
    if body.get("image"):
        lines.append(f"Image={body['image']}")
    if body.get("container_name"):
        lines.append(f"ContainerName={body['container_name']}")
    if body.get("user"):
        lines.append(f"User={body['user']}")
    if body.get("working_dir"):
        lines.append(f"WorkingDir={body['working_dir']}")
    if body.get("entrypoint"):
        entry = body["entrypoint"]
        joined = " ".join(entry) if isinstance(entry, list) else str(entry)
        lines.append(f"Entrypoint={joined}")
    if body.get("command"):
        command = body["command"]
        joined = " ".join(command) if isinstance(command, list) else str(command)
        lines.append(f"Exec={joined}")
    lines.extend(environment(body))
    for label, value in sorted((body.get("labels") or {}).items()):
        lines.append(f"Label={label}={value}")
    for host in body.get("extra_hosts") or []:
        lines.append(f"AddHost={host}")
    lines.extend(ports(body))
    lines.extend(volumes(body))
    lines.extend(podman_args(body))
    lines.extend(network(body))
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    outdir, source = parse(argv)
    document = yaml.safe_load(source.read_text(encoding="utf-8")) or {}
    services = document.get("services") or {}
    if not isinstance(services, dict):
        return die(f"{source}: `services:` is not a mapping")
    outdir.mkdir(parents=True, exist_ok=True)
    for name, body in sorted(services.items()):
        (outdir / f"{name}.container").write_text(
            unit_for(name, body or {}, source), encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
