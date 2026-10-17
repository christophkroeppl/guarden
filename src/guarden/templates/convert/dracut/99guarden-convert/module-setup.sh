#!/bin/bash
# dracut module 99guarden-convert: installs the offline ext4 -> btrfs pre-mount hook.

check() {
  return 0
}

depends() {
  echo rootfs-block
}

install() {
  inst_multiple btrfs-convert btrfs findfs blkid e2fsck
  # hostonly builds skip btrfs on an ext4 host; clear it so the module installs
  hostonly="" instmods btrfs
  mkdir -p "$initdir/etc"
  if [ -f /var/lib/guarden/soil/state ] &&
    [ "$(cat /var/lib/guarden/soil/state 2>/dev/null)" = converting ]; then
    : >"$initdir/etc/guarden-convert.enable"
  fi
  inst_hook pre-mount 99 "$moddir/guarden-convert-hook.sh"
}