#!/bin/sh
# guarden-convert: one-shot offline ext4 -> btrfs conversion (dracut pre-mount hook).
# Sourced by dracut — never call `exit`, and keep all names ic_* to avoid
# clobbering dracut's shell state. Minimal initrd: only sed/cat/mkdir/mount/
# umount/findfs/blkid are guaranteed (no tr/awk/head).

ic_emit() { # <priority> <msg>
  echo "<$1>guarden-convert: $2" >/dev/kmsg 2>/dev/null || true
  echo "guarden-convert: $2" >/dev/console 2>/dev/null || echo "guarden-convert: $2"
}
ic_log() { ic_emit 6 "$*"; }
ic_err() { ic_emit 3 "ERROR: $*" >&2; }

ic_convert() {
  ic_type="$(blkid -p -s TYPE -o value "$ic_dev" 2>/dev/null || true)"
  ic_label="$(blkid -s LABEL -o value "$ic_dev" 2>/dev/null || true)"
  # ic_dev is the real device node: a /dev/disk/by-* SYMLINK is dropped by udev
  # the moment btrfs-convert changes the fs type, and the label restore, the
  # remount and the symlink rebuild would then all hit a dangling path.
  ic_realdev="$ic_dev"
  ic_log "root='${ic_root:-unset}' dev=$ic_dev realdev=${ic_realdev:-unresolved} type=${ic_type:-unknown}"

  case "$ic_type" in
  btrfs)
    ic_log "$ic_dev is already btrfs; skipping"
    return
    ;;
  ext4) ;;
  *)
    ic_log "$ic_dev has fs type '${ic_type:-unknown}'; nothing to do"
    return
    ;;
  esac

  ic_log "converting $ic_dev (ext4) to btrfs offline (uuid+label preserved)..."
  if ! btrfs-convert --uuid copy --copy-label --no-progress "$ic_dev"; then
    # fs is normally still ext4 here: let the boot continue so the state machine
    # can retry on the next --apply
    ic_err "$ic_dev: CONVERSION FAILED — roll back with: btrfs-convert -r $ic_dev"
    return
  fi
  ic_log "$ic_dev: conversion OK"

  # --copy-label is unreliable; restore the captured label explicitly
  if [ -n "$ic_label" ]; then
    if btrfs filesystem label "$ic_dev" "$ic_label" 2>/dev/null; then
      ic_log "label restored: $ic_label"
    else
      ic_err "could not restore label '$ic_label'"
    fi
  fi

  # udev drops the by-* symlink on fs-type change, but dracut's initqueue waits
  # for the exact path root= resolved to — recreate it if needed.
  case "$ic_root" in
  LABEL=*)   ic_dir=/dev/disk/by-label;     ic_name="${ic_root#LABEL=}" ;;
  UUID=*)    ic_dir=/dev/disk/by-uuid;      ic_name="${ic_root#UUID=}" ;;
  PARTLABEL=*) ic_dir=/dev/disk/by-partlabel; ic_name="${ic_root#PARTLABEL=}" ;;
  PARTUUID=*)  ic_dir=/dev/disk/by-partuuid;  ic_name="${ic_root#PARTUUID=}" ;;
  /dev/disk/by-*) ic_dir="${ic_root%/*}";  ic_name="${ic_root##*/}" ;;
  *) ic_dir="" ;;
  esac
  if [ -n "$ic_dir" ] && [ -n "${ic_name:-}" ] && [ -b "${ic_realdev:-}" ]; then
    mkdir -p "$ic_dir"
    ln -sf "../../${ic_realdev##*/}" "$ic_dir/$ic_name" &&
      ic_log "root symlink ensured: $ic_dir/$ic_name -> $ic_realdev"
  else
    ic_err "cannot re-create the root symlink (${ic_dir:-?}/${ic_name:-?}); root may not mount"
  fi

  # The next boot runs a flat btrfs (no subvolumes yet) while the image's fstab
  # still names ext4 for /; rewrite that line for the flat boot. Userspace
  # rewrites it again for subvol=@ and subvol=@var.
  mkdir -p /guarden-root
  if mount -t btrfs "$ic_dev" /guarden-root; then
    ic_log "patching / in fstab for the flat btrfs boot"
    sed -i -E 's|^([^#][^[:space:]]*[[:space:]]+/[[:space:]]*)ext[234]([[:space:]].*)?$|\1btrfs noatime,compress=zstd 0 0 # guarden-storage|' \
      /guarden-root/etc/fstab
    ic_fstype="$(sed -n -E 's|^[^#][^[:space:]]*[[:space:]]+/[[:space:]]+([^[:space:]]+).*|\1|p' /guarden-root/etc/fstab | sed -n 1p)"
    if [ "$ic_fstype" = btrfs ]; then
      ic_log "fstab patched: / -> btrfs"
    else
      ic_err "fstab / fstype is '${ic_fstype:-?}', expected btrfs"
    fi
    mkdir -p /guarden-root/var/log
    {
      echo "guarden-convert: conversion result on $ic_dev"
      echo "root line: $(sed -n -E '/^[^#][^[:space:]]*[[:space:]]+\/[[:space:]]+/p' /guarden-root/etc/fstab | sed -n 1p)"
    } >>/guarden-root/var/log/guarden-convert.log 2>/dev/null
    sync
    umount /guarden-root || ic_err "could not unmount /guarden-root"
  else
    ic_err "could not mount the converted fs to patch fstab (root will stay read-only)"
  fi
  ic_log "done; continuing boot"
}

ic_log "pre-mount hook fired (marker $([ -e /etc/guarden-convert.enable ] && echo present || echo absent))"

if [ -e /etc/guarden-convert.enable ]; then
  ic_root="${root:-$(getarg root= 2>/dev/null || true)}"
  ic_root="${ic_root#block:}"
  case "$ic_root" in
  LABEL=* | UUID=* | PARTUUID=* | PARTLABEL=*) ic_dev="$(findfs "$ic_root" 2>/dev/null || true)" ;;
  /dev/*) ic_dev="$(readlink -f "$ic_root" 2>/dev/null || true)" ;;
  *) ic_dev="" ;;
  esac

  if [ -z "$ic_dev" ]; then
    ic_err "cannot resolve root= ('${ic_root:-unset}'); refusing to guess"
  elif [ ! -b "$ic_dev" ]; then
    ic_err "root device '${ic_dev}' is not a block device; skipping"
  else
    ic_convert
  fi
fi