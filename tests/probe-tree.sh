#!/usr/bin/env bash
set -uo pipefail
U=svchome
H=/home/$U
export XDG_RUNTIME_DIR=/run/user/$(id -u $U)
echo "=== everything podman writes under the home ==="
find "$H/.config" "$H/.local" -maxdepth 4 2>/dev/null | sort
echo
echo "=== what is 'build staging' in the home? ==="
grep -rn "staging" /home/rumlyne/.hermes/cache/scratch/ 2>/dev/null | head -0
echo "=== podman build's own scratch: does it write into the home? ==="
ls -la "$H/.local/share/containers/" 2>/dev/null
echo "=== does a rootless podman write a 'build' cache dir? ==="
find "$H" -maxdepth 2 -name '*build*' 2>/dev/null
