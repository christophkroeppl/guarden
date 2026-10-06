# cloudflared publishes no checksum file, so the pin's digests were computed, not copied

ADR-0015 requires a pinned artefact to carry `format`, `url`, `sha256` and
`binary_sha256`, and requires both digests to be verified on install. Recording **where
those two values came from**, because the obvious source does not exist and the next
person will go looking for it.

## There is no `.sha256` sidecar

`2026.10.0` is a real tag and the asset names are the real ones. But:

```
GET .../2026.10.0/cloudflared-linux-amd64.sha256  →  404
GET .../2026.10.0/cloudflared-linux-arm64.sha256  →  404
```

Enumerating every asset on the release via the GitHub API returns 28 files — every
`.deb`, `.rpm`, `.pkg`, `.tgz` and `.exe` for six architectures plus three FIPS
variants — and **not one checksum**. So there is nothing to diff against, and any digest
in the repository that claimed to come from upstream did not.

## So both digests were computed from the published binaries

Downloaded, hashed, and the two values written to the pin:

| arch | asset | size | sha256 |
|---|---|---|---|
| `x86_64` | `cloudflared-linux-amd64` | 40.1 MB | `d33ff2d14475178d2012c2c56beba87389ac5ded27649519f198a7d3134a99db` |
| `aarch64` | `cloudflared-linux-arm64` | 37.7 MB | `e6422b9d4f72d3194bc5a38676f13667c06666523217b842a877d72a80b5ac08` |

**`sha256` and `binary_sha256` are the same value here, and that is correct.** `format` is
`raw` — the asset *is* the binary, with no archive to unpack — so there is exactly one
file and therefore one digest. The second field exists for `format = "tarball"`, where
the archive and the executable inside it are two different files and a substitution
attack gets one without the other. Writing the same value twice on a `raw` artefact is the
truth, not a copy-paste slip.

Two consequences worth stating, because both are the ADR working rather than the ADR
being satisfied by paperwork:

- The pin cannot be re-verified against upstream. It can only be verified against
  *itself* — which is what `soil packages --check` does, re-reading the retained binary
  and refusing a host whose file does not match. That catches a corrupted or swapped
  binary on the box; it cannot catch upstream publishing a bad build. For that, the
  value has to come from a second channel, and cloudflared offers none.
- **The 40 MB static binary against podlet's 19 MB** is the trade ADR-0015 already
  records. It is the price of there being no sidecar to verify against and no package to
  take the distribution's signature instead.

Nothing was downloaded to the development machine and left there: this was a hash of a
stream, and the 78 MB of binaries went to a browser workspace that is not the checkout.