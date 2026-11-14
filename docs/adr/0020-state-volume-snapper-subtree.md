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

accepted (2026-10-20, operator) — DECIDED and IMPLEMENTED (2026-10-21, ticket 325).
This ADR records which of the two answers guarden takes and what it costs, because the
answer changes the contract the `Volume=` line carries. The implementation is the
payload directory this ADR names: `state/<vol>/data/`, mounted by the renderer, with
the refusal for a volume whose data is at the root. The two facts this ADR got wrong
in its first revision — that a snapshot's content changes, and that the mount shape's
expressibility was open — are corrected below, and the correction is recorded rather
than made silently.

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
  contents costs one extra directory level inside the snapshot: the snapshot
  covers the *data*, and `.snapshots` is snapper's own metadata about the
  snapshot and was never part of it — it is a nested btrfs subvolume, and
  btrfs does not recurse into a nested subvolume when it snapshots. So the
  content a restore produces is the data, before and after, and the delta is
  where the data sits. That is a cost we can state. Shape 1's cost is that
  the service gains write access to snapper's metadata, and nothing measures
  that cost — it is a permission grant with no bound.

## What the decision costs, stated

- **A snapshot's content does NOT change.** A `state` volume's snapshot already excluded
  snapper's `.snapshots` subtree, because `.snapshots` is a **nested btrfs subvolume** and
  btrfs does not recurse into a nested subvolume when it snapshots — the same fact the
  spec's §2 layout rests on. Measured on the operator's host: `btrfs subvolume list`
  shows `.snapshots` as a subvolume *of* the volume, with each snapshot one level under
  it. So a restored `state` volume carried the data and not the subtree, before this
  decision and after it. **The only delta is one extra directory level inside the
  snapshot.** An earlier revision of this ADR said the snapshot's content changes, and
  that was wrong.
- **A `state` volume's data must be one level down from the mount point.** The volume's
  *contents* are mounted, so the container's data path is the volume's data path, and
  `.snapshots` is not among them. This is the same shape as the service-side answer
  above, and it is why the two answers agree.
- **The payload directory is `state/<vol>/data/`**, one level down inside the subvolume,
  and the container mounts it. The subvolume is still the volume — it is what snapper
  snapshots and what the configuration owns — and the payload is inside it. The
  repository's mount target is unchanged and no environment value has to be set: the
  image's own data path lands inside the payload, so the image's convention wins and
  guarden's layout makes room for it.
- **A `state` volume whose data is at the root is REFUSED, and guarden does not move
  it.** A move renames live data under a running process, it cannot skip `.snapshots`
  without a second rule, and it is not atomic across a service's several volumes. So
  the mutator refuses with one line, naming the service, the volume, the payload
  directory and the work, and it changes nothing: the volume starts EMPTY and the
  operator moves the data across deliberately. The exit is `1` — the host is not in the
  state the request assumed. **`weedr service start` asks the same question through the
  same function**, because a service deployed before this change carries the old shape
  and the start is the operator's way out of it; the spec carries where the refusal is
  enforced (§8.1).
- **`bulk` volumes are unaffected** — they carry no snapper configuration and therefore
  no `.snapshots` subtree, and their mount source is still the subvolume itself. The
  decision changes only `state` volumes, and a rule that changed every volume would be
  a rule about a problem only `state` has.
- **The `Volume=` line the renderer writes changes** for a `state` volume, and the
  spec's §2 table and §8.1 are amended alongside the implementation. The change is that
  the mount source is the payload directory rather than the subvolume root.

## What is NOT decided here

- **The A3 subdir-chown fallback** (ticket 308's item 1) is a separate decision and
  is not settled by this one.

## The measurement, taken

**The mount shape IS expressible, and it was measured rather than assumed.** A
btrfs subvolume's contents are not themselves a subvolume, so this was a real question:
podman/quadlet has to bind a directory *inside* a subvolume rather than the subvolume
itself, and the snapshot has to land where snapper expects.

It does. A `Volume=<path>:<target>` line names a path, and a directory inside a
subvolume is a path. The renderer writes the payload's path, podman binds it, and the
container sees the payload and nothing else. The snapper side is untouched by the
binding: snapper's configuration still owns the subvolume, and its `.snapshots` subtree
still sits inside it, one level away from the payload the container sees.

**So the fallback below is not needed, and the earlier revision of this ADR — which
left the shape open and named the service-side answer as the fallback — is superseded
on that point.** The service-side answer stays supported and documented, because a
repository may always point an image at a subdirectory of what it is given, and that
is a fact about the repository rather than about the host.

## The fallback, if the measurement had refused

The service-side answer — `PGDATA` one level down — is documented and supported, and
it is recorded in each affected service's manifest. Had the contents-mount not been
expressible, guarden would have fallen back to it rather than to shape 1. The
reasoning is one line: **the cost of shape 1 is a permission grant on the snapshot's
own protection, and the cost of the fallback is a line in a manifest.**
