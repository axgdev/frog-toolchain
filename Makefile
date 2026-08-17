SHELL := /bin/sh

TOPDIR ?= $(CURDIR)
# The selected channel's source config.  use-config materializes it into
# the active .config (gitignored); ct-ng itself only ever reads .config.
CONFIG ?= .config.edge
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
SUDO ?= sudo
ALPINE_IMAGE ?= alpine:3.23
CTNG_VER ?= 1.29.0-rc2
CTNG_REF ?= d7a90ff11aae5e59d6acd8c491f0297c15b7fa37
CTNG_SRC_DIR ?= $(TOPDIR)/.ctng-src
CTNG_GIT_DIR ?= $(CTNG_SRC_DIR)/crosstool-ng
CTNG_TARBALL ?= $(CTNG_SRC_DIR)/crosstool-ng-$(CTNG_REF).tar.gz
CTNG_URL ?= https://github.com/crosstool-ng/crosstool-ng/archive/$(CTNG_REF).tar.gz

# Alpine chroot (docker-less CI reproduction).  CHROOT_DIR holds the
# minirootfs tarball and its extraction; it is gitignored.  Inside the
# chroot the repo lives at /workspace, i.e. CHROOT_WORKSPACE here.
CHROOT_DIR ?= $(TOPDIR)/.chroot
ALPINE_MIRROR ?= https://dl-cdn.alpinelinux.org
ALPINE_RELEASE ?= v3.23
CHROOT_ARCH ?= $(shell uname -m)
CHROOT_ROOTFS ?= $(CHROOT_DIR)/alpine-minirootfs-$(ALPINE_RELEASE)-$(CHROOT_ARCH).tar.gz
CHROOT_WORKSPACE ?= $(CHROOT_DIR)/rootfs/workspace

.PHONY: install-deps-ubuntu install-deps-alpine install-ctng \
	use-config ci-validate ci-prepare oldconfig build toolchain \
	artifact-name pack channel docker-ci ci-in-container \
	chroot-init chroot-ci chroot-clean

# ---------------------------------------------------------------------------
# Channel, versions and artifact naming, derived from the selected config.
# The config file names the channel: .config=edge, .config.stable-v1.0.0=stable,
# .config.nuttx=nuttx, .config.uclibc=uclibc.  Override with CHANNEL=...
# ---------------------------------------------------------------------------
CONFIG_CHANNEL := edge
ifeq ($(CONFIG),.config.stable-v1.0.0)
CONFIG_CHANNEL := stable
endif
ifeq ($(CONFIG),.config.nuttx)
CONFIG_CHANNEL := nuttx
endif
ifeq ($(CONFIG),.config.uclibc)
CONFIG_CHANNEL := uclibc
endif
ifeq ($(CONFIG),.config.edge)
CONFIG_CHANNEL := edge
endif

# use-config stamps the channel into .channel so later targets (artifact-name,
# install-ctng, toolchain, pack) keep working after the config is copied to
# .config, without every invocation having to repeat CONFIG=.
CHANNEL ?= $(shell cat .channel 2>/dev/null || echo $(CONFIG_CHANNEL))

# Versions, kernel and libc are read from the active .config (the file
# crosstool-ng actually builds) once use-config has materialized it,
# falling back to the source CONFIG before the first use-config.
ACTIVE_CONFIG ?= $(shell [ -f .config ] && echo .config || echo $(CONFIG))

