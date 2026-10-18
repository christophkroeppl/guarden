#!/usr/bin/env python3
r"""The tunnel's preview `path:` rules, read back the way `cloudflared` reads them.

ticket 264: `ingress.path` is a regex, first-match-wins, and the
`http_status:404` catch-all is last — so the path a preview ref renders into
has to be quoted (a raw `.` is a metacharacter `systemd_escape` passes
through), anchored (`/abc` must not match `/abcd`), and it has to arrive byte
for byte (the template's scalar is double-quoted YAML, where `\x2d` is an
escape that decodes in transit and hands the regex a different string than the
one the escaping produced).

The file is parsed with pyyaml — the same YAML layer the written config goes
through before `cloudflared` ever sees it — and each rule is matched against
request paths with Python's `re`, whose `\xHH` hex escape, anchors and
alternation are the semantics Go's `regexp` shares for these patterns.

Run by tests/t360-ingress-path.sh.
"""

from __future__ import annotations

import re
import sys

import yaml

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def matches(rule: dict, request: str) -> bool:
    return re.search(str(rule["path"]), request) is not None


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: t360-ingress-path.py TUNNEL-CONFIG\n")
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
    if not isinstance(document, dict) or "ingress" not in document:
        sys.stderr.write("error: the tunnel config is not a document with an ingress list\n")
        return 1

    previews = [rule for rule in document["ingress"] if isinstance(rule, dict) and "path" in rule]
    by_target = {str(rule.get("service")): rule for rule in previews}
    check(
        len(previews) == 3,
        "the three preview routes should each render exactly one ingress path, "
        f"got {[rule.get('path') for rule in previews]}",
    )

    def preview(publication: int) -> dict | None:
        return by_target.get(f"http://routed-preview:{publication}")

    # The ticket's headline: a preview whose ref is `.` must not match a
    # request for another preview's ref. First-match-wins makes an unanchored
    # `/."` the rule that answers every contested path on the hostname.
    dot = preview(32001)
    check(dot is not None, "the preview with ref '.' rendered no ingress rule")
    if dot is not None:
        check(
            not matches(dot, "/abc"),
            f"the ingress path for ref '.' renders as {dot['path']!r} and matches "
            f"/abc, so this preview captures another preview's traffic",
        )
        check(
            matches(dot, "/."),
            f"the ingress path for ref '.' renders as {dot['path']!r} and does not "
            f"match its own request /.",
        )
        check(
            matches(dot, "/./deep"),
            f"the ingress path for ref '.' renders as {dot['path']!r} and does not "
            f"match a request under its own path",
        )
        check(
            dot.get("hostname") == "preview.tunnel.example.net",
            f"the preview rules belong on preview.tunnel.example.net, got {dot.get('hostname')!r}",
        )

    # Anchoring: `/abc` is the preview's own path, `/abcd` is another ref's.
    abc = preview(32002)
    check(abc is not None, "the preview with ref 'abc' rendered no ingress rule")
    if abc is not None:
        check(
            not matches(abc, "/abcd"),
            f"the ingress path for ref 'abc' renders as {abc['path']!r} and matches "
            f"/abcd, so it is unanchored",
        )
        check(
            matches(abc, "/abc"),
            f"the ingress path for ref 'abc' renders as {abc['path']!r} and does not "
            f"match its own request /abc",
        )
        check(
            matches(abc, "/abc/deep"),
            f"the ingress path for ref 'abc' renders as {abc['path']!r} and does not "
            f"match a request under its own path",
        )

    # The YAML round trip: `systemd_escape("feature-x")` is `feature\x2dx`, and
    # that exact string has to be what the regex engine is handed — in a
    # double-quoted YAML scalar `\x2d` decodes to `-` in transit, undoing the
    # escaping, and the engine must still match the raw request `/feature-x`
    # (a hex escape does that; a decoded `-` only appears to).
    fx = preview(32003)
    check(fx is not None, "the preview with ref 'feature-x' rendered no ingress rule")
    if fx is not None:
        check(
            "feature\\x2dx" in str(fx["path"]),
            f"systemd_escape's output does not survive the YAML round trip byte for "
            f"byte: the ingress path for ref 'feature-x' is {fx['path']!r}",
        )
        check(
            matches(fx, "/feature-x"),
            f"the ingress path for ref 'feature-x' renders as {fx['path']!r} and does "
            f"not match its own request /feature-x",
        )
        check(
            not matches(fx, "/feature-xother"),
            f"the ingress path for ref 'feature-x' renders as {fx['path']!r} and "
            f"matches /feature-xother, so it is unanchored",
        )

    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main())
