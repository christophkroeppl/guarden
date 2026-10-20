# The build context's ignore file: the source's file, and guarden's lines in it

Ticket 317 asked one question the spec had not answered: `weedr service build` runs
`podman build` with the service's home as its context, and the home held only
`.guarden/`, `compose.yaml`, `Containerfile` and `.dockerignore`. A Containerfile that
COPYs a source file died with `125` and `"/Cargo.toml": no such file or directory`.

The spec (§6.6, amended 2026-10-20 in `8d4f360`) settles the shape: **the context is the
whole staged source**, and **the exclusion of the podman store and the secret database is
guarden's, not the repository's**. What it did not settle is *where* guarden's exclusion
lives and *how* the source's own narrowing survives beside it. That is this ADR, and it
is settled by measurement on podman 5.7.0 rather than by preference.

## Status

accepted (2026-10-20) — implemented in `c74f8b8` on `fix/t317-build-context`.

## The measurements

All on a cut from the golden (`probe-t317`), podman 5.7.0, buildah's builder:

| question | answer |
|---|---|
| a context's own `.dockerignore` | honoured, with no flag |
| `--ignorefile` **and** a context `.dockerignore` | the flag **replaces** the lookup — the context's own patterns are NOT applied |
| `--ignorefile` **and** a context `.containerignore` | the flag wins over both |
| `.containerignore` **and** `.dockerignore` both present | **`.containerignore` is read**; the `.dockerignore` is never consulted |
| the last matching pattern | wins: `*.txt` then `!plain.txt` re-includes; `!plain.txt` then `*.txt` excludes |
| `--ignorefile` naming a missing file | hard error, exit 125, no silent fallback |
| a `.dockerignore` excluding the Containerfile itself | the build still works — ignore rules apply to `COPY`/`ADD` sources, not to the `-f` recipe |
| the podman secret database | `<home>/.local/share/containers/storage/secrets/secrets.json` — **inside** the store, so one exclusion covers both |
| `COPY .` with no ignore file | the store AND `.config/containers/systemd/*.container` land in the image |
| `COPY .` with the store ignored | the store is absent from the image |

## The decision

**Guarden writes the exclusion into the context's own ignore file, under both names,
with the source's patterns first and guarden's last, at build time.**

- **Into the context's own file, and not `--ignorefile`.** `--ignorefile` *replaces* the
  context's lookup. Passing a merged file would therefore drop the source's own
  narrowing unless guarden re-merged it — and a merged file that guarden owns, outside
  the context, is a second answer to a question §6.6 gives the source. Writing into the
  context's own file keeps the source's patterns and guarden's in the ONE file podman
  reads, with no flag and no second mechanism.
- **Under both `.dockerignore` and `.containerignore`.** Buildah prefers
  `.containerignore` and never consults `.dockerignore` when both are present. A
  repository that ships `.containerignore` and nothing else would otherwise have
  guarden's `.dockerignore` ignored entirely, and the store would go into the image.
- **The source's patterns first, guarden's last.** The last matching pattern wins, so
  guarden's lines last means a source-side `!` negation cannot re-include the store.
- **At build time, not at copy time.** The home's podman store grows after the copy —
  podman writes the image layers and the secret database into it. A copy-time exclusion
  would be a statement about the past; the build is the moment the context is read.
- **Idempotent.** The merge replaces everything from a marker line onward, so a second
  build, or a home copied from another service's home, does not accumulate the block.

## What it is NOT

- **It is not a manifest key.** A `COPY` resolves against the context directory: no
  list expresses `COPY .`, a glob, a nested path or a multi-stage build. The
  Containerfile already states what the build needs; the ignore file is how the source
  narrows it.
- **It is not a second copy of the source's narrowing.** The source's patterns are the
  context's own and are kept verbatim ahead of guarden's.
- **It is not the copy's business.** The copy excludes the store and the rendered units
  because those are the HOST's and not the source's — a tree read from another
  service's home (`add --from <service>`) carries that service's store, and copying it
  whole would copy another service's credential material into the new home. That is a
  different rule from the ignore file's, and the two do not overlap: the copy's rule is
  about what is not the source's, the ignore file's is about what the build must not see.

## What it costs, stated

- **Guarden writes into a file in the service's own home.** The home is `0700` to the
  service user, so the service can edit its own ignore file — and a service that
  removes guarden's lines would put the store into its own next image. The marker line
  makes the removal detectable rather than silent: the next build rewrites the block,
  because the merge replaces from the marker and writes the file before the build reads
  it. A service that edits the file between the write and the build would need to win a
  race against a root process in its own home, which is a narrower thing than "the
  service owns its own build context" — but it is a thing, and it is stated rather than
  denied.
- **Two names to keep in step.** The merge writes both, so they cannot disagree; and
  the merge is idempotent, so a service shipping only one of them gets the other as
  well.
