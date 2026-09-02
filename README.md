# podman-isolated

Fully isolated, multi-version builds of the upstream Podman container engine and its OCI companion stack (`crun`, `conmon`, `netavark`, `aardvark-dns`, `pasta`). 

Built specifically for Debian/Ubuntu systems where you need modern, upstream Podman features (e.g., Podman 6.x) running cleanly side-by-side with the distribution's official Podman packages without package conflicts, `/usr` pollution, or runtime helper collisions.

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

| | |
|---|---|
| **License** | AGPL-3.0 |
| **Supported Platforms** | Ubuntu 24.04 (Noble Numbat), Ubuntu 26.04 (Resolute Raccoon), Debian |
| **Architectures** | amd64 (x86_64), arm64 (aarch64) |
| **Default Prefix** | `/opt/podman/releases/<version>` (symlinked to `/opt/podman/current`) |

---

## Provenance

This project started as an independent fork of [slazarov/podman-ubuntu](https://github.com/slazarov/podman-ubuntu) (which itself originated from [luckylinux/podman-debian](https://github.com/luckylinux/podman-debian)). 

While upstream `podman-ubuntu` is designed as an in-place package replacement under `/usr` (declaring `Conflicts:` and `Replaces:` against Ubuntu's stock packages), **`podman-isolated`** is re-architected for **peaceful coexistence**:
* Complete separation from the host system's package manager.
* Multi-version release layout with instant symlink switching.
* Hermetic container configuration and runtime isolation to prevent cross-talk.

---

## Why podman-isolated?

When attempting to run upstream Podman on an existing Linux system, several common pitfalls emerge:

1. **Package Collisions:** Distribution package managers (APT) manage `/usr/bin/podman`, `/usr/bin/crun`, and `/usr/libexec/podman/*`. Overwriting these breaks system updates and dependent services.
2. **Runtime Helper Leakage:** Upstream Podman searches `$PATH` and `/etc/containers` for companion binaries. Without explicit isolation, an upstream Podman binary can quietly invoke the system's older `/usr/bin/crun` or `/usr/bin/conmon`, causing subtle runtime incompatibilities (such as the runner-images crun mismatch bug).
3. **Database & Storage Clashes:** If multiple Podman instances share `/var/lib/containers` or `$HOME/.local/share/containers`, storage driver metadata and database locks collide.
4. **Network Socket Crossover:** Running custom bridge networks simultaneously can collide if both engines look for network daemons (like `aardvark-dns`) in the same default `/run/` socket paths.

`podman-isolated` solves this by packaging the complete container engine and companion utilities into a self-contained prefix with an isolating execution wrapper.

---

## Directory & Release Architecture

All releases live under `/opt/podman/` in isolated, versioned directory trees:

```text
/opt/podman/
├── releases/
│   ├── 6.1.0/
│   │   ├── bin/                 # podman, crun, conmon
│   │   ├── libexec/podman/      # netavark, aardvark-dns, pasta, quadlet, rootlessport
│   │   ├── etc/containers/      # containers.conf, storage.conf, registries.conf
│   │   ├── share/containers/    # seccomp.json
│   │   └── var/xdg/             # Rootless storage and config
│   └── 5.4.0/                   # Co-existing earlier release
├── current -> releases/6.1.0    # Active version pointer
└── bin/
    └── podman-upstream          # Environment-isolating runner script
```

The host system's `/usr/bin/podman`, `/etc/containers/`, `/var/lib/containers/`, and `~/.local/share/containers/` remain 100% untouched.

---

## The `podman-upstream` Wrapper

Running `/opt/podman/bin/podman-upstream` (or symlinked to `~/.local/bin/podman-upstream`) sets up the hermetic environment before launching the engine:

* Pins `PATH` and `CONTAINERS_HELPER_BINARY_DIR` to the prefix.
* Directs `CONTAINERS_CONF` to the prefix-local `containers.conf`.
* Directs rootless `XDG_DATA_HOME` and `XDG_CONFIG_HOME` into the prefix tree so rootless databases and image stores never collide with the host.
* Switches to `storage-root.conf` when invoked via `sudo` to keep rootful container storage confined to the prefix's `var/lib/containers/storage`.

```bash
# Verify upstream Podman version
podman-upstream version

# Ubuntu's system Podman remains unaffected
podman version
```

---

## Components Built

Each release builds and packages the complete modern OCI stack:

| Component | Role | Tested Version |
| :--- | :--- | :--- |
| **[Podman](https://github.com/containers/podman)** | Daemonless container engine | 6.1.0 |
| **[crun](https://github.com/containers/crun)** | Fast, low-memory OCI runtime (C) | 1.29.1 |
| **[conmon](https://github.com/containers/conmon)** | Container monitor & lifecycle | 2.2.1 |
| **[Netavark](https://github.com/containers/netavark)** | Container network stack (Rust) | 2.1.0 |
| **[Aardvark-DNS](https://github.com/containers/aardvark-dns)** | Container DNS server | 2.1.0 |
| **[pasta / passt](https://passt.top/)** | Rootless user-mode networking | Latest upstream |

---

## Building from Source

### Prerequisites
* Ubuntu 24.04 / 26.04 or Debian-based host
* System build tools: Go (1.22+), Rust / Cargo, GCC / Clang, make

### Build & Installation Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/xpufx/podman-isolated.git
   cd podman-isolated
   ```

2. Specify your target prefix:
   ```bash
   export INSTALL_PREFIX="/opt/podman/releases/6.1.0"
   ```

3. Resolve upstream versions:
   ```bash
   eval "$(./scripts/resolve_versions.sh versions-stable.env)"
   ```

4. Build and install into the prefix:
   ```bash
   ./setup.sh
   ```

5. Point the `current` symlink and link the wrapper:
   ```bash
   ln -sfn releases/6.1.0 /opt/podman/current
   mkdir -p ~/.local/bin
   ln -sfn /opt/podman/bin/podman-upstream ~/.local/bin/podman-upstream
   ```

---

## Packaging as Non-Conflicting `.deb` Packages

In addition to direct prefix builds, `podman-isolated` supports generating standalone Debian packages using **nFPM**:

* Packages are named with track/major indicators (e.g. `podman6`, `podman5`).
* Packages contain no `Conflicts:` or `Replaces:` against distro `podman`.
* All files are staged into `/opt/podman/releases/<version>/`.
* Allows running `apt install podman6` alongside the OS distro package.

---

## License & Credits

* Distributed under the **[AGPL-3.0](LICENSE)** license.
* Based on [slazarov/podman-ubuntu](https://github.com/slazarov/podman-ubuntu) by Stefan Lazarov.
* Prior lineage from [luckylinux/podman-debian](https://github.com/luckylinux/podman-debian) and the upstream [Containers Project](https://github.com/containers).
