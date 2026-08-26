# Plan: Independent upstream Podman alongside Ubuntu's Podman

> Status: APPROVED as the Phase 1 contract (after 2 rounds of adversarial review).
> Decisions (Phase 0): 6.x · runtime core first · local branch, no push · native build.
> Fork base: `slazarov/podman-ubuntu` (this repo), local branch only.

## The problem

Ubuntu 24.04 ships Podman 4.9.3 at `/usr/bin/podman`, managed by `apt`. We want a
**modern upstream Podman (6.x)** that we can upgrade/rollback independently, **without
ever touching Ubuntu's copy** and without the two confusing each other at runtime.

Real-world evidence (actions/runner-images #14473): Podman picked up `/usr/bin/crun`
1.14.1 instead of a newer crun via PATH resolution — `crun: unknown version specified`.
Our isolation prevents exactly that failure class.

## Target layout

```
/opt/podman/
├── releases/
│   ├── 6.1.0/                 # one self-contained install tree
│   │   ├── bin/               # podman, podman-remote, crun, rootlessport, quadlet
│   │   ├── libexec/podman/    # conmon, netavark, aardvark-dns, (passt/pasta TBD per Phase 1)
│   │   ├── share/containers/  # seccomp.json, policy.json
│   │   └── etc/containers/    # OWN containers.conf/storage.conf/registries.conf
│   └── ...
├── current -> releases/6.1.0
└── src/                       # build cache

/usr/local/bin/podman-upstream   # wrapper -> /opt/podman/current/bin/podman
```

- `podman version` → Ubuntu 4.9.3 (untouched)
- `podman-upstream version` → our 6.x build
- Rollback = repoint `current` symlink.

## Base repo decision

**Fork `slazarov/podman-ubuntu`** — local working fork, new branch, **no GitHub push**
unless asked. Reasons:
- It already has the **version resolver** (`resolve_versions.sh` + `versions-stable.env`
  for 6.x, `versions-v5.env` for 5.x) with soak windows and series caps — the
  coupled-core pairing (netavark/aardvark 2.x + buildah 1.44 ↔ podman 6.x) that the
  runner-images bug proves matters. We reuse this; we do **not** reinvent version
  resolution.
- It already builds all 12 components with native on-host scripts.
- `andrewtheguy/podman-package` (cloned at `~/code/3rdparty/podman-package`, kept as
  reference) is smaller and dpkg-in-Docker based; useful only as a cross-check for
  exact build steps. Not the base.

### What this repo's own code confirms (verifiable in the index)
- **`PREFIX=/usr` is hardcoded** across build scripts: `scripts/build_podman.sh`
  hardcodes `PREFIX=/usr` in both build and install; `scripts/build_crun.sh` hardcodes
  `./configure --prefix=/usr`. **No `INSTALL_PREFIX` abstraction exists today.**
- **`config/containers.conf` hardcodes** `seccomp_profile = "/usr/share/containers/seccomp.json"`
  and `helper_binaries_dir = ["/usr/bin", "/usr/libexec/podman", "/usr/lib/podman"]`,
  installed verbatim to `/etc/containers/containers.conf` by
  `scripts/install_container-configs.sh`. The prefix-local replacement is a direct,
  mechanical fix to this exact file.
- **`DESTDIR` vs `PREFIX` separation is real**: `DESTDIR` is documented as a staging
  tree for packaging (`CONFIGURATION.md`), separate from `PREFIX` which is compiled
  into binaries' path assumptions. `scripts/package_all.sh` already checks `DESTDIR`.
- **Version resolver is real and matches the plan**: `versions-stable.env` caps
  `PODMAN_SERIES="6"`, `NETAVARK_SERIES="2"`, `AARDVARK_DNS_SERIES="2"`,
  `BUILDAH_SERIES="1.44"` with a soak window; `scripts/resolve_versions.sh` documents
  the precedence.

### What rests on the plan author's out-of-band reading (NOT verifiable in this repo; to be confirmed empirically)
- That upstream podman's `Makefile` exposes `BINDIR / LIBEXECDIR / LIBEXECPODMAN /
  ETCDIR` as separate, prefix-relative variables. **This is the load-bearing technical
  assumption.** The plan author read it from upstream `containers/podman` source, but
  that source is cloned at build time and is not in this repo's index. **Phase 1/2's
  empirical `strace`/`podman info` proof is the mechanism that confirms or refutes it.**
- That upstream `containers/common`'s helper-binary resolution is config/env driven (no
  hardcoded `/usr` *in the resolver*). Same status: author's reading, pending empirical
  confirmation.

## Isolation strategy hierarchy (in priority order)

We isolate the stack using the least-surprising mechanism that actually works at
runtime. Earlier options are preferred because they change *where Podman looks*, not
just *where files land*:

1. **Native prefix support** — build each component with a coherent alternate prefix
   (`PREFIX`/configure prefix/Makefile vars). Preferred.
2. **Explicit runtime / configuration overrides** — where upstream supports them
   (e.g. `helper_binaries_dir`, `conmon_path`, `seccomp_profile` in `containers.conf`;
   `CONTAINERS_HELPER_BINARY_DIR`, `CONTAINERS_STORAGE_CONF`, `XDG_*` env vars). Used to
   bind the prefix tree together at runtime.
3. **Patch the upstream build** — only where a component has an unavoidable `/usr`
   assumption that options 1–2 can't address.
4. **Staging + symlink tree (`DESTDIR` + symlinks)** — considered **only as a last
   resort and treated as an experiment, not an assumed fallback.** This can produce a
   filesystem layout that *looks* isolated while the binaries still believe they're
   installed under `/usr`. Admissible only after Phase 2 has *demonstrated correct
   runtime behavior* under that arrangement — never as a shortcut to skip 1–3.

## The real feature we build (isolated-install mode)

1. **`INSTALL_PREFIX` abstraction** threaded through every build script (Phase 1
   establishes which components accept it cleanly): podman via the Makefile prefix vars;
   crun via `./configure --prefix=`; conmon via `make install.bin PREFIX=`;
   netavark/aardvark/passt staged to the location Phase 1 determines. `DESTDIR` retained
   independently for any future packaging.
2. **Prefix-local `containers.conf`** shipped in `<prefix>/etc/containers/`, with
   `helper_binaries_dir`, `conmon_path`, and `seccomp_profile` set to **prefix-relative
   values verified in Phase 1** (no pre-assumed paths).
3. **`podman-upstream` wrapper** setting, for the prefix: `PATH`,
   `CONTAINERS_HELPER_BINARY_DIR`, `CONTAINERS_STORAGE_CONF`, `CONTAINERS_REGISTRIES_CONF`,
   and `XDG_CONFIG_HOME` / `XDG_DATA_HOME`. Belt-and-suspenders so podman only ever finds
   its own helpers.
4. **Storage isolation, explicitly for both modes:**
   - **Rootless:** `storage.conf` `graphroot`/`runroot` + `XDG_DATA_HOME`/`XDG_RUNTIME_DIR`
     pointed under the prefix; tested as the unprivileged user.
   - **Rootful:** `storage.conf` `graphroot`/`runroot` set explicitly under the prefix
     (e.g. `/opt/podman/current/var/lib/containers`, `runroot` under a prefix tmp); tested
     as root. `XDG_DATA_HOME` alone is **not** assumed sufficient for either mode.

## The isolation test (corrected)

Phase 1's acceptance test is **not** "zero `/usr` leakage" — a dynamically linked binary
legitimately reads `/usr/lib/*`, `/etc/ld.so.cache`, etc. The correct test is **no
unintended use of Ubuntu's Podman ecosystem**:

- ✗ no `/usr/bin/crun` (must be our prefix crun)
- ✗ no Ubuntu `conmon`
- ✗ no Ubuntu `netavark` / `aardvark-dns`
- ✗ no `/etc/containers/*` configuration
- ✗ no Ubuntu container-storage database

**Critical acceptance criterion:** the test must identify the **actual executable paths**
of `podman`, `crun`, `conmon`, Netavark, and Aardvark-DNS **used by the running Podman
process** — not merely prove that the corresponding private files exist. Having
`/opt/podman-test/bin/crun` on disk does not prove Podman invoked it.

A successful Phase 2 establishes, with evidence (e.g. `podman info`,
`strace -f -e trace=execve,file`, or per-process `/proc/<pid>/...`), something like:

```text
Podman       /opt/podman-test/bin/podman
crun         /opt/podman-test/bin/crun
conmon       /opt/podman-test/libexec/podman/conmon
netavark     /opt/podman-test/libexec/podman/netavark
aardvark     /opt/podman-test/libexec/podman/aardvark-dns
config       /opt/podman-test/etc/containers/...
storage      /opt/podman-test/var/...
```

with the corresponding **Ubuntu paths demonstrably unused** (no `execve` of
`/usr/bin/crun`, no open of `/etc/containers/*`, no access to Ubuntu's storage
graphroot) — for **both rootless and rootful**.

## Execution plan (phased)

- **Phase 0 — Decisions (done):** 6.x · runtime core first · local branch, no push · native build.
- **Phase 1 — Throwaway build.** Build **one** Podman 6.x into `/opt/podman-test` (runtime
  core: podman, crun, conmon, netavark, aardvark, passt, common-config). Inspect every
  binary/helper path. **Establish** (empirically, not by assumption):
  - whether the upstream Makefile prefix vars actually relocate the full tree
    (confirms/refutes the load-bearing assumption);
  - the exact `conmon_path` semantics for the built version;
  - where passt/pasta must live and how Podman invokes it;
  - any other runtime path expectations (apparmor, hooks, rootlessport/quadlet).
- **Phase 2 — Empirical isolation proof.** Run the corrected isolation test above
  (rootless **and** rootful), applying the strategy hierarchy (prefer native prefix +
  runtime overrides; patch only if unavoidable; staging/symlink only as a
  demonstrated-last-resort experiment). Fix any leak. Confirm storage is prefix-local in
  both modes, and that the **actual invoked executables** are the prefix's, not Ubuntu's.
- **Phase 3 — Generalize.** Promote to `/opt/podman/releases/<ver>` + `current` symlink +
  `podman-upstream` wrapper + rollback.
- **Phase 4 (optional) — Expand scope.** Add buildah, skopeo, toolbox, fuse-overlayfs,
  catatonit.

## Risk register

- **Disk:** `/opt` ~15 GB free, disk at 97%. One release tree ~80 MB. Fine; we won't hoard releases.
- **Shared libs:** glibc 2.39, libseccomp, kernel shared with host by design
  (intentional, safe). Only version-sensitive Podman components isolated.
- **Build deps:** installing `meson`, `libcap-dev`, `libseccomp-dev`, etc. as
  *build-time* apt packages — does **not** modify Ubuntu's Podman. Flagged for transparency.
- **Unverified upstream assumption:** the plan's feasibility hinges on upstream prefix-var
  support, which is the author's out-of-band reading. Phase 1 is explicitly the gate that
  confirms or kills this; if the prefix vars don't relocate the tree as expected, we
  descend the strategy hierarchy (runtime overrides → targeted build patch →
  staging/symlink *only as a demonstrated experiment*) rather than proceed on a false
  premise.
- **Storage modes:** rootless vs rootful treated as distinct, explicit cases, not assumed
  away by `XDG_DATA_HOME`.
- **Staging/symlink pitfall:** a symlink tree can *look* isolated while binaries still
  resolve under `/usr`. Admissible only after Phase 2 demonstrates correct runtime
  behavior — never as a cosmetic shortcut.

---

## Phase 1 & 2 — ACTUAL RESULTS (2026-08-26)

Both phases executed on this host. Summary of what was empirically established.

### Version set resolved (stable/6.x track)
`podman v6.1.0`, `crun 1.29.1`, `conmon v2.2.1`, `netavark v2.1.0`,
`aardvark-dns v2.1.0`, `container-configs common/v0.69.1`. Build deps + Go 1.26.6
(system, >= required 1.25.9) + Rust 1.96.0 (`~/.cargo`, >= MSRV 1.88) used; no
`sudo`, no `/opt/go`, no system Podman modification.

### Load-bearing assumption: CONFIRMED
Upstream `PREFIX`/`LIBEXECDIR`/`LIBEXECPODMAN` prefix vars DO relocate the full
tree. Built into `/opt/podman-test` (later promoted to
`/opt/podman/releases/6.1.0`): `bin/{podman,podman-remote,crun,conmon}`,
`libexec/podman/{netavark,aardvark-dns,passt,pasta,quadlet,rootlessport,...}`,
`etc/containers/*`, `share/containers/seccomp.json`. C components (crun/conmon)
honored `./configure --prefix` / `make PREFIX=`; Rust (netavark/aardvark) honored
the `libexec/podman` staging; passt staged in `libexec/podman` (Phase 1 probe
confirmed podman invokes it there).

### Isolation leaks found & fixed (this is the whole point)
Raw prefix binary (no env) leaks to Ubuntu: `podman info` reported
`/usr/bin/crun`, `/usr/bin/conmon`, `/usr/lib/podman/{netavark,aardvark}`,
`/usr/bin/pasta`, `/usr/share/containers/seccomp.json`. Root cause: the prefix
`containers.conf` was not being consulted AND `conmon_path`/`helper_binaries_dir`
needed absolute prefix paths + an explicit `[engine.runtimes] crun = [...]`.
Fixed by a prefix-local `containers.conf` with absolute `/opt/podman/...` paths
and the `podman-upstream` wrapper that exports `CONTAINERS_CONF` +
`CONTAINERS_HELPER_BINARY_DIR` + `XDG_*`.

### Phase 2 proof (rootless) — PASSED
`strace -f -e trace=execve` on `podman-upstream run` showed actual execve of:
- `/opt/podman/releases/6.1.0/bin/conmon` (v2.2.1)
- `/opt/podman/releases/6.1.0/bin/crun` (v1.29.1)
- `/opt/podman/current/libexec/podman/{netavark,aardvark-dns,pasta}`
- ZERO execve of `/usr/bin/crun` or `/usr/bin/conmon`.
Storage graphRoot = `/opt/podman/current/var/xdg/data/containers/storage`
(prefix-local); Ubuntu's graphRoot (`~/.local/share/containers`) untouched.
Container ran successfully. `podman version` (Ubuntu 4.9.3) remains intact.

### Storage note (learned the hard way)
Podman marks extracted image layer dirs read-only (`0555`) and immutable (`chattr
+i`). After moving the tree, the stale storage DB refused deletion until `chmod -R
u+w` + `chattr -i` cleared those. Lesson: a release move requires resetting
storage state, or build directly at the final `INSTALL_PREFIX` path.

### Outstanding
- **Rootful** mode not yet re-tested post-promotion (sudo step aborted earlier);
  the same wrapper + `XDG_*` under the prefix applies, but must be confirmed.
- `podman-upstream` is installed at `/opt/podman/bin/podman-upstream` (symlinked
  into `~/.local/bin`); not in `/usr/local/bin` (needs sudo). Add `~/.local/bin`
  to PATH or call via absolute path.
- `phase1-build*.sh` drivers are throwaway scaffolding (untracked / gitignored).

### Phase 3 status
Mechanism implemented and proven: `/opt/podman/releases/6.1.0` + `current`
symlink + `podman-upstream` wrapper. Rollback = repoint `current`. The
`INSTALL_PREFIX` abstraction in the build scripts is the reusable feature for
future releases (ideally driven by the `podman-package` Docker build system on
its `isolated-build` branch for hermetic, reproducible prefix builds).
