#!/usr/bin/env bash
set -uo pipefail
# The suite's exact helper shape: run_in "$home" setpriv ... podman ...
U=ctxprobe
H=/var/lib/guarden/services/$U/home
UID_=$(id -u $U)

echo "=== the suite's shape: env -C \$home, setpriv, export to /tmp ==="
runuser -u $U -- env -C "$H" setpriv --reuid="$U" --regid="$U" --clear-groups \
    env -u OLDPWD HOME="$H" PWD="$H" USER="$U" LOGNAME="$U" \
    XDG_RUNTIME_DIR="/run/user/$UID_" podman create --name "t317b-$U" "localhost/$U:latest"
echo "rc=$?"
runuser -u $U -- env -C "$H" setpriv --reuid="$U" --regid="$U" --clear-groups \
    env -u OLDPWD HOME="$H" PWD="$H" USER="$U" LOGNAME="$U" \
    XDG_RUNTIME_DIR="/run/user/$UID_" podman export --output "/tmp/t317b-$U.tar" "t317b-$U"
echo "rc=$?"
echo "--- tar -tf:"
tar -tf "/tmp/t317b-$U.tar" 2>/dev/null
echo
echo "=== is the tarball there? ==="
ls -la "/tmp/t317b-$U.tar" 2>&1
echo
echo "=== does the suite's 'run_in /tmp tar -tf' see it? (the tarball is 0700-owned by the service) ==="
ls -la /tmp/t317b-$U.tar
