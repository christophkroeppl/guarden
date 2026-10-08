# 263: the edge is listening, the routes load, and the packet still does not arrive

**Blocked by:** nothing. **Blocks:** `t50-slice.sh`, and therefore any release gate that runs
the whole suite.

**What to build:** A measurement that says why a `curl` from the host to the edge's own
loopback publication times out, when the edge is demonstrably listening on that publication.

This ticket supersedes its own earlier text. Two hypotheses have been tested and **both
refuted**, and the refutations are the useful part.

## Refuted: container group inheritance

`/var/lib/guarden/edge/dynamic` is `2750 guarden:edge`. The hypothesis was that the edge
container does not inherit its user's supplementary groups, and the proposed fix was
`GroupAdd=keep-groups` in the rendered unit.

**Refuted by experiment.** Making the route file world-readable on the host let the container
read it — and `curl` still timed out with exit 28. The permission path is not the cause.
`assert_supplementary_group traefik-production edge` was always true.

## Refuted: Traefik flag case sensitivity

The quadlet source used `--entryPoints.web.address=:80` (PascalCase). The hypothesis was that
Traefik v3.2 only accepts `--entrypoints` and silently ignored the PascalCase flags, so the
`:443` and `:8080` entrypoints never bound and every request 404'd.

**Refuted by instrumenting the suite.** Adding a trace after each assertion shows the run
reaches:

```
REACHED: assert_stdout_has 127.0.0.1:20001
REACHED: assert_stdout_has 127.0.0.1:20002
REACHED: assert_stdout_has 127.0.0.1:20003
```

All three publications — web, TLS and API — **are** bound, with the original PascalCase flags.
Traefik accepts them. The `--api.insecure=true` flag that came with that patch would also have
widened the API's exposure, and it is not needed.

The patch is preserved at `/tmp/263-entrypoints.patch` and is **not** on any branch.

## What is established

- the edge container runs, as uid 994, with pasta mapping `127.0.0.1/20000-20000:8080-8080`
  and `127.0.0.1/20001-20001:80-80`;
- all three entrypoints are bound on their loopback publications;
- the route file is written and readable inside the container;
- the suite dies on the **first `curl`**, `http://127.0.0.1:$web_publication/`, with exit 28
  — a connection timeout, meaning **no TCP connection was established at all**.

A timeout rather than a 404 is the load-bearing observation. A route that does not match, or a
router that does not exist, still produces an HTTP answer. A timeout means the SYN went
somewhere that did not answer.

## Where that leaves it

Candidates, none yet excluded:

- **the firewall.** `accept_lines` grants a publication to the service itself, its declared
  consumers, the edge's uid per route publication, and `host.admin_user` alone on the API.
  The suite's `curl` runs as **root**. Is root in any accept set for the edge's own web
  publication? `mod owner uid-owner 0` appears in some renders; whether it covers this path is
  the thing to check, and whether root's traffic to `127.0.0.1` traverses `guarden-svc` at all.
- **pasta's host mapping.** ADR-0013 / spec §7.6: pasta translates to `127.0.0.1` in userspace
  before the kernel's packet path, so a rule matching anything other than `127.0.0.1` matches
  no packet. If the accept or the deny is matching the alias rather than loopback, the packet
  is dropped and the client sees a timeout — exactly this symptom.
- **the deny.** `-A guarden-svc -d 127.0.0.0/8 -j DROP` with the resolver accepts above it. Is
  uid 0 or the edge's uid reaching that deny for this destination?

## Acceptance

- A measurement names the layer that drops the packet — firewall, pasta mapping, or something
  else — with the command that produced it.
- The fix is at that layer and no wider. **No `GroupAdd`.** If the answer is that the API's
  accept set needs root, that is a grant-surface question and needs an ADR.
- `t50-slice.sh` green on `develop` with no branch applied, and its failure path names itself
  rather than exiting with empty stderr (ticket 262, criterion 3).

## Why this ticket exists at all

Three agents have spent hours here, and each one reached for the nearest plausible cause rather
than measuring. One proposed a security-model change on an unconfirmed hypothesis. One
diagnosed a flag-casing bug that the suite's own passing assertions disprove. Both were
recorded here rather than merged, which is the only reason the next agent inherits facts
instead of three confident wrong answers.