#!/usr/bin/env bash
set -uo pipefail
echo "=== what does 'podman export' list for a file COPYed to /copied? ==="
W=/tmp/probe5
rm -rf "$W"; mkdir -p "$W"; cd "$W"
printf '[package]\nname = "ctxapp"\n' > Cargo.toml
cat > Containerfile <<'EOF'
FROM scratch
COPY Cargo.toml /copied
EOF
podman build --tag probe5:x -f Containerfile . 2>&1 | tail -2
podman create --name probe5c probe5:x >/dev/null 2>&1
podman export --output /tmp/probe5.tar probe5c 2>&1 | tail -1
echo "--- tar -tf:"
tar -tf /tmp/probe5.tar 2>/dev/null
echo
echo "=== and for 'COPY . /all'? ==="
printf 'x\n' > other.txt
cat > Containerfile2 <<'EOF'
FROM scratch
COPY . /all
EOF
podman build --tag probe5:y -f Containerfile2 . 2>&1 | tail -2
podman create --name probe5d probe5:y >/dev/null 2>&1
podman export --output /tmp/probe5b.tar probe5d 2>&1 | tail -1
echo "--- tar -tf:"
tar -tf /tmp/probe5b.tar 2>/dev/null
echo
echo "=== does podman export need the container to be running? ==="
podman ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | head -5
