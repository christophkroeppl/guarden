#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_exit 1 soil btrfs --check
assert_output_has "drift" soil btrfs --check
assert_no_file "$GUARDEN_STATE/soil/btrfs.done"

assert_exit 0 soil btrfs --apply
assert_output_has "reboot required" soil btrfs --apply
assert_file "$GUARDEN_STATE/soil/reboot-needed"
assert_file "$GUARDEN_STATE/soil/btrfs.state"
assert_no_file "$GUARDEN_STATE/soil/btrfs.done"
assert_exit 1 soil btrfs --check
assert_output_has "drift" soil btrfs --check

mkdir -p "$GUARDEN_SYSROOT/etc"
cat > "$GUARDEN_SYSROOT/etc/fstab" <<'EOF'
UUID=rootfs / ext4 defaults 0 1
UUID=boot /boot ext4 defaults 0 2
EOF

rm -f "$GUARDEN_STATE/soil/reboot-needed"

assert_exit 0 soil btrfs --apply
assert_file "$GUARDEN_STATE/soil/btrfs.done"
assert_no_file "$GUARDEN_STATE/soil/reboot-needed"
assert_call_log_has "dracut"
assert_call_log_has "btrfs subvolume create"
assert_output_has "converted" cat "$GUARDEN_STATE/soil/btrfs.state"
assert_output_has "UUID=boot /boot ext4" cat "$GUARDEN_SYSROOT/etc/fstab"
assert_output_has "btrfs subvol=@" cat "$GUARDEN_SYSROOT/etc/fstab"
assert_output_has "btrfs subvol=@home" cat "$GUARDEN_SYSROOT/etc/fstab"

assert_exit 0 soil btrfs --check
assert_output_has "ok" soil btrfs --check

assert_exit 0 soil btrfs --apply
assert_output_has "no drift" soil btrfs --apply

finish
