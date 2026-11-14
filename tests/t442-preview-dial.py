#!/usr/bin/env python3
"""The edge's rendered file, read back the way the file provider reads it.

Review r2, finding F2: two instances of one preview service produced the SAME
router key and the SAME `Host()` rule, so a YAML map — which holds one
definition per key — served one of them and dropped the other. The file's text
is not enough to catch that: a file with one router written once looks
identical to a file with two routers, once you only grep for the host.

So the file is parsed with pyyaml — the same YAML layer the written
configuration goes through before the edge ever sees it — and the LINKS are
checked: the router that carries an instance's path is the router that points
at THAT instance's publication, and the two routers are two.

Run by tests/t442-preview-dial.sh.
"""

from __future__ import annotations

import sys

import yaml

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write("usage: t442-preview-dial.py EDGE-FILE PUB-A PUB-B [REF-A REF-B]\n")
        return 2
    path, pub_a, pub_b = sys.argv[1], sys.argv[2], sys.argv[3]
    # The refs are the paths the routers carry. They are arguments and not
    # constants because the suite names the instances it created, and a helper
    # that hard-coded them would be asserting about refs this run never made.
    ref_a, ref_b = ("alpha", "beta")
    if len(sys.argv) >= 6:
        ref_a, ref_b = sys.argv[4], sys.argv[5]
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except OSError as exc:
        sys.stderr.write(f"error: the edge file {path} could not be read: {exc.strerror}\n")
        return 1
    except yaml.YAMLError as exc:
        sys.stderr.write(f"error: the edge file {path} is not YAML: {exc}\n")
        return 1
    if not isinstance(document, dict):
        sys.stderr.write("error: the edge file is not a YAML document\n")
        return 1
    http = document.get("http")
    if not isinstance(http, dict):
        sys.stderr.write("error: the edge file has no http section\n")
        return 1
    routers = http.get("routers")
    services = http.get("services")
    if not isinstance(routers, dict) or not isinstance(services, dict):
        sys.stderr.write("error: the edge file has no routers or no services\n")
        return 1

    check(
        len(routers) == 2,
        f"the edge file names {len(routers)} routers, expected 2 (one per instance): "
        f"{sorted(routers)}",
    )

    # The rule that carries an instance's path, and the target it points at.
    by_path: dict[str, str] = {}
    for name, router in routers.items():
        if not isinstance(router, dict):
            continue
        rule = str(router.get("rule", ""))
        for ref, publication in ((ref_a, pub_a), (ref_b, pub_b)):
            if f"PathPrefix(`/{ref}`)" in rule:
                by_path[ref] = str(name)
                # The router's own `service:` must name a service that exists.
                named = router.get("service")
                check(
                    named in services,
                    f"the router for ref {ref!r} names the service {named!r}, which the "
                    f"file does not define",
                )
                if named in services:
                    entry = services[named]
                    servers = entry.get("loadBalancer", {}).get("servers", [])
                    urls = [str(server.get("url", "")) for server in servers]
                    check(
                        f"http://routed-preview:{publication}" in urls,
                        f"the router for ref {ref!r} points at {urls}, not at the "
                        f"instance's own publication {publication}",
                    )

    for ref in (ref_a, ref_b):
        check(
            ref in by_path,
            f"no router carries the path /{ref}, so that instance is not served at all",
        )

    # The two routers are two: distinct keys, and distinct services. Two
    # instances of one service that share a router key are the collision.
    check(
        len(set(by_path.values())) == len(by_path),
        f"the two instances share a router: {by_path}",
    )

    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
