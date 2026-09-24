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

## storage: subvolumes and snapper ladders

```
soil storage --apply      # data subvolumes (pond-prod, pond-nonprod, volumes root) + snapper ladders + apt hook
soil storage --check      # ok when converged
```

Ladders cover `root` (`/`), `home` (`/home`), and `pond-prod`
(`/var/lib/pond/prod`). `pond-nonprod` is rebuildable and is never snapshotted.

Space-aware prune priority (FREE_LIMIT, reaped first to last): home and agents
first (`0.20`), root (`0.12`), `pond-prod` last (`0.06`). The pond is the last
thing to shrink.

Ladder and retention settings change only through `soil storage --apply`.
Never hand-edit `/etc/snapper/configs/*` — every `--apply` rewrites the
canonical values. To change a ladder, change the canonical values in
`soil/soil`, then run `soil storage --apply`.

Root is snapshotted before every apt install and upgrade (`DPkg::Pre-Invoke`
hook `/etc/apt/apt.conf.d/80snapper`).

## snapshots day to day

```
snapper -c root list                 # root timeline and apt pre snapshots
snapper -c home list
snapper -c pond-prod list
snapper -c root create -d "note"     # manual snapshot
snapper -c root undochange <pre>..<post> /   # roll back an apt run
snapper -c root delete <id>
```

Pinned snapshots survive pruning (stakes); everything else follows the ladder.

## lockout drill

```
soil firewall --apply --deadman      # arms a 15m timer that restores firewall access
```

If ferm cuts you off, wait for the dead-man timer to fire (it stops ferm and
disables ufw), or use the console and run `systemctl stop ferm`.
