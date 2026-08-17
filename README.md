# frog-toolchain

This repository contains a crosstool-ng configuration and patches to build the
MIPS toolchain used for the SF2000, GB300 and other frog devices.

## Local build (Ubuntu 24.04+)

From a clean Ubuntu machine:

```sh
sudo apt-get install -y make
make install-deps-ubuntu
make install-ctng
make toolchain
```

## Local build (Alpine 3.23+)

From a clean Alpine machine:

```sh
apk add --no-cache make
make install-deps-alpine
make toolchain
```

Output:
- Toolchain is installed under `x-tools/` in this repo.
- Downloaded tarballs are cached in `.tarballs/`.

## Channels

The workflow builds static Alpine host toolchains and publishes a release with
the artifacts:

- edge Alpine 3.23 x86_64 / arm64
- stable Alpine 3.23 x86_64 / arm64
- nuttx Alpine 3.23 x86_64 / arm64
- uclibc Alpine 3.23 x86_64 / arm64

`edge` is built from `.config.edge` (newlib, bare-metal). `stable` is built from
`.config.stable-v1.0.0` (newlib, bare-metal, same component versions as edge
so a release updates every channel at once).

`nuttx` is built from `.config.nuttx`, a minimal bare-metal config for NuttX
and the applications built on top of it. NuttX ships its own libc in-tree, so
this config drops newlib entirely; only binutils + GCC (C and C++ frontends)
+ libgcc are produced, which is all NuttX links against. NuttX builds its own
C++ runtime (libcxx/libcxxabi) in-tree, so the toolchain's libstdc++ is not
needed either. This makes the toolchain significantly faster to compile
while producing the same `mipsel-mti-elf` compiler tuple and static ELF
output.

`uclibc` is built from `.config.uclibc` and targets the `sf2000-linux`
project: `mipsel-unknown-linux-uclibc`, little-endian MIPS32, soft-float,
no-MMU, static-only uclibc-ng with static-PIE support (the SF2000 kernel uses
a no-MMU static-PIE loader). It uses the newest toolchain components: GCC
16.2.0, binutils 2.47, uclibc-ng 1.0.59, and Linux 7.1 kernel headers.

All channels track the latest crosstool-ng versions (GCC 16.2.0, binutils
2.47, newest libc releases) so a release updates every toolchain at once.

## Channel scoping

The bare-metal channels (`edge`, `stable`, `nuttx`) build a toolchain exactly
as before: bare-metal kernel (no Linux headers), newlib (or no libc for
`nuttx`), and **no** uclibc/linux patches. Only the `uclibc` channel uses
Linux kernel headers, uclibc-ng, and the linux-specific patches below.

## crosstool-ng patches

`install-ctng` builds crosstool-ng from a pinned commit. In CI, the patches
in `patches/ct-ng/<version>/` are applied **only for the `uclibc` channel**;
bare-metal channels build stock crosstool-ng. The Makefile derives this
from the selected channel config, so `make install-ctng` alone does the
right thing both in CI and locally:

- `mips: make MMU selectable and support no-MMU linux tuples` — upstream
  crosstool-ng forces MMU on for MIPS, which prevents building the no-MMU
  uclibc static-PIE configuration the SF2000 Linux target needs. This makes
  MIPS MMU support selectable like ARM/RISC-V and teaches the no-MMU kernel
  tuple logic that MIPS uses the plain `linux` tuple.

## Package patches

Target-package patches live in `patches/<package>/<version>/` and are applied
through crosstool-ng's `CT_LOCAL_PATCH_DIR` mechanism:

- `patches/newlib/...` — MIPS fixes for the newlib channels.
- `patches/gcc/16.2.0/0001-mips-support-static-pie-linking.patch` — forwards
  `-static-pie` to `ld` in the MIPS GNU/Linux link spec (needed for the
  no-MMU static-PIE loader). Only the `uclibc` channel's gcc build applies
  it; the bare-metal channels set `CT_GCC_PATCH_ORDER="bundled"` so local
  gcc patches never touch their builds.
- `patches/uClibc-ng/1.0.59/...` — no-MMU static-PIE ELF support for MIPS,
  a `MAP_UNINITIALIZED` fallback, and host-`getconf` guards for the Alpine
  build container (uclibc channel only).

## Building locally

Everything the GitHub workflow does is a Makefile target, so you can
reproduce (and debug) the CI build on your own machine:

```sh
make install-deps-ubuntu          # one-time: host build dependencies
make use-config CONFIG=.config.uclibc   # select a channel config
make ci-validate                  # check the local patches for the libc
make install-ctng                 # crosstool-ng, patched for the channel
make toolchain                    # full toolchain build (~30-40 min)
make pack                         # artifact tarball
```

