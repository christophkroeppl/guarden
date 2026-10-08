# The podman network stack: netavark is installed and guarden never asks for it

Measured on `guarden-golden` (podman 5.7.0), 2026-10-06. Every number below is the
machine's own answer, not a document's.

## The question

Do we use [netavark](https://github.com/containers/netavark) and
[aardvark-dns](https://github.com/containers/aardvark-dns)? Do we need them?

## The answer

**We use neither, and we do not need them. We use `pasta`, which is a different thing
entirely** — and the reason is not preference, it is that the two models are
incompatible with guarden's design.

**`grep -rli 'netavark\|aardvark'` over `src/`, `tests/`, `docs/` and `modules/`
returns nothing.** Not a refusal, not a config key: the words are absent. `netavark` is
installed on the host and no guarden program, unit, document or test mentions it.

| | on the golden | guarden's relationship to it |
|---|---|---|
| `podman` 5.7.0 | installed | the runtime, declared in `packages.toml` |
| `netavark` 1.16.1-3.1 | **installed** | **never named** |
| `passt` (provides `/usr/bin/pasta`) | installed | **required, and required implicitly** |
| `aardvark-dns` | **absent** | never named — and correctly so |

`podman info` reports `NetworkBackend: netavark`. That is podman's *default*, and guarden
never uses it, because every generated unit carries `Network=pasta:` — the renderer owns
the backend and **overwrites** whatever the unit source asked for.

## Why the two models cannot be mixed

`netavark` is a **bridge/namespace** stack: it creates a bridge, allocates addresses, and
gives each container an IP on a shared network, with `aardvark-dns` answering names for
that network. Its unit of isolation is the *network*, and containers on it can address
each other by name.

`pasta` is a **per-namespace passthrough**: each container gets its own network namespace
with the host reachable through a mapped gateway. There is no shared network to join and
therefore nothing for `aardvark-dns` to serve.

guarden requires all four of these, and three of them are the reason pasta is the only
answer:

1. **"There is no shared podman network, no name map, and no per-group address space"**
   (AGENTS.md, binding). This is netavark's model exactly. Adopting netavark to get
   container-to-container DNS would mean adopting the shared network it requires.
2. **The renderer writes `AddHost=<provider>:<ingress.alias>` and nothing else.** There is
   no `hosts` lock and no `/etc/hosts` write, because nothing writes a name map. Name
   resolution between services is `AddHost`, not aardvark's zone file.
3. **The isolation boundary is the per-service uid and the `0700` on its tree**, not a
   network segment. A shared bridge is a second boundary guarden would have to hold.
4. **Loopback is closed by default** (spec §7.6) with a per-publication accept set. That
   whole design presumes the container reaches the host only through the gateway pasta
   maps — a bridge gives it other paths in.

So netavark is not merely unused: **it is the shape of thing guarden refuses**, and
aardvark-dns is the DNS half of a shared network guarden does not have.

## The finding: `pasta` is a `Recommends`, not a `Depends`

```
apt-cache depends podman →  Depends: netavark
                             Recommends: passt
                             Recommends: slirp4netns
```

`pasta` is `/usr/bin/pasta` from the **`passt`** package, and podmer only **recommends**
it. It is installed on the golden because `--install-recommends` is on.

**That makes the entire design depend on a recommendation.** A host installed with
`--no-install-recommends` — a common hardening default, and the default in many container
images — gets podman, gets netavark (a hard `Depends`), and **does not get `pasta`**. Every
generated unit then carries `Network=pasta:`, every container fails to start with a
backend podman cannot find, and the failure surfaces per-service at deploy time rather
than at `soil install`.

`packages.toml` lists `podman` and not `passt`, so `soil packages` does not install it
either. It is present on the golden by accident of the image's apt configuration.

**This is the same class of defect as the two already found this week**: a load-bearing
thing the host happens to provide. Ticket 270 is exactly this shape for iptables — the
firewall's *table* was inherited from `update-alternatives` rather than stated. Here the
*network backend* is inherited from an apt recommendation rather than declared.

## The fix, and its KISS shape

Declare it, the way `ferm` is declared:

```toml
packages = [ ..., "podman", "passt", ... ]
```

That is one line per family in `packages/packages.toml` and nothing else. No new phase, no
new verification step, no second network stack. `passt` is a **distribution package** in
Debian, Fedora and Arch, so this is not a pinned artefact and does not touch ADR-0015.

**A test should assert the backend exists**, which no suite currently does — `t20-install.sh`
asserts `pasta_options` is *configured*, and nine suites assert `Network=pasta:` is
*rendered*, and not one asks whether pasta is *installed*. That is the shape of the gap:
the configuration is asserted everywhere and the dependency nowhere.

## What this does not change

- Not a vendor repository, not a pinned artefact, no ADR amendment needed.
- No change to the rendered units, the firewall, or the refusal list.
- netavark stays installed as podman's dependency. Removing it is not the point and would
  be a change to podman, not to guarden.
