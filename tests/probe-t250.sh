#!/usr/bin/env bash
# Run t250-verb-split on this machine and show what it says.
set -uo pipefail
export PATH="/home/ubuntu/guarden/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GUARDEN_PREFIX=/
export PYTHONPATH=/home/ubuntu/guarden/src
export GUARDEN_ROOT=/home/ubuntu/guarden
cd /home/ubuntu/guarden
bash tests/t250-verb-split.sh
echo "EXIT: $?"
