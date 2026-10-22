# 361 — the `[ownership]` walk follows a symlinked volume root, and chowns through it as root

**Found by** the adversarial review of ticket 308's second item (`merge(308)` at `32a3eab`), the
same day the grant merged. It is a container-to-root escalation, and it was in the tree for
less than three hours.

## What the walk did

`volumes.own_tree` is the one place guarden hands a volume's tree to a host uid, and it runs as
the mutator — root. Its input is `<tree>/<kind>/<vol>`, and `<tree>/bulk` is the **service's own
`0700` directory**, created and owned by the service user. So the service user — or its
container, under the `keep-id` pin — can remove `bulk/<vol>` and leave a symlink in its place.

The walk then asked the link, not the volume:

```
target.is_dir()       follows the link            -> True
target.lstat()        reads the LINK's own pair   -> never equals the grant, so no early return
target.rglob("*")     scandirs the link's target  -> the entries OUTSIDE the volume
```

`pathlib` refuses to recurse into a symlinked directory *below* its base; it has no such rule
for the base itself. Measured with `pathlib` alone:

```
link -> <tmp>/real     link.rglob("*")   -> real's entries
link -> /              link.rglob("*")   -> /bin  /boot  /dev  /etc  /lib  /lib32  ...
```

## Measured against the shipped function

The function was extracted verbatim from `git show HEAD:src/guarden/volumes.py` and run with a
recording `set_owner`, on a volume root that is a symlink:

```
the shipped own_tree, on a volume root that is a symlink to outside:
  it raised: no
  it reported: ['handed .../bulk/data to 65534:65534']

  ESCAPED  chown(.../bulk/data, follow=False)          resolves to outside
  ESCAPED  chown(.../bulk/data/sub, follow=True)       resolves to outside/sub
  ESCAPED  chown(.../bulk/data/sub/deeper, follow=True) resolves to outside/sub/deeper
  ESCAPED  chown(.../bulk/data/victim, follow=True)    resolves to outside/victim

  4 chown(s) made as root, 4 of them OUTSIDE the service's tree
  VERDICT: ESCAPED THE VOLUME
```

Every entry reads as inside the volume by its **name** and resolves outside it. With the link
pointing at `/`, those four are `/`, `/bin`, `/boot`, … — root chowning the filesystem, on the
next deploy that carries a grant, triggered by the user whose data the walk exists to protect.

Two conditions are needed: an admin `[ownership]` grant on that volume, and a service user who
leaves the link. The first is a deliberate act; the second is what any compromised container
can do.

## The fix (`82c8462`)

1. **`lstat`, not `is_dir`** — a link is not a volume. A symlinked root is refused with a
   diagnostic naming the volume and the uid it would have given away.
2. **The walk is bounded.** `paths.mount_base` is now the one definition of the tree a
   declared volume sits in, and `mount_source` builds its path from it — so the path the walk
   is handed and the bound it is checked against cannot disagree. A link *above* the volume
   (`bulk` itself replaced) is refused by the same bound.
3. The ordinary walk is unchanged: a real directory inside the tree is walked, and a volume
   whose root already carries the granted pair still costs one `stat`.

## Tests

`tests/test_volume_owner_walk.py`, 5 cases, all firing before any privileged call so they run
under `just unit`:

| case | asserts |
| --- | --- |
| a symlinked volume root | refused, and nothing under the link was touched |
| a link to `/` | refused — the reported case |
| a link above the volume | refused, "outside the service's own tree" |
| a real volume inside the tree | walked, root and entries |
| a volume already carrying the pair | one `stat`, no walk (convergence) |

`just unit`: 136 tests, OK. `t277-volume-owner` re-run at the fixed tip: green, with the grant
still measured end to end (`the granted volume's tree is owned by uid 65534`, `the container
reading the granted volume: Permission denied`).

## What this says about the class

The review found it because it asked what a `chown` as root does when its input is controlled
by the party it is protecting. The grant was correct in every respect the ticket described —
the refusal set, the walk's ownership, the option-A boundary — and wrong in the one place the
ticket did not name: that its input path can be replaced by a link.
