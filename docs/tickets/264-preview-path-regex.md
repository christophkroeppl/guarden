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
## Follow-on: `slices()` cannot see an instance at all

The escaping fix is on `fix/t264-preview-path`. It cannot pass its own test,
because **no preview instance ever reaches `render_tunnel`.**

Measured in the VM: the suite's `weedr service ingest routed-preview/feature-x`
does create a real instance —

    /var/lib/guarden/services/routed-preview/instances/feature\x2dx/

— with its own unit directory and its own rendered units. So the test is not
creating a slot and the instance is not missing.

The defect is in `roots.slices()`:

```python
for directory in sorted(path for path in paths.SHARED.iterdir() if path.is_dir()):
    routes = conf.read_toml(directory / "routes.toml").get("routes") or []
```

It iterates `SHARED/*` — one level — and reads each service's **slot**
`routes.toml`. An instance's routes live at
`SHARED/<service>/instances/<escaped-ref>/routes.toml`, one level deeper, and
this loop never visits it.

**So `render_tunnel` has no path to a preview instance regardless of what any
test does.** Every preview published on the tunnel today carries a hostname
and no path, which means the first preview route in the file wins every
request under it — the collision ticket 264 exists to close, arriving by a
different route than the one it was filed for.

The fix is for `slices()` to walk instances as well as slots, keyed so a
caller can tell them apart, and for `render_tunnel` to use each instance's own
ref. That is a change to what the edge's route configuration means, so it
wants an ADR: today a service has one route slice, and after this it has one
per instance.

## Regression found by the full gate: the unreserved rule contradicts ticket 220

`c949878` added `is_url_safe` — RFC 3986 unreserved only, refusing anything else with
exit 2. It makes **two suites red on develop**, independent of any branch:

    $ tests/lxc.sh run t110-previews.sh --no-cache
    error: ref 'feature/x' is not URL-safe; a preview ref must contain only
    alphanumeric characters, '-', '.', '_', and '~' (RFC 3986 unreserved)
    FAIL t110-previews.sh

    $ tests/lxc.sh run t130-paths.sh --no-cache
    FAIL t130-paths.sh

**The rule contradicts its own ticket.** Ticket 220's unticked item says a preview is
published at a path built from the ref, and that the ref is *"a path on one host"* —
`feature/x` is the canonical example and it is exactly what these suites use.
A character set that excludes `/` cannot express a path.

**Do not simply delete the rule.** It was written to close a real collision: two refs
differing only by percent-encoding decode to the same path, so `feature%2Fx` and
`feature/x` must not both be publishable. That reasoning is sound and the defect
ticket 264 describes — an unescaped `.` in a regex — is real.

The two requirements are compatible, and the fix is to escape rather than refuse:

- accept a ref that is a **path** — segments of unreserved characters separated by `/`;
- percent-encode each segment when building the URL path, so the published path is
  unambiguous and cannot collide after decoding;
- keep the regex quoting and anchoring that ticket 264 needs, which is a separate
  concern from what characters may appear in a ref.

An earlier revision of this work reached for a stricter character set instead. That
trades a collision for a broken feature, and two suites say so.
