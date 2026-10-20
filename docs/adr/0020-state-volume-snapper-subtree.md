# A state volume's snapper subtree: what the container may see of it

guarden's isolation boundary is one host uid per service and its `0700` tree. A `state`
volume is a btrfs subvolume with a snapper configuration of its own, and snapper puts its
own `.snapshots` directory **inside** that subvolume, `0750 root:root`. The container is
rootless: its `uid 0` is the *service* uid through `/etc/subuid`, so it cannot `chown` a
directory owned by the real host root. Every image whose entrypoint runs `chown -R` over
its data directory therefore fails against a `state` volume — the stock `postgres` image
among them, and with it `mariadb`, `mysql` and `elasticsearch`. This is not a race and
not a misconfiguration: the volume always carries snapper's root-owned subtree, so the
failure is structural.

Operator decision locked 2026-10-20, after a measured option review, on ticket 273.

## Status

accepted (2026-10-20, operator) — DECIDED, not yet implemented. The implementation is
ticket 273's "What to build", unchanged in shape; this ADR records which of the two
answers guarden takes and what it costs, because the answer changes what a snapshot of
a volume contains and that is a contract question, not an implementation detail.

## The two answers, and which one guarden takes

**The service-side answer is what an operator does today, and it stays supported.** Point
the image at a subdirectory of the volume that is not the volume root, so the recursive
chown never sees `.snapshots`. For postgres that is `PGDATA=/var/lib/postgresql/data/pgdata`;
for others the equivalent. The data still lives inside the volume, one level down, and
the volume still snapshots.

**The guarden-side answer is the real fix, and it has two shapes:**

1. *Make `.snapshots` traversable and ownable by the service user.* It would stop the
   chown from failing.
2. *Mount the subvolume's **contents** rather than the subvolume, so the container never
   sees `.snapshots` at all.*

**Guarden takes shape 2, and NOT shape 1.** The reasons are the spec's, and they are not
close:

- **Shape 1 contradicts the isolation boundary.** `.snapshots` is `root:root` and
  `0750` *on purpose* — it is snapper's bookkeeping, and the spec says nothing
  root-owned lives inside a service's home (§2, "Nothing root-owned lives inside a
  service's home"). Making the service user able to `chown` snapper's subtree means the
  service can rewrite the marks that protect its own snapshots, and can delete them. The
  marks are what `weedr pin sync` writes and what the retention ladder reads; a service
  that can chown them can unmark them, and a pinned snapshot stops being protected
  against the service that owns it. The 0700 home is the property this whole platform
  rests on, and shape 1 spends it to fix a chown.
- **Shape 2 is the same answer the platform already gives the image store.** The podman
  image store lives in the service's home and the container never sees snapper's
  bookkeeping in it either. "Snapper's bookkeeping is not the container's business" is
  already a principle here; shape 2 applies it to the volume.
- **Shape 2's cost is knowable, and shape 1's is not.** Mounting the subvolume's
  contents changes what a snapshot of the volume contains: the snapshot covers the
  *data*, and `.snapshots` is snapper's own metadata about the snapshot, not part of it.
  That is a change to what a restore produces, and it is a change we can state. Shape 1's
  cost is that the service gains write access to snapper's metadata, and nothing
  measures that cost — it is a permission grant with no bound.

## What the decision costs, stated

- **A snapshot's content changes.** A restored `state` volume carries the data and not
  snapper's `.snapshots` subtree. Nothing in guarden reads that subtree out of a snapshot
  — snapper's configuration owns the volume and its own subtree lives beside the data it
  snapshots — so this is a statement about the artefact, not a behaviour change.
- **A `state` volume's data must be one level down from the mount point.** The volume's
  *contents* are mounted, so the container's data path is the volume's data path, and
  `.snapshots` is not among them. This is the same shape as the service-side answer
  above, and it is why the two answers agree.
- **`bulk` volumes are unaffected** — they carry no snapper configuration and therefore
  no `.snapshots` subtree. The decision changes only `state` volumes.
- **The `Volume=` line the renderer writes changes** for a `state` volume, and the
  spec's §2 table is amended alongside the implementation. The change is that the
  mount source is the subvolume's contents rather than the subvolume itself.

## What is NOT decided here

- **Whether the mount shape is expressible as it stands.** A btrfs subvolume's contents
  are not themselves a subvolume, and a bind of a directory inside a subvolume is a
  different object from a bind of the subvolume. Whether podman/quadlet can express
  "mount the contents of this subvolume" — and whether a snapshot still lands where
  snapper expects — is a **measurement**, and the implementation is where it is taken.
  If it turns out not to be expressible, this ADR is wrong and the fallback is
  shape 1 with its cost stated above, or the service-side answer, which is documented
  and supported either way. The decision is which way to try and what the fallback is;
  it is not a claim that the shape works.
- **The A3 subdir-chown fallback** (ticket 308's item 1) is a separate decision and
  is not settled by this one.

## The fallback, if the measurement refuses

The service-side answer — `PGDATA` one level down — is already documented, is already
supported, and is recorded in each affected service's manifest. If the contents-mount is
not expressible, guarden falls back to the service-side answer and says so, rather than
shape 1. The reasoning is one line: **the cost of shape 1 is a permission grant on the
snapshot's own protection, and the cost of the fallback is a line in a manifest.**
