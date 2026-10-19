"""roots — the edge's routes.

spec 6.4. Reads the rendered route slice of every service from
`/var/lib/guarden/shared/<name>/` and renders the edge's file-provider
configuration into `/var/lib/guarden/edge/dynamic/`, which is the one directory
it may write. Traefik-specific by decision and with no intermediate route
format: if the edge is ever replaced, `roots` is replaced.

One file per service, so a route change is one file changing and the edge
picks it up from its own watch without a restart, and a service that is removed
takes its routes with it.

With the tunnel module, `roots` also renders a tunnel ingress file into
`/var/lib/guarden/tunnel/ingress/` for routes whose destination is `tunnel`.
"""

from __future__ import annotations

import argparse
import re
import sys

from guarden import basicauth, cli, conf, edgeconf, errors, names, paths, registry, render
from guarden import config as config_mod
from guarden import modules as modules_mod

GROUPS = (("sync", "render every service's routes into the edge's directory", None),)

TEMPLATE = "edge-routes.yml.j2"
EXTENSION = ".yml"
# The per-service basic-auth middleware's name suffix, shared with the template
# that emits it so the name is written once (ticket 292).
BASICAUTH_SUFFIX = "-basicauth"
FORWARD_AUTH = f"_{edgeconf.MIDDLEWARE}{EXTENSION}"

TUNNEL_TEMPLATE = "tunnel-ingress.yml.j2"

