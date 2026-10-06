# `t130-packages` asserted a precondition it never established, and `passt` was never declared

Two defects, found while answering "does guarden use netavark/aardvark". The first is a
product gap, the second a test defect, and they were found in that order.

## 1. `pasta` is a `Recommends`, not a `Depends`

Measured on `guarden-golden`, podman 5.7.0:

```
apt-cache depends podman →  Depends: netavark
                             Recommends: passt
                             Recommends: slirp4netns

dpkg -S $(readlink -f /usr/bin/pasta)  →  passt: /usr/bin/pasta
podman info --format {{.Host.NetworkBackend}}  →  netavark
```

`pasta` — the backend every generated unit names, and the only one the renderer will
emit — comes from the **`passt`** package, and podman only **recommends** it. It is
installed on the golden because that image has `--install-recommends` on.

A host installed `--no-install-recommends` gets podman, gets netavark (a hard
`Depends`), and **no backend at all**: every container then fails to start on a
`Network=pasta:` podman cannot find, and the failure surfaces per-service at deploy
rather than at `soil install`.

`packages.toml` listed `podman` and not `passt`, so `soil packages` did not install it
either. **The whole design depended on an apt recommendation.**

**The gap's shape:** nine suites assert `Network=pasta:` is *rendered*, `t20-install.sh`
asserts `pasta_options` is *configured*, and not one asked whether pasta is *installed*.
The configuration was verified everywhere and the dependency nowhere — which is the same
defect class as ticket 270 one layer up, where the firewall's *table* was inherited from
`update-alternatives` rather than stated.

Fixed by declaring `passt` in all three family lists, with the reason recorded at the
list, and by `assert_dpkg passt` beside the existing `assert_dpkg podman`.

## 2. The comparison that decides ticket 130 could not see a conditional package

`soil packages --list` prints three roles. A conditional row is emitted as:

```
conditional zram: installed only when the configuration asks
  zram
```

— a header line **and** a two-space-indented package row.

The suite compared the phase's list against the rendered cloud-init document with:

```sh
grep -vE '^(family|install|query) ' "$FIXTURES/list-stdout" | sort
```

That filter matches neither shape. The header starts `conditional ` and the package
carries a leading indent, so **both survived** into the "converged but not rendered"
comparison and the suite failed on a package that is *deliberately* absent — and
`tools/render-user-data` renders the substrate and harness roles only, by design.

Now one filter that drops all four prefixes and any indented row.

## 3. And the one underneath it: 38 suites write the same file

With the above fixed, the suite failed differently — `/etc/guarden/podlet.release is
still there`. It asserted:

```sh
assert_file_missing /etc/guarden/podlet.release
```

with the comment *"this suite ran no `install`, so the record is absent rather than
half-filled."*

**That reasoning is about the wrong subject.** The golden's `base` snapshot carries no
record, so a clean cut satisfies the assertion by itself — but **38 suites export
`GUARDEN_PREFIX=/` and call `stage_podlet_release`**, which writes exactly that file to
the real root. So the assertion held only when this suite happened to run before any of
them, and this file was *itself* one of the 38.

Confirmed rather than reasoned: the file's mtime on a cut was the minute of the run that
created it, the golden had no `/etc/guarden/podlet.release` and no
`/usr/lib/guarden/bin/` at all, and the failure reproduced identically with my own change
stashed.

**A suite must establish a precondition it depends on.** The fix is `rm -f` on the two
paths rather than asserting their absence. The `--check` immediately after is the actual
claim — on a machine with no record the phase reports the missing fetch — and that is
what the suite now asserts.

## What was *not* wrong

The `passt` change is a distribution package, so it is not a pinned artefact, not a
vendor repository, and **ADR-0015 is untouched**. netavark stays installed as podman's
dependency; removing it would be a change to podman, not to guarden.

Guarden does not need netavark or aardvark-dns and could not use them coherently: a
shared bridge network with per-container DNS is precisely what AGENTS.md forbids
("no shared podman network, no name map, and no per-group address space"), and service
names come from `AddHost=` with no `/etc/hosts` write anywhere.
