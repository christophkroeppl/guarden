"""`weedr share`: a time-bounded grant to reach a tunnel route, and its projection.

Ticket 220, ADR-0015, spec 6.2. A **grant is an issuance**, and an issuance
always expires: there is no spelling of "never", because a grant that cannot be
time-bounded is a grant whose expiry is somebody's memory.

Four facts are load-bearing and each is a rule rather than an implementation
detail:

- **The record is guarden's.** One file per issuance under
  `/var/lib/guarden/share/`, named by its id, holding an **absolute** deadline
  computed at issue time. A root-owned wall clock that can move backwards must
  not be able to extend a grant, so what is stored is the deadline and not a
  duration. Nothing aggregates these files: the projection is recomputed from
  them on every run, so a process that died midway leaves nothing to reconcile.
- **The vendor's Access policy is a projection of the record, never the record.**
  The union of the live issuances for a hostname is rendered as one `Allow`
  policy, and that rendered document is guarden's own — it is written to
  `/var/lib/guarden/share/projection.json` before any vendor call, which is both
  the thing an operator can read and the thing a suite can assert without a real
  Cloudflare account. The vendor call copies it; it does not decide it.
- **The reconciler is idempotent and adds before it removes.** A projection
  identical to the last one it applied makes no call at all, and a change that
  both adds and removes an email puts the union in force before the smaller set,
  so there is no window in which an address that should be able to reach the
  route cannot.
- **It stops rather than clearing anything when its own state is unreadable.**
  An issuance that will not parse, or a store that is not a directory, is exit
  `1` with the projection left exactly where it was. A reconciler that cannot
  read its record must never render an empty projection, because an empty
  projection is what removes every address.

**`session_duration` is set, and to the root-owned maximum.** See
`docs/notes/220-session-duration-decision.md`: a deadline-derived value would
change on every run and so could never be idempotent, so the bound is the one
constant an operator owns — `[share] max` — rendered into the vendor's Go
duration syntax. It is a second, shorter bound under guarden's own deadline, and
the act that ends a grant is still this reconciler removing the email.
"""

from __future__ import annotations

import hashlib
import json
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from guarden import conf, durations, errors, paths, registry, users

LIVE = "live"
EXPIRED = "expired"
REVOKED = "revoked"

STORE_MODE = 0o750
RECORD_MODE = 0o640
PROJECTION_MODE = 0o640

PROJECTION = paths.SHARE / "projection.json"
APPLIED = paths.SHARE / "applied"

                                                                              
                                                                     
TUNNEL = "tunnel"

# The login method a projected policy requires, in guarden's own vocabulary. The
# vendor's id for it lives in `vendor.py` and nowhere else, because it is the
# vendor's number and this document is guarden's.
LOGIN_METHOD = "one_time_pin"


