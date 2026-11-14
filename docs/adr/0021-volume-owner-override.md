# The owner override: what may change a volume's owner, and what may not

ADR-0019 moved the container's user onto the service identity and settled that guarden
never chowns a file to an image's uid: a pin decides *where* a uid lands, not *who
starts*. Ticket 308's second item records the escape hatch that decision left open — a
volume whose tree has to belong to a host uid that is not the service's own. The deferral
was explicit: `overrides.toml`'s contract is a closed set of tables, so a new key is a
spec amendment, not an invented key.

Operator decision locked 2026-10-20 on ticket 308's item 2, and narrowed 2026-10-22 to
what the pin can actually deliver: **the grant is host-side ownership only.** The other
reading — that it lets a container act as another uid — is not expressible with one
`keep-id` pin, and "What it buys, and what it does not" is where that is said with the
measurement behind it.

## Status

accepted (2026-10-20, operator), implemented (2026-10-22) — ticket 308's item 2. The
implementation, `tests/t277-volume-owner.sh`'s §3.3 section, `docs/spec.md` §3.3 and this
ADR landed in one change, because a grant the program refuses and a grant it applies are
two different contracts.

## The decision

**`overrides.toml` gains an eighth table, `[ownership]`, and it is the only new surface.
It is a grant, and it is refused in every way the other grants are refused.**

```toml
[ownership]
# The host uid that owns a bulk volume's tree.
volumes = { "scratch" = 999 }
```

The rules, each of which is one of the platform's existing rules applied to a new table:

- **The manifest cannot ask for it.** The manifest names the volume; the *admin* names
  the uid. A repository that asked for its own volume's owner would be asking for a
  host uid it cannot be trusted to know, and the whole point of the request/grant split
  (§7.7) is that the repository never widens its own reach.
- **The value is refused unless it is a uid the host already has.** Not any number: a
  uid that is not in `/etc/passwd` is refused, because a number nobody owns is not an
  owner. The service's own uid is the default and needs no entry.
- **The name is refused unless the manifest declares the volume.** A grant on a name
  nothing declares is a grant that does nothing, and the operator who wrote it would
  believe it was in effect — which is the one thing this file must never allow, because
  the file is how the operator knows every way the host has been widened.
- **It is refused for a `state` volume.** A `state` volume's tree is snapper's as much as
  the service's: it carries `.snapshots`, `0750 root:root`, and its image's entrypoint may
  chown the data directory on start — ADR-0020 names the class, and the two decisions must
  not disagree. **Whether a given image chowns is not knowable before it runs** (no probe
  reads an entrypoint's behaviour), so the whole kind is refused rather than a subset
  guarden cannot detect, and an owner the service user does not hold is exactly the chown
  that fails.
- **The owner is applied by guarden's own walk, at the reconcile — never by a chown the
  container performs.** `volumes.own_tree` walks the volume the grant names, under
  the mutator's hand, which is root; a container that chowned its own tree to a host uid
  is a container escalating. The walk runs from `weedr service add`/`ingest` (spec 5.3) on
  the **converged** path too — the grant has no verb of its own, so writing the file and
  re-running the reconcile is how an operator applies it. **A grant removed is the create
  path's walk**: `_make_tree` and the volume's create own the whole tree, and they run on a
  deploy that is not converged, so the reconcile walks only the volumes a grant names.
  Walking every volume on every reconcile would be a second statement of the tree's rule
  in the place `_repair` is deliberately narrow.

## What it buys, and what it does not

**The subtree is owned on the host by the named uid.** A process running as that uid — a
backup agent run as that user, another service's container whose own service uid is the
granted one, an operator's own inspection as root — can read it.

**A container cannot act as that uid.** A unit whose image declares a user renders
`UserNS=keep-id:uid=<image uid>,gid=<gid>` (`render.py:262`, `clone.py:539-548`), which
maps exactly one image uid onto the service identity; every other host uid is unmapped
inside the container, and `tests/t277-volume-owner.sh:230-250` measures the consequence as
`Permission denied`. So the granting service's own container does not read the subtree,
and **cross-service volume sharing is not something this grant provides** — a second
service reads the volume only when the admin names that service's own uid, and even then
the path has to reach it (§3.3 `[mounts] allow`). A sentence promising that a container
reads a subtree owned by another uid would be promising what the pin cannot deliver.

**The service user loses the volume's tree.** The tree stays `0700` and it is the granted
uid's, so the service that owns the volume can neither read nor write it. An operator
granting an owner on a volume the service still needs at run time is choosing a volume the
service no longer uses; the choice is stated here rather than discovered at the first
`Permission denied` in a container's log.

**The tree above the volume is not widened.** The service tree and its `bulk/` directory
are the service's own `0700`, so a process running as the granted uid reaches the volume
only through a path the host allows it — a bind mount guarden made, an operator's root
shell. Guarden does not widen the tree above a volume to make the grant useful: that tree
is the isolation boundary (spec 2.1), and this grant is about one volume inside it.

## What it is NOT

- **It is not a second ownership model.** One volume, one owner, chosen by the admin.
  It is not a per-path owner map, and it is not a way to say "this file belongs to
  another uid and that one does not" — a per-path map is a policy engine, and the
  platform has none.
- **It is not in the manifest, and it is not in the registry.** The registry is the
  mutator's record of what IS; an override is what the admin granted. Putting the
  grant in the registry would make a projection a grant, which is the confusion
  ticket 291 was about.
- **It does not extend to the home, the unit source, or the credential store.** The
  `[mounts] allow` table already says which host paths a unit may bind-mount, and the
  home's ownership is the isolation boundary itself: a service's home is `0700` to the
  service's user, and nothing changes that.

## Why the surface is `overrides.toml` and not somewhere else

The spec's sentence is *"Nothing else is overridable"* (§3.3) — and that sentence is
load-bearing, because it is what makes the file auditable: an operator can read one
file and know every way the host has been widened beyond the repository's request. A
grant surface outside that file is a grant surface nobody reads. So the new table goes
*in* the file, and the spec's sentence is amended to name it — the same amendment
`[expose]` already required, when the exposure cluster added its table.

**`[ownership]` is the EIGHTH table, and the counts around this decision were stale.**
The file carries `[ports]`, `[retention]`, `[groups]`, `[mounts]`, `[firewall]`,
`[expose]` and `[basicauth]` (ADR-0024) today, so the new one is the eighth — not the
seventh this ADR first said, and not the "sixth" ticket 308's status line said. Both were
written before a later ADR added a table, which is the failure mode: **recount from the
schema that declares the tables (`overrides.py`'s `KEYS`), never from another document.**

## The scope of this decision

This is ticket 308's item 2. Items 1 (the A3 subdir-chown fallback) and 3 (the
manifest runtime-uid field) are separate decisions and are **not** settled here. Item 3
in particular is the more interesting one — declaring an image's runtime uid for
*mapping* is not changing an in-container uid — and it deserves its own ADR when a
live image needs it.
