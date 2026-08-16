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

`edge` is built from `.config` (newlib, bare-metal). `stable` is built from
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

## crosstool-ng patches

`install-ctng` builds crosstool-ng from a pinned commit and applies the
patches in `patches/ct-ng/<version>/` first:

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
  no-MMU static-PIE loader).
- `patches/uClibc-ng/1.0.59/...` — no-MMU static-PIE ELF support for MIPS,
  a `MAP_UNINITIALIZED` fallback, and host-`getconf` guards for the Alpine
  build container.

## GitHub Actions Builds

The workflow is triggered by **creating a GitHub release** (draft or
published). It uses the release tag for naming.

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
