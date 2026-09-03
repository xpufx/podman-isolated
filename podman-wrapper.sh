#!/usr/bin/env bash
# podman-wrapper — invoke the isolated Podman build with prefix environment.
#
# Sets up the hermetic environment before launching the engine, ensuring
# binaries, helpers, configs, and user storage are fully isolated from the host.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ -n "${PODMAN_ROOT_OVERRIDE:-}" ]]; then
    PODMAN_ROOT="${PODMAN_ROOT_OVERRIDE}"
elif [[ -x "$(cd "$(dirname "${SELF}")/.." && pwd)/bin/podman" ]]; then
    PODMAN_ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
elif [[ -x "/opt/podman/current/bin/podman" ]]; then
    PODMAN_ROOT="/opt/podman/current"
else
    echo "podman: binary not found under prefix $(cd "$(dirname "${SELF}")/.." && pwd)" >&2
    exit 1
fi

export PATH="${PODMAN_ROOT}/bin:${PODMAN_ROOT}/libexec/podman:${PATH}"
export CONTAINERS_CONF="${PODMAN_ROOT}/etc/containers/containers.conf"
export CONTAINERS_HELPER_BINARY_DIR="${PODMAN_ROOT}/libexec/podman"
export CONTAINERS_REGISTRIES_CONF="${PODMAN_ROOT}/etc/containers/registries.conf"

CMD_NAME="$(basename "$0")"
if [[ "${CMD_NAME}" == "podman" || "${CMD_NAME}" == podman-wrapper* || "${CMD_NAME}" == podman-upstream* || -z "${CMD_NAME}" ]]; then
    REL_NAME="$(basename "${PODMAN_ROOT}")"
    MAJOR="${REL_NAME%%.*}"
    if [[ "${MAJOR}" =~ ^[0-9]+$ ]]; then
        CMD_NAME="podman${MAJOR}"
    else
        CMD_NAME="podman6"
    fi
fi

if [[ "$(id -u)" -eq 0 ]]; then
    if [[ -f "${PODMAN_ROOT}/etc/containers/storage-root.conf" ]]; then
        export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage-root.conf"
    else
        export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage.conf"
    fi
else
    export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage.conf"
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/${CMD_NAME}"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/${CMD_NAME}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/${CMD_NAME}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
fi

# If invoking "system service" without an explicit URI, default to the isolated socket
if [[ "${1:-}" == "system" && "${2:-}" == "service" ]]; then
    has_uri=false
    for arg in "${@:3}"; do
        if [[ "$arg" =~ ^(unix|tcp):// ]]; then
            has_uri=true
            break
        fi
    done
    if [[ "$has_uri" == false ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            set -- "$@" "unix:///run/${CMD_NAME}/podman.sock"
        else
            set -- "$@" "unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${CMD_NAME}/podman.sock"
        fi
    fi
fi

exec "${PODMAN_ROOT}/bin/podman" "$@"
