#!/usr/bin/env bash
# package_tarball.sh — generate standalone binary tarball for isolated Podman
set -euo pipefail

relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

source "${toolpath}/config.sh"
source "${toolpath}/functions.sh"

OUTPUT_DIR="${1:-${BUILD_ROOT}/tarballs}"
mkdir -p "${OUTPUT_DIR}"

if [[ -z "${DESTDIR:-}" || ! -d "${DESTDIR}${INSTALL_PREFIX}" ]]; then
    echo "ERROR: DESTDIR prefix ${DESTDIR:-}${INSTALL_PREFIX} does not exist" >&2
    exit 1
fi

REL_NAME="$(basename "${INSTALL_PREFIX}")"
# Prefer the resolved tag; fall back to the release dir name — the same
# derivation package_all.sh uses. PODMAN_TAG is empty when this script runs
# outside the resolver-export environment (e.g. package step without TAGs),
# which previously produced version-less "podman-isolated--linux-*.tar.gz".
if [[ -n "${PODMAN_TAG:-}" ]]; then
    PKG_VERSION="${PODMAN_TAG#v}"
else
    PKG_VERSION="${REL_NAME}"
fi
ARCH_NAME="${ARCH:-amd64}"
TARBALL_BASE="podman-isolated-${PKG_VERSION}-linux-${ARCH_NAME}"
STAGING_DIR="$(mktemp -d)"

trap 'rm -rf "${STAGING_DIR}"' EXIT

echo "=== Creating Standalone Tarball: ${TARBALL_BASE}.tar.gz ==="

# Structure of tarball:
#   opt/podman/releases/<version>/...
#   install.sh
#   README.md
mkdir -p "${STAGING_DIR}/opt/podman/releases/${REL_NAME}"
cp -a "${DESTDIR}${INSTALL_PREFIX}/." "${STAGING_DIR}/opt/podman/releases/${REL_NAME}/"

# Clean any ephemeral or log files if present in staging
rm -f "${STAGING_DIR}/opt/podman/releases/${REL_NAME}"/*.log
rm -rf "${STAGING_DIR}/opt/podman/releases/${REL_NAME}/var"

# Create install.sh helper
cat <<'INSERTEOF' >"${STAGING_DIR}/install.sh"
#!/usr/bin/env bash
# Standalone installer for Podman Isolated
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: installer must be run as root (or via sudo)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL_DIR="$(find "${SCRIPT_DIR}/opt/podman/releases" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [[ -z "${REL_DIR}" || ! -d "${REL_DIR}" ]]; then
    echo "ERROR: release directory not found in ${SCRIPT_DIR}/opt/podman/releases" >&2
    exit 1
fi

REL_VER="$(basename "${REL_DIR}")"
MAJOR="${REL_VER%%.*}"
if [[ "${MAJOR}" =~ ^[0-9]+$ ]]; then
    CMD_NAME="podman${MAJOR}"
else
    CMD_NAME="podman6"
fi

TARGET_PREFIX="/opt/podman/releases/${REL_VER}"
echo ">>> Installing Podman Isolated ${REL_VER} to ${TARGET_PREFIX}..."
mkdir -p "/opt/podman/releases"
cp -a "${REL_DIR}" "/opt/podman/releases/"

# Install symlink to /usr/bin/<pkg>
mkdir -p /usr/bin
ln -sf "${TARGET_PREFIX}/bin/podman-wrapper" "/usr/bin/${CMD_NAME}"
echo ">>> Created symlink /usr/bin/${CMD_NAME} -> ${TARGET_PREFIX}/bin/podman-wrapper"

# Optional /opt/podman/current symlink
ln -sfn "releases/${REL_VER}" "/opt/podman/current"

echo ">>> Successfully installed ${CMD_NAME} (${REL_VER})."
echo "    Run '${CMD_NAME} --version' to verify."
INSERTEOF
chmod 0755 "${STAGING_DIR}/install.sh"

# Create standalone README.md
cat <<INSERTEOF >"${STAGING_DIR}/README.md"
# Podman Isolated ${PKG_VERSION} (Linux ${ARCH_NAME})

Standalone binary release of upstream Podman ${PKG_VERSION} and companion OCI stack
(crun, conmon, netavark, aardvark-dns, etc.).

## Quick Install

To install to \`/opt/podman/releases/${REL_NAME}\` with symlink \`/usr/bin/podman${REL_NAME%%.*}\`:

\`\`\`bash
sudo ./install.sh
\`\`\`

## Verification

\`\`\`bash
podman${REL_NAME%%.*} --version
podman${REL_NAME%%.*} info
\`\`\`
INSERTEOF

# Build tarball
tar -czf "${OUTPUT_DIR}/${TARBALL_BASE}.tar.gz" -C "${STAGING_DIR}" .

# Generate SHA256
(cd "${OUTPUT_DIR}" && sha256sum "${TARBALL_BASE}.tar.gz" >"${TARBALL_BASE}.tar.gz.sha256")

echo ">>> Generated ${OUTPUT_DIR}/${TARBALL_BASE}.tar.gz"
echo ">>> Checksum: $(cat "${OUTPUT_DIR}/${TARBALL_BASE}.tar.gz.sha256")"
