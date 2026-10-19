#!/usr/bin/env bash
# install.sh — the one-shot guarden host installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/main/tools/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/christophkroeppl/guarden/develop/tools/install.sh | sudo bash
#   sudo bash tools/install.sh [--check] [--inline] [--branch NAME]
#
# Converges a fresh host into a guarden host by running the soil phases
# in order: install → packages → storage → sysctl → firewall → units.
#
# **One click, and the host converges by itself.** The btrfs root conversion
# (soil storage) is a staged offline operation that crosses two reboots, and a
# run of this script that stopped at the first of them left the operator to
# reboot the box and re-run the script by hand, twice. The installer now hands
# the work to a **temporary systemd service** that carries the run across those
# reboots: the service runs this script again after every boot, and this
# script — when it is the service talking — reboots the machine itself instead
# of stopping and waiting for an admin.
#
# The service is **removed when the installation has finished**, which is the
# moment a full `soil --check` is clean: a host that has converged has no
# installer to re-run, and a unit left behind would re-run it at every boot.
#
# **The branch is set once.** The cloud-init document carries it — the
# renderer knows the branch of the checkout it renders from — and the
# scripts-only path takes it from `--branch`, from `GUARDEN_REPO_BRANCH`, or
# from the repository's own default branch. Whatever it resolves to is
# recorded in the service's environment, so the run that happens after the
# first reboot uses the same branch as the run that staged the reboot: the
# operator never names it twice.
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
#   --inline  run the phases in this process instead of handing over to the
#             service, and stop with exit 75 when a phase asks for a reboot
#   --branch  clone and run from this branch (default: the repository's own)
#
# Exit codes:
#   0   converged (or already converged, or --check with no drift, or the
#       installation was handed over to the service)
#   1   an error occurred (or --check with drift)
#   2   rejected input
#   70  a reboot was queued by the service (the machine is leaving)
#   75  a reboot is required (btrfs conversion staged) and --inline was given,
#       so the run stopped and asked for one

set -euo pipefail

REPO_URL="${GUARDEN_REPO_URL:-https://github.com/christophkroeppl/guarden.git}"
REPO_BRANCH="${GUARDEN_REPO_BRANCH:-}"
REPO_DIR="${GUARDEN_REPO_DIR:-/usr/local/src/guarden}"
# The branch used when the repository does not answer. **The repository's own
# default branch is asked for first**, and this is only the fallback for a
# repository that cannot be reached — a name, not a guess.
DEFAULT_BRANCH="main"
# install runs before packages on a fresh host: soil packages installs the
# pinned podlet, whose record is seeded by soil install. On a host where
# install already ran (cloud-init, previous run), the order is irrelevant.
PHASE_ORDER=("install" "packages" "storage" "sysctl" "firewall" "units")

# The temporary service, and the state it keeps beside it.
#
# `/var/lib/guarden/install/` is under `/var`, and that is what makes it
# survive the btrfs conversion: the conversion rsyncs `/var` into the `@var`
# subvolume, so the persisted script and the run counter come back after the
# reboot the conversion asked for. A script under `/tmp` would not survive at
# all, and one under the checkout would be rsynced into `@` — which works, but
# the checkout is the thing the service re-clones, and a copy of the script
# beside the state it keeps is one file rather than two.
INSTALL_STATE_DIR="/var/lib/guarden/install"
PERSISTED_SCRIPT="${INSTALL_STATE_DIR}/install.sh"
RUNS_FILE="${INSTALL_STATE_DIR}/runs"
# The marker the unit's ExecStopPost reads to decide whether the machine is
# going down. It is under /run, which is tmpfs and is therefore per-boot: a
# marker left over from a previous boot cannot make a later run reboot.
REBOOT_MARKER="/run/guarden-install-reboot"
INSTALL_UNIT_NAME="guarden-install.service"
INSTALL_UNIT="/etc/systemd/system/${INSTALL_UNIT_NAME}"
# **The bound on the loop.** The conversion asks for two reboots, so three
# runs. The counter is what stops a run that keeps asking for a reboot: a
# conversion that is not progressing would otherwise put the host in a loop an
# admin has to break by hand. Past the bound the service stops and says what
# to look at.
MAX_RUNS=6