To reproduce the CI build **exactly** (same `alpine:3.23` container and
commands the workflow runs, catching host-vs-container issues such as
musl-specific failures early), use `docker-ci` instead of the manual
steps above. It selects the channel, then runs the container-side build:

```sh
make docker-ci CONFIG=.config.uclibc
```

This runs the same docker invocation the GitHub workflow uses (the
workflow's "Build and pack toolchain" step is literally `make docker-ci
CONFIG=...`), so what you see locally is what CI runs. Requires docker.

### Chroot-based reproduction (no docker needed)

Environments without docker — including containers that cannot run
containers inside — can reproduce the CI build in an Alpine minirootfs
chroot instead. This runs the **same** `ci-in-container` recipe against
an `alpine:3.23` (musl) environment, so it catches the same
host-vs-container issues as `docker-ci`. Requires root, `wget`, `rsync`
and a `chroot` binary on the host:

```sh
make chroot-init                     # download + extract the Alpine minirootfs
make chroot-ci CONFIG=.config.uclibc # sync repo into the chroot, build, copy artifact out
make chroot-clean                    # remove the chroot (tarball + extraction + workspace)
```

The minirootfs tarball is cached in `.chroot/` (so only the first
`chroot-init` downloads), but the rootfs is re-extracted and the repo
re-synced on every `chroot-ci`, giving docker-like freshness. Caches
(`.ccache`, `.tarballs`) are excluded from the sync, so the chroot flow
keeps its own warm caches across runs inside the chroot workspace.

Useful helpers:

```sh
make -s artifact-name             # the artifact name CI would produce
make -s channel                   # channel, kernel and libc of the config
```

### ccache

Toolchain builds are cached with [ccache](https://ccache.dev) by default
(the build compiles are run through ccache; crosstool-ng itself has no
built-in caching). The cache lives in `.ccache` and is persisted across
CI runs by the workflow, so a release that only changes a patch rebuilds
mostly from cache. Disable with `make USE_CCACHE=n toolchain`.

The cache is self-validating, so it can never serve stale objects:

- `CCACHE_COMPILERCHECK=content` hashes the compiler binaries, so any
  rebuild of gcc/binutils (config, crosstool-ng or gcc patch change)
  invalidates everything compiled with them;
- source and header content is part of every cache key;
- in CI the cache is keyed on the config + patches hash, so any change
  to either starts from a fresh cache.

The Makefile derives everything from the selected config:

- **Channel** from the config file name: `.config.edge` = edge,
  `.config.stable-v1.0.0` = stable, `.config.nuttx` = nuttx,
  `.config.uclibc` = uclibc.

`make use-config` copies the selected source config into the active
`.config` (gitignored), which is the only file crosstool-ng reads — so
local builds never dirty the tracked channel configs.
- **crosstool-ng patches** are applied only for the `uclibc` channel
  (`make install-ctng` builds stock crosstool-ng otherwise).
- **Artifact name** from the channel, host architecture, and the gcc,
  binutils and libc versions in the config.

## GitHub Actions Builds

The workflow is triggered by **creating a GitHub release** (draft or
published) and only calls Makefile targets; there is no workflow-specific
build logic left to drift out of sync:

1. `make use-config CONFIG=<channel config>` — select the channel.
2. `make -s artifact-name` — name the artifact.
3. `make ci-validate` — check the local patches.
4. `make docker-ci CONFIG=<channel config>` — runs the container-side
   build (`ci-in-container`: apk deps, patched/stock crosstool-ng, the
   toolchain build as a non-root `builder` user, and pack) inside the
   same `alpine:3.23` container used by CI.

Artifacts are named with the channel, host architecture, and tool versions
from the channel config, for example:

```
toolchain-edge-static-arm64-gcc16.2.0-binutils2.47-newlib4.6.0.20260123.tar.xz
toolchain-stable-static-arm64-gcc16.2.0-binutils2.47-newlib4.6.0.20260123.tar.xz
toolchain-nuttx-static-arm64-gcc16.2.0-binutils2.47-nolibc.tar.xz
toolchain-uclibc-static-arm64-gcc16.2.0-binutils2.47-uclibc-ng1.0.59.tar.xz
```

Release names include the tag, release channels, and host architectures.

To trigger a build:
- Create a new release in GitHub with tag `vX.Y.Z`.
- The workflow will run and attach artifacts to that release.

## Notes

- The workflow uses `.config` for edge, `.config.stable-v1.0.0` for stable,
  `.config.nuttx` for nuttx, and `.config.uclibc` for the uclibc channel.
- If you change any config, keep it committed so the CI artifacts include
  the correct version strings.
