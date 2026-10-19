"""Where a service's routes are published: the one resolver (tickets 293/294).

Three inputs, in this order, and nothing else decides a destination:

1. The **record** — `[exposure] value` in the service's registry, written only
   by `weedr expose set` (ticket 294). It is per service, and a service's name
   carries its environment (spec 5.1), so one registry file is one service ×
   environment entry. `public` is the operator's word and `edge` is the slice's
   for the same position: the edge is the host's forwarded 80/443 ingress, and
   `weedr share issue` refuses an edge-destination route — "a grant may only
   name a route the tunnel carries" — because a grant to reach what is already
   public is a second grant of nothing.
2. The **track's** `expose` field — the per-environment default the root-owned
   `[[environments]]` row states (spec 3.1 states the field, spec 10 puts
   the track table in `guarden.toml`).
3. The **derived default** (ticket 293): the tunnel when the `cloudflared`
   module is enabled, loopback-only otherwise. Fail-closed: a tunnel with no
   module behind it resolves to `loopback`, never to a route nothing reads —
   the same "refuse rather than guess" rule spec 6.3 gives the renderer.

Every consumer calls this: the mutator's allocation, the renderer's slice, the
firewall's accept set and `soil --check`'s drift item. The duplication it
replaces — mutator and renderer each re-deriving "tunnel or track expose" — was
two places to be wrong in, and the drift line exists because they were allowed
to disagree.

A loopback service is fail-closed all the way down: its record overrides even
the root-owned `[expose] tunnel` label grant, because a record that says
"private" and a label that says "publish this one anyway" is the two halves of
one decision disagreeing, and private is the answer that loses nothing.
"""

from __future__ import annotations

from collections.abc import Iterable

# The operator's vocabulary for a record: what `weedr expose set` accepts and
# what `[exposure] value` holds.
RECORD_VALUES = ("loopback", "tunnel", "public")

# The slice's vocabulary for a route destination: what `roots` and the
# firewall's `route_destinations` read today, and what keeps reading it.
LOOPBACK = "loopback"
TUNNEL = "tunnel"
EDGE = "edge"

# The module whose presence makes a tunnel a tunnel (spec 3.1 `[modules]`,
# spec 10 "the module set" — a root-owned answer, never a repository's).
CF_MODULE = "cloudflared"


def tunnel_enabled(modules: Iterable[str] | None) -> bool:
    return CF_MODULE in list(modules or [])


def _tunnel_or_loopback(modules: Iterable[str] | None) -> str:
    """Fail-closed: a tunnel nobody carries is a private service."""
    return TUNNEL if tunnel_enabled(modules) else LOOPBACK


def from_record(value: str, modules: Iterable[str] | None) -> str:
    """One record value to the destination the slices speak."""
    if value == "public":
        return EDGE
    if value == TUNNEL:
        return _tunnel_or_loopback(modules)
    if value == LOOPBACK:
        return LOOPBACK
    # An unrecognised record is the host not being in the state the caller
    # assumed rather than a value to guess at; the verb refuses values, so this
    # only ever sees a record a hand edited.
    raise ValueError(f"{value!r} is not an exposure record value")


def resolve(record, track, modules: Iterable[str] | None) -> str:
    """The service's default destination: record, then track, then derived.

    `track` is `None` in two shapes and both are fail-closed: `loom check`
    renders with no host context at all, and `weedr expose list` walks a
    record whose environment names no track in `guarden.toml` (the row was
    deleted). Private loses nothing; `edge` is the one answer no operator
    asked for, so a missing track resolves like a missing module rather than
    like a grant — the same refusal-without-guessing rule `set`/`unset`
    apply to that host state, one step earlier.
    """
    recorded = getattr(record, "exposure", None) if record is not None else None
    if recorded:
        return from_record(recorded, modules)
    if track is None:
        return _tunnel_or_loopback(modules)
    track_value = getattr(track, "expose", "") or ""
    if track_value == EDGE:
        return EDGE
    if track_value == TUNNEL:
        return _tunnel_or_loopback(modules)
    if track_value == LOOPBACK:
        return LOOPBACK
    # The track says nothing (ticket 293's unset default): the module set is
    # the operator's answer, so the tunnel when it exists and private when it
    # does not.
    return _tunnel_or_loopback(modules)


def destinations(
    record,
    track,
    modules: Iterable[str] | None,
    tunnel_labels: Iterable[str],
    hosts: Iterable[str],
) -> dict[str, str]:
    """Every route label's destination, in one pass.

    A loopback record wins over everything, including a `[expose] tunnel`
    label grant — fail-closed beats a grant that would contradict it. Short of
    that, a labelled route keeps the tunnel it was granted (ticket 293/3.3's
    per-service override), and the rest follow the service's resolution.
    """
    labels = set(tunnel_labels)
    recorded = getattr(record, "exposure", None) if record is not None else None
    base = resolve(record, track, modules)
    out: dict[str, str] = {}
    for host in hosts:
        if recorded == LOOPBACK:
            out[host] = LOOPBACK
        elif host in labels:
            out[host] = _tunnel_or_loopback(modules)
        else:
            out[host] = base
    return out
