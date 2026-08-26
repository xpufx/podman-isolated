#!/usr/bin/env bash
# podman-upstream — invoke the isolated upstream Podman build.
#
# Installed only in isolated mode (INSTALL_PREFIX != /usr). It points Podman
# exclusively at the prefix tree it lives in, so it never consults the system
# /usr/bin/podman ecosystem or /etc/containers. Without this wrapper, running
# the prefix binary raw falls back to the system config and leaks to /usr.
#
# PODMAN_ROOT is derived from this script's own location (the prefix it was
# installed into), so the wrapper is portable across any INSTALL_PREFIX.
# Override with PODMAN_UPSTREAM_ROOT if needed (e.g. testing a throwaway tree).
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PODMAN_ROOT="${PODMAN_UPSTREAM_ROOT:-$(cd "$(dirname "${SELF}")/.." && pwd)}"

if [[ ! -x "${PODMAN_ROOT}/bin/podman" ]]; then
    echo "podman-upstream: prefix podman not found at ${PODMAN_ROOT}/bin/podman" >&2
    echo "  Is this wrapper installed inside an isolated Podman prefix?" >&2
    exit 1
fi

export PATH="${PODMAN_ROOT}/bin:${PODMAN_ROOT}/libexec/podman:${PATH}"
export CONTAINERS_CONF="${PODMAN_ROOT}/etc/containers/containers.conf"
export CONTAINERS_HELPER_BINARY_DIR="${PODMAN_ROOT}/libexec/podman"
export CONTAINERS_STORAGE_CONF="${PODMAN_ROOT}/etc/containers/storage.conf"
export CONTAINERS_REGISTRIES_CONF="${PODMAN_ROOT}/etc/containers/registries.conf"
export XDG_CONFIG_HOME="${PODMAN_ROOT}/var/xdg/config"
export XDG_DATA_HOME="${PODMAN_ROOT}/var/xdg/data"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

exec "${PODMAN_ROOT}/bin/podman" "$@"
