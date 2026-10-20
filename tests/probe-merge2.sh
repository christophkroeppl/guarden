#!/usr/bin/env bash
set -uo pipefail
echo "=== the fixed merge: both names carry BOTH halves ==="
rm -rf /tmp/mergeprobe2
python3 - <<'PYEOF'
from pathlib import Path
import sys
sys.path.insert(0, "/home/ubuntu/guarden/src")
from guarden import service
home = Path("/tmp/mergeprobe2")
home.mkdir(exist_ok=True)
(home / ".dockerignore").write_text("Cargo.toml\n")
service.write_build_exclusions(home, (0, 0))
print("--- .dockerignore:")
print((home / ".dockerignore").read_text())
print("--- .containerignore:")
print((home / ".containerignore").read_text())
print("=== idempotent? merge again ===")
service.write_build_exclusions(home, (0, 0))
print("--- .dockerignore after a second merge:")
print((home / ".dockerignore").read_text())
PYEOF
