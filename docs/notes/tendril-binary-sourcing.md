# Where `cloudflared` comes from — the input to ticket 220's ADR

**Not the ADR itself.** This note records what is already in the repository, so the
ADR argues from the existing mechanism rather than from memory. The decision is the
operator's; the facts are these.

## The constraint, from the ticket

`cloudflared` is **not in Debian, Ubuntu or Fedora**. The vendor publishes it through
its own APT repository at `pkg.cloudflare.com`, with a separately-rolled signing key.
So it is not a distribution package, and adding a vendor APT repository is a different
trust decision from what guarden does today — **the repository's contents change
under guarden's version pin.** A pin pins a URL and a digest; a repository serves
whatever it serves today.

## What already exists: the `podlet` machinery

AGENTS.md: *"There is exactly one fetch from outside a distribution repository, and it
is deliberate: the pinned `podlet` release … It is the only third-party binary."*

`src/guarden/hostprep.py` implements that as:

```
PODLET_FIELDS = ("format", "url", "sha256", "binary_sha256")
PODLET_FORMATS = ("tar.xz", "zip")
_PODLET_MACHINES = {"x86_64", "amd64", "aarch64", "arm64"}
PODLET_FETCH = "podlet.fetch"
```

The four fields are the shape of a pin: **format**, **url**, the **artefact's**
digest checked before anything is unpacked out of it, and the **program's** digest
re-read on every `--check` because the artefact is not kept. The machine map makes the
url per-architecture rather than assumed.

**This is the reusable part, and it is worth noticing that it is generic in shape and
podlet-named in fact.** A second pinned binary needs the same four fields and the same
two digests and nothing else. The naming is the only thing that is podlet-shaped.

## What it cannot do today

**`.deb` is not a supported format.** `PODLET_FORMATS` is a closed set of two —
`tar.xz` and `zip` — and each has a hand-written reader: the tar reader looks for "the
single regular member named `podlet`" and refuses an archive with none or several; the
zip reader has its own `_zip_regular` test. Both readers name `podlet` in their own
error messages.

Cloudflare's own repository ships a **`.deb`**, which is an `ar` archive containing a
compressed tarball — a third reader, and `ar` is not in the standard library the way
`tarfile` and `zipfile` are.

## The three options, and what each costs

**A — a pinned `.deb` with a recorded SHA256, in the manner of `podlet`.**
Reuses the four fields and both digest checks unchanged; needs a third format reader
and a way to get the binary out of an `ar` archive. Keeps guarden's property that the
version in force is *recorded in this repository and asserted by `soil packages
--check`*, which the ticket asks for and which a vendor repository cannot give.

**B — the vendor APT repository.** No new reader, and the vendor's own signing and
update machinery. But then guarden does not know what it is running: the repository's
contents move under the pin, and the ticket's own requirement — *"the version in force
is recorded in this repository and asserted by `soil packages --check`"* — becomes
something the repository, not guarden, decides. It also makes guarden's install depend
on a third-party APT key, which is a persistent trust addition to every host.

**C — a container image.** Nothing new is fetched at all, which is the strongest
property of the three. But the tunnel is the one component that must dial out *before*
any container is up, so it cannot be a service like the others: it is the thing that
makes the others reachable. Modelling it as an ordinary service would be a second
class of thing, which spec §2 forbids.

## What the ADR has to settle beyond the sourcing

Two things are cheaper to decide alongside the sourcing than after it:

1. **Whether `cloudflared` generalises the pin machinery or gets its own.** The four
   fields and two digest checks are already right for a second binary; the names are
   `PODLET_*`. Generalising them is a rename that touches one module, and it is what
   KISS argues for — a second copy of a verified-fetch implementation is two places to
   get security wrong. If that is the choice, the ADR should say so, because it is a
   change to a mechanism ticket 210 already proved.
2. **Whether `.deb` is a format guarden unpacks at all.** It is an `ar` archive, which
   is a container format with no stdlib reader, and unpacking one is unpacking a
   *package manager's* output. If the answer is no, then option A is off the table and
   the choice is B or C — and that should be discovered before the ADR argues for A.

## MEASURED: there is a raw binary, and it removes option A's objection

I guessed a "static binary" and then checked, because the guess was load-bearing.
Read from the GitHub releases API (metadata only — no artefact was downloaded):

```
$ curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest
tag: 2026.10.0        26 assets
  cloudflared-linux-amd64            40129756      <- raw, no extension
  cloudflared-linux-arm64            37687584      <- raw, no extension
  cloudflared-linux-amd64.deb        19316284
  cloudflared-fips-linux-amd64       (raw)
  cloudflared-linux-{386,arm,x86_64}.rpm
  no asset matches "static"
```

**So: no `static` asset exists, and a raw per-architecture binary does.** That is the
`podlet` shape with **one fewer field** — a URL and one digest, no archive, no reader,
no `ar`, no `.deb`. The `.deb` objection above is real but **does not apply**, because
guarden would not take the `.deb`.

The cost is honest and worth stating: **40 MB against 19 MB.** The raw binary is
statically linked where the package is not, so it carries a libc it does not need and
cannot be patched by the distribution's security updates. Against that, a pinned
binary is *already* what guarden does for `podlet`, so the marginal trust cost of the
second one is the mechanism, not the size.

## Where that leaves the decision

Option **A, on a raw binary**, is now clearly the cheapest: it reuses `PODLET_FIELDS`
and both digest checks unchanged, needs no new reader, and keeps the property the
ticket actually asks for — *the version in force recorded in this repository and
asserted by `soil packages --check`*.

Two questions remain, and both belong in the ADR rather than in a note:

1. **Does the pin machinery get generalised or duplicated?** `PODLET_FIELDS`,
   `PODLET_FORMATS`, `PODLET_FETCH` and `PODLET_RECORD` are podlet-named and generic in
   shape. A second binary wants the same four fields and the same two digest checks. A
   rename touches one module; a second copy is two places to get a security property
   wrong. KISS and the repo's own "one canonical statement per rule" both say rename.
   But it changes a mechanism ticket 210 already proved, so it is the ADR's call and
   not this note's.

2. **Is a vendored static runtime acceptable to this design at all?** `podlet` is
   already one, so the precedent exists — but the ADR should say so explicitly rather
   than let it pass unremarked, because it is the kind of decision that is much harder
   to revisit once a host depends on it.

**A vendor APT repository (B) is now the clearly worse option.** It buys nothing that
the raw binary does not already give, and it costs the recorded-version property, a
persistent third-party APT key on every host, and contents that move under guarden's
pin. **A container image (C)** remains excluded by spec §2: the tunnel must dial out
before any container exists, so it cannot be an ordinary service.

## One thing a fetch this size must not do

A 40 MB download is the largest thing guarden has ever fetched, and the standing rule
is that a fetch is a **phase** that runs in the VM — never onto a development machine.
Whichever option the ADR takes, `soil packages` must fetch it into the mutator's own
temporary and verify the digest there, and no agent may hand-download it to "check the
URL works". That has already been got wrong on this branch once, at cost.
