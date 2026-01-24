SHELL := /bin/sh

TOPDIR ?= $(CURDIR)
CONFIG ?= .config
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
SUDO ?= sudo
CTNG_VER ?= 1.28.0
CTNG_SRC_DIR ?= $(TOPDIR)/.ctng-src
CTNG_TARBALL ?= $(CTNG_SRC_DIR)/crosstool-ng-$(CTNG_VER).tar.xz
CTNG_URL ?= https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-$(CTNG_VER)/crosstool-ng-$(CTNG_VER).tar.xz

.PHONY: install-deps-ubuntu install-deps-alpine install-ctng-ubuntu \
	ci-prepare oldconfig build toolchain pack

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
		bash \
		bison \
		build-base \
		crosstool-ng \
		file \
		flex \
		gawk \
		git \
		gperf \
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

install-ctng-ubuntu:
	@if command -v ct-ng >/dev/null 2>&1; then \
		ct-ng --version; \
		exit 0; \
	fi
	@mkdir -p $(CTNG_SRC_DIR)
	@wget -q -O $(CTNG_TARBALL) $(CTNG_URL)
	@tar -xf $(CTNG_TARBALL) -C $(CTNG_SRC_DIR)
	@cd $(CTNG_SRC_DIR)/crosstool-ng-$(CTNG_VER) && \
		./configure --prefix=/usr/local && \
		make -j$(JOBS) && \
		$(SUDO) make install
	@ct-ng --version

ci-prepare:
	sed -i \
		-e 's|^CT_LOCAL_TARBALLS_DIR=.*|CT_LOCAL_TARBALLS_DIR="$${CT_TOP_DIR}/.tarballs"|' \
		-e 's|^CT_LOCAL_PATCH_DIR=.*|CT_LOCAL_PATCH_DIR="$${CT_TOP_DIR}/patches"|' \
		-e 's|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR="$${CT_TOP_DIR}/x-tools/$${CT_HOST:+HOST-$${CT_HOST}/}$${CT_TARGET}"|' \
		-e 's/^CT_LOG_PROGRESS_BAR=.*/# CT_LOG_PROGRESS_BAR is not set/' \
		-e "s/^CT_PARALLEL_JOBS=.*/CT_PARALLEL_JOBS=$(JOBS)/" \
		-e "s/^CT_LOAD=.*/CT_LOAD=$(JOBS)/" \
		$(CONFIG)
	grep -q '^CT_LOCAL_PATCH_DIR=' $(CONFIG) || echo 'CT_LOCAL_PATCH_DIR="$${CT_TOP_DIR}/patches"' >> $(CONFIG)
	grep -q '^CT_LOCAL_TARBALLS_DIR=' $(CONFIG) || echo 'CT_LOCAL_TARBALLS_DIR="$${CT_TOP_DIR}/.tarballs"' >> $(CONFIG)
	grep -q '^CT_PREFIX_DIR=' $(CONFIG) || echo 'CT_PREFIX_DIR="$${CT_TOP_DIR}/x-tools/$${CT_HOST:+HOST-$${CT_HOST}/}$${CT_TARGET}"' >> $(CONFIG)
	grep -q '^CT_PARALLEL_JOBS=' $(CONFIG) || echo "CT_PARALLEL_JOBS=$(JOBS)" >> $(CONFIG)
	grep -q '^CT_LOAD=' $(CONFIG) || echo "CT_LOAD=$(JOBS)" >> $(CONFIG)
	grep -q '^# CT_LOG_PROGRESS_BAR is not set' $(CONFIG) || echo '# CT_LOG_PROGRESS_BAR is not set' >> $(CONFIG)
	ct-ng oldconfig

oldconfig:
	ct-ng oldconfig

build:
	ct-ng build

toolchain: ci-prepare build

pack:
	@if [ -z "$(ARTIFACT_NAME)" ]; then \
		echo "ARTIFACT_NAME is required"; \
		exit 2; \
	fi
	tar -C x-tools -cJf "$(ARTIFACT_NAME)" .
