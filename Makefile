SHELL := /bin/sh

TOPDIR ?= $(CURDIR)
CONFIG ?= .config
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
SUDO ?= sudo
CTNG_VER ?= 1.29.0-rc2
CTNG_REF ?= d7a90ff11aae5e59d6acd8c491f0297c15b7fa37
CTNG_SRC_DIR ?= $(TOPDIR)/.ctng-src
CTNG_GIT_DIR ?= $(CTNG_SRC_DIR)/crosstool-ng
CTNG_TARBALL ?= $(CTNG_SRC_DIR)/crosstool-ng-$(CTNG_REF).tar.gz
CTNG_URL ?= https://github.com/crosstool-ng/crosstool-ng/archive/$(CTNG_REF).tar.gz

.PHONY: install-deps-ubuntu install-deps-alpine install-ctng \
	use-config ci-validate ci-prepare oldconfig build toolchain \
	artifact-name pack channel

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

# use-config stamps the channel into .channel so later targets (artifact-name,
# install-ctng, toolchain, pack) keep working after the config is copied to
# .config, without every invocation having to repeat CONFIG=.
CHANNEL ?= $(shell cat .channel 2>/dev/null || echo $(CONFIG_CHANNEL))

GCC_VERSION      ?= $(shell sed -n 's/^CT_GCC_VERSION="\(.*\)"/\1/p' $(CONFIG))
BINUTILS_VERSION ?= $(shell sed -n 's/^CT_BINUTILS_VERSION="\(.*\)"/\1/p' $(CONFIG))
NEWLIB_VERSION   ?= $(shell sed -n 's/^CT_NEWLIB_VERSION="\(.*\)"/\1/p' $(CONFIG))
UCLIBC_VERSION   ?= $(shell sed -n 's/^CT_UCLIBC_NG_VERSION="\(.*\)"/\1/p' $(CONFIG))
KERNEL           ?= $(shell sed -n 's/^CT_KERNEL="\(.*\)"/\1/p' $(CONFIG))
LIBC             ?= $(shell sed -n 's/^CT_LIBC="\(.*\)"/\1/p' $(CONFIG))

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
	@if [ "$(CONFIG)" != ".config" ]; then cp "$(CONFIG)" .config; fi
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
	ct-ng build

toolchain: ci-prepare build

pack:
	tar -C x-tools -cJf "$(ARTIFACT_NAME)" .
	@echo "Packed $(ARTIFACT_NAME)"
