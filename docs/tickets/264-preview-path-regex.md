# 264: a preview ref becomes an unanchored regex, so one preview captures another's traffic

**Blocked by:** nothing. **Blocks:** nothing today; it is a defect in code already on `develop`.

**What to build:** A narrow fix to how a preview ref is rendered into cloudflared's ingress
`path:`, plus the test that fails without it. Found by the adversarial reviewer
(`mimo-v2.6-pro`) against `c949878`, and verified in the tree before this ticket was written.

## The hole

`roots.py` renders a tunnel preview route as:

```python
escaped_ref = names.systemd_escape(route["ref"])
previews.append({..., "path": f"/{escaped_ref}"})
```

and `tunnel-ingress.yml.j2` writes `path: "{{ preview.path }}"`.

**cloudflared's `ingress.path` is a regex, matched first-match-wins.** `names.py:137` defines:

```python
_SYSTEMD_SAFE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:")
```

`.` and `_` pass through **raw**. So:

- a preview with ref `.` renders `path: "/."`, which matches **every** request on
  `preview.<tunnel_domain>` — it captures every other preview's customer traffic;
- ref `a` renders `/a`, which matches `/abc`, `/apple`, `/anything`.

Ingress is first-match-wins and the `http_status:404` catch-all is last, so whichever preview
is rendered first wins every contested path.

## Why the RFC 3986 rule does not prevent this

`c949878` added `is_url_safe` — RFC 3986 **unreserved** characters only — reasoning about
percent-encoding collisions. **`.` is unreserved**, so `is_url_safe(".")` is `True` and the ref
is admitted. The rule closed the percent-decoding collision and left the regex metacharacter
open. A character set that is safe in a URL path is not automatically safe in a regex.

## The second defect, same commit

The template double-quotes the scalar: `path: "{{ preview.path }}"`. In double-quoted YAML,
`\x2d` is a valid `\xXX` escape, so `systemd_escape`'s output is **decoded in transit**:
escaped `feature\x2dx` becomes `feature-x` and collides with escaped `feature/x` →
`feature-x`. The escaping the ref validation depends on is undone by the quoting.

## What the fix must do

1. **Regex-quote and anchor** the path, or percent-encode the segment. An anchored form is
   `^/<quoted>(/|$)`. Quoting alone is not enough — an unanchored `/a` still matches `/abc`.
2. **Stop the YAML double-quoted decode.** Single-quote the scalar, or emit the path such
   that `\xNN` survives YAML parsing.
3. Keep `is_url_safe` for the percent-decoding collision it was written for. It is correct for
   that and insufficient for this; do not weaken it to "fix" the regex problem.

## Acceptance

- A preview whose ref is `.` does not match a request for another preview's ref. Assert it.
- `systemd_escape`'s output survives the YAML round trip byte for byte. Assert it.
- Both asserted in a suite that **fails when the fix is reverted** — re-introduce the raw `.`
  and confirm red, then restore. A guard that only passes on current state catches nothing.
- `t220-tendril.sh` green on `develop` with no branch applied.