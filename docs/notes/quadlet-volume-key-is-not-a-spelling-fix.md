# The `.volume` template emits a key quadlet does not accept

**Status: RESOLVED by measurement. There is no replacement key — the key does not
exist, and a `.volume` unit is the wrong tool.**

## What quadlet's own schema says

Read from the quadlet man page shipped by the distribution
(`/usr/share/man/man5/quadlet.5.gz`), section `Volume units [Volume]`:

> Volume files are named with a `.volume` extension and contain a section `[Volume]`
> describing **the named Podman volume**. The generated service is a one-time command
> that ensures **the volume exists on the host, creating it if needed**.

The complete list of valid `[Volume]` keys:

```
ContainersConfModule  Copy  Device  Driver  GlobalArgs  Group  Image
Label  Options  PodmanArgs  Type  User  VolumeName
```

**`Source` is not among them, and nothing in the section accepts a host path.** Every
one of those keys is an argument to `podman volume create`.

## Why that is fatal rather than a spelling problem

A `[Volume]` unit creates a **podman named volume**. guarden's volumes are **btrfs
subvolumes** at a path the mutator created, owned by the service uid, snapshotted,
cloned and rolled back. A podman named volume is none of those things, and
`podman volume create` has no option that makes one into a pre-existing host path.

So there is no key to substitute. The fix is a different mechanism.

## The fix

A subvolume is a **host path**, and a host path in a container is a **bind mount**,
which is `Mount=` in the `[Container]` section (equivalently `Volume=`), not a
`.volume` unit:

```
Mount=type=bind,source=<the subvolume path>,destination=<in-container path>
```

The dependency edge the `.volume` unit was there to provide — "the volume exists
before the container starts" — is already how guarden orders things: the mutator
creates the subvolume before it installs the container unit, so the path is there
before the unit is ever started. The `.volume` unit buys nothing for a subvolume and
costs a rejected unit.

`docs/spec.md` §7 and the `loom` refusal list both describe volumes as subvolumes, so
the renderer emitting a `.volume` unit is the inconsistency, not the spec.

## What to change

1. `src/guarden/templates/quadlet-volume.j2` — delete. Nothing should generate it.
2. `loom` — emit `Mount=type=bind,...` per declared volume instead, and stop writing
   a `.volume` unit per volume.
3. The start-order edges: the volume's ordering requirement moves from a unit
   dependency to the mutator's create-before-install order, which already exists.
4. Suites `t30-remove`, `t50-slice`, `t70-fork` assert on the generated `.volume` unit
   and need to assert on the `Mount=` line and the subvolume instead.

## Evidence

```
$ lxc exec probe-quadlet -- zcat /usr/share/man/man5/quadlet.5.gz | col -b \
    | sed -n '1665,1710p'
.SH Volume units [Volume]
Volume files are named with a .volume extension and contain a section [Volume]
describing the named Podman volume. ...
Valid options for [Volume] are listed below:
[Volume] options            podman volume create equivalent
ContainersConfModule=...    --module=...
Copy=true                   --opt copy
Device=tmpfs                --opt device=tmpfs
Driver=image                --driver=image
...
VolumeName=foo              podman volume create foo
```

and the generator's own rejection, from guarden's rendered units:

```
converting "data.volume": unsupported key 'Source' in group 'Volume'
```
