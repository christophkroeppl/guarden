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
root-owned timer** and not by the vendor, and the structural SSH guarantee still holds
— a tunnel grant cannot disable it.

## Part two — where the binary comes from

**The tunnel is a container, and it is the vendor's own image.** This is the
**amendment** to this ADR's first revision, which decided `cloudflared` would be a second
pinned host binary. It is not: the vendor publishes `cloudflare/cloudflared` as an image
on Docker Hub, and a container is how every other service in this design runs (spec §2,
"everything deployed is a service"). Taking the image means:

- **No second pinned artefact.** `PINNED_ARTEFACTS` stays `(podlet,)`, `cloudflared.release`
  is deleted, and the pin machinery serves exactly one name. The 40 MB statically-linked
  binary, the `raw` format reader, and the "no distribution security update" cost all
  disappear — they were the price of running the program on the host, and it no longer
  runs on the host.
- **The version is still recorded and still asserted.** The image tag is the version
  (`docker.io/cloudflare/cloudflared:2026.10.0`), it is a line in the module's own unit
  source, and it is pinned by digest in the same sense every other module's image is. What
  changed is *which* mechanism records it: a unit source's `Image=` rather than a
  `*.release` file.
- **`Image=` is not `ExecStart=`.** The first revision's other problem is gone with it: a
  raw systemd unit with a multi-word `ExecStart=` is refused by `unitsource.format_line`
  by design, and a `[Container]` unit passes its arguments one `Exec=` line each, which is
  how `gate`'s traefik already runs.

**What the first revision got right, and is kept.** A vendor *APT repository* is still
refused, for the reason below. The pin machinery is still renamed rather than copied, and
still serves `podlet`. The egress-only property is unaffected by containerising — a
container that dials out binds no port and is reached by nobody, exactly as a host process
that dials out does.

## The pin mechanism, and what still uses it

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

## What a raw binary *would* have cost — kept as the reason it was not taken

The first revision decided `cloudflared` would be pinned as a **raw per-architecture
binary** with no extension: a url and one digest, no archive and no reader. Read from the
vendor's releases API, metadata only:

```
cloudflared-linux-amd64     40129756
cloudflared-linux-arm64     37687584
cloudflared-linux-amd64.deb 19316284
```

**40 MB against 19 MB**, statically linked where the package is not, so it carries a libc
it does not need and receives no distribution security update. That cost is why the
container is the better answer rather than a footnote: the image carries the same program
with the vendor maintaining it, and the host fetches nothing it must pin and re-verify.

The argument that survives, and is why a vendor APT repository is still refused: **a
repository's contents move under guarden's pin.** A pin names a url and a digest; a
repository serves whatever it serves today. An image tag is not a repository — it is an
immutable name for specific bytes, which is what the pin was for.

## What this ADR decides, and what it leaves

**Decided:** a host may terminate public traffic in more than one place; the second
terminator is egress-only, binds nothing, and **runs as the vendor's own container image
rather than as a second pinned host binary** (amended); the pin is a url and two digests,
it is renamed rather than copied, and it still serves `podlet` and only `podlet`.

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