GCC_VERSION      ?= $(shell sed -n 's/^CT_GCC_VERSION="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
BINUTILS_VERSION ?= $(shell sed -n 's/^CT_BINUTILS_VERSION="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
NEWLIB_VERSION   ?= $(shell sed -n 's/^CT_NEWLIB_VERSION="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
UCLIBC_VERSION   ?= $(shell sed -n 's/^CT_UCLIBC_NG_VERSION="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
KERNEL           ?= $(shell sed -n 's/^CT_KERNEL="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
LIBC             ?= $(shell sed -n 's/^CT_LIBC="\(.*\)"/\1/p' $(ACTIVE_CONFIG))

# Artifact libc label: newlib channels carry the newlib version, nuttx has
# no libc, uclibc carries the uclibc-ng version.
ifeq ($(NEWLIB_VERSION),)
LIBC_LABEL := nolibc
else
LIBC_LABEL := newlib$(NEWLIB_VERSION)
endif
ifneq ($(UCLIBC_VERSION),)
LIBC_LABEL := uclibc-ng$(UCLIBC_VERSION)
endif

HOST_ARCH ?= $(shell uname -m | sed -e 's/^aarch64$$/arm64/' -e 's/^x86_64$$/x86_64/')

ARTIFACT_NAME ?= toolchain-$(CHANNEL)-static-$(HOST_ARCH)-gcc$(GCC_VERSION)-binutils$(BINUTILS_VERSION)-$(LIBC_LABEL).tar.xz

# Cross compiler prefix (target tuple) as crosstool-ng names the tools,
# e.g. mipsel-mti-elf / mipsel-unknown-linux-uclibc.  crosstool-ng builds
# mips little-endian 32-bit as "mipsel" and appends "-elf" for bare-metal
# or "-linux-uclibc" for the uclibc channel.
ARCH          ?= $(shell sed -n 's/^CT_ARCH="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
TARGET_VENDOR ?= $(shell sed -n 's/^CT_TARGET_VENDOR="\(.*\)"/\1/p' $(ACTIVE_CONFIG))
ifeq ($(KERNEL),linux)
TARGET_PREFIX := $(ARCH)el-$(TARGET_VENDOR)-linux-uclibc
else
TARGET_PREFIX := $(ARCH)el-$(TARGET_VENDOR)-elf
endif

# ---------------------------------------------------------------------------
# ccache (optional, on by default).  Wraps the host and cross compilers so
# repeated toolchain builds reuse compiled objects.  The cache lives in
# .ccache and is persisted across CI runs by the workflow's cache step.
# Disable with: make USE_CCACHE=n toolchain
# ---------------------------------------------------------------------------
# The cache is self-validating, so it can never serve stale objects:
# CCACHE_COMPILERCHECK=content hashes the compiler binary, so rebuilding a
# compiler (config, ct-ng or gcc patch change) invalidates everything built
# with it; source and header content is part of every cache key; and in CI
# the cache is keyed on the config + patches hash, so any of those changes
# starts from a fresh cache.
USE_CCACHE ?= y
CCACHE_DIR ?= $(TOPDIR)/.ccache
CCACHE_MAXSIZE ?= 2G
CCACHE_WRAPPER_DIR ?= $(TOPDIR)/.ccache-bin

# Local patch directory for the selected libc (validated by ci-validate).
PATCH_DIR ?= $(shell if [ -n "$(NEWLIB_VERSION)" ]; then echo newlib/$(NEWLIB_VERSION); \
	elif [ -n "$(UCLIBC_VERSION)" ]; then echo uClibc-ng/$(UCLIBC_VERSION); fi)

# Only the uclibc channel uses the linux/uclibc crosstool-ng patches;
# bare-metal channels build stock crosstool-ng.
ifeq ($(CHANNEL),uclibc)
CTNG_PATCHES ?= $(wildcard patches/ct-ng/$(CTNG_VER)/*.patch)
else
CTNG_PATCHES ?=
endif

install-deps-ubuntu:
	$(SUDO) apt-get update
	$(SUDO) apt-get install -y --no-install-recommends \
		autoconf \
		automake \
		bison \
		build-essential \
		ccache \
		file \
		flex \
		gawk \
		gperf \
		help2man \
		libncurses5-dev \
		libncursesw5-dev \
		libtool \
		libtool-bin \
		make \
		patch \
		perl \
		pkg-config \
		python3 \
		rsync \
		texinfo \
		unzip \
		wget \
		xz-utils \
		zlib1g-dev

install-deps-alpine:
	apk add --no-cache \
		autoconf \
		automake \
		bash \
		bison \
		build-base \
		ccache \
		file \
		flex \
		gawk \
		git \
		gperf \
		help2man \
		libtool \
		make \
		ncurses-dev \
		patch \
		perl \
		python3 \
		rsync \
		texinfo \
		unzip \
		wget \
		xz \
		zlib-dev

install-ctng:
	@mkdir -p $(CTNG_SRC_DIR)
	@wget -q -O $(CTNG_TARBALL) $(CTNG_URL)
	@rm -rf $(CTNG_GIT_DIR)
	@mkdir -p $(CTNG_GIT_DIR)
	@tar -xf $(CTNG_TARBALL) -C $(CTNG_GIT_DIR) --strip-components=1
	@if [ -z "$(CTNG_PATCHES)" ]; then \
		echo "Building stock crosstool-ng (no uclibc/linux patches) for the $(CHANNEL) channel"; \
	else \
		echo "Applying $(words $(CTNG_PATCHES)) crosstool-ng patch(es) for the $(CHANNEL) channel"; \
		for p in $(CTNG_PATCHES); do \
			echo "Applying crosstool-ng patch: $$p"; \
			patch -d $(CTNG_GIT_DIR) -p1 < "$$p" || exit 1; \
		done; \
	fi
	@cd $(CTNG_GIT_DIR) && \
		./bootstrap && \
		./configure --prefix=/usr/local && \
		make -j$(JOBS) && \
		$(SUDO) make install
	@ct-ng version

# Materialize the selected channel config into the active .config and make
# sure the toolchain itself is built static.
use-config:
	@echo "$(CONFIG_CHANNEL)" > .channel
	@cp "$(CONFIG)" .config
	sed -i 's/# CT_STATIC_TOOLCHAIN is not set/CT_STATIC_TOOLCHAIN=y/' .config

# Print the channel, kernel and libc the active config will build.
channel:
	@echo "$(CHANNEL) (kernel=$(KERNEL), libc=$(LIBC))"

# Print the artifact name for the active config (also used by CI to name
# the uploaded artifact).
artifact-name:
	@echo "$(ARTIFACT_NAME)"

# Check that the local patches for the selected libc exist.
ci-validate:
	@if [ -n "$(PATCH_DIR)" ]; then \
		test -d "$(TOPDIR)/patches/$(PATCH_DIR)" || { \
			echo "Missing local patch dir: patches/$(PATCH_DIR)"; exit 1; }; \
		echo "Using local patches from patches/$(PATCH_DIR)"; \
		find "$(TOPDIR)/patches/$(PATCH_DIR)" -maxdepth 1 -type f -name '*.patch' | sort; \
	fi

ci-prepare:
	@echo "Preparing $(CHANNEL) channel: kernel=$(KERNEL), libc=$(LIBC), host=$(HOST_ARCH)"
	sed -i \
		-e 's|^CT_LOCAL_TARBALLS_DIR=.*|CT_LOCAL_TARBALLS_DIR="$${CT_TOP_DIR}/.tarballs"|' \
		-e 's|^CT_LOCAL_PATCH_DIR=.*|CT_LOCAL_PATCH_DIR="$${CT_TOP_DIR}/patches"|' \
		-e 's|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR="$${CT_TOP_DIR}/x-tools/$${CT_HOST:+HOST-$${CT_HOST}/}$${CT_TARGET}"|' \
		-e 's/^CT_LOG_PROGRESS_BAR=.*/# CT_LOG_PROGRESS_BAR is not set/' \
		-e "s/^CT_PARALLEL_JOBS=.*/CT_PARALLEL_JOBS=$(JOBS)/" \
		-e "s/^CT_LOAD=.*/CT_LOAD=\"$(JOBS)\"/" \
		.config
	grep -q '^CT_LOCAL_PATCH_DIR=' .config || echo 'CT_LOCAL_PATCH_DIR="$${CT_TOP_DIR}/patches"' >> .config
	grep -q '^CT_LOCAL_TARBALLS_DIR=' .config || echo 'CT_LOCAL_TARBALLS_DIR="$${CT_TOP_DIR}/.tarballs"' >> .config
	grep -q '^CT_PREFIX_DIR=' .config || echo 'CT_PREFIX_DIR="$${CT_TOP_DIR}/x-tools/$${CT_HOST:+HOST-$${CT_HOST}/}$${CT_TARGET}"' >> .config
	grep -q '^CT_PARALLEL_JOBS=' .config || echo "CT_PARALLEL_JOBS=$(JOBS)" >> .config
	grep -q '^CT_LOAD=' .config || echo "CT_LOAD=\"$(JOBS)\"" >> .config
	grep -q '^# CT_LOG_PROGRESS_BAR is not set' .config || echo '# CT_LOG_PROGRESS_BAR is not set' >> .config
	ct-ng oldconfig

oldconfig:
	ct-ng oldconfig

build:
	@if [ "$(CHANNEL)" = "uclibc" ]; then \
		if ! grep -q "ARCH_SUPPORTS_BOTH_MMU" /usr/local/share/crosstool-ng/config/arch/mips.in 2>/dev/null || \
		   [ ! -d /usr/local/share/crosstool-ng/packages/uClibc-ng/$(UCLIBC_VERSION) ]; then \
			echo "ERROR: the uclibc channel needs the patched crosstool-ng (mips MMU + uClibc-ng/$(UCLIBC_VERSION) patches)."; \
			echo "Run 'make install-ctng' first -- the CI workflow does this in the container."; \
			exit 1; \
		fi; \
	fi
	@if [ "$(USE_CCACHE)" = "y" ] && command -v ccache >/dev/null 2>&1; then \
		echo "Building with ccache (cache: $(CCACHE_DIR), max $(CCACHE_MAXSIZE))"; \
		mkdir -p $(CCACHE_WRAPPER_DIR); \
		for c in gcc g++ cc c++ $(TARGET_PREFIX)-gcc $(TARGET_PREFIX)-g++; do \
			ln -sf "$$(command -v ccache)" "$(CCACHE_WRAPPER_DIR)/$$c"; \
		done; \
		PATH="$(CCACHE_WRAPPER_DIR):$$PATH" \
		CCACHE_DIR="$(CCACHE_DIR)" \
		CCACHE_BASEDIR="$(TOPDIR)" \
		CCACHE_COMPILERCHECK="content" \
		CCACHE_SLOPPINESS="time_macros,file_macro" \
		CCACHE_MAXSIZE="$(CCACHE_MAXSIZE)" \
			ct-ng build; \
	else \
		[ "$(USE_CCACHE)" = "y" ] && \
			echo "ccache not found; building without it (run make install-deps-ubuntu/alpine)"; \
		ct-ng build; \
	fi

toolchain: ci-prepare build

# Build exactly as CI does: run the whole toolchain build inside the same
# alpine container the workflow uses, so a local run reproduces CI (same
# musl host, same packages) and catches host-vs-container issues early.
# Requires docker.  Needs the channel config selected first (use-config).
docker-ci: use-config
	docker run --rm -v "$(TOPDIR):/workspace" -w /workspace $(ALPINE_IMAGE) \
		/bin/sh -c 'apk add --no-cache make && make ci-in-container'

# The container-side half of docker-ci: everything the workflow used to
# inline, in one place.  Runs as root until the actual build, which runs
# as the unprivileged 'builder' user (crosstool-ng refuses to run as root).
ci-in-container:
	make install-deps-alpine
	make install-ctng SUDO=
	adduser -D -h /home/builder builder
	chown -R builder:builder /workspace
	su -s /bin/sh builder -c 'make toolchain'
	make pack

# Set up an Alpine minirootfs chroot for docker-less CI reproduction.
# Needs root, wget and rsync on the host.  The rootfs is re-extracted
# every run (docker-like freshness); the downloaded tarball is cached.
chroot-init:
	@[ "$$(id -u)" = "0" ] || { echo "ERROR: chroot-init needs root"; exit 1; }
	@command -v wget >/dev/null 2>&1 || { echo "ERROR: wget is required"; exit 1; }
	@command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync is required"; exit 1; }
	@mkdir -p $(CHROOT_DIR)
	@if [ ! -f "$(CHROOT_ROOTFS)" ]; then \
		echo "Downloading Alpine $(ALPINE_RELEASE) minirootfs for $(CHROOT_ARCH)"; \
		name=$$(wget -qO- "$(ALPINE_MIRROR)/alpine/$(ALPINE_RELEASE)/releases/$(CHROOT_ARCH)/" \
			| grep -oE 'alpine-minirootfs-[0-9.]+-$(CHROOT_ARCH)\.tar\.gz' | sort -V | tail -1); \
		[ -n "$$name" ] || { echo "ERROR: no minirootfs found for $(CHROOT_ARCH)"; exit 1; }; \
		wget -qO "$(CHROOT_ROOTFS)" "$(ALPINE_MIRROR)/alpine/$(ALPINE_RELEASE)/releases/$(CHROOT_ARCH)/$$name"; \
	fi
	@rm -rf $(CHROOT_DIR)/rootfs
	@mkdir -p $(CHROOT_DIR)/rootfs
	@tar -xf "$(CHROOT_ROOTFS)" -C $(CHROOT_DIR)/rootfs
	@cp /etc/resolv.conf $(CHROOT_DIR)/rootfs/etc/resolv.conf
	@# The minirootfs ships without device nodes; create the ones the
	@# toolchain build needs (null, zero, urandom, tty).
	@rm -f $(CHROOT_DIR)/rootfs/dev/null $(CHROOT_DIR)/rootfs/dev/zero \
		$(CHROOT_DIR)/rootfs/dev/urandom $(CHROOT_DIR)/rootfs/dev/tty
	@mknod -m 666 $(CHROOT_DIR)/rootfs/dev/null c 1 3
	@mknod -m 666 $(CHROOT_DIR)/rootfs/dev/zero c 1 5
	@mknod -m 666 $(CHROOT_DIR)/rootfs/dev/urandom c 1 9
	@mknod -m 666 $(CHROOT_DIR)/rootfs/dev/tty c 5 0
	@echo "Alpine chroot ready at $(CHROOT_DIR)/rootfs"

# Reproduce the CI build in the Alpine chroot instead of docker: same
# ci-in-container recipe, same alpine:3.23 (musl) environment.  The repo
# is rsynced into the chroot (caches excluded, so each flow keeps its own
# .ccache/.tarballs), the build runs, and the artifact is copied back out.
chroot-ci: use-config chroot-init
	@[ "$$(id -u)" = "0" ] || { echo "ERROR: chroot-ci needs root"; exit 1; }
	@command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync is required"; exit 1; }
	@echo "Syncing the repository into the chroot..."
	@mkdir -p $(CHROOT_WORKSPACE)
	@rsync -a --delete \
		--exclude=.git --exclude=.chroot --exclude=.build --exclude=x-tools \
		--exclude=.ctng-src --exclude=.ccache-bin --exclude=.tarballs \
		--exclude=.ccache \
		"$(TOPDIR)/" "$(CHROOT_WORKSPACE)/"
	@chroot $(CHROOT_DIR)/rootfs /bin/sh -c \
		'apk add --no-cache make && cd /workspace && make ci-in-container'
	@if [ -f "$(CHROOT_WORKSPACE)/$(ARTIFACT_NAME)" ]; then \
		echo "Copying artifact out of the chroot"; \
		cp "$(CHROOT_WORKSPACE)/$(ARTIFACT_NAME)" "$(TOPDIR)/$(ARTIFACT_NAME)"; \
	fi

# Remove the chroot (minirootfs tarball + extraction + workspace).
chroot-clean:
	rm -rf $(CHROOT_DIR)
	@echo "Removed $(CHROOT_DIR)"

pack:
	tar -C x-tools -cJf "$(ARTIFACT_NAME)" .
	@echo "Packed $(ARTIFACT_NAME)"
