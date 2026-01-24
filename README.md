# frog-toolchain

This repository contains a crosstool-ng configuration and patches to build the
MIPS toolchain used for the SF2000, GB300 and other devices from the frog
family.

## Local build

Requirements (host): crosstool-ng, build-essential, bison, flex, gawk, gperf,
libtool, make, patch, perl, python3, rsync, texinfo, unzip, wget, xz-utils,
zlib1g-dev, and ncurses dev headers.

Build steps:

```sh
ct-ng oldconfig
ct-ng build
```

Output:
- Toolchain is installed under `x-tools/` in this repo.
- Downloaded tarballs are cached in `.tarballs/`.

## GitHub Actions builds

The workflow builds two variants and publishes a release with the artifacts:
- glibc (Ubuntu 22.04)
- musl (Alpine 3.23)

The workflow is triggered by:
- Git tag push matching `v*`, or
- Draft release creation in GitHub (uses the release tag).

Artifacts are named with the OS and tool versions from `.config`, for example:

```
toolchain-ubuntu-22.04-gcc15.2.0-binutils2.45-newlib4.5.0.20241231.tar.xz
```

Release names include the tag and the toolchain versions.

To trigger a build by tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

To trigger a build via draft release:
- Create a new release in GitHub with tag `vX.Y.Z` and check "Draft".
- The workflow will run and attach artifacts to that release.

## Notes

- The workflow always uses `.config` (no defconfig logic).
- If you change `.config`, keep it committed so the CI artifacts include the
  correct version strings.
