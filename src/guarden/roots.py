"""roots — the edge's routes.

spec 6.4. Reads the rendered route slice of every service from
`/var/lib/guarden/shared/<name>/` and renders the edge's file-provider
configuration into `/var/lib/guarden/edge/dynamic/`, which is the one directory
it may write. Traefik-specific by decision and with no intermediate route
format: if the edge is ever replaced, `roots` is replaced.

One file per service, so a route change is one file changing and the edge
picks it up from its own watch without a restart, and a service that is removed
takes its routes with it.
"""

from __future__ import annotations

import argparse
import sys

from guarden import cli, conf, edgeconf, errors, paths, render
from guarden import config as config_mod
from guarden import modules as modules_mod

GROUPS = (("sync", "render every service's routes into the edge's directory", None),)

TEMPLATE = "edge-routes.yml.j2"
EXTENSION = ".yml"

EPILOG = """\
`roots sync` writes one file per service into the edge's configuration
directory and nowhere else. The edge reads that directory, so a route change
appears without a restart.

With the auth module installed, a route declaring `auth: true` gets the
forward-auth rule aimed at the service named in /etc/guarden/edge/auth-provider.
With it not installed, `roots` emits the route without a middleware and writes
one warning naming the service and the route, on every sync.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="roots",
        description="The edge's routes.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    cli.add_groups(parser, "group", GROUPS)
    return parser


def slices() -> dict[str, list[dict]]:
    """Every service's rendered routes, in service-name order."""
    out: dict[str, list[dict]] = {}
    if not paths.SHARED.is_dir():
        return out
    for directory in sorted(path for path in paths.SHARED.iterdir() if path.is_dir()):
        routes = conf.read_toml(directory / "routes.toml").get("routes") or []
        if routes:
            out[directory.name] = [dict(route) for route in routes]
    return out


def file_name(service: str) -> str:
    return f"{service}{EXTENSION}"


def _router(service: str, route: dict) -> str:
    return f"{service}-{route.get('label', route.get('host', 'route'))}"


def render_service(service: str, routes: list[dict], entrypoints: list[str]) -> str:
    rows = [
        {
            "router": _router(service, route),
            "rule": f"Host(`{route.get('host', '')}`)",
            "entrypoints": entrypoints,
            "target": f"http://{route.get('target', '')}",
            "middleware": bool(route.get("auth")),
        }
        for route in routes
    ]
    return render.render_template(TEMPLATE, service=service, rows=rows)


def write(service: str, body: str) -> None:
    conf.write_file(paths.EDGE_DYNAMIC / file_name(service), body, 0o644)


def sweep(written: set[str]) -> list[str]:
    """Remove the file of a service that is gone, and nothing else."""
    removed: list[str] = []
    for path in sorted(paths.EDGE_DYNAMIC.glob(f"*{EXTENSION}")):
        if path.name in written:
            continue
        path.unlink()
        removed.append(path.name)
    return removed


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.group != "sync":
        return cli.pending(cli.invocation("roots", args.group, None))
    try:
        return sync()
    except errors.GuardenError as failure:
        sys.stderr.write(failure.report("roots") + "\n")
        return failure.code


def sync() -> int:
    config = config_mod.load()
    entrypoints = _entrypoints(config)
    if not entrypoints:
        raise errors.GuardenError(
            f"no enabled module declares an edge, so there is nothing to render routes into; "
            f"the enabled modules are: {', '.join(config.modules) or 'none'}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    routes = slices()
    written: set[str] = set()
    printed: list[str] = []
    warnings: list[str] = []
    for service, entries in routes.items():
        write(service, render_service(service, entries, entrypoints))
        written.add(file_name(service))
        printed.append(f"{service} {len(entries)} routes")
        if "auth" not in config.modules:
            for route in entries:
                if route.get("auth"):
                    warnings.append(
                        errors.warn(
                            f"{service}: the route {_router(service, route)} declares "
                            f"`auth: true` and the auth module is not installed, so it is "
                            f"emitted without a middleware"
                        )
                    )
    for name in sweep(written):
        printed.append(f"removed {name}")
    for line in warnings:
        sys.stderr.write(line + "\n")
    for line in printed:
        sys.stdout.write(line + "\n")
    return 0


def _entrypoints(config) -> list[str]:
    """The entrypoints a route may be attached to: the ones that serve.

    Read from the edge's own shipped unit source, so the answer is what the
    edge was built with and not a list here that could drift from it. The
    redirect entrypoint is never one of them: every request to it becomes a
    redirect, so a router on it would answer a 301 for a host it was meant to
    proxy.
    """
    for module in config.modules:
        try:
            entry = modules_mod.read(module).edge()
        except errors.GuardenError:
            continue
        if entry is None:
            continue
        found = edgeconf.of_source(modules_mod.source_of(module, entry.name), entry.name)
        serving = edgeconf.routing_entrypoints(found)
        if not serving:
            raise errors.GuardenError(
                f"the edge {entry.name} declares no entrypoint that serves, so every route "
                f"would land on the redirect and answer a redirect instead of the container"
            )
        return serving
    return []


if __name__ == "__main__":
    raise SystemExit(main())
