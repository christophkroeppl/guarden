#!/usr/bin/env bash
set -uo pipefail
# The suite's flow with guarden's merge in place.
U=ctxprobe
H=/var/lib/guarden/services/$U/home
UID_=$(id -u $U)
asuser() { env -C "$H" setpriv --reuid="$U" --regid="$U" --clear-groups \
    env -u OLDPWD HOME="$H" PWD="$H" USER="$U" LOGNAME="$U" \
    XDG_RUNTIME_DIR="/run/user/$UID_" "$@"; }

echo "=== write the merged .dockerignore into the home ==="
printf 'Cargo.toml\n# guarden: the podman store and the rendered units are never in the build context\n.local/share/containers\n.config/containers\n' > "$H/.dockerignore"
printf '# guarden: the podman store and the rendered units are never in the build context\n.local/share/containers\n.config/containers\n' > "$H/.containerignore"
chown $U:$U "$H/.dockerignore" "$H/.containerignore"

echo "=== the build ==="
asuser podman build --tag "localhost/$U:latest" -f "$H/Containerfile" . 2>&1 | tail -6
echo
echo "=== the export ==="
asuser podman create --name "t317d-$U" "localhost/$U:latest" 2>&1 | tail -1
asuser podman export --output "/tmp/t317d-$U.tar" "t317d-$U" 2>&1 | tail -1
echo "--- tar -tf:"
tar -tf "/tmp/t317d-$U.tar" 2>/dev/null
echo
echo "=== so: with .containerignore present, does the .dockerignore's 'Cargo.toml' still apply? ==="
echo "(the .containerignore does NOT exclude Cargo.toml, so Cargo.toml IS copied)"
