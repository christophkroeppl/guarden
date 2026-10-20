#!/usr/bin/env bash
set -uo pipefail
echo "=== THE BUG: guarden writes .containerignore, so the source's .dockerignore is dropped ==="
W=/tmp/probe7
rm -rf "$W"; mkdir -p "$W"; cd "$W"
printf '[package]\nname = "ctxapp"\n' > Cargo.toml
cat > Containerfile <<'EOF'
FROM scratch
COPY Cargo.toml /copied
EOF
# the source's own narrowing
printf 'Cargo.toml\n' > .dockerignore
# guarden's block, written to BOTH names
printf '# guarden: ...\n.local/share/containers\n.config/containers\n' > .containerignore

echo "--- build with .dockerignore (source excludes Cargo.toml) AND .containerignore (guarden's):"
podman build --tag probe7:a -f Containerfile . 2>&1 | tail -4
echo "rc=$?"

echo
echo "--- build with ONLY .dockerignore (source excludes Cargo.toml):"
rm -f .containerignore
podman build --tag probe7:b -f Containerfile . 2>&1 | tail -4
echo "rc=$?"

echo
echo "=== so the fix: guarden must merge the source's patterns into .containerignore TOO ==="
W2=/tmp/probe8
rm -rf "$W2"; mkdir -p "$W2"; cd "$W2"
printf '[package]\nname = "ctxapp"\n' > Cargo.toml
cat > Containerfile <<'EOF'
FROM scratch
COPY Cargo.toml /copied
EOF
printf 'Cargo.toml\n# guarden: ...\n.local/share/containers\n.config/containers\n' > .containerignore
echo "--- build with the source's patterns MERGED into .containerignore:"
podman build --tag probe8:a -f Containerfile . 2>&1 | tail -4
echo "rc=$? (125 = the source's exclusion holds, which is CORRECT)"
