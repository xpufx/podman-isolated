# Verification & Real-World Compatibility Report

This document records the verification tests conducted for **Podman Isolated** packages, detailing what was tested, the host environments used, and the verified behavior.

---

## 1. Test Environments

* **Operating System**: Ubuntu 24.04.3 LTS (Noble Numbat)
* **Architecture**: `x86_64` (amd64)
* **Kernel**: Linux `6.8.0-xx-generic`
* **Test Hosts**:
  * **Production-Like Developer Host (`ubuntu-xpufx`)**: An active workstation running system Podman with an existing multi-container stack (11–14 containers, custom bridges, databases, and background daemons).
  * **Clean Host VM (`ubuntu-xpufx-clone`)**: A freshly provisioned environment for validating package installation, complete removal, and filesystem hygiene.

---

## 2. Packaging & Lifecycle

### Installation
* **Action**: Installed `podman6` directly from the public repository (`aptitude install podman6`).
* **Verified Behavior**:
  * Self-contained: Installs without forcing upgrades of existing system libraries or conflicting with distribution packages.
  * Prefix layout: Installs all binaries, companion libraries, and OCI helpers into `/opt/podman/releases/<version>/`.
  * Entrypoint: Installs a single versioned symlink at `/usr/bin/podman6` conforming to Debian packaging standards.
  * System integrity: Background system services and existing user sessions continue running unaffected.

### Removal & Purge Hygiene
* **Action**: Removed the package completely (`aptitude purge podman6`).
* **Verified Behavior**:
  * Uninstalls cleanly and silently with zero packaging warnings.
  * Removes `/opt/podman/releases/<version>/` and the entrypoint symlink completely.
  * Leaves no orphaned files or untracked configuration artifacts behind.

---

## 3. Concurrent Multi-Engine Execution

Podman Isolated is designed to allow a modern Podman version (such as 6.x) to run side-by-side with a distribution-provided Podman without interference.

### Test Setup: Two Stacks Running Concurrently Under the Same User
1. **System Podman Stack**:
   * 11 active containers (Postgres, Redis, MinIO/Silo, API, Worker, BFF).
   * Custom bridge network `hsi-network` (`10.89.12.0/24`).
   * Offset port bindings (`6801->5432`, `9100->9000`, etc.).
2. **Podman 6 Stack**:
   * Multi-container compose stack (`podman6-test-postgres`, `podman6-test-silo`).
   * Custom bridge network `podman6-test_test-net` (`10.89.0.0/24`).
   * Default port bindings (`5432->5432`, `9000->9000`).

### Verified Behavior:
* **Helper Binaries & Process Trees**:
  * System Podman executes via `/usr/bin/podman`, `/usr/bin/conmon`, and `/usr/bin/crun`.
  * Podman 6 executes via `/opt/podman/releases/6.1.0/bin/podman`, `conmon`, and `crun`.
  * Both process trees run concurrently with zero cross-talk.
* **Networking & DNS (`netavark` & `aardvark-dns`)**:
  * Separate `aardvark-dns` instances run concurrently under the same user UID, listening on independent sockets.
  * Container names resolve accurately within each stack's isolated network.
  * Subnets remain distinct and non-conflicting (`10.89.0.0/24` vs `10.89.12.0/24`).
* **Storage & State Isolation**:
  * System Podman stores images and containers under `~/.local/share/containers/storage`.
  * Podman 6 rootless storage resides under `~/.local/share/podman6/containers/storage`.
  * Neither engine sees, queries, or alters the other's images, containers, or volumes.

---

## 4. Startup Order Independence

To verify that neither engine relies on the other:

1. **Both Stacks Stopped**: All containers on both engines brought to a complete stop.
2. **Podman 6 Started First**:
   * Launched via `podman6 compose up -d` while system Podman was completely idle.
   * All containers initialized to healthy and served traffic normally, confirming full operational independence.
3. **System Podman Started Second**:
   * All 11 system containers started while Podman 6 was actively running.
   * Both stacks operated simultaneously with zero port collisions, socket locks, or network degradation.

---

## 5. Scope & Coverage

* **Actively Verified**: Ubuntu 24.04 LTS (live host & clean VM) and Ubuntu 26.04 (CI container environment).
* **Architectures Verified**: `x86_64` (amd64) on physical hardware and KVM; `aarch64` (arm64) via automated CI workflows.
* **Planned Coverage**: Native packages for Debian 12/13, Arch Linux (`pacman`), and RPM-based distributions.

---

## 6. Potential Issues & Edge Cases

### Subnet Allocation Overlap
* **Behavior**: Rootless bridge networks use user-isolated network namespaces. Neither instance can inspect the internal bridges of the other. By default, both engines allocate subnets from Netavark's default pool (`10.89.0.0/16` in `/24` increments). If both engines create networks that happen to draw the same subnet (e.g. both pick `10.89.0.0/24`), traffic within their respective namespaces still works, but inter-container routing by IP between engines or overlapping host port binds could cause confusion.
* **Tip**: If you run multiple engines simultaneously and want to guarantee zero subnet overlap, assign an offset default subnet pool in `~/.config/podman6/containers/containers.conf`:
  ```toml
  [network]
  default_subnet_pools = [
    {"base" = "10.90.0.0/16", "size" = 24}
  ]
  ```
