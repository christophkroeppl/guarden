#!/usr/bin/env bash
# The provisioning step cloud-init runs before install.sh: clone the repo.
#
# Tracked in the repository and inlined into the cloud-init document by
# tools/render-user-data, so the script a machine runs and the script in the
# repository are the same bytes. It is deliberately small — everything that
# converges the host is install.sh's, and this only puts install.sh on disk.
set -euo pipefail

REPO_URL="__REPO_URL__"
REPO_BRANCH="__REPO_BRANCH__"
REPO_DIR="__REPO_DIR__"

log() { printf '[guarden-provision] %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
    log "error: must be run as root"
    exit 1
fi

if [[ -d "$REPO_DIR/.git" ]]; then
    log "updating repo at $REPO_DIR"
    git -C "$REPO_DIR" fetch --quiet origin 2>/dev/null || true
    git -C "$REPO_DIR" checkout --quiet "$REPO_BRANCH" 2>/dev/null || true
    git -C "$REPO_DIR" pull --quiet origin "$REPO_BRANCH" 2>/dev/null || true
else
    log "cloning $REPO_URL ($REPO_BRANCH) to $REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi

log "repo ready; install.sh will converge the host"