def rfc3339(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_rfc3339(text: str, what: str) -> int:
    """An absolute deadline, read back as seconds since the epoch."""
    try:
        moment = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except ValueError:
        raise errors.GuardenError(
            f"{what} is {text!r}, which is not an RFC3339 UTC timestamp", errors.HOST_NOT_AS_ASSUMED
        ) from None
    return int(moment.timestamp())


@dataclass
class Issuance:
    """One grant: who, which hostnames, and the absolute moment it ends."""

    id: str
    service: str
    ref: str
    hosts: list[str]
    email: str
    issued: int
    deadline: int
    revoked: int | None = None

    def state(self, now: int) -> str:
        if self.revoked is not None:
            return REVOKED
        return EXPIRED if self.deadline <= now else LIVE

    def is_live(self, now: int) -> bool:
        return self.state(now) == LIVE

    def to_document(self) -> dict:
        document: dict = {
            "id": self.id,
            "service": self.service,
            "hosts": list(self.hosts),
            "email": self.email,
            "issued": rfc3339(self.issued),
            "deadline": rfc3339(self.deadline),
        }
        if self.ref:
            document["ref"] = self.ref
        if self.revoked is not None:
            document["revoked"] = rfc3339(self.revoked)
        return document

    @classmethod
    def from_document(cls, document: dict, where: Path) -> Issuance:
        """A record read back, or a refusal naming the field it is missing.

        A record is guarden's own file and this is the only place a hand edit is
        caught, so a missing field is exit `1` with the field and the file named
        rather than an empty hostname that shares nothing.
        """
        missing = [
            key for key in ("id", "service", "hosts", "email", "issued", "deadline")
            if not document.get(key)
        ]
        if missing:
            raise errors.GuardenError(
                f"{where} is an issuance record missing {', '.join(missing)}; an issuance names "
                f"who may reach which hostname until when",
                errors.HOST_NOT_AS_ASSUMED,
            )
        hosts = document["hosts"]
        if not isinstance(hosts, list) or not all(isinstance(host, str) for host in hosts):
            raise errors.GuardenError(
                f"{where}: hosts is not a list of strings", errors.HOST_NOT_AS_ASSUMED
            )
        revoked = document.get("revoked")
        return cls(
            id=str(document["id"]),
            service=str(document["service"]),
            ref=str(document.get("ref", "")),
            hosts=list(hosts),
            email=str(document["email"]),
            issued=parse_rfc3339(str(document["issued"]), f"{where}: issued"),
            deadline=parse_rfc3339(str(document["deadline"]), f"{where}: deadline"),
            revoked=parse_rfc3339(str(revoked), f"{where}: revoked") if revoked else None,
        )


def record_path(issuance_id: str) -> Path:
    return paths.SHARE / f"{issuance_id}.toml"


def store_readable() -> None:
    """The store is a directory of guarden's, or reconcile stops.

    An absent store is **empty** — a host that has issued nothing — and is not
    unreadable. A store that exists and is not a directory is neither, and
    reconcile must not read it as "no issuances", because rendering an empty
    projection from an unreadable record is what removes every address.
    """
    if paths.SHARE.exists() and not paths.SHARE.is_dir():
        raise errors.GuardenError(
            f"{paths.SHARE} is not a directory, so the issuances cannot be read; nothing is "
            f"projected and no vendor policy is touched",
            errors.HOST_NOT_AS_ASSUMED,
        )


def load_all() -> list[Issuance]:
    """Every issuance, live, expired and revoked, in deadline order."""
    store_readable()
    out: list[Issuance] = []
    if not paths.SHARE.is_dir():
        return out
    for path in sorted(paths.SHARE.glob("*.toml")):
        document = conf.read_toml(path)
        if not document:
            raise errors.GuardenError(
                f"{path} is an empty issuance record; nothing is projected and no vendor policy "
                f"is touched",
                errors.HOST_NOT_AS_ASSUMED,
            )
        out.append(Issuance.from_document(document, path))
    return sorted(out, key=lambda entry: (entry.deadline, entry.id))


def load(issuance_id: str) -> Issuance | None:
    store_readable()
    path = record_path(issuance_id)
    document = conf.read_toml(path)
    if not document:
        return None
    return Issuance.from_document(document, path)


def _write(issuance: Issuance) -> None:
    paths.SHARE.mkdir(parents=True, exist_ok=True)
    conf.write_toml(record_path(issuance.id), issuance.to_document(), RECORD_MODE, _owner())


def _owner() -> tuple[int, int]:
    return (0, users.group_id("guarden"))


def new_id() -> str:
    """A short, unique name for an issuance, and one that is not a path."""
    return secrets.token_hex(8)


def destinations(record) -> list[tuple[str, str]]:
    """`(label, destination)` per route the service declares, in manifest order."""
    return [(label, record.route_destinations.get(label, "")) for label in record.route_hosts]


def route_hosts(record) -> list[str]:
    return [record.route_hosts[label] for label, _ in destinations(record)]


def issue(service_argument: str, email: str, until: str, config, now: int) -> Issuance:
    """Record one issuance, or refuse it at the seam before anything is written.

    Every refusal here is a rejected input and happens **before** the record is
    written: a grant that exists locally and not at the vendor is a grant an
    operator believes is closed and is not, so nothing is stored until the input
    is one the host would honour.
    """
    from guarden import names

    _validate_email(email)
    seconds = durations.parse(until, "--until")
    if seconds > config.share.max_seconds:
        raise errors.GuardenError(
            f"--until {until!r} is longer than the root-owned maximum "
            f"{durations.go(config.share.max_seconds)}; there is no spelling of \"never\", and "
            f"a grant above the maximum is one nobody agreed to",
            errors.REJECTED_INPUT,
        )

    resolved = names.resolve(service_argument, list(config.tracks), allow_default=False)
    record = registry.load(resolved.name)
    if record is None:
        raise errors.GuardenError(
            f"{resolved.name} has no registry entry, so it has no route to share",
            errors.HOST_NOT_AS_ASSUMED,
        )
    declared = destinations(record)
    if not declared:
        raise errors.GuardenError(
            f"{resolved.name} declares no route, and a grant is a grant to reach a route; "
            f"there is nothing for the tunnel to carry",
            errors.HOST_NOT_AS_ASSUMED,
        )
    for label, destination in declared:
        if destination != TUNNEL:
            raise errors.GuardenError(
                f"the route {label!r} of {resolved.name} has destination {destination!r}, and a "
                f"grant may only name a route the tunnel carries; there is no --via flag, "
                f"because which terminator carries a route is configuration and a flag that "
                f"chose it would be a second place",
                errors.REJECTED_INPUT,
            )

    issuance = Issuance(
        id=new_id(),
        service=resolved.name,
        ref=resolved.ref or "",
        hosts=[record.route_hosts[label] for label, _ in declared],
        email=email,
        issued=now,
        deadline=now + seconds,
    )
    _write(issuance)
    return issuance


def revoke(issuance_id: str, now: int) -> tuple[Issuance | None, bool]:
    """End one issuance immediately. `(record, changed)`; `None` is unknown id."""
    issuance = load(issuance_id)
    if issuance is None:
        return None, False
    if issuance.revoked is not None:
        return issuance, False
    issuance.revoked = now
    _write(issuance)
    return issuance, True


def _validate_email(email: str) -> None:
    if "@" not in email or email.startswith("@") or email.endswith("@") or " " in email:
        raise errors.GuardenError(
            f"{email!r} is not an email address, and an Access policy matches on the address the "
            f"customer signs in with"
        )


def listing(issuances: list[Issuance], now: int) -> list[dict]:
    """`weedr share list`: every issuance with its state and its absolute deadline."""
    return [
        {
            "id": issuance.id,
            "service": issuance.service,
            "ref": issuance.ref or None,
            "hosts": list(issuance.hosts),
            "email": issuance.email,
            "state": issuance.state(now),
            "issued": rfc3339(issuance.issued),
            "deadline": rfc3339(issuance.deadline),
            "revoked": rfc3339(issuance.revoked) if issuance.revoked is not None else None,
        }
        for issuance in issuances
    ]


                                                                               


@dataclass
class Policy:
    """One hostname's projected `Allow` policy, and the emails behind it."""

    hostname: str
    emails: list[str] = field(default_factory=list)

    def to_document(self, session_duration: str) -> dict:
        return {
            "hostname": self.hostname,
            "decision": "allow",
            "name": f"guarden share {self.hostname}",
            "session_duration": session_duration,
            "include_emails": list(self.emails),
            "require_login_methods": [LOGIN_METHOD],
        }


def projection(issuances: list[Issuance], now: int, session_duration: str) -> list[dict]:
    """The union of the live issuances, one policy per hostname, in name order.

    Expired and revoked issuances contribute nothing: the record keeps them so
    "who could see this" is answerable, and the projection is a function of who
    can reach it **now**.
    """
    live: dict[str, set[str]] = {}
    for issuance in issuances:
        if not issuance.is_live(now):
            continue
        for host in issuance.hosts:
            live.setdefault(host, set()).add(issuance.email)
    return [
        Policy(hostname=host, emails=sorted(live[host])).to_document(session_duration)
        for host in sorted(live)
    ]


def render_projection(policies: list[dict]) -> str:
    return json.dumps({"policies": policies}, separators=(",", ":"), sort_keys=True) + "\n"


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _applied() -> dict:
    """What the last successful apply put in force: its digest and its hostnames.

    The hostnames are kept so a hostname that has **lost** its last live
    issuance can have its policy withdrawn. Without them the reconciler could
    add and update but never remove, and "the grant is still refused after
    `weedr share revoke`" would be false.
    """
    try:
        return json.loads(APPLIED.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def reconcile(config, now: int) -> tuple[int, list[str], list[str]]:
    """Recompute the projection from the record and copy it to the vendor.

    Returns `(exit_code, stdout_lines, warning_lines)`. The order is the
    contract: read the record, render the whole projection, write it, and only
    then call the vendor. A record that cannot be read raises before the
    projection is rendered, so an unreadable store can never produce the empty
    projection that removes every address.
    """
    from guarden import vendor

    issuances = load_all()
    session_duration = durations.go(config.share.max_seconds)
    policies = projection(issuances, now, session_duration)
    body = render_projection(policies)
    digest = _digest(body)
    applied = _applied()

    if digest == applied.get("digest"):
        return (
            0,
            ["nothing to reconcile; the vendor policy is the projection of the record"],
            [],
        )

    paths.SHARE.mkdir(parents=True, exist_ok=True)
    conf.write_file(PROJECTION, body, PROJECTION_MODE, _owner())

    live_hosts = {policy["hostname"] for policy in policies}
    gone = sorted(set(applied.get("hostnames", [])) - live_hosts)
    status, lines = vendor.apply(config, policies, gone)
    if status == vendor.UNCONFIGURED:
        return 0, [], lines
    if status == vendor.FAILED:
        return errors.HOST_NOT_AS_ASSUMED, [], lines
    conf.write_file(
        APPLIED,
        json.dumps({"digest": digest, "hostnames": sorted(live_hosts)}, separators=(",", ":"))
        + "\n",
        PROJECTION_MODE,
        _owner(),
    )
    return 0, lines, []