CHECK_MODE=0
INLINE_MODE=0
AUTO_REBOOT=0
HAS_DRIFT=0
# Set by the unit: this run IS the service, so it must not start a service.
FROM_SERVICE="${GUARDEN_INSTALL_SERVICE:-0}"

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

usage() {
    sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_MODE=1
            ;;
        --inline)
            INLINE_MODE=1
            ;;
        --reboot)
            AUTO_REBOOT=1
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
            usage
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
# and soil applies. Taken after the root check and argument parsing so
# that --help and the usage error work without root.
#
# **The service's run waits on this lock too**, and waits for as long as it
# takes: the unit is started with no timeout, because a run that blocked on
# this lock for longer than systemd's default would be killed mid-install.
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

# The branch, resolved once. An explicit `--branch` or `GUARDEN_REPO_BRANCH`
# wins; otherwise the repository's own default branch is asked for, which is
# the branch the operator's own URL names when they pulled the raw script
# from the repository's own head. The answer is what the service's
# environment carries, so the run after the first reboot uses the same branch
# without anybody naming it again.
resolve_branch() {
    if [[ -n "$REPO_BRANCH" ]]; then
        printf '%s' "$REPO_BRANCH"
        return
    fi
    local remote=""
    remote=$(git ls-remote --symref "$REPO_URL" HEAD 2>/dev/null \
        | awk '/^ref: refs\/heads\// {sub(/^refs\/heads\//, "", $2); print $2; exit}') || remote=""
    if [[ -z "$remote" ]]; then
        remote="$DEFAULT_BRANCH"
    fi
    printf '%s' "$remote"
}

REPO_BRANCH=$(resolve_branch)

if [[ -d "$REPO_DIR/.git" ]]; then
    log "updating repo at $REPO_DIR ($REPO_BRANCH)"
    git -C "$REPO_DIR" fetch --quiet origin 2>/dev/null || true
    git -C "$REPO_DIR" checkout --quiet "$REPO_BRANCH" 2>/dev/null || true
    git -C "$REPO_DIR" pull --quiet origin "$REPO_BRANCH" 2>/dev/null || true
else
    log "cloning guarden repo to $REPO_DIR ($REPO_BRANCH)"
    mkdir -p "$(dirname "$REPO_DIR")"
    if ! git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"; then
        die "the branch $REPO_BRANCH of $REPO_URL could not be cloned; name one with --branch"
    fi
fi

# **The branch has to carry the installer.** A branch that does not clones
# without a complaint and leaves the host with no `tools/install.sh` in it,
# which is a failure with no diagnostic from guarden — the reader is left
# looking at a clone that worked.
if [[ ! -f "$REPO_DIR/tools/install.sh" ]]; then
    die "the branch $REPO_BRANCH of $REPO_URL carries no tools/install.sh; name a branch that does, with --branch"
fi

soil_cmd() {
    (cd "$REPO_DIR" && PYTHONPATH=src python3 -m guarden.soil "$@")
}

# --------------------------------------------------------------------------
# the temporary service
# --------------------------------------------------------------------------

