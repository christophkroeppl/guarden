#!/usr/bin/env python3
"""The tunnel's ingress hostnames, read back the way cloudflared reads them.

usage: t454-tunnel-hostname.py <tunnel-config> <hostname> [<hostname>...]

The tunnel's ingress file is YAML and cloudflared matches it **first match
wins**, so a hostname that is not in the list is a hostname the tunnel does not
answer: the request falls through to the `http_status:404` catch-all. Ticket
324's defect was a route published at a bare label — `web` — which is in no
zone at all, so no DNS could answer it and nothing said so.

The file is parsed with pyyaml — the same YAML layer the written config goes
through before cloudflared ever sees it — and the hostnames are read out of the
`ingress` list. A `grep` over the text would find the name inside a comment or
inside a path rule; this asks the parsed document.

Each named hostname must be present as the `hostname` of a rule that has a
`service` — a rule without a service is not a route, and a route whose service
is empty dials nothing.

Run by tests/t454-tunnel-hostname.sh.
"""

from __future__ import annotations

import sys

import yaml

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: t454-tunnel-hostname.py TUNNEL-CONFIG HOSTNAME...\n")
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
    if not isinstance(document, dict) or not isinstance(document.get("ingress"), list):
        sys.stderr.write("error: the tunnel config is not a document with an ingress list\n")
        return 1

    rules = [rule for rule in document["ingress"] if isinstance(rule, dict)]
    by_hostname: dict[str, list[dict]] = {}
    for rule in rules:
        hostname = rule.get("hostname")
        if isinstance(hostname, str):
            by_hostname.setdefault(hostname, []).append(rule)

    for wanted in sys.argv[2:]:
        found = by_hostname.get(wanted)
        check(
            found is not None,
            f"the tunnel's ingress carries no rule for the hostname {wanted!r}; "
            f"it carries {sorted(by_hostname)}",
        )
        for rule in found or []:
            service = rule.get("service")
            check(
                isinstance(service, str) and service.startswith("http://"),
                f"the rule for {wanted!r} dials {service!r}, which is no service",
            )

    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
