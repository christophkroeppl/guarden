# 40: soil: btrfs convert + snapper ladders

**What to build:** The host gets btrfs with snapshot ladders, including one reboot. An operator runs `soil btrfs --apply` on an ext4 root, reboots once, and comes back with `@`/`@home` subvolumes and fstab fixed; `soil storage --apply` installs snapper ladders and the apt hook; a sysadmin readme lists the most important commands.

**Blocked by:** T30 (soil: host prep)

**Status:** ready-for-agent

- [ ] `soil btrfs --check` / `--apply` converts root from ext4 to btrfs offline (dracut pre-mount hook), keeps `/boot` on ext4, and creates `@` and `@home` subvolumes
- [ ] The convert needs exactly one reboot and resumes from persisted state; a second run after success reports no drift
- [ ] `soil storage --check` / `--apply` creates the remaining data subvolumes (including `pond-prod` and `pond-nonprod` data) and the `weedr`-owned volumes root
- [ ] Snapper ladders cover root, home, and `pond-prod`; `pond-nonprod` is explicitly not snapshotted
- [ ] Root is snapshotted on apt install and upgrade
- [ ] Space-aware pruning uses the priority order: home and agents first, root, `pond-prod` last
- [ ] Ladder and retention settings change only through `soil storage --apply`, never by hand-editing snapper configs
- [ ] A sysadmin readme documents the most important commands
- [ ] Proven on the golden VM: install, convert, reboot, `--check` clean, evidence tarball captured
