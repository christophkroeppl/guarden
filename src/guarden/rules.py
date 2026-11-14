"""A `firewall:` request: its closed shape, and its one translation into ferm.

spec 7.7. A request is one iptables-shaped rule line because that is the dialect
`iptables-save` prints back, so an admin can read a request against the running
ruleset without knowing ferm's stanza syntax. **The accepted shape is closed and
the closure is the whole of the guarantee**: a request may add a rule to a chain
guarden renders and may do nothing else, so there is nothing here that opens,
closes, renames or flushes a chain or a table, sets a policy, or inserts rather
than appends — the keys that could are not in the tables below.

The translation into ferm is a total function of the accepted shape, one ferm
keyword per accepted option, and the tables here are the only place either
half is written. `manifest` validates through `parse` and the mutator renders
through `ferm_line`, so the shape that was checked is the shape that is written.

The one rule here that is not a request is `resolver_lines`: the accept the host
itself needs for its own stub resolver (spec §7.6, ADR-0016). It is a rendered
accept in the mutator's dialect, drawn from guarden's knowledge of the host and
from no configuration, and no key anywhere adds one.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass

from guarden import errors

DEFAULT_CHAIN = "guarden-svc"

# systemd-resolved's stub listener. One address, not the loopback network the
# default deny covers, and one port on both protocols because the stub listens on
# both — ADR-0016.
RESOLVER_ADDRESS = "127.0.0.53"
RESOLVER_PORT = 53
RESOLVER_PROTOCOLS = ("udp", "tcp")

# The uid that resolves names on the host's own behalf. Root is not a service
# uid and never is — but every name lookup on a systemd-resolved host goes to
# the stub, so refusing root's query breaks the box's own tooling rather than
# only the workloads. ADR-0023.
ROOT_UID = 0

# The chains guarden renders, and the only two a request may name. `guarden-in`
# is soil's skeleton in 10-framework.conf and `guarden-svc` is the mutator's own
# in 50-services.conf; growing this set is a change to spec 7.7.
GRANTABLE_CHAINS = (DEFAULT_CHAIN, "guarden-in")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

TOKEN_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")
ADDRESS_RE = re.compile(r"^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$")
INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.:@-]+$")
PORT_RE = re.compile(r"^([0-9]+([:-][0-9]+)*|[a-z][a-z0-9-]*)$")

JUMP = "jump"
GOTO = "goto"
JUMP_KEYS = ("-j", "--jump", "-g", "--goto")

FLAGS = {
    "-f": "fragment",
    "--fragment": "fragment",
}

VALUES = {
    "-p": ("proto", TOKEN_RE),
    "--protocol": ("proto", TOKEN_RE),
    "-s": ("saddr", ADDRESS_RE),
    "--source": ("saddr", ADDRESS_RE),
    "-d": ("daddr", ADDRESS_RE),
    "--destination": ("daddr", ADDRESS_RE),
    "--sport": ("sport", PORT_RE),
    "--source-port": ("sport", PORT_RE),
    "--dport": ("dport", PORT_RE),
    "--destination-port": ("dport", PORT_RE),
    "-i": ("if", INTERFACE_RE),
    "--in-interface": ("if", INTERFACE_RE),
    "-o": ("outerface", INTERFACE_RE),
    "--out-interface": ("outerface", INTERFACE_RE),
}

# The options whose ferm spelling carries its module. Each keyword below is the
# WHOLE ferm phrase, module included: `mod owner uid-owner 1001`, not a bare
# `uid-owner 1001`, because ferm only reads a match as belonging to a module it
# was told to load and a rule naming a module it was not is a rule the whole
# file fails to load. `-m` is deliberately absent — naming a module is what these
# do, and a bare `-m` whose module this program does not spell out would be the
# one option that could produce a rule iptables refuses.
MODULED = {
    "--tcp-flags": ("mod tcp tcp-flags", r"^[A-Za-z0-9_,!]+$"),
    "--icmp-type": ("mod icmp icmp-type", TOKEN_RE),
    "--uid-owner": ("mod owner uid-owner", TOKEN_RE),
    "--gid-owner": ("mod owner gid-owner", TOKEN_RE),
    "--limit": ("mod limit limit", TOKEN_RE),
    "--limit-burst": ("mod limit limit-burst", TOKEN_RE),
}

# The targets a rule in the filter table's own chain may carry: the built-in
# verdicts, `LOG`, and a chain guarden renders. `DNAT`, `SNAT` and `MASQUERADE`
# are nat targets and would not load in this chain, and a jump to any other
# chain is a jump guarden does not render.
TARGETS = frozenset(
    {
        "ACCEPT",
        "DROP",
        "REJECT",
        "RETURN",
        "NOP",
        "LOG",
        *GRANTABLE_CHAINS,
    }
)

# Refused by name, so the diagnostic can say what the key does rather than only
# that it is unknown. The decision is the closed table above; this is why a
# developer can act on the answer.
REFUSED = {
    "-N": "creates a chain",
    "--new-chain": "creates a chain",
    "-X": "deletes a chain",
    "--delete-chain": "deletes a chain",
    "-E": "renames a chain",
    "--rename-chain": "renames a chain",
    "-F": "flushes a chain",
    "--flush": "flushes a chain",
    "-P": "sets a chain's policy",
    "--policy": "sets a chain's policy",
    "-Z": "zeroes a chain's counters",
    "--zero": "zeroes a chain's counters",
    "-I": "inserts a rule at a position",
    "--insert": "inserts a rule at a position",
    "-D": "deletes a rule",
    "--delete": "deletes a rule",
    "-R": "replaces a rule in place",
    "--replace": "replaces a rule in place",
    "-A": "appends by naming the chain itself",
    "--append": "appends by naming the chain itself",
    "-t": "names a table",
    "--table": "names a table",
}

REASON = (
    "a request may only add a rule to a chain guarden renders: the manifest's "
    "`firewall:` entry is closed to name, chain and rule, and position is "
    "guarden's"
)


@dataclass(frozen=True)
class Match:
    keyword: str
    values: tuple[str, ...]
    negated: bool


@dataclass(frozen=True)
class Request:
    """One parsed rule: the matches, the target that ends it, and the line.

    `rule` is the text as the manifest wrote it, because that is what
    `weedr firewall list` reports and what deduplication is by content; the
    translation into ferm is derived from the parsed shape and never the other
    way round.
    """

    matches: tuple[Match, ...]
    jump: str
    target: str
    rule: str

    def ferm_line(self) -> str:
        # **The `!` goes between the keyword and its value**, which is where
        # ferm reads it: `dport ! ftp`, `saddr ! 192.0.2.0/24`, and
        # `mod owner uid-owner ! 1001`. A `!` before the keyword is not a
        # negation in ferm's dialect and a rule carrying one does not load.
        words: list[str] = []
        for match in self.matches:
            words.append(match.keyword)
            if match.negated:
                words.append("!")
            words += list(match.values)
        words += [self.jump, self.target]
        return " ".join(words) + ";"


def resolver_lines(uids: Iterable[int]) -> list[str]:
    """The stub resolver's accepts, one line per uid and per protocol, and the
    reply accepts beside them.

    `podman pull` runs on the host as the service user, so its DNS query leaves
    through `OUTPUT` and meets the default deny — pasta's exclusion from the
    loopback mapping is about traffic from *inside* a container and says nothing
    about this path (spec §7.6, ADR-0016). One address, one port, both
    protocols, owner-matched to service uids like every other accept and to root
    beside them (ADR-0023), and no key anywhere that adds another.

    **The reply accept belongs here, in `OUTPUT`, and not in `INPUT`.** The
    query is sent by the service uid, so it carries the owner match. The reply
    is sent by systemd-resolved, not the service uid, so no owner match can
    fire on it — and because both endpoints are local, the reply is locally
    generated and traverses `OUTPUT` before it is ever delivered to `INPUT`,
    where it meets the same default deny. An accept by source address alone is
    the whole of it: only the resolver holds `127.0.0.53:53`, and a loopback
    source cannot be forged from a service uid.

    **Root is in the set, and it is the host's own fact rather than the
    registry's** (ADR-0023). The uid list this function takes is the service
    uids; root is not one and never will be — the registry is a record of the
    workloads, and root is not a workload. But a name lookup on a
    systemd-resolved host goes to the stub at `127.0.0.53`, so refusing root's
    query does not confine the damage to a workload: it breaks the box's own
    tooling. Measured on a converged host, root's `getent hosts <name>` exits 2
    with the deny's own counter moving, `curl <url>` exits 6, and
    `apt-get update` reports "Temporary failure resolving archive.ubuntu.com"
    — while the same lookup as the service uid answers. **And the refusal is
    invisible where it costs the most:** `apt-get update` still exits 0, so a
    host whose package index silently stopped refreshing looks like a host
    whose mirror was merely unreachable.

    So root's accepts are rendered here, from the host's own knowledge, beside the
    service ones and not as one of them: the same address, the same port, the same two
    protocols, and no key anywhere that adds another. **"Beside" is about the
    reasoning and not about the file** — `sorted()` puts uid 0's two lines first, so
    `50-services.conf` shows root's accepts above every service uid's. The order
    carries no meaning: accepts are not ordered among themselves and every accept
    precedes the deny.
    """
    every = sorted(set(uids) | {ROOT_UID})
    lines = [
        f"    mod owner uid-owner {uid} daddr {RESOLVER_ADDRESS} "
        f"proto {protocol} dport {RESOLVER_PORT} jump ACCEPT;"
        for uid in every
        for protocol in RESOLVER_PROTOCOLS
    ]
    lines += [
        f"    saddr {RESOLVER_ADDRESS} "
        f"proto {protocol} sport {RESOLVER_PORT} jump ACCEPT;"
        for protocol in RESOLVER_PROTOCOLS
    ]
    return lines


def validate_name(value: object, where: str) -> str:
    if not isinstance(value, str) or not NAME_RE.match(value):
        raise errors.GuardenError(
            f"{where}: a firewall entry names {value!r} as its `name`, and it is what a grant "
            f"names, so it must match {NAME_RE.pattern} and be stable in the repository"
        )
    return value


def validate_chain(value: object, where: str) -> str:
    if value is None:
        return DEFAULT_CHAIN
    if not isinstance(value, str) or value not in GRANTABLE_CHAINS:
        raise errors.GuardenError(
            f"{where}: a firewall entry names the chain {value!r}, and guarden renders only "
            f"{' and '.join(GRANTABLE_CHAINS)}; a rule may not name a chain guarden does not "
            f"render, and growing that set is a change to spec 7.7 rather than configuration"
        )
    return value


def parse(line: object, where: str) -> Request:
    if not isinstance(line, str) or not line.strip():
        raise errors.GuardenError(f"{where}: a firewall entry has no `rule`")
    if "\n" in line or "\r" in line:
        raise errors.GuardenError(
            f"{where}: a firewall entry's `rule` is one line, and this one carries a newline"
        )
    tokens = line.split()
    if not tokens[0].startswith("-"):
        raise errors.GuardenError(
            f"{where}: a firewall entry's `rule` is one iptables-shaped line beginning with an "
            f"option, and {line!r} does not"
        )

    matches: list[Match] = []
    jump = ""
    target = ""
    negated = False
    rest = list(tokens)
    while rest:
        key = rest.pop(0)
        if key == "!":
            if not rest:
                raise errors.GuardenError(f"{where}: the rule {line!r} ends on a '!'")
            negated = True
            continue
        if key in JUMP_KEYS:
            if not rest:
                raise errors.GuardenError(f"{where}: the rule {line!r} has no target after {key}")
            jump = GOTO if key in ("-g", "--goto") else JUMP
            target = _target(rest.pop(0), line, where)
            negated = False
            if rest:
                raise errors.GuardenError(
                    f"{where}: the target of the rule {line!r} is not its last word. A rule is "
                    f"one chain's match and one target, and anything after the target is not a "
                    f"key guarden recognises"
                )
            continue
        if negated and key in FLAGS:
            raise errors.GuardenError(
                f"{where}: the rule {line!r} negates {key}, and a flag with no value has nothing "
                f"to negate"
            )
        if key in FLAGS:
            matches.append(Match(FLAGS[key], (), negated))
            negated = False
            continue
        if key in VALUES:
            keyword, shape = VALUES[key]
            value = _value(rest, key, shape, line, where)
            matches.append(Match(keyword, (value,), negated))
            negated = False
            continue
        if key in MODULED:
            keyword, pattern = MODULED[key]
            if not rest:
                raise errors.GuardenError(f"{where}: the rule {line!r} has no value for {key}")
            value = _shape(rest.pop(0), key, re.compile(pattern), line, where)
            matches.append(Match(keyword, (value,), negated))
            negated = False
            continue
        _refuse(key, line, where)

    if not jump:
        raise errors.GuardenError(
            f"{where}: the rule {line!r} has no -j or -g target, and a request adds one rule "
            f"with exactly one target"
        )
    return Request(tuple(matches), jump, target, line.strip())


def _value(rest: list[str], key: str, shape: re.Pattern[str], line: str, where: str) -> str:
    if not rest:
        raise errors.GuardenError(f"{where}: the rule {line!r} has no value for {key}")
    return _shape(rest.pop(0), key, shape, line, where)


def _shape(value: str, key: str, shape: re.Pattern[str], line: str, where: str) -> str:
    if not shape.match(value):
        raise errors.GuardenError(
            f"{where}: the rule {line!r} gives {key} the value {value!r}, and a request carries "
            f"only the values {key} takes"
        )
    return value


def _target(value: str, line: str, where: str) -> str:
    if value not in TARGETS:
        raise errors.GuardenError(
            f"{where}: the rule {line!r} jumps to {value!r}, and a request may name only "
            f"{', '.join(sorted(TARGETS))} — a chain guarden does not render is a jump to "
            f"nothing, and the nat targets do not load in the chain guarden renders"
        )
    return value


def _refuse(key: str, line: str, where: str) -> None:
    doing = REFUSED.get(key)
    if doing is not None:
        raise errors.GuardenError(
            f"{where}: the rule {line!r} carries {key!r}, which {doing}. {REASON}"
        )
    known = sorted(set(FLAGS) | set(VALUES) | set(MODULED) | set(JUMP_KEYS))
    raise errors.GuardenError(
        f"{where}: the rule {line!r} carries {key!r}, which is not an option a request may use. "
        f"The options are: {', '.join(known)}"
    )