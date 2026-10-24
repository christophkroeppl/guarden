#!/usr/bin/env bash
# Build a source tarball (*.tar.gz) of guarden.
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

DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

PKG="guarden-${VERSION}"
mkdir -p "$STAGE/$PKG"

# Selected source tree (no .git, .venv, tests cache).
cp -a src "$STAGE/$PKG/"
cp -a tools "$STAGE/$PKG/"
mkdir -p "$STAGE/$PKG/packages" "$STAGE/$PKG/docs"
cp packages/packages.toml "$STAGE/$PKG/packages/"
if [ -f docs/spec.md ]; then cp docs/spec.md "$STAGE/$PKG/docs/"; fi
cp pyproject.toml justfile "$STAGE/$PKG/" 2>/dev/null || true
printf '%s\n' "$VERSION" > "$STAGE/$PKG/VERSION"

OUT="$DIST/guarden-${VERSION}.tar.gz"
tar -czf "$OUT" -C "$STAGE" "$PKG"

# Also place a copy at the repo root for convenience.
cp "$OUT" "$ROOT/guarden-${VERSION}.tar.gz"

echo "$OUT"
echo "guarden-${VERSION}.tar.gz"