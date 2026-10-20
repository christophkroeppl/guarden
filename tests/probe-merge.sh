#!/usr/bin/env bash
set -uo pipefail
# What does guarden's own merge produce, and does it exclude the source file?
U=ctxprobe
H=/var/lib/guarden/services/$U/home
cat > /tmp/probe6.py <<'PYEOF'
import sys
sys.path.insert(0, "/src")
PYEOF
echo "=== simulate guarden's merge on a source .dockerignore that excludes Cargo.toml ==="
python3 - <<'PYEOF'
from pathlib import Path
import sys
sys.path.insert(0, "/home/ubuntu/guarden/src")
from guarden import service
home = Path("/tmp/mergeprobe")
home.mkdir(exist_ok=True)
(home / ".dockerignore").write_text("Cargo.toml\n")
service.write_build_exclusions(home, (0, 0))
print("--- .dockerignore after the merge:")
print((home / ".dockerignore").read_text())
print("--- .containerignore after the merge:")
print((home / ".containerignore").read_text())
print("--- BUILD_EXCLUSIONS:", service.BUILD_EXCLUSIONS)
print("--- BUILD_IGNORE_NAMES:", service.BUILD_IGNORE_NAMES)
PYEOF
