#!/usr/bin/env bash
set -uo pipefail
# The suite's EXACT helper shape, no runuser: env -C $home setpriv ...
U=ctxprobe
H=/var/lib/guarden/services/$U/home
UID_=$(id -u $U)

echo "=== setpriv directly (t350's shape) ==="
env -C "$H" setpriv --reuid="$U" --regid="$U" --clear-groups \
    env -u OLDPWD HOME="$H" PWD="$H" USER="$U" LOGNAME="$U" \
    XDG_RUNTIME_DIR="/run/user/$UID_" podman create --name "t317c-$U" "localhost/$U:latest"
echo "rc=$?"
env -C "$H" setpriv --reuid="$U" --regid="$U" --clear-groups \
    env -u OLDPWD HOME="$H" PWD="$H" USER="$U" LOGNAME="$U" \
    XDG_RUNTIME_DIR="/run/user/$UID_" podman export --output "/tmp/t317c-$U.tar" "t317c-$U"
echo "rc=$?"
echo "--- tar -tf:"
tar -tf "/tmp/t317c-$U.tar" 2>/dev/null
echo
echo "=== and the tar -tf as ROOT (the suite's 'run_in /tmp tar -tf') ==="
tar -tf "/tmp/t317c-$U.tar" 2>/dev/null
echo "rc=$?"
echo
echo "=== the tarball's ownership and mode ==="
ls -la "/tmp/t317c-$U.tar"
