# The owner override: what may change a volume's owner, and what may not

ADR-0019 moved the container's user onto the service identity and settled that guarden
never chowns a file to an image's uid: a pin decides *where* a uid lands, not *who
starts*. Ticket 308's second item records the escape hatch that decision left open — a
volume shared by two image uids, where one image's uid must own some of the tree and
the other the rest. The deferral was explicit: `overrides.toml`'s contract is a closed
set of tables, so a new key is a spec amendment, not an invented key.

Operator decision locked 2026-10-20 on ticket 308's item 2.

## Status

accepted (2026-10-20, operator) — DECIDED, not yet implemented. The implementation is
ticket 308's item 2; this ADR records the shape of the grant and the boundary it draws,
because a grant is a grant and the boundary is the whole of it.

## The decision

**`overrides.toml` gains a sixth table, `[ownership]`, and it is the only new surface.
It is a grant, and it is refused in every way the other grants are refused.**

```toml
[ownership]
# The uid that owns a volume's tree, when the image's own uid cannot.
volumes = { "data" = 999 }
```

The rules, each of which is one of the platform's existing rules applied to a new table:

- **The manifest cannot ask for it.** The manifest names the volume; the *admin* names
  the uid. A repository that asked for its own volume's owner would be asking for a
  host uid it cannot be trusted to know, and the whole point of the request/grant split
  (§7.7) is that the repository never widens its own reach.
- **The value is refused unless it is a uid the host already has.** Not any number: a
  uid that is not in `/etc/passwd` is refused, because a number nobody owns is not an
  owner. The service's own uid is the default and needs no entry.
- **The uid is applied to the volume's tree the way ADR-0019 says: by the walk, once,
  at a named step — never as a chown the container performs.** A container that chowns
  its own tree to a host uid is a container escalating; the same walk that skips
  snapper's subtree (ADR-0020) and the podman store (`_in_podman_store`) is the walk
  that applies it, and it applies the owner to the *host* side, under the mutator's
  hand.
- **It is refused for a `state` volume whose images chown their data.** That is the
  case ADR-0020 decides, and the two must not disagree: ADR-0020 makes the container
  not see snapper's subtree, and this table must not then let a container chown its own
  data to a host uid.

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

**The spec's "five tables" is already six.** `[ports]`, `[firewall]`, `[retention]`,
`[groups]`, `[mounts]`, and `[expose]`. Ticket 308's deferral said "overrides.toml's
contract is 'five tables and nothing else'" — that count was already stale when it was
written, and the amendment records the real number rather than the remembered one.

## What it costs, stated

- **An owner uid on a volume is a uid outside the service's own boundary.** The volume
  is `0700`-owned by the service's user, and a subtree of it owned by another uid is
  read by that uid. This is a real widening, and it is why the grant is refused for
  `state` volumes whose images chown, and why the value must be a uid the host knows.
- **The service user cannot then write that subtree** unless the other uid is the
  service's own or a group it holds. An operator granting an owner is choosing which
  half of a shared volume is writable by whom, and the answer is not always symmetric.
  This is a consequence to state, not a defect.
- **The walk that applies it is a second walk.** ADR-0019's walk skips snapper's
  subtree and the podman store; this one adds the ownership step. It is the same walk
  with one more rule, not a second mechanism, and the tree walk's carve-out list is
  where the rule goes.

## The scope of this decision

This is ticket 308's item 2. Items 1 (the A3 subdir-chown fallback) and 3 (the
manifest runtime-uid field) are separate decisions and are **not** settled here. Item 3
in particular is the more interesting one — declaring an image's runtime uid for
*mapping* is not changing an in-container uid — and it deserves its own ADR when a
live image needs it.