write_unit() {
    # Written to a sibling and renamed, so systemd never reads a half-written
    # unit: the write protocol of spec 3.5, for a file systemd reads.
    local temporary="${INSTALL_UNIT}.new"
    cat >"$temporary" <<UNIT
[Unit]
Description=guarden host installation (temporary; removed when the host converges)
Documentation=file:///usr/share/doc/guarden/
After=network-online.target
Wants=network-online.target
# **The unit is skipped, not failed, when the persisted script is not there.**
# A boot on which the state directory did not survive is a boot with nothing
# to run, and a unit that failed there would sit in \`systemctl --failed\`
# for the rest of the install's life.
ConditionPathExists=${PERSISTED_SCRIPT}

[Service]
Type=oneshot
# **No timeout.** The install crosses reboots and runs package transactions,
# and systemd's default start timeout would kill a run that is doing either.
TimeoutStartSec=0
# **70 is the reboot, and it is a success here.** The run that staged the
# conversion asks for the reboot it was going to ask for and stops; a unit
# that reported that as a failure would sit in \`systemctl --failed\` through
# the whole install and tell the operator the install is broken when it is
# doing exactly what it should.
SuccessExitStatus=70
# The branch, the repository and the checkout travel with the unit, so the
# run after a reboot is the run the operator asked for and not a fresh guess.
Environment=GUARDEN_INSTALL_SERVICE=1
Environment=GUARDEN_REPO_URL=${REPO_URL}
Environment=GUARDEN_REPO_BRANCH=${REPO_BRANCH}
Environment=GUARDEN_REPO_DIR=${REPO_DIR}
ExecStart=${PERSISTED_SCRIPT} --reboot
# **The reboot is queued here, and not by the run itself.** The run that
# staged the conversion writes the marker and exits cleanly; this is what
# reads it and queues the reboot, after the run is done. A run that queued
# its own reboot would be racing systemd's own shutdown of the very unit it
# is running in, and whether the run reached its exit code before the
# manager killed it would decide whether the install was recorded as a
# success or a failure.
ExecStopPost=/bin/sh -c 'if [ -f ${REBOOT_MARKER} ]; then systemctl --no-block reboot || true; fi'

[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$temporary"
    mv -f "$temporary" "$INSTALL_UNIT"
}

persist_script() {
    # The copy the service runs. **Written to a sibling and renamed**, because
    # the file being replaced may be the one this very process is running:
    # writing it in place would fail with ETXTBSY, and the rename leaves the
    # running process on the old inode and the service on the new one.
    local temporary="${PERSISTED_SCRIPT}.new"
    install -d -m 0750 -o root -g root "$INSTALL_STATE_DIR"
    install -m 0750 -o root -g root "$REPO_DIR/tools/install.sh" "$temporary"
    mv -f "$temporary" "$PERSISTED_SCRIPT"
}

install_service() {
    persist_script
    write_unit
    systemctl daemon-reload
    systemctl enable "$INSTALL_UNIT_NAME"
}

remove_service() {
    # The unit first, then the state: `disable` drops the wants symlink, the
    # file goes, and the daemon-reload is what tells systemd the unit is gone.
    systemctl disable "$INSTALL_UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$INSTALL_UNIT"
    systemctl daemon-reload
    rm -f "$PERSISTED_SCRIPT"
    rm -f "$RUNS_FILE"
    rmdir "$INSTALL_STATE_DIR" 2>/dev/null || true
}

read_runs() {
    local runs=0
    if [[ -r "$RUNS_FILE" ]]; then
        read -r runs <"$RUNS_FILE" || true
    fi
    [[ "$runs" =~ ^[0-9]+$ ]] || runs=0
    printf '%s' "$runs"
}

bump_runs() {
    local runs
    runs=$(read_runs)
    runs=$((runs + 1))
    install -d -m 0750 -o root -g root "$INSTALL_STATE_DIR"
    printf '%s\n' "$runs" >"$RUNS_FILE"
    chmod 0640 "$RUNS_FILE"
    printf '%s' "$runs"
}

request_reboot() {
    # **Two paths, and the caller decides which.** The service's run writes
    # the marker and lets the unit's ExecStopPost queue the reboot, so the
    # run finishes its work cleanly before the machine goes down. An inline
    # run has no unit to read the marker, so it queues the reboot itself.
    #
    # `--no-block` in both: the client is not waiting for the shutdown that
    # is about to stop the very process it is running in. The transaction is
    # queued in the manager, and killing this client afterwards does not
    # cancel it.
    if [[ "$FROM_SERVICE" == "1" ]]; then
        : >"$REBOOT_MARKER"
        log "rebooting now"
        return
    fi
    log "rebooting now"
    systemctl --no-block reboot || true
}

# --------------------------------------------------------------------------
# the phases
# --------------------------------------------------------------------------

run_phases() {
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
                    if [[ $AUTO_REBOOT -eq 1 ]]; then
                        banner
                        printf '[install]  the root filesystem conversion is staged; rebooting.\n'
                        banner
                        request_reboot
                        # **A distinct code, not zero.** The reboot is queued
                        # and this process is about to be killed by it, so the
                        # run must stop here: a zero would carry on to the
                        # final check and report a converged host that the
                        # machine is leaving.
                        return 70
                    fi
                    banner
                    printf '[install]  btrfs root conversion staged.\n'
                    printf '[install]  REBOOT now, then re-run:\n'
                    printf '[install]    curl -fsSL %s\n' \
                        "https://raw.githubusercontent.com/christophkroeppl/guarden/$REPO_BRANCH/tools/install.sh | sudo bash"
                    banner
                    return 75
                fi
                die "soil storage --apply failed (exit $result)"
            fi
        else
            soil_cmd "$phase" --apply
        fi

        log "$phase: done"
    done
    return 0
}

if [[ $CHECK_MODE -eq 1 ]]; then
    for phase in "${PHASE_ORDER[@]}"; do
        set +e
        soil_cmd "$phase" --check
        check_result=$?
        set -e
        if [[ $check_result -eq 0 ]]; then
            log "$phase: converged"
        else
            log "$phase: DRIFT"
            HAS_DRIFT=1
        fi
    done
    if [[ $HAS_DRIFT -eq 1 ]]; then
        exit 1
    fi
    log "all phases converged"
    exit 0
fi

# --------------------------------------------------------------------------
# the hand-over
# --------------------------------------------------------------------------

if [[ "$FROM_SERVICE" != "1" && $INLINE_MODE -ne 1 ]]; then
    # **This run sets the service up and starts it; the service does the
    # work.** The phases, the reboots and the cleanup all happen inside the
    # service, so there is exactly one place where a reboot is decided and
    # one place where a finished install is recognised. A run of this script
    # that did the phases here and only *set up* the service for the reboots
    # would have two, and the two would answer differently.
    install_service
    # **The lock is released before the wait.** The service's own run takes
    # the same lock, and a hand-over that held it while waiting for the
    # service would be a hand-over waiting for a service that cannot start.
    exec 9>&-
    # **The wait is the whole of the operator's experience.** The command
    # returns when the install has converged, and the box reboots under it
    # when the conversion says so, which is the one moment the operator has
    # to reconnect for and the only moment there is.
    set +e
    systemctl start "$INSTALL_UNIT_NAME"
    service_result=$?
    set -e
    if [[ $service_result -ne 0 ]]; then
        # A unit that cannot start is the one failure the operator would
        # otherwise only find in a journal they were not told to read.
        journalctl -u "$INSTALL_UNIT_NAME" -n 30 --no-pager >&2 || true
        die "the install service failed; the unit stays for the next boot and the journal above says why"
    fi
    exit 0
fi

if [[ "$FROM_SERVICE" == "1" ]]; then
    # This run is the service. The counter is bumped **before** the phases,
    # and that is the only ordering that works: the conversion's second stage
    # rsyncs `/var` into the `@var` subvolume, so anything written after that
    # rsync is lost with the old tree. The counter is written before it, and
    # comes back.
    RUNS=$(bump_runs)
    if (( RUNS > MAX_RUNS )); then
        die "the install has run $RUNS times without converging; the marker is /var/lib/guarden/soil/reboot-required and the state is /var/lib/guarden/soil/state"
    fi
    log "install service run $RUNS of $MAX_RUNS"
    # The persisted copy is refreshed on every run, so a branch that moved
    # between two boots is installed from its own current bytes.
    persist_script
fi

set +e
run_phases
phase_result=$?
set -e

# **70 is the reboot.** The reboot is queued in the manager and this process
# is about to be killed by it, so the run stops here — a converged host is
# not what this is, and the machine is leaving.
if [[ $phase_result -eq 70 ]]; then
    exit 70
fi

if [[ $phase_result -eq 75 ]]; then
    exit 75
fi

if [[ $phase_result -ne 0 ]]; then
    exit 1
fi

# **The installation is finished when a full check is clean.** The phases
# above asked each one whether it had converged and applied the ones that had
# not; this asks all of them again, and a clean answer is the only thing that
# says the host is where the installer wanted it. The service is removed
# then, and a host that has converged has no installer left to re-run.
set +e
soil_cmd --check
final=$?
set -e

if [[ $final -ne 0 ]]; then
    banner
    printf '[install]  the install did not converge; the service stays for the next boot.\n'
    banner
    exit 1
fi

if [[ "$FROM_SERVICE" == "1" ]]; then
    remove_service
fi

banner
printf '[install]  guarden host converged\n'
banner
printf '[install] next steps:\n'
printf '[install]   1. Fill in /etc/guarden/guarden.toml\n'
printf '[install]   2. Add projects: weedr project add --repository <url> <name>\n'
printf '[install]   3. Grant poke keys: weedr project grant <name> <pubkey>\n'
