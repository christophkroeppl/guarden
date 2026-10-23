#!/usr/bin/env bash
# install.sh — one-shot guarden host installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
#   sudo bash tools/install.sh [--check]
#
# Converges a fresh host into a guarden host by running the soil phases
# in order: packages → storage → sysctl → firewall → install → units.
#
# The btrfs root conversion (soil storage) requires up to two reboots.
# When a reboot is needed the script exits with code 75 and tells the
# operator to reboot and re-run — the conversion is a state machine
# that picks up where it left off.
#
# There is no cloud-init detection, and none is needed: every phase is
# check-then-apply, so a phase that is already converged is skipped no matter
# what converged it -- cloud-init, a previous run of this script, or a human.
# On a host cloud-init provisioned, `soil packages --check` finds the substrate
# already installed and the phase reports "already converged" without applying;
# on a fresh host it reports drift and applies. The check is the detection, and
# it is more precise than asking whether cloud-init ran: it asks whether the
# host is in the target state, which is the only question that matters.
#
# Options:
#   --check   report drift for every phase without making changes
#   --branch  clone and run from this branch (default: develop)
#
# Exit codes:
#   0   converged (or already converged, or --check with no drift)
#   1   an error occurred (or --check with drift)
#   2   rejected input
#   75  a reboot is required (btrfs conversion staged)

set -euo pipefail

REPO_URL="${GUARDEN_REPO_URL:-https://github.com/christophkroeppl/guarden.git}"
REPO_BRANCH="${GUARDEN_REPO_BRANCH:-develop}"
REPO_DIR="${GUARDEN_REPO_DIR:-/usr/local/src/guarden}"
PHASE_ORDER=("install" "packages" "storage" "sysctl" "firewall" "units")

CHECK_MODE=0
HAS_DRIFT=0

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[install] %s\n' "$*"
}

banner() {
    printf '[install] ════════════════════════════════════════\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_MODE=1
            ;;
        --branch)
            shift
            REPO_BRANCH="${1:-}"
            [[ -n "$REPO_BRANCH" ]] || die "--branch needs a value"
            ;;
        --branch=*)
            REPO_BRANCH="${1#--branch=}"
            ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    die "this script must be run as root (sudo)"
fi

# Concurrent-run guard: two simultaneous invocations (cloud-init retrying
# while an operator runs it manually) must not interleave repo clone/update
# and soil applies.
exec 9>/run/guarden-install.lock
flock 9

if ! python3 -c "import yaml, jinja2" 2>/dev/null; then
    log "bootstrapping Python dependencies (yaml, jinja2)"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-yaml python3-jinja2
    elif command -v dnf &>/dev/null; then
        dnf install -y -q python3-pyyaml python3-jinja2
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm --quiet python-yaml python-jinja2
    else
        die "no supported package manager found to install Python dependencies"
    fi
fi

if [[ -d "$REPO_DIR/.git" ]]; then
    log "updating repo at $REPO_DIR"
    git -C "$REPO_DIR" fetch --quiet origin 2>/dev/null || true
    git -C "$REPO_DIR" checkout --quiet "$REPO_BRANCH" 2>/dev/null || true
    git -C "$REPO_DIR" pull --quiet origin "$REPO_BRANCH" 2>/dev/null || true
else
    log "cloning guarden repo to $REPO_DIR"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi

soil_cmd() {
    (cd "$REPO_DIR" && PYTHONPATH=src python3 -m guarden.soil "$@")
}

for phase in "${PHASE_ORDER[@]}"; do
    # soil --check exits 0 (converged), 1 (drift), or 2 (rejected input).
    # Only 0 and 1 are expected here; 2 means the program itself failed.
    set +e
    soil_cmd "$phase" --check
    check_result=$?
    set -e

    if [[ $check_result -eq 2 ]]; then
        die "soil $phase --check failed (exit 2: rejected input)"
    fi

    if [[ "$CHECK_MODE" -eq 1 ]]; then
        if [[ $check_result -eq 0 ]]; then
            log "$phase: converged"
        else
            log "$phase: DRIFT"
            HAS_DRIFT=1
        fi
        continue
    fi

    if [[ $check_result -eq 0 ]]; then
        log "$phase: already converged"
        continue
    fi

    log "=== applying $phase ==="

    if [[ "$phase" == "storage" ]]; then
        set +e
        soil_cmd storage --apply
        result=$?
        set -e

        # soil storage exits 1 (not 75) when staging a reboot — h.error()
        # uses EXIT_NOT_CONVERGED. The reboot marker file is the signal.
        if [[ $result -ne 0 ]]; then
            if [[ -f /var/lib/guarden/soil/reboot-required ]]; then
                banner
                printf '[install]  btrfs root conversion staged.\n'
                printf '[install]  REBOOT now, then re-run:\n'
                printf '[install]    curl -fsSL %s\n' \
                    "https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash"
                banner
                exit 75
            fi
            die "soil storage --apply failed (exit $result)"
        fi
    else
        soil_cmd "$phase" --apply
    fi

    log "$phase: done"
done

if [[ "$CHECK_MODE" -eq 1 ]]; then
    if [[ "$HAS_DRIFT" -eq 1 ]]; then
        exit 1
    fi
    log "all phases converged"
    exit 0
fi

banner
printf '[install]  guarden host converged\n'
banner
printf '[install] next steps:\n'
printf '[install]   1. Fill in /etc/guarden/guarden.toml\n'
printf '[install]   2. Add projects: weedr project add --repository <url> <name>\n'
printf '[install]   3. Grant poke keys: weedr project grant <name> <pubkey>\n'
