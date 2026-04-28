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

## GitHub Actions Builds

The workflow builds static Alpine host toolchains and publishes a release with
the artifacts:
- edge Alpine 3.23 x86_64
- edge Alpine 3.23 arm64
- stable Alpine 3.23 x86_64
- stable Alpine 3.23 arm64

The workflow is triggered by **creating a GitHub release** (draft or published).
It uses the release tag for naming.

Artifacts are named with the channel, host architecture, and tool versions from
`.config`, for example:

```
toolchain-edge-static-arm64-gcc15.2.0-binutils2.46.0-newlib4.6.0.20260123.tar.xz
```

Release names include the tag, release channels, and host architectures.

To trigger a build:
- Create a new release in GitHub with tag `vX.Y.Z`.
- The workflow will run and attach artifacts to that release.

## Notes

- The workflow always uses `.config` (no defconfig logic).
- If you change `.config`, keep it committed so the CI artifacts include the
  correct version strings.
