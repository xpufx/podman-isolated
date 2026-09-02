#!/usr/bin/env bash
# podman-upstream — invoke the isolated upstream Podman build.
#
# Installed in isolated mode (INSTALL_PREFIX != /usr). It points Podman
# exclusively at the prefix tree it lives in, so it never consults the system
# /usr/bin/podman ecosystem or /etc/containers. Without this wrapper, running
# the prefix binary raw falls back to the system config and leaks to /usr.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ -n "${PODMAN_UPSTREAM_ROOT:-}" ]]; then
    PODMAN_ROOT="${PODMAN_UPSTREAM_ROOT}"
elif [[ -x "/opt/podman/current/bin/podman" ]]; then
    PODMAN_ROOT="/opt/podman/current"
elif [[ -x "$(cd "$(dirname "${SELF}")/.." && pwd)/bin/podman" ]]; then
    PODMAN_ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
else
    echo "podman-upstream: prefix podman not found at /opt/podman/current/bin/podman" >&2
    exit 1
fi

export PATH="${PODMAN_ROOT}/bin:${PODMAN_ROOT}/libexec/podman:${PATH}"
export CONTAINERS_CONF="${PODMAN_ROOT}/etc/containers/containers.conf"
export CONTAINERS_HELPER_BINARY_DIR="${PODMAN_ROOT}/libexec/podman"
export CONTAINERS_REGISTRIES_CONF="${PODMAN_ROOT}/etc/containers/registries.conf"

if [[ "$(id -u)" -eq 0 ]]; then
    if [[ -f "${PODMAN_ROOT}/etc/containers/storage-root.conf" ]]; then
        export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage-root.conf"
    else
        export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage.conf"
    fi
else
    export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage.conf"
    export XDG_CONFIG_HOME="${PODMAN_ROOT}/var/xdg/config"
    export XDG_DATA_HOME="${PODMAN_ROOT}/var/xdg/data"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
fi

exec "${PODMAN_ROOT}/bin/podman" "$@"
