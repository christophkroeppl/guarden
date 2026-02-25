#!/bin/bash
# Restart all stacks: root project (socket-proxy + proxy) and each standalone stack.
# Run from anywhere; uses repo root for paths. Loads root .env and per-stack .env when present.

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_ENV="${SCRIPT_DIR}/.env"

# Subdirs that are included in root compose.yaml — we don’t restart them separately
INCLUDED_IN_ROOT="traefik socket-proxy"

run_restart() {
    local compose_file="$1"
    local env_args=()
    [ -f "${ROOT_ENV}" ] && env_args+=("--env-file" "${ROOT_ENV}")
    local dir
    dir="$(dirname "${compose_file}")"
    if [ -f "${dir}/.env" ]; then
        env_args+=("--env-file" "${dir}/.env")
    fi
    docker compose -f "${compose_file}" "${env_args[@]}" restart
}

# 1. Restart root project (socket-proxy + proxy from includes)
if [ -f "${SCRIPT_DIR}/compose.yaml" ]; then
    echo "Restarting root project..."
    run_restart "${SCRIPT_DIR}/compose.yaml"
fi

# 2. Restart each standalone stack (subdirs with compose, not included in root)
for dir in "${SCRIPT_DIR}"/*; do
    [ -d "${dir}" ] || continue
    name="$(basename "${dir}")"
    [[ "${name}" == .* ]] && continue
    case " ${INCLUDED_IN_ROOT} " in
        *" ${name} "*) continue ;;
    esac
    for compose in "${dir}/compose.yaml" "${dir}/compose.yml"; do
        if [ -f "${compose}" ]; then
            echo "Restarting ${name}..."
            run_restart "${compose}"
            break
        fi
    done
done

echo "Done."