EPILOG = """\\
`roots sync` writes one file per service into the edge's configuration
directory and nowhere else. The edge reads that directory, so a route change
appears without a restart.

With the auth-authelia module installed, /etc/guarden/edge/auth-provider names the
service a route declaring `auth: true` is put behind, and roots validates that
name on every sync: it must be a service that exists in a track with
`gated = true`, and anything else is exit 1 with nothing written at all.
With the module not installed, roots emits the route without a middleware and
writes one warning naming the service and the route, on every sync.
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


def basicauth_flags() -> dict[str, bool]:
    """The per-service basic-auth policy the renderer recorded (ticket 292).

    Read from the same slice file `slices()` reads, so the middleware and the
    routes it attaches to can never come from two sources. A service whose
    slice predates the flag (or carries `false`) is grandfathered: no flag, no
    middleware, byte-identical output.
    """
    out: dict[str, bool] = {}
    if not paths.SHARED.is_dir():
        return out
    for directory in sorted(path for path in paths.SHARED.iterdir() if path.is_dir()):
        out[directory.name] = bool(
            conf.read_toml(directory / "routes.toml").get("basicauth")
        )
    return out


def file_name(service: str) -> str:
    return f"{service}{EXTENSION}"


def _router(service: str, route: dict) -> str:
    return f"{service}-{route.get('label', route.get('host', 'route'))}"


def render_service(service: str, routes: list[dict], entrypoints: list[str],
                   provider: str | None, basicauthed: bool = False) -> str:
    """One service's routes, as the file provider reads them.

    A route carries the forward-auth middleware only when it asked for it,
    there is a provider to ask for it from, and it is not the provider's own
    route. The provider's own route is the lockout this excludes: a sign-in
    page behind itself cannot be reached, whatever its manifest declares.

    The **basic-auth** middleware (ticket 292) is the other half of the story
    and is deliberately not a route's to choose: when the mutator recorded the
    policy for this service, every route the edge serves here carries it, in
    front of forward-auth when both apply. No manifest reaches this flag — it
    arrives in the slice from the registry — so there is no key that removes
    it (spec 4's closed key sets, spec 10).
    """
    rows = [
        {
            "router": _router(service, route),
            "rule": f"Host(`{route.get('host', '')}`)",
            "entrypoints": entrypoints,
            "target": f"http://{route.get('target', '')}",
            "middleware": bool(route.get("auth")) and provider is not None
            and service != provider,
            "basicauth": bool(basicauthed),
        }
        for route in routes
        if route.get("destination") == "edge"
    ]
    if not rows:
        return ""
    # One file, one definition: a service with no policy renders byte for byte
    # what it rendered before, and the file provider merges this directory, so
    # the definition exists only in the files that use it.
    return render.render_template(
        TEMPLATE,
        service=service,
        rows=rows,
        basicauth_name=f"{service}{BASICAUTH_SUFFIX}",
        users_file=basicauth.users_file(service) if basicauthed else "",
    )


def write(service: str, body: str) -> None:
    if not body:
        return
    conf.write_file(paths.EDGE_DYNAMIC / file_name(service), body, 0o640)


def _quote_ref(escaped_ref: str) -> str:
    r"""`escaped_ref` as a regex fragment: its `\xNN` byte escapes kept, the
    rest quoted.

    cloudflared's `ingress.path` is a regex, and `systemd_escape` already
    leaves a ref in a form the engine reads byte for byte: a byte outside the
    safe set is `\xNN`, a hex escape matching that raw byte of the request
    path, while what it passes through raw is the safe set — and `.` among
    those is a metacharacter. So the `\xNN` runs stay as they are and
    everything else goes through `re.escape`.
    """
    parts = re.split(r"(\\x[0-9a-fA-F]{2})", escaped_ref)
    return "".join(
        part if index % 2 else re.escape(part) for index, part in enumerate(parts)
    )


def _ingress_path(ref: str) -> str:
    r"""A preview ref as cloudflared's `ingress.path`: quoted, anchored, and
    written to survive the template's double-quoted YAML scalar.

    `^/<quoted>(/|$)` because ingress matching is first-match-wins and the
    `http_status:404` catch-all is last: an unanchored `/abc` answers `/abcd`
    and a raw `.` answers every request on the preview hostname, so whichever
    preview renders first wins every contested path.

    The backslashes are doubled because `path:` is written between double
    quotes, where `\xNN` is itself an escape — undoubled it decodes in transit
    and hands the regex a bare `-` instead of `systemd_escape`'s output,
    undoing the escaping the ref's validation depends on.
    """
    pattern = f"^/{_quote_ref(names.systemd_escape(ref))}(/|$)"
    return pattern.replace("\\", "\\\\")


def render_tunnel(routes: list[dict], config) -> str:
    """The host's tunnel ingress, as `cloudflared` reads it.

    Only routes whose destination is `tunnel` are rendered. The catch-all is
    `http_status:404` and is last, so a hostname in the tunnel's zone that no
    service claims is a 404 from the tunnel rather than a default page.

    Preview instances on the tunnel are published at preview.<tunnel_domain>/<ref>
    as a path on one host (same shape as preview.$DOMAIN/<ref>).
    """
    if not config.tunnel_domain:
        return ""
    rows = [
        {
            "hostname": route.get("host", ""),
            "service": f"http://{route.get('target', '')}",
        }
        for route in routes
        if route.get("destination") == "tunnel"
    ]

    previews = []
    if config.tunnel_domain:
        for _service_name, entries in slices().items():
            for route in entries:
                if route.get("destination") == "tunnel" and route.get("ref"):
                    # This is a tunnel route for a preview instance
                    previews.append({
                        "hostname": f"preview.{config.tunnel_domain}",
                        "service": f"http://{route.get('target', '')}",
                        "path": _ingress_path(route["ref"]),
                    })

    if not rows and not previews:
        return ""
    return render.render_template(TUNNEL_TEMPLATE, rows=rows, previews=previews)


def write_tunnel(body: str) -> None:
    if not body:
        return
    paths.TUNNEL.mkdir(parents=True, exist_ok=True)
    conf.write_file(paths.TUNNEL_CONFIG, body, 0o640)


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


def provider_for(config) -> str | None:
    """The auth service a `auth: true` route is put behind, or `None`.

    The module not being enabled is `None` and not an error: the ticket makes an
    absent provider a warning on every sync rather than a failure, because a
    host without the auth-authelia module is a host whose routes were never protected and
    making `roots` fail would break the edge on top of it.

    The module being enabled and the marker being unusable IS an error, raised
    from `edgeconf.provider` and caught by `main` as exit 1 with nothing
    written.
    """
    if "auth-authelia" not in config.modules:
        return None
    return edgeconf.provider(config)


def _warnings(routes: dict[str, list[dict]], provider: str | None) -> list[str]:
    """One `warning:` line per route that asked for the middleware and did not
    get it, every sync.

    Repeated rather than once-ever on purpose: a warning somebody scrolled past
    is the same as no warning at all. There is no provider's-own-route case to
    skip: with no provider named, no route is the provider's.
    """
    if provider is not None:
        return []
    out: list[str] = []
    for service, entries in routes.items():
        for route in entries:
            if not route.get("auth"):
                continue
            out.append(
                errors.warn(
                    f"{service}: the route {_router(service, route)} declares `auth: true` "
                    f"and the auth-authelia module is not installed, so it is emitted without a "
                    f"middleware"
                )
            )
    return out


def provider_publication(provider: str) -> int:
    """The loopback publication the provider's own sign-in page is reached on.

    Read from the provider's own route slice rather than guessed from its
    registry: the slice says which container serves the route, and a provider
    with two containers would otherwise be aimed at whichever publication sorted
    first. A registry with no entry for it at all is exit `1` naming the service,
    because a forward-auth rule aimed at port 0 answers nothing and looks
    configured.
    """
    slice_path = paths.SHARED / provider / "routes.toml"
    for route in conf.read_toml(slice_path).get("routes") or []:
        publication = route.get("publication")
        if isinstance(publication, int) and not isinstance(publication, bool) and publication:
            return publication
    record = registry.load(provider)
    held = sorted(set(record.publication.values())) if record is not None else []
    if held:
        return held[0]
    raise errors.GuardenError(
        f"the auth provider {provider} holds no publication, so a route put behind it would "
        f"be aimed at nothing; `weedr service list` reports the publications a service holds",
        errors.HOST_NOT_AS_ASSUMED,
    )


def forward_auth(provider: str) -> str:
    """The middleware definition, aimed at the provider's own publication.

    Forward-auth is one request to the provider, answered with a redirect to its
    sign-in page or with 2xx carrying the header, so the address is
    `<name>:<publication>` — the same form every route target uses (spec 7.3),
    because the edge resolves the name through the `AddHost=` entry loom wrote
    and a loopback address would be the host's, which a container does not share.
    """
    return render.render_template(
        "edge-forward-auth.yml.j2",
        middleware=edgeconf.MIDDLEWARE,
        address=f"{provider}:{provider_publication(provider)}",
    )


def sync() -> int:
    config = config_mod.load()
    entrypoints = _entrypoints(config)
    if not entrypoints:
        raise errors.GuardenError(
            f"no enabled module declares an edge, so there is nothing to render routes into; "
            f"the enabled modules are: {', '.join(config.modules) or 'none'}",
            errors.HOST_NOT_AS_ASSUMED,
        )
    provider = provider_for(config)
    routes = slices()
    policies = basicauth_flags()
    # **The whole plan is rendered before the first byte is written**, after
    # `provider_for` has refused a marker that does not hold. A validator that
    # writes the routes and then complains has already broken the routes that
    # were working, which is the one outcome this exists to prevent.
    plan = [
        (service, render_service(service, entries, entrypoints, provider,
                                 policies.get(service, False)))
        for service, entries in routes.items()
    ]
    auth_body = forward_auth(provider) if provider else None
    written = {file_name(service) for service, body in plan if body}

    tunnel_body = render_tunnel(
        [route for entries in routes.values() for route in entries], config
    )

    for service, body in plan:
        write(service, body)
    if auth_body is not None:
        conf.write_file(paths.EDGE_DYNAMIC / FORWARD_AUTH, auth_body, 0o640)
        written.add(FORWARD_AUTH)
    if tunnel_body:
        write_tunnel(tunnel_body)
    elif paths.TUNNEL_CONFIG.is_file():
        paths.TUNNEL_CONFIG.unlink()
    printed = [f"{service} {len(routes[service])} routes" for service, _ in plan]
    for name in sweep(written):
        printed.append(f"removed {name}")

    for line in _warnings(routes, provider):
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