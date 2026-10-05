# 240: a subvolume is a bind mount, and a `.volume` unit is not a subvolume

**Blocked by:** nothing. **Unblocks:** `t50-slice`, and the quadlet-generator
question in `docs/notes/quadlet-generator-is-not-switched-on.md`.

**What to build:** Delete the `.volume` unit guarden renders per declared volume, and
express each volume in the container's own `[Container]` table as a bind mount of the
subvolume the mutator already created.

## Why there is no key to fix

`src/guarden/templates/quadlet-volume.j2` writes `Source=` into `[Volume]`. The
generator rejects it:

```
converting "data.volume": unsupported key 'Source' in group 'Volume'
converting "node.container": requested Quadlet source myapp-staging-chainstate.volume
  was not found
```

The distribution's own man page (`quadlet.5.gz`, section *Volume units `[Volume]`*)
says what that section is:

> …a section `[Volume]` describing **the named Podman volume**. The generated service is
> a one-time command that ensures that the volume exists on the host, creating it if
> needed.

The complete key list — `ContainersConfModule`, `Copy`, `Device`, `Driver`, `GID`,
`GlobalArgs`, `Group`, `Image`, `Label`, `Options`, `PodmanArgs`, `ServiceName`,
`Type`, `UID`, `User`, `VolumeName` — is entirely arguments to `podman volume create`.
**None accepts a host path.** `Source` is not a misspelling of anything.

A `[Volume]` unit creates a podman named volume. A guarden volume is a **btrfs
subvolume** at a host path the mutator created: owned by the service uid, `0700`,
snapshotted, cloned on fork, rolled back. A named volume is none of those, and
`podman volume create` has no option that turns one into a pre-existing host path.

**A second error hides inside the same symptom.** Quadlet resolves units by
**filename**: `data.volume` declares `VolumeName=myapp-preview-data.volume` and the
container references *that*. The two names differ, so even a valid `[Volume]` would
not have resolved. Deleting the unit fixes both.

## What to build, precisely

**`Volume=`, not `Mount=`.** Both are correct quadlet and both are equivalent for a
bind mount. `Volume=` lands with far less new surface: `Volume` is already in
`GUARDEN_OWNED_ORDER` (`render.py:126`), `_quadlet_mount` already parses it, and
`t40-hostpaths.py` already walks its sources.

- **`src/guarden/templates/quadlet-volume.j2` — delete.**
- **`src/guarden/render.py:725`** — drop the `plan.add(f"units/{name}.volume", …)`.
- **`src/guarden/render.py:994 _volume_unit`** — delete, and emit one
  `Volume=<subvolume path>:<in-container path>` per declared volume from
  `document.volumes()` instead, beside the other guarden-owned lines.
- The in-container destination is the volume's declared mount point, so the
  repository's own `Volume=` line for a declared volume is **removed** and guarden's
  derived one written in its place — one place a subvolume becomes a unit line.

### The ordering edge the `.volume` unit was there to provide

It is already how guarden works: the mutator creates the subvolume **before** it
installs the container unit, so the path exists before the unit can be started. A
`.volume` unit buys a subvolume nothing and costs a rejected one. Nothing is lost.

## Three things this must fix at the same time

Two are pre-existing and one is a live escape surface. Fixing only the template leaves
every render refused.

**1. `check_mount_paths` would refuse every declared volume** (`render.py:492-503`).
It allows `[mounts] allow` plus `ALLOWED_ROOT = "/etc/guarden"`, and the service's own
volume tree is in neither. It never fires today only because `.volume` put the path in
a file this guard never reads. Its refusal message already *claims* "is not the
service's own volume", which is false today.

**The fix is not to widen the guard.** Emit guarden's derived volume lines from
`document.volumes()` and keep the repository's `Volume=` lines for admin-allowed host
paths only. Then a guarden-owned path never reaches the guard, a manifest still cannot
name a host path, and there is exactly one place a subvolume becomes a unit line.

**2. `REFUSED_DIRECTIVES` contains `"Mounts"`** (`render.py:102`), which **is not a
quadlet key** — upstream's is `KeyMount = "Mount"`. So `t40-refusals.sh:71` asserts a
refusal of a directive quadlet would reject as *unsupported*, and the test passes for
the wrong reason. Worse: the real `Mount` is in neither `REFUSED_DIRECTIVES` nor
`GUARDEN_OWNED_ORDER`, `_lines()` passes source keys through verbatim, and
`_mounts_of_unit` (`render.py:359-363`) reads only `Volume` — so **a repository can
already write `Mount=type=bind,source=/,destination=/host` today and nothing looks at
it.** Change the refusal to `Mount`, add it to the owned keys, and read `Mount=` in
`_mounts_of_unit` so the path guard sees it.

**3. `tests/t40-refusals.sh:71`** uses `Mounts=type=bind,src=/,destination=/host` —
not quadlet syntax either. It must become the real key.

## Rootless: no obstacle, and guarden's own design is why

Podman's rootless docs, on a bind-mount source owned by another uid: `CAP_DAC_OVERRIDE`
overrides a mode only when uid **and** gid both map in the namespace, and their table
shows `700` owned by a subuid-range uid as passing. A guarden subvolume is `0700`
owned by the service uid — the passing case. **`idmap` must not be used** (rootful
only). **No `:z`/`:Z`** — it would relabel the snapper tree, and the target is
Debian/Ubuntu. **No `U=true`** — it would chown the snapshot tree.

It already works in anger: the edge and dashboard bind
`/var/lib/guarden/{edge/dynamic,shared/dashboard}` rootless today with no relabel.

## What does not change

- **Snapshot, clone and rollback semantics are untouched.** Only how the container
  *reaches* the subvolume changes; `btrfs` operates on the host path. A rollback swaps
  contents at the same path and a bind mount follows the path — which is what a
  rollback should do.
- **A `bulk` volume's empty subvolume after a fork** is indistinguishable from a
  populated one to a bind mount.

## Suites

- **`tests/t40-volumes.sh`** — the one that actually changes. The `.volume`-unit
  assertions go; the subvolume path assertions stay. **Add**: a cross-service read is
  refused, and `Mount=type=bind,source=/` is refused.
- **`tests/t40-render.sh:181`** — drops `units/data.volume`.
- **`tests/t40-refusals.sh:71`** — the real key.
- **`tests/t50-slice.sh`** — add `podman inspect --format '{{.Mounts}}'` as the service
  user, proving source path and destination, which is the claim no unit file can make.
- **`t30-remove.sh` and `t70-fork.sh`** assert nothing about `.volume`; they are
  unaffected by this change.

## Not to be claimed without measuring

`docs/notes/quadlet-generator-is-not-switched-on.md:47-63` records that the generator
was never switched on, and an empty `podman quadlet list` may not be explained by
`Source=` alone. Whether the generator produces anything at all after this change is
**unproven** — it is the first thing to measure in the VM, and a green suite that never
generated a unit would prove nothing.

## One command per shell invocation, and everything runs in the VM

No fake, no stand-in for quadlet. The proof is a generated unit and a container that
started.
