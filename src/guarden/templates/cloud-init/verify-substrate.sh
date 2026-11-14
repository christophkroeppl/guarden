#!/usr/bin/env bash
# Verify the substrate the golden-VM checks depend on, loudly and early.
#
# Tracked here and inlined into the cloud-init document by the renderer, so the
# script a machine runs and the script in the repository are the same bytes.
#
# If pasta is missing every networking claim is unprovable, and the run must say
# so at the point of failure rather than eleven separate "not run" verdicts
# later. Same for btrfs-progs, without which `soil storage` cannot converge.
set -eu

{
  echo "podman: $(podman --version 2>/dev/null || echo MISSING)"
  echo "pasta:  $(command -v pasta || echo MISSING)"
  echo "btrfs:  $(btrfs --version 2>/dev/null || echo MISSING)"
  echo "kernel: $(uname -r)"
  echo "os:     $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "cgroup: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
} > /var/lib/guarden-evidence/substrate.txt
cat /var/lib/guarden-evidence/substrate.txt

if ! command -v pasta >/dev/null 2>&1; then
  echo "FATAL: pasta is absent; the rootless-network claims cannot be proven" >&2
  exit 1
fi
if ! command -v btrfs >/dev/null 2>&1; then
  echo "FATAL: btrfs-progs is absent; soil storage cannot converge" >&2
  exit 1
fi
