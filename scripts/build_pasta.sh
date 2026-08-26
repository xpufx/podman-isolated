#!/bin/bash

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Change Folder to Build Root
cd "${BUILD_ROOT}" || exit

# Initialize build logging
log_build_output "pasta"

step_start "Cloning repository"
git_clone_update git://passt.top/passt passt
cd "${BUILD_ROOT}/passt"
git fetch --all
git fetch --tags
git pull
step_done

step_start "Saving version"
export GIT_CHECKED_OUT_TAG=$(date +"%Y%m%d")
step_done

step_start "Logging version"
log_component "pasta"
step_done

step_start "Configuring ccache"
# Enable ccache for C build caching when configured
if [[ "${CCACHE_ENABLED:-false}" == "true" ]] && command -v ccache &>/dev/null; then
    export CC="ccache gcc"
    echo "  ccache enabled for C compilation"
fi
step_done

step_start "Building"
run_logged make -j "$NPROC"
step_done

step_start "Installing"
# Passt/pasta location is deliberately staged under libexec/podman for the
# isolated-podman branch; Phase 1 empirically confirms whether Podman invokes
# it from there. (Upstream passt has its own conventions — this is a probe,
# not an assumption.)
PASTDIR="${INSTALL_PREFIX}/libexec/podman"
if [[ -n "${DESTDIR:-}" ]]; then
    install -D -m 0755 passt "${DESTDIR}${PASTDIR}/passt"
    [[ -f passt.avx2 ]] && install -D -m 0755 passt.avx2 "${DESTDIR}${PASTDIR}/passt.avx2"
    install -D -m 0755 pasta "${DESTDIR}${PASTDIR}/pasta"
    [[ -f pasta.avx2 ]] && install -D -m 0755 pasta.avx2 "${DESTDIR}${PASTDIR}/pasta.avx2"
    install -D -m 0755 pesto "${DESTDIR}${PASTDIR}/pesto"
    install -D -m 0755 passt-repair "${DESTDIR}${PASTDIR}/passt-repair"
else
    install -D -m 0755 passt "${PASTDIR}/passt"
    [[ -f passt.avx2 ]] && install -D -m 0755 passt.avx2 "${PASTDIR}/passt.avx2"
    install -D -m 0755 pasta "${PASTDIR}/pasta"
    [[ -f pasta.avx2 ]] && install -D -m 0755 pasta.avx2 "${PASTDIR}/pasta.avx2"
    install -D -m 0755 pesto "${PASTDIR}/pesto"
    install -D -m 0755 passt-repair "${PASTDIR}/passt-repair"
fi
step_done
