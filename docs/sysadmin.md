# guarden sysadmin readme

Most important commands for operating the box. All `soil` commands run as root.

## soil phases

```
soil <phase> --check      # report drift, change nothing, exit 1 when drift exists
soil <phase> --apply      # converge the host
```

Phases: `users`, `firewall`, `sysctl`, `btrfs`, `storage`, `root-scripts`, `units`.

Audit everything: run `--check` for each phase. Fix drift with `--apply`.

## btrfs convert (ext4 root, one reboot)

```
soil btrfs --apply        # installs the dracut pre-mount hook, writes the reboot-needed marker
reboot                    # the hook converts root offline to btrfs, keeps /boot ext4, clears the marker
soil btrfs --apply        # resumes from persisted state: creates @ and @home, fixes fstab
soil btrfs --check        # ok when the convert is complete
```

State lives in `/var/lib/guarden/soil/btrfs.state`; the reboot-needed marker is
`/var/lib/guarden/soil/reboot-needed`. Exactly one reboot is required. A second
run after success reports `no drift`. `/boot` stays on ext4.

## storage: subvolumes and ladders

```
soil storage --apply      # volumes root + root/home ladders + apt hook
soil storage --check      # ok when converged
```

`soil storage` creates the volumes root (`/var/lib/guarden/beds/`) and the generic
ladders for `root` (`/`) and `home` (`/home`). Pond data subvolumes appear only when a
pond is dug — none exist by default.

A ladder is owned by the subvolume it protects: a pond's subvolume
(`/var/lib/guarden/ponds/<pond>/`), or a bed's own subvolume when it has one. Its config
lives with that owner, so `soil storage --apply` never rewrites it.

Space-aware prune priority (FREE_LIMIT, reaped first to last): home and agents
first (`0.20`), root (`0.12`), pond data last (`0.06`). Pond data is the last
thing to shrink.

Root and home ladder settings change only through `soil storage --apply`.
Never hand-edit `/etc/snapper/configs/root` or `/etc/snapper/configs/home` — every
`--apply` rewrites the canonical values. To change them, change the canonical values in
`soil`, then run `soil storage --apply`. Ladders owned by a pond or a bed are
configured by their owner, not by soil.

Root is snapshotted before every apt install and upgrade (`DPkg::Pre-Invoke`
hook `/etc/apt/apt.conf.d/80snapper`).

## ladders and pins

```
stakes list                # every ladder and its pins
stakes query <id>          # holders of one snapshot
stakes pin <id> --holder <bed>
stakes unpin <id> --holder <bed>
```

Pinned snapshots survive pruning; everything else follows the ladder that owns it.
`stakes` never blocks snapper — the cleanup hook reads the state file and exits 0
regardless.

## ponds

```
weedr pond dig <name>                      # create a pond (name is pond-<env>-<name>; none by default)
weedr pond fill <bed> -p <name>            # db + role for the bed
weedr pond drain <bed> -p <name>           # remove them; production asks first
```

Pond data lives in `/var/lib/guarden/ponds/<pond>/` and gets its ladder from its owner.
Each pond runs as its own user `pond-<env>-<name>` — created by `weedr pond dig` with
linger and its quadlet dir, exactly like a bed; there is no shared `pond` user.

## snapshots day to day

```
snapper list                        # every config
snapper -c root list                # root timeline and apt pre snapshots
snapper -c home list
snapper -c root create -d "note"    # manual snapshot
snapper -c root undochange <pre>..<post> /   # roll back an apt run
snapper -c root delete <id>
```

Pinned snapshots survive pruning (stakes); everything else follows its ladder.

## ferm and ports

```
weedr ferm list               # active ferm rules
```

Open ports come from `.guarden/bed.yaml` (`ports:`) plus the bed's admin override file;
`weedr` applies them. Nothing opens a port by hand.

## bed overrides (root-owned)

- `/home/bed-<env>-<name>/overrides.yaml` — root:root, `0444`. Readable by the bed
  user and the CLIs, writable only by root.
- Root-owned admin drop-ins in the bed's quadlet dir
  (`/home/bed-<env>-<name>/.config/containers/systemd/`), unit-level ones as
  `<unit>.container.d/`.
- Regeneration and `hose` never touch root-owned paths.

## deploy queue

One build at a time by default; the lane count is a root-owned override:

```
weedr queue lanes 2         # allow two concurrent builds (default 1)
weedr redeploy <bed> --now  # jump the queue for one request
```

The new count applies between builds — it never kills an in-flight one. Production still
jumps to the front of whichever lane frees up first.

## boot ordering

The fence bed starts first, then production ponds, then production beds. Staging and
preview start only after **all** production services have started, plus a fixed delay.
Container dependencies order the units inside each wave — a pond before the beds that
consume it. `weedr` writes the systemd ordering drop-ins; the delay is fixed in v1.

## lockout drill

```
soil firewall --apply --deadman      # arms a 15m timer that restores firewall access
```

If ferm cuts you off, wait for the dead-man timer to fire (it stops ferm and
disables ufw), or use the console and run `systemctl stop ferm`.
