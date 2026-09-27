# 40: soil: btrfs convert + snapper ladders

**What to build:** The host gets btrfs with snapshot ladders, including one reboot. An operator runs `soil btrfs --apply` on an ext4 root, reboots once, and comes back with `@`/`@home` subvolumes and fstab fixed; `soil storage --apply` installs snapper ladders and the apt hook; a sysadmin readme lists the most important commands.

**Blocked by:** T30 (soil: host prep)

**Status:** ready-for-agent

- [ ] `soil btrfs --check` / `--apply` converts root from ext4 to btrfs offline (dracut pre-mount hook), keeps `/boot` on ext4, and creates `@` and `@home` subvolumes
- [ ] The convert needs exactly one reboot and resumes from persisted state; a second run after success reports no drift
- [ ] `soil storage --check` / `--apply` creates the base data subvolumes and the `weedr`-owned volumes root; pond data subvolumes and pond ladders are out of scope here and tracked in ticket 130
- [ ] Snapper ladders cover root and home; ladder config for any other subvolume is owned by the subvolume it protects (ticket 130), not by soil
- [ ] Root is snapshotted on apt install and upgrade
- [ ] Space-aware pruning uses the priority order: home and agents first, root
- [ ] Ladder and retention settings are owned by the subvolume they protect (soil owns only root and home) and change only through that owner's `--apply`, never by hand-editing snapper configs
- [ ] A sysadmin readme documents the most important commands
- [ ] Proven on the golden VM: install, convert, reboot, `--check` clean, evidence tarball captured
