# The `.volume` template emits a key quadlet does not accept

**Status: root cause found, fix not made. Do not guess the replacement key.**

## What is measured

`podman-user-generator -user -dryrun`, run as the service user, on guarden's own
rendered units:

```
converting "data.volume": unsupported key 'Source' in group 'Volume' in
  …/home/.config/containers/systemd/data.volume
converting "node.container": requested Quadlet source myapp-staging-chainstate.volume
  was not found
converting "web.container": requested Quadlet source myapp-staging-data.volume
  was not found
processing encountered some errors
```

Two facts, both from the generator itself:

1. **`src/guarden/templates/quadlet-volume.j2` writes `Source={{ source }}`, and
   `[Volume]` has no `Source` key.** quadlet rejects the unit outright, so no
   `.volume` unit is generated.
2. **The container then cannot resolve its volume.** `node.container` correctly
   writes `Volume=myapp-staging-chainstate.volume:/var/lib/bitcoin` — the
   `<unit>.<volume>` form quadlet wants — but the `.volume` unit it names does not
   exist, because (1) stopped it being generated.

So the chain is: bad key → volume unit not generated → container's volume
reference unresolvable → container unit not generated → `systemctl start` answers
`Unit not found`. **This is the whole of `t30-remove`, `t50-slice` and `t70-fork`.**

## Correction to the earlier reading

`docs/notes/quadlet-generator-is-not-switched-on.md` said the generator was not
enabled. That is wrong, and its "options 1 and 3" are wrong with it. Measured:

- podman 5.7 ships **no `quadlet.service`**; `podman.service` is the REST API
  (`ExecStart=/usr/bin/podman system service`).
- The generator is **`/usr/lib/systemd/user-generators/podman-user-generator`**, a
  systemd generator, so it runs at `daemon-reload` — which `start_units` already
  does. The generator **is** reached.
- A debug-level reload logs nothing because the generator is not declining the
  files with a reason: it is failing on them, and the message is at `-dryrun`.

**Nothing in guarden needs to switch a generator on. Guarden's own rendered unit is
wrong.**

## The replacement key is not guessed

`Volume=` was tried and the generator named it unsupported too:

```
converting "data.volume": unsupported key 'Volume' in group 'Volume'
```

That change was reverted rather than shipped. `[Volume]`'s documented keys are
`ContainersConfModule`, `Copy`, `Device`, `Driver`, `GlobalArgs`, `Image`,
`Label`, `Options`, `Type`, `User`, `Group` and `VolumeName` — none of which
carries a host source path, because a quadlet `.volume` is a **named podman
volume**, not a bind mount.

That raises the real question, which is a design one and not a spelling one:

**guarden's volumes are btrfs subvolumes the mutator created, and a podman named
volume is a different thing.** Either

- the `.volume` unit is the wrong instrument and a container should mount the
  subvolume path directly — `Volume=/var/lib/guarden/services/<svc>/state/data:/var/lib/app`
  in `[Container]`, which is an ordinary podman bind of a path guarden owns; or
- a named podman volume is created per guarden volume and the subvolume is bind-mounted
  into it, which is a second mechanism for the same job.

The first is smaller, matches what the mutator already does to the filesystem, and
keeps one owner per volume. The second is what `.volume` units are for, but it
means podman — not guarden — owns where the data lives, which cuts against
"persistent data is declared in one of two lists" and against the subvolume being
the thing snapshots clone.

**This needs a decision before code.** It is not a one-line template fix, and
shipping either spelling without deciding would be the guess this note exists to
prevent.
