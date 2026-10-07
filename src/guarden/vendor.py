"""The vendor side of a share: the one thing that calls Cloudflare.

Ticket 220. This is the only module in guarden that makes an HTTP request to a
service vendor, and it is deliberately thin: **the record and the projection are
guarden's, and this copies the projection to the vendor.** It decides nothing.
The document it sends is the one `share.reconcile` rendered and wrote to
`/var/lib/guarden/share/projection.json`; if the two could disagree, the file an
operator reads would be a second, quieter opinion.

Three rules are load-bearing and none is observable without a real account, so
they are stated here rather than only in a suite:

- **Adds before removes.** Every live hostname's policy is upserted first, and
  only then are the policies of hostnames that no longer have a live issuance
  deleted. So there is no window in which an address that should reach the route
  cannot. It is a whole-policy write, so the union is in force in one act.
- **A failed call changes nothing locally.** The record and the projection stay
  exactly where they are and one `warning:` names the endpoint and the vendor's
  error. The applied digest is not written, so the next reconcile retries.
- **The token never appears in an argv.** `curl --config -` takes the header on
  stdin, so a process list cannot show it. The token is read from
  `/etc/guarden/share.api-token`, `0600 root`; its name and the scopes it needs
  are in `guarden.toml`'s `[share]` table, where an operator audits what a leaked
  one would reach.
"""

from __future__ import annotations

import json

from guarden import errors, paths, tool

API_BASE = "https://api.cloudflare.com/client/v4"

# The vendor's own id for the one-time-PIN login method. It is the vendor's
# number, so it lives here and nowhere else: the projection carries guarden's
# vocabulary (`one_time_pin`) and this is the one place the two are translated.
ONE_TIME_PIN_ID = "699d98642c564d2e855e9661899b7252"

# The three outcomes of an apply. `UNCONFIGURED` is a state and `FAILED` is a
# failure, and the difference is the whole of "a failed API call leaves the local
# record and warns" — a host with no vendor account has not failed at anything.
APPLIED = "applied"
UNCONFIGURED = "unconfigured"
FAILED = "failed"


def endpoint(config, suffix: str = "") -> str:
    return (
        f"{API_BASE}/accounts/{config.share.account}/access/apps/{config.share.app}"
        f"/policies{suffix}"
    )


def token() -> str | None:
    """The API token, or `None` when nothing has planted one.

    Absent is a state, not a failure: a host with no vendor account is a host
    with no token, and reconcile warns and stops rather than pretending it
    reached the vendor.
    """
    try:
        value = paths.SHARE_TOKEN.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def _policy_body(policy: dict) -> str:
    return json.dumps(
        {
            "name": policy["name"],
            "decision": policy["decision"],
            "session_duration": policy["session_duration"],
            "include": [{"email": {"email": email}} for email in policy["include_emails"]],
            "require": [{"login_method": {"id": ONE_TIME_PIN_ID}}],
        },
        separators=(",", ":"),
    )


def _request(url: str, method: str, body: str | None) -> tool.Result:
    """One vendor request, with the token on stdin and never on the argv."""
    config_file = (
        'header = "Authorization: Bearer '
        + (token() or "")
        + '"\n'
        'header = "Content-Type: application/json"\n'
        f'url = "{url}"\n'
        f'request = "{method}"\n'
    )
    if body is not None:
        config_file += f"data = {json.dumps(body)}\n"
    return tool.call(
        ["curl", "--silent", "--show-error", "--fail", "--config", "-"], stdin=config_file
    )


def _failure(what: str, url: str, result: tool.Result) -> str:
    detail = errors.oneline(result.stderr.strip() or result.stdout.strip()) or str(
        result.returncode
    )
    return errors.warn(
        f"the vendor would not {what} at {url}: {detail}; the record and the projection are "
        f"unchanged and the next reconcile will retry"
    )


def apply(config, policies: list[dict], gone: list[str]) -> tuple[str, list[str]]:
    """Copy the projection to the vendor: upserts first, deletions after.

    `gone` is the hostnames whose policies were applied before and have no live
    issuance now. Returns `(status, lines)`, where status is one of:

    - `APPLIED` — every call succeeded;
    - `UNCONFIGURED` — there is no account, application or token, so there was
      nothing to call. That is a **state**, not a failure: a host with no vendor
      account is a host that has issued nothing, and the verb warns and exits 0;
    - `FAILED` — a call was attempted and the vendor refused it. The caller must
      not record the projection as applied, and this is exit `1`.

    A failure is a warning rather than a raise: the local record is the
    reconciler's own state and a vendor that is down must not make it look empty.
    """
    if not config.share.account or not config.share.app:
        return UNCONFIGURED, [
            errors.warn(
                "share.account or share.app is empty in [share], so the projection cannot be "
                "sent and the vendor policy is whatever it was; nothing local has changed"
            )
        ]
    if token() is None:
        return UNCONFIGURED, [
            errors.warn(
                f"{paths.SHARE_TOKEN} holds no API token, so the projection was not sent; "
                f"nothing local has changed"
            )
        ]

    lines: list[str] = []
    for policy in policies:
        url = endpoint(config)
        result = _request(url, "POST", _policy_body(policy))
        if not result.ok:
            lines.append(_failure(f"accept the policy for {policy['hostname']}", url, result))
            return FAILED, lines
        lines.append(f"projected {policy['hostname']} to {len(policy['include_emails'])} emails")

    for hostname in gone:
        url = endpoint(config)
        result = _request(url, "DELETE", None)
        if not result.ok:
            lines.append(_failure(f"withdraw the policy for {hostname}", url, result))
            return FAILED, lines
        lines.append(f"withdrew {hostname}")
    return APPLIED, lines
