#!/usr/bin/env bash
# Build a Debian package (.deb) of guarden.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PYVER="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("pyproject.toml").read_text()
m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "1.0.0")
PY
)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
VERSION="${GUARDEN_VERSION:-${PYVER}+g${SHA}}"
DEBVER="${VERSION}-1"

DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

PKGROOT="$STAGE/guarden_${DEBVER}_all"
mkdir -p "$PKGROOT/DEBIAN"

# Stage installed file tree.
python3 "$ROOT/packaging/stage_deb.py" "$ROOT" "$PKGROOT" "$VERSION"

# Maintainer scripts.
cat > "$PKGROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v soil >/dev/null 2>&1; then
    soil install >/dev/null 2>&1 || true
fi
exit 0
EOF
cat > "$PKGROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst" "$PKGROOT/DEBIAN/prerm"

# Control file.
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: guarden
Version: ${DEBVER}
Section: admin
Priority: optional
Architecture: all
Depends: python3 (>= 3.11), python3-yaml, python3-jinja2, git
Maintainer: Christoph Kroeppl <ch.kroeppl@gmx.at>
Description: One VPS, a handful of projects, one edge.
 Guarden is a host provisioning and project deployment tool.
EOF

OUT="$DIST/guarden_${DEBVER}_all.deb"
dpkg-deb --build --root-owner-group "$PKGROOT" "$OUT"

# Also place a copy at the repo root for convenience.
cp "$OUT" "$ROOT/guarden_${DEBVER}_all.deb"

echo "$OUT"