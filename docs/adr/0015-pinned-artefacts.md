# 0015 — a second terminator, and a pinned artefact is a url and two digests

**Status:** accepted. Supersedes the `edge` entry in `CONTEXT.md` and the "exactly one
fetch … it is the only third-party binary" sentence in `AGENTS.md`, both of which
ticket 220 requires this ADR to replace.

Two questions, one document because they are one decision: **a host may terminate
public traffic in more than one place**, and **where the second one's binary comes
from.** Splitting them would put the trust question in a document that could be read
without the answer to the question that made it necessary.

## Part one — a host may terminate public traffic in more than one place

`CONTEXT.md` names `edge` as *the* place public traffic terminates. That was true while
there was one terminator, and it is now false: a track may carry routes that are not
published on the edge, reached instead by a tunnel that **dials out and is reached by
nobody**.

**The second terminator is egress-only, and that is what makes it not a door.** The
edge is a door: the kernel forwards public ports to it, so anything on the internet can
address it. A tunnel inverts that — it establishes an outbound connection and the
public side connects *through* it to nothing the kernel forwards. Adding one does not
add an ingress path, and it binds no port: it is an ordinary unprivileged service with
no publication of its own and no `PublishPort`, so the firewall's ingress rules are
unchanged by its existence.

**What does not change:** production keeps serving from the edge on the kernel's
forwarded ports, the production zone's nameserver does not move, and `20-ingress-nat.conf`
is byte-identical before and after the module is added. A tunnel-published route is
**absent** from the edge's dynamic directory — the two terminators never both claim a
hostname, and the edge's catch-all 404 stays last.

**And the thing that would make it a door is refused:** a grant is an issuance with an
**absolute** expiry, the vendor's Access policy is a **projection** of guarden's own
record and never the record, expiry is enforced by a **root-owned reconciler on a
root-owned timer** and not by the vendor, and the dead-man timer still restores
firewall access — a tunnel grant cannot disable it.

## Part two — where the binary comes from

**A pinned third-party binary is `format`, `url`, `sha256`, `binary_sha256` — and the
implementation is one mechanism, named for nothing in particular.**

Today `src/guarden/hostprep.py` carries that as `PODLET_FIELDS`, `PODLET_FORMATS`,
`PODLET_FETCH`, `PODLET_RECORD` and `PODLET_RECORD_NAME`. Those names are podlet's. The
shape is not: a machine map (`_PODLET_MACHINES`), a closed format set, an artefact
digest checked **before anything is unpacked out of it**, and a program digest re-read
on **every** `--check` because the artefact is not kept.

**A second pinned binary reuses all of it.** The four fields and the two digest checks
are the whole of it. So the module is **renamed** to say what it is rather than
duplicated — one implementation, one place to get a security property right.

## Why this is not `pip install`

AGENTS.md: *"There is exactly one fetch from outside a distribution repository, and it
is deliberate … It is the only third-party binary. This keeps the host installable on
a distro we have not tried yet."*

That constraint is real. This ADR **supersedes its "only"** — a host may now fetch
more than one pinned artefact, and `podlet` is no longer the only one — while keeping
the property that made it true. The line, unchanged:

- **Distribution packages wherever one exists.** A vendor APT repository is refused for
  the reason AGENTS.md already gives for `podlet`, and one more:

- **Still no installer, still no repository, still no index.** A vendor APT repository
  is refused for the reason AGENTS.md already gives for `podlet`, and one more:
  **a repository's contents move under guarden's pin.** A pin names a url and a digest;
  a repository serves whatever it serves today. So the version in force would be
  decided by the vendor at install time rather than recorded here and asserted by
  `soil packages --check`.
- **Still a distribution package wherever one exists.** This ADR is about the gap where
  none does.

## The shape of the decision, stated once

A pin is **a url and two digests, and nothing else**. Not a repository. Not a
resolver. Not a floating "latest".

- `sha256` — the **artefact's**, compared in the fetch temporary *before* anything is
  unpacked out of it. A file another process can see is not where that comparison
  happens.
- `binary_sha256` — the **program's**, re-read on every `--check`. The artefact is not
  kept, so this is the digest that says what is installed.

A vendor repository has no digests guarden can state, which is the whole objection.

## What a raw binary costs, stated honestly

The second artefact guarden will pin is `cloudflared`, and it is published as a **raw
per-architecture binary** with no extension. That is this shape with **one fewer
field** — a url and one digest, no archive and no reader.

Read from the vendor's releases API, metadata only:

```
cloudflared-linux-amd64     40129756
cloudflared-linux-arm64     37687584
cloudflared-linux-amd64.deb 19316284
```

**40 MB against 19 MB.** The raw binary is statically linked where the package is not,
so it carries a libc it does not need, and it receives no distribution security update.
That is a real cost and it is not waved away — it is the same trade `podlet` already
makes, taken a second time deliberately rather than by accident, and the alternative
(a vendor repository) costs the recorded-version property *and* a persistent
third-party APT signing key on every host, which is strictly worse than a large file
whose digest is known.

## What this ADR decides, and what it leaves

**Decided:** a host may terminate public traffic in more than one place; the second
terminator is egress-only and binds nothing; the pin is a url and two digests and the
fetch machinery is renamed rather than copied.

**Left to ticket 220's implementation:** the module's shape, the issuance and expiry
mechanics, and the reconciler. This ADR does not pre-empt them — it refuses them a
shape they cannot have, which is the point of writing it first.

## Why rename rather than copy

Two copies of a verified-fetch implementation are two places to get a security property
wrong, and the property in question — *verify before you unpack* — is exactly the kind
that gets forgotten in the copy. The repo already has the rule this instantiates: **one
canonical statement per rule**, every other document pointing at it.

A rename touches one module and no behaviour. It is the smallest change that makes a
second artefact possible without a second implementation.
