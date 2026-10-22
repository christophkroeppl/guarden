#!/usr/bin/env python3
"""The spec's route name, against the allocator that computes it.

usage: routename.py <spec.md>

**A document that says what a program computes has to be checked against that
program, not against a copy of its answer.** `docs/spec.md` §4 states what a
route's allocated name is, and the allocator that produces it is
`publications.claim_host` with `service._zone`. A suite that asserted the spec
says `<host_prefix><label>` would be asserting a string copied out of the
spec — so it would stay green the moment the allocator and the spec drifted
apart, which is the exact defect ticket 358 exists to close: the spec claimed
`web.myapp.com` where the allocator wrote `staging.web`, and three suites
pinned the allocator's answer while the contract said otherwise.

So this asks the allocator. It calls the real functions with the real
arguments and compares what the SPEC SAYS to what the allocator RETURNS:

  * the spec must state the bare form — `<track host_prefix><host:>` — as the
    name, and must not offer the shape the allocator never produced;
  * the spec's own examples must be names the allocator can produce, so each
    is checked by ALLOCATING it rather than by reading it;
  * `host.domain` must be stated as the `${domain}` substitution and NOT as
    part of a route's name, because it is in no allocated name.

**It runs in a machine and not on the checkout.** It imports guarden's own
allocator, so it executes a program of this repository, and the rule is that a
program of this repository is executed in a cut machine and nowhere else
(AGENTS.md, "Test seam"). It is a helper rather than a suite because its
subject is a document and a function, not a host's state — the same shape as
`tests/registryhost.py`, which reads the registry a program wrote.

Run by tests/t480-doc-claims.sh.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from guarden import config as config_mod  # noqa: E402
from guarden import exposure  # noqa: E402
from guarden import publications  # noqa: E402
from guarden import service as service_mod  # noqa: E402

TUNNEL_DOMAIN = "tunnel.example.net"

FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        FAILURES.append(what)


def section(text: str, heading: str) -> str:
    """The text of one `## N.` section, up to the next one."""
    start = text.find(f"\n## {heading} ")
    if start < 0:
        return ""
    rest = text[start + 1 :]
    nxt = rest.find("\n## ", 1)
    return rest if nxt < 0 else rest[:nxt]


def track(prefix: str = "staging.", kind: str = config_mod.SLOT):
    """The two fields of a track the allocator reads."""
    return type("Track", (), {"kind": kind, "host_prefix": prefix})()


def allocated(label: str, prefix: str, destination: str, kind: str = config_mod.SLOT) -> str:
    """The name the allocator gives this route, from the allocator itself."""
    zone = service_mod._zone(track(prefix, kind), destination, TUNNEL_DOMAIN, "svc")
    return publications.claim_host(label, prefix, zone, {}, "svc")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: routename.py SPEC.md\n")
        return 2
    spec = Path(argv[1]).read_text(encoding="utf-8")
    four = section(spec, "4.")
    nine = section(spec, "9.")
    three = section(spec, "3.")

    edge = allocated("web", "staging.", exposure.LOOPBACK)
    production = allocated("web", "", exposure.LOOPBACK)
    tunnel = allocated("web", "", exposure.TUNNEL)
    instance = allocated("web", "preview.", exposure.TUNNEL, config_mod.INSTANCE)

    # 1. The spec states the bare form, and the bare form is the allocator's.
    check(
        "<track host_prefix><host:>" in four,
        "spec §4 does not state the bare form `<track host_prefix><host:>` as a route's name",
    )
    check(
        edge == "staging.web",
        f"the allocator computes {edge!r} for the staging track; "
        f"the expected name is `staging.web`",
    )
    check(
        production == "web",
        f"the allocator computes {production!r} for the production track; "
        f"the expected name is the bare label `web`",
    )
    # 2. The spec does not offer the shape the allocator never produced.
    check(
        "web.myapp.com" not in four,
        "spec §4 offers `web.myapp.com` as a route's name; the allocator never produces it — "
        "the prefix is in front of the label, not a subdomain of any domain",
    )

    # 3. The spec's examples are names the allocator can produce. Each is
    #    checked by ALLOCATING it, so an example that drifts from the
    #    allocator's arithmetic fails here rather than misleading a reader.
    #    §3.4's registry record is the production track, whose prefix is
    #    empty, so its tunnel name carries no prefix.
    check(
        tunnel == "web.tunnel.example.net",
        f"the allocator computes {tunnel!r} for a tunnel route; "
        f"the expected name is `web.tunnel.example.net`",
    )
    check(
        instance == "preview.web",
        f"the allocator computes {instance!r} for a preview instance; "
        f"the expected name is `preview.web`",
    )
    for example, where, name in (
        ("staging.web", four, "§4"),
        ("web.tunnel.example.net", three, "§3.4"),
        ("preview.web", nine, "§9"),
    ):
        check(
            example in where,
            f"spec {name} does not carry the example {example!r}, which the allocator produces",
        )

    # 4. `host.domain` is the `${domain}` substitution and is in NO allocated
    #    name. The second half is the part the spec got wrong: it said a
    #    repository "cannot claim a name outside host.domain", which names a
    #    boundary the name does not have.
    check(
        "host.domain" in four,
        "spec §4 does not state `host.domain`'s role",
    )
    check(
        "${domain}" in four,
        "spec §4 does not state that `host.domain` is the `${domain}` substitution",
    )
    # The old sentence, asserted absent by its CLAIM and not by its wording: a
    # boundary drawn around `host.domain`. A reworded version of the same false
    # claim is the same defect, so the rule is about what a sentence SAYS rather
    # than about the words it uses: every sentence in the spec that mentions
    # `host.domain` must either state that it is the substitution's source, or
    # deny that a name is in it. The sentence the spec used to carry — "A
    # repository therefore cannot claim a name outside `host.domain`" — does
    # neither, and is refused.
    negation = re.compile(
        r"\b(?:not|no|never|nor|neither|cannot|can't|isn't|aren't|without)\b", re.IGNORECASE
    )
    for sentence in re.split(r"(?<=[.:])\s+", spec):
        if "host.domain" not in sentence:
            continue
        states_substitution = "substitution" in sentence
        denies_membership = bool(negation.search(sentence)) and bool(
            re.search(r"\bname", sentence, re.IGNORECASE)
        )
        check(
            states_substitution or denies_membership,
            f"the spec makes `host.domain` a boundary a name is inside or outside: {sentence!r}; "
            "`host.domain` is the `${domain}` substitution's source and is in no allocated name",
        )
    for name in (edge, production, tunnel, instance):
        check(
            "example.com" not in name,
            f"the allocator produced {name!r}, which carries a domain — and `host.domain` is in "
            "no allocated name",
        )

    # 5. The zone is the tunnel's, and the spec says so — because the bare
    #    form is only the whole truth for a route the edge serves.
    check(
        "tunnel_domain" in four,
        "spec §4 does not state that a tunnel route's name carries the tunnel's zone",
    )
    check(
        "<track host_prefix><host:>.<tunnel_domain>" in four,
        "spec §4 does not state the tunnel route's name as the prefix, the label and the zone",
    )

    for failure in FAILURES:
        sys.stderr.write(f"error: {failure}\n")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
