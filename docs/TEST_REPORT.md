# Real-World Verification & Compatibility Report

This document records the manual and automated real-world verification tests conducted for **Podman Isolated** packages, detailing what was tested, the specific host environments used, and the verified behavior.

---

## 1. Test Environment

* **Operating System**: Ubuntu 24.04.3 LTS (Noble Numbat)
* **Architecture**: `x86_64` (amd64)
* **Kernel**: Linux `6.8.0-xx-generic`
* **Test Hosts**:
  * **Primary Development Host**: `ubuntu-xpufx` (production-like developer machine running existing system Podman 4.x/5.x stacks with 14 active containers across custom networks).
  * **Clean Clone VM**: `ubuntu-xpufx-clone` (dedicated environment for testing package install, purge, file ownership, and directory removal hygiene).

---

## 2. Packaging & Lifecycle Tests

### A. Clean Installation
* **Action**: Installed `podman6` directly from the live public repository via `aptitude install podman6`.
* **Verified Behavior**:
  * Installed cleanly without pulling in unintended dependencies or upgrading existing system libraries.
  * Installed all binaries, libraries, and helpers into `/opt/podman/releases/<version>/`.
  * Placed a single symlink into `/usr/bin/podman6` (fully adhering to Debian Policy §9.1.2 by avoiding `/usr/local/bin`).
  * `needrestart` and system services were not disrupted; running system processes remained untouched.

### B. Complete Purge & Directory Hygiene
* **Action**: Ran `aptitude purge podman6` on a clean system.
* **Verified Behavior**:
  * Package removed cleanly with **zero warnings**.
  * No warning about `/usr/local/bin` not being empty.
  * No warning about `/opt` not being empty (`dpkg` sanitization ensures the package does not claim ownership of the root `/opt` system directory).
  * `/opt/podman/releases/<version>` and all installed files were completely removed without leaving orphan files.

---

## 3. Simultaneous Multi-Stack & Isolation Tests

The primary goal of Podman Isolated is allowing bleeding-edge Podman (e.g. 6.x) to run side-by-side with an existing system Podman without conflict.

### Tested Setup: Two Stacks Running Concurrently
1. **System Podman Stack**:
   * 11 active containers (Postgres, Redis, Silo/MinIO, API, Worker, BFF, etc.).
   * Custom bridge network `hsi-network` (`10.89.12.0/24`).
   * Offset port bindings (`6801->5432`, `9100->9000`, etc.).
2. **Podman 6 Stack**:
   * Multi-container compose stack (`podman6-test-postgres`, `podman6-test-silo`).
   * Custom bridge network `podman6-test_test-net` (`10.89.0.0/24`).
   * Default port bindings (`5432->5432`, `9000->9000`).

### Test Results:
* **Process Separation**:
  * System Podman used `/usr/bin/podman`, `/usr/bin/conmon`, and `/usr/bin/crun`.
  * Podman 6 used `/opt/podman/releases/6.1.0/bin/podman`, `conmon`, and `crun`.
  * Both process trees executed simultaneously with no crossover.
* **Network & DNS (`netavark` & `aardvark-dns`)**:
  * Two separate `aardvark-dns` daemons ran concurrently under the same user UID (one in `/usr/lib/podman`, one in `/opt/podman/releases/6.1.0/libexec`).
  * Container names resolved correctly within each stack without leaking or clobbering DNS namespaces.
  * Netavark assigned distinct, non-conflicting subnets (`10.89.0.0/24` vs `10.89.12.0/24`).
* **Storage & State**:
  * System Podman storage: `~/.local/share/containers/storage`
  * Podman 6 rootless storage: `~/.local/share/podman6/containers/storage`
  * Neither engine saw, modified, or conflicted with the other's images, layers, or volumes.

---

## 4. Inverted Startup Order & Independence Tests

To ensure Podman 6 has zero hidden dependencies on system Podman:

1. **Both Stacks Stopped**: Both engines brought to zero running containers.
2. **Podman 6 Started First (Solo)**:
   * Stack launched with `podman6 compose up -d`.
   * Both Postgres and Silo reached `Up (healthy)` and served traffic with system Podman completely offline.
   * Proved Podman 6 requires no prior setup or active services from system Podman.
3. **System Podman Started Second (Concurrent)**:
   * System Podman started all 11 containers while Podman 6 was already running.
   * All 11 system containers started healthy.
   * Neither engine experienced connection drops, port collisions, or socket errors.

---

## 5. Scope & Limitations

* **Distros Actively Verified**: Ubuntu 24.04 LTS (live host & clone VM) and Ubuntu 26.04 (CI container build & smoke tests).
* **Architectures Verified**: `x86_64` (amd64) on bare metal/KVM; `aarch64` (arm64) verified via GitHub Actions runners.
* **Not Yet Covered**: Debian 12/13 bare-metal hosts (targeted next), Fedora/RHEL RPM packages, and Arch Linux pacman setups.
