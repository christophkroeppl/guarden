#!/usr/bin/env bash
set -uo pipefail
# Reproduce the suite's flow exactly, as the service user, in a fresh home.
U=ctxprobe
useradd --system --no-create-home --home-dir /home/$U --shell /usr/sbin/nologin $U 2>/dev/null || true
grep -q "^$U:" /etc/subuid || usermod --add-subuids 200000-65536 $U
H=/var/lib/guarden/services/$U/home
mkdir -p "$H/.guarden/quadlet"
printf 'project: ctxprobe\nunits: .guarden/quadlet/\n' > "$H/.guarden/service.yml"
printf '[Unit]\nDescription=x\n\n[Container]\nImage=localhost/%s:latest\n' "$U" > "$H/.guarden/quadlet/app.container"
printf 'FROM scratch\nCOPY Cargo.toml /copied\n' > "$H/Containerfile"
printf '[package]\nname = "ctxapp"\n' > "$H/Cargo.toml"
chown -R $U:$U /var/lib/guarden/services/$U
mkdir -p /run/user/$(id -u $U); chown $U:$U /run/user/$(id -u $U)
asuser() { runuser -u $U -- env -C "$H" HOME=$H USER=$U LOGNAME=$U XDG_RUNTIME_DIR=/run/user/$(id -u $U) "$@"; }

echo "=== the build, exactly as weedr does it ==="
asuser podman build --tag "localhost/$U:latest" -f "$H/Containerfile" . 2>&1 | tail -6
echo "rc=$?"
echo
echo "=== the export ==="
asuser podman create --name "t317-$U" "localhost/$U:latest" 2>&1 | tail -1
asuser podman export --output "/tmp/t317-$U.tar" "t317-$U" 2>&1 | tail -2
echo "rc=$?"
echo "--- tar -tf:"
tar -tf "/tmp/t317-$U.tar" 2>/dev/null
echo
echo "=== is the tarball there? ==="
ls -la "/tmp/t317-$U.tar" 2>&1
