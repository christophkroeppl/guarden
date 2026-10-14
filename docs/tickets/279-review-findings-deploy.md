# 279 — the adversarial review of the deploy: what it got right, and the one thing it got wrong

2026-10-14. The review ran on `opencode-go:step-5-preview-free` with no filesystem
access, so every claim below was re-measured here. Verdict given: NEEDS_WORK.

## Upheld, and acted on

**#2 — the literal `DATABASE_URL` is a design defect, not a test shortcut.** The
review's sharpest observation: the same unit carries `Secret=DB_PASSWORD,type=mount`
*and* the password inline in `DATABASE_URL`. A file that mounts a secret and prints
it is self-refuting. The literal lands in the `.container` on disk, in
`systemctl --user cat`, in `podman inspect`, and in the journal on failure. The
review's minimum honest fix is right: the edge should hand the consumer a
**reference**, and a thin entrypoint reads `/run/secrets/<name>` and exports the
URL before exec'ing the image's entrypoint — because umami reads only
`DATABASE_URL`, so today the mount is decorative. Filed as the edge-credential
work; `guarden-dev` is treated as burned.

**#4 — the false "converged" is the most dangerous of the four.** Agreed and
already filed (275). The review's reason is better than mine: it is the only one of
the four that *removes the signal that would catch the others*, and it is the only
one still shipping.

**#6 — the S3 round-trip was the weakest claim, and the review named the exact
hole.** It could not distinguish "the volume had the right ownership by luck",
"rustfs is not running as 10001", and "the write never touched the state volume".
Re-measured here and closed: the image runs as **uid 10001**, the state volume is
owned (through the namespace) at host uid 306608, the container sees `10001 10001`
and writes `/data` and `/logs`; the round-trip's objects are in the state volume
and survive a restart.

**#5 — the untested list was accurate.** Umami was verified functionally after the
review (HTTP 200, `/api/heartbeat` → `{"ok":true}`, durable across a restart), and
cross-container DNS is verified (`postgres-production:20000` resolves and accepts
from inside another service's container). The restart case is verified for all
three shared services.

## Refuted, with the measurement

**#7 — "a value that legitimately contains a space is silently split again."**
**False, and the measurement is decisive.** The review reasoned from the rendered
text and never ran quadlet. Measured on the deploy VM with a real service whose
`environment:` carries `GREETING: hello world` alongside `NAME: alice`:

```
rendered:  Environment="GREETING=hello world" NAME=alice
ExecStart: ... --env "GREETING=hello\x20world" --env NAME=alice ...
container: NAME=alice
           GREETING=hello world
```

Both variables arrive, and the spaced value arrives **intact** — quadlet escapes
the space as `\x20` inside the quoted argument, which podman then decodes. So the
unquoted-with-segment-quoting emission is correct, and the review's proposed
"per-variable quoting" change is what the renderer already does.

The review's other sub-claim in #7 stands and is kept: the three suites pinned
`type=file` because they asserted *rendered text*, and changing the pinned value
leaves the method unchanged. A suite that starts a container carrying a secret is
the fix, and that is recorded in 276.

## Kept as an open question

The review could not verify whether the `127.0.0.1` publish is guarden's default
or was hand-set, and warned that a later run mapping a console port to `0.0.0.0`
would turn a loopback VM into a LAN-exposed admin UI.

**Answered, and the answer is the good one.** `render.py` generates every
`PublishPort` line itself (`LOOPBACK = "127.0.0.1"`, `render.py:113`), from the
ingress the manifest declares — a manifest names a container port and a route, not
a host bind address, so it has no way to request a non-loopback publish. The
`0.0.0.0` mapping the review feared is not reachable through the manifest surface;
it would take a hand-written root-owned drop-in, which is the operator's act and
not a repository's. The guardrail the review asked for already exists by
construction.

`check_publish_ports` (`render.py:754`) is the adjacent guard: it refuses one host
port published twice on one protocol, keyed on (host, protocol) rather than host
alone, because `443` and `443/udp` on one host port is valid and starts.
