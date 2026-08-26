#!/usr/bin/env bash
# podman-upstream — invoke the isolated upstream Podman build.
#
# Isolation is the DEFAULT here: it points Podman exclusively at the prefix tree
# under /opt/podman/current, so it never consults Ubuntu's /usr/bin/podman
# ecosystem or /etc/containers. Without this wrapper, running the prefix binary
# raw falls back to the system config and leaks to /usr (proven in Phase 2).
#
# Override the root with PODMAN_UPSTREAM_ROOT (used to test a throwaway tree).
set -euo pipefail

PODMAN_ROOT="${PODMAN_UPSTREAM_ROOT:-/opt/podman/current}"

if [[ ! -x "${PODMAN_ROOT}/bin/podman" ]]; then
    echo "podman-upstream: prefix podman not found at ${PODMAN_ROOT}/bin/podman" >&2
    echo "  Is /opt/podman/current symlinked to a built release?" >&2
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
