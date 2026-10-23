# picogit - minimal git client for embedded devices
#
#   make host       x86_64 static musl build (development / tests)
#   make armv7      ARMv7-A, static musl, soft-float ABI (default router build)
#   make armv7hf    ARMv7-A, static musl, hard-float (VFPv3-D16)
#   make aarch64    AArch64, static musl
#   make mipsel     MIPS32r2 little-endian, static musl, soft-float
#   make mips       MIPS32r2 big-endian (e.g. OpenWrt ath79), soft-float
#   make x86        32-bit x86 (i586 baseline), static musl
#   make riscv64    RISC-V 64 (rv64gc, lp64d), static musl
#   make cross CC=... any other target with an external cross compiler
#                   (used by the OpenWrt package, see openwrt/picogit/Makefile)
#   make test       unit + integration tests with the host binary
#   make test-armv7 the same tests with the armv7 binary under qemu-arm
#   make test-qemu-<target>  the same for any other target (e.g. riscv64)
#
# Toolchain: a pinned zig release (downloaded on first use) is used as
# `zig cc`.  Any other cross compiler can be used instead with
#   make armv7 CC=arm-linux-musleabi-gcc TARGET_CFLAGS="-march=armv7-a -mfloat-abi=soft -mthumb"
# or, for targets without a predefined name,
#   make cross CC=mips-linux-musl-gcc TARGET_CFLAGS="-march=mips32r2" EMBED_MODE=source

TOP := $(abspath .)
include $(TOP)/deps.mk

DL       := $(TOP)/dl
BUILD    := $(TOP)/build
SRCROOT  := $(BUILD)/src
TOOLDIR  := $(TOP)/.cache/toolchain
ZIG_DIR  := $(TOOLDIR)/zig-x86_64-linux-$(ZIG_VERSION)
ZIG      := $(ZIG_DIR)/zig
HOSTCC   ?= cc
PYTHON   ?= python3

# Version: from git, or from VERSION in a source tarball made by `make dist`
# (git archive substitutes it), else "unknown".
PICOGIT_VERSION := $(or $(shell git -C $(TOP) describe --tags --always --dirty 2>/dev/null),$(shell grep -v Format $(TOP)/VERSION 2>/dev/null),unknown)
PICOGIT_VERSION := $(patsubst v%,%,$(PICOGIT_VERSION))

LUA_SRC     := $(SRCROOT)/lua-$(LUA_VERSION)
ZLIB_SRC    := $(SRCROOT)/zlib-$(ZLIB_VERSION)
MBEDTLS_SRC := $(SRCROOT)/mbedtls-$(MBEDTLS_VERSION)
STAMP_SRC   := $(SRCROOT)/.stamp-$(LUA_VERSION)-$(ZLIB_VERSION)-$(MBEDTLS_VERSION)$(if $(filter 1,$(SYSTEM_LIBS)),-sys)
HOSTLUA     := $(BUILD)/hostlua/lua

# 1 = use the system's Mbed TLS, zlib and CA store (see the target section)
SYSTEM_LIBS   ?= 0
SYSTEM_CAFILE ?= /etc/ssl/certs/ca-certificates.crt

export ZIG_GLOBAL_CACHE_DIR := $(BUILD)/zig-cache
export ZIG_LOCAL_CACHE_DIR  := $(BUILD)/zig-cache

ALL_TARGETS := host armv7 armv7hf aarch64 mipsel mips x86 riscv64

# (dist is declared next to its rule)
# check-size, dist: declared next to their rules
.PHONY: all $(ALL_TARGETS) test test-unit test-integration test-armv7 test-oldkernel test-https test-https-armv7 \
        sizes fetch clean distclean binary
all: host

ifeq ($(origin CC),default)
PREREQ_CC := $(ZIG)
endif

# With SYSTEM_LIBS=1 (see below) only the Lua sources are needed.
ifeq ($(SYSTEM_LIBS),1)
SRC_TARBALLS := $(DL)/$(LUA_TARBALL)
CA_PREREQ    :=
else
SRC_TARBALLS := $(DL)/$(LUA_TARBALL) $(DL)/$(ZLIB_TARBALL) $(DL)/$(MBEDTLS_TARBALL)
CA_PREREQ    := $(DL)/$(CACERT_FILE)
endif

# Sources must be extracted before the per-target make reads the mbedTLS
# file list, hence the recursion.
$(ALL_TARGETS): $(STAMP_SRC) $(HOSTLUA) $(CA_PREREQ) $(PREREQ_CC)
	@$(MAKE) --no-print-directory TARGET=$@ binary

.PHONY: cross
cross: $(STAMP_SRC) $(HOSTLUA) $(CA_PREREQ)
	@$(MAKE) --no-print-directory TARGET=cross binary

# ---------------------------------------------------------------------------
# Downloads (verified) and source extraction

define download
$(DL)/$(2):
	@mkdir -p $(DL)
	@echo "  FETCH   $(2)"
	@curl -fsSL --retry 3 -o $$@.part $(1)
	@echo "$(3)  $$@.part" | sha256sum -c --quiet - || { echo "checksum mismatch: $(2)"; rm -f $$@.part; exit 1; }
	@mv $$@.part $$@
endef
$(eval $(call download,$(ZIG_URL),$(ZIG_TARBALL),$(ZIG_SHA256)))
$(eval $(call download,$(LUA_URL),$(LUA_TARBALL),$(LUA_SHA256)))
$(eval $(call download,$(ZLIB_URL),$(ZLIB_TARBALL),$(ZLIB_SHA256)))
$(eval $(call download,$(MBEDTLS_URL),$(MBEDTLS_TARBALL),$(MBEDTLS_SHA256)))
$(eval $(call download,$(CACERT_URL),$(CACERT_FILE),$(CACERT_SHA256)))

fetch: $(DL)/$(ZIG_TARBALL) $(DL)/$(LUA_TARBALL) $(DL)/$(ZLIB_TARBALL) \
       $(DL)/$(MBEDTLS_TARBALL) $(DL)/$(CACERT_FILE)

# Re-check every file already in dl/ (e.g. restored from a CI cache)
# against deps.mk; a mismatching file is deleted.
.PHONY: verify-downloads
verify-downloads:
	@cd $(DL) 2>/dev/null || exit 0; \
	for pair in $(ZIG_TARBALL)=$(ZIG_SHA256) $(LUA_TARBALL)=$(LUA_SHA256) \
	            $(ZLIB_TARBALL)=$(ZLIB_SHA256) $(MBEDTLS_TARBALL)=$(MBEDTLS_SHA256) \
	            $(CACERT_FILE)=$(CACERT_SHA256); do \
	    f=$${pair%%=*}; h=$${pair#*=}; [ -f "$$f" ] || continue; \
	    if echo "$$h  $$f" | sha256sum -c --quiet - >/dev/null 2>&1; then echo "  OK      $$f"; \
	    else echo "  BAD     $$f (removed)"; rm -f "$$f"; fi; \
	done

$(ZIG): $(DL)/$(ZIG_TARBALL)
	@mkdir -p $(TOOLDIR)
	@echo "  UNPACK  $(notdir $<)"
	@tar -C $(TOOLDIR) -xf $<
	@touch $@

$(STAMP_SRC): $(SRC_TARBALLS)
	@mkdir -p $(SRCROOT)
	@echo "  UNPACK  $(notdir $^)"
	@rm -rf $(LUA_SRC) $(ZLIB_SRC) $(MBEDTLS_SRC)
	@for f in $^; do tar -C $(SRCROOT) -xf $$f || exit 1; done
	@touch $@

# A native Lua interpreter, used at build time to precompile the embedded
# Lua modules to bytecode.
$(HOSTLUA): $(STAMP_SRC)
	@mkdir -p $(dir $@)
	@echo "  HOSTCC  lua"
	@$(HOSTCC) -O2 -DLUA_USE_POSIX -o $@ \
	    $(filter-out $(LUA_SRC)/src/luac.c,$(wildcard $(LUA_SRC)/src/*.c)) -lm

# ---------------------------------------------------------------------------
# Per-target build (invoked recursively with TARGET=...)

ifneq ($(TARGET),)

# Bytecode is portable between little-endian targets with 64-bit
# lua_Integer/lua_Number; big-endian targets would need EMBED_MODE=source.
EMBED_MODE ?= bytecode

ifeq ($(TARGET),host)
  ZTARGET := x86_64-linux-musl
  ZCPU    :=
else ifeq ($(TARGET),armv7)
  # Explicitly strip every FPU feature: zig's generic v7a CPU otherwise
  # tags the binary as VFPv3.
  ZTARGET := arm-linux-musleabi
  ZCPU    := -mcpu=generic+v7a-vfp2-vfp3-vfp4-neon-d32-fp64-fp16-fpregs -mthumb
else ifeq ($(TARGET),armv7hf)
  # VFPv3-D16 without NEON: the lowest common FPU of BCM470x Cortex-A9.
  ZTARGET := arm-linux-musleabihf
  ZCPU    := -mcpu=generic+v7a+vfp3d16-neon -mthumb
else ifeq ($(TARGET),aarch64)
  ZTARGET := aarch64-linux-musl
  ZCPU    :=
else ifeq ($(TARGET),mipsel)
  ZTARGET := mipsel-linux-musleabi
  ZCPU    := -mcpu=mips32r2
else ifeq ($(TARGET),mips)
  ZTARGET := mips-linux-musleabi
  ZCPU    := -mcpu=mips32r2
  EMBED_MODE := source
else ifeq ($(TARGET),x86)
  # i586: also runs on old x86 boards (Geode, Vortex86 class) without cmov
  ZTARGET := x86-linux-musl
  ZCPU    := -mcpu=i586
else ifeq ($(TARGET),riscv64)
  ZTARGET := riscv64-linux-musl
  ZCPU    := -mcpu=baseline_rv64
else ifeq ($(TARGET),cross)
  ifeq ($(origin CC),default)
    $(error TARGET=cross needs an external compiler: make cross CC=...)
  endif
else
  $(error unknown TARGET '$(TARGET)'; use one of: $(ALL_TARGETS))
endif

ifeq ($(origin CC),default)
  CC := $(ZIG) cc -target $(ZTARGET) $(ZCPU)
endif

OUT := $(BUILD)/$(TARGET)
OBJ := $(OUT)/obj

OPTFLAGS ?= -Os
CFLAGS_COMMON := $(OPTFLAGS) -ffunction-sections -fdata-sections \
    -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector \
    $(TARGET_CFLAGS)
LDFLAGS_COMMON := -static -Wl,--gc-sections -s $(TARGET_LDFLAGS)

LUA_CFLAGS     := $(CFLAGS_COMMON) -DLUA_USE_POSIX -w
ZLIB_CFLAGS    := $(CFLAGS_COMMON) -DHAVE_UNISTD_H -w
MBEDTLS_CFLAGS := $(CFLAGS_COMMON) -I$(MBEDTLS_SRC)/include -I$(TOP)/config \
    -DMBEDTLS_CONFIG_FILE='"pg_mbedtls_config.h"' -w
PG_CFLAGS      := $(CFLAGS_COMMON) -std=c99 -D_GNU_SOURCE -Wall -Wextra \
    -Wno-unused-parameter -I$(LUA_SRC)/src -I$(ZLIB_SRC) -I$(MBEDTLS_SRC)/include \
    -I$(TOP)/config -I$(TOP)/src/c -DMBEDTLS_CONFIG_FILE='"pg_mbedtls_config.h"' \
    -DPICOGIT_VERSION='"$(PICOGIT_VERSION)"' -DPICOGIT_CA_DATE='"$(CACERT_DATE)"'

LUA_CORE := lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject \
    lopcodes lparser lstate lstring ltable ltm lundump lvm lzio lauxlib \
    lbaselib lcorolib ldblib liolib lmathlib loadlib loslib lstrlib ltablib \
    lutf8lib
ZLIB_CORE := adler32 compress crc32 deflate inflate inffast inftrees trees uncompr zutil
MBEDTLS_CORE := $(basename $(notdir $(wildcard $(MBEDTLS_SRC)/library/*.c)))
PG_CORE := core zlib_bind sha1_bind fs http rand

LUA_MODULES := $(sort $(wildcard $(TOP)/src/lua/*.lua))

LUA_OBJS     := $(addprefix $(OBJ)/lua/,$(addsuffix .o,$(LUA_CORE)))
ZLIB_OBJS    := $(addprefix $(OBJ)/zlib/,$(addsuffix .o,$(ZLIB_CORE)))
MBEDTLS_OBJS := $(addprefix $(OBJ)/mbedtls/,$(addsuffix .o,$(MBEDTLS_CORE)))
PG_OBJS      := $(addprefix $(OBJ)/pg/,$(addsuffix .o,$(PG_CORE))) \
    $(OBJ)/gen/embedded_lua.o $(OBJ)/gen/cabundle.o
LIB_OBJS     := $(LUA_OBJS) $(ZLIB_OBJS) $(MBEDTLS_OBJS) $(PG_OBJS)
LDLIBS       := -lm

# SYSTEM_LIBS=1: link Mbed TLS and zlib from the system (dynamically) and
# use the system CA store instead of embedding one. Lua is still built in.
# This is how distributions such as OpenWrt want packages built, so that
# security fixes in the libraries reach picogit without a rebuild.
ifeq ($(SYSTEM_LIBS),1)
  LDFLAGS_COMMON := -Wl,--gc-sections -s $(TARGET_LDFLAGS)
  PG_CFLAGS := $(CFLAGS_COMMON) -std=c99 -D_GNU_SOURCE -Wall -Wextra \
      -Wno-unused-parameter -I$(LUA_SRC)/src -I$(TOP)/src/c \
      -DPICOGIT_VERSION='"$(PICOGIT_VERSION)"' -DPICOGIT_CA_DATE='"$(CACERT_DATE)"' \
      -DPICOGIT_SYSTEM_CA='"$(SYSTEM_CAFILE)"'
  PG_OBJS  := $(filter-out $(OBJ)/gen/cabundle.o,$(PG_OBJS))
  LIB_OBJS := $(LUA_OBJS) $(PG_OBJS)
  LDLIBS   := -lmbedtls -lmbedx509 -lmbedcrypto -lz -lm
endif

binary: $(OUT)/picogit $(OUT)/picogit-dev
	@printf "  SIZE    %-28s %8d bytes\n" "$(TARGET)/picogit" $$(stat -c %s $(OUT)/picogit)

$(OUT)/picogit: $(OBJ)/pg/main.o $(LIB_OBJS)
	@echo "  LD      $(TARGET)/picogit"
	@$(CC) $(CFLAGS_COMMON) $(LDFLAGS_COMMON) -o $@ $(OBJ)/pg/main.o $(LIB_OBJS) $(LDLIBS)

$(OUT)/picogit-dev: $(OBJ)/pg/main-dev.o $(LIB_OBJS)
	@echo "  LD      $(TARGET)/picogit-dev"
	@$(CC) $(CFLAGS_COMMON) $(LDFLAGS_COMMON) -o $@ $(OBJ)/pg/main-dev.o $(LIB_OBJS) $(LDLIBS)

$(OBJ)/lua/%.o: $(LUA_SRC)/src/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      lua/$*"
	@$(CC) $(LUA_CFLAGS) -c -o $@ $<

$(OBJ)/zlib/%.o: $(ZLIB_SRC)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      zlib/$*"
	@$(CC) $(ZLIB_CFLAGS) -c -o $@ $<

$(OBJ)/mbedtls/%.o: $(MBEDTLS_SRC)/library/%.c $(TOP)/config/pg_mbedtls_config.h
	@mkdir -p $(dir $@)
	@echo "  CC      mbedtls/$*"
	@$(CC) $(MBEDTLS_CFLAGS) -c -o $@ $<

$(OBJ)/pg/%.o: $(TOP)/src/c/%.c $(wildcard $(TOP)/src/c/*.h) $(TOP)/config/pg_mbedtls_config.h
	@mkdir -p $(dir $@)
	@echo "  CC      $*"
	@$(CC) $(PG_CFLAGS) -c -o $@ $<

$(OBJ)/pg/main-dev.o: $(TOP)/src/c/main.c $(wildcard $(TOP)/src/c/*.h)
	@mkdir -p $(dir $@)
	@echo "  CC      main (dev)"
	@$(CC) $(PG_CFLAGS) -DPICOGIT_DEV -c -o $@ $<

$(OBJ)/gen/embedded_lua.c: $(LUA_MODULES) $(TOP)/tools/embed.lua
	@mkdir -p $(dir $@)
	@echo "  EMBED   $(words $(LUA_MODULES)) lua modules ($(EMBED_MODE))"
	@$(HOSTLUA) $(TOP)/tools/embed.lua $(EMBED_MODE) $@ $(LUA_MODULES)

$(OBJ)/gen/cabundle.c: $(DL)/$(CACERT_FILE) $(TOP)/tools/mkcabundle.py
	@mkdir -p $(dir $@)
	@echo "  CABUNDLE $(CACERT_FILE)"
	@$(PYTHON) -I $(TOP)/tools/mkcabundle.py $< $@

$(OBJ)/gen/%.o: $(OBJ)/gen/%.c
	@echo "  CC      gen/$*"
	@$(CC) $(PG_CFLAGS) -c -o $@ $<

endif # TARGET

# ---------------------------------------------------------------------------
# Tests

QEMU_ARM ?= $(shell command -v qemu-arm-static || command -v qemu-arm)

test: host
	@$(MAKE) --no-print-directory test-unit test-integration

test-unit:
	@PICOGIT_DEV_BIN="$(PICOGIT_RUN) $(or $(PICOGIT_DEV_BIN),$(BUILD)/host/picogit-dev)" \
	    sh $(TOP)/test/unit/run.sh

test-integration:
	@PICOGIT="$(PICOGIT_RUN) $(or $(PICOGIT_BIN),$(BUILD)/host/picogit)" \
	    PICOGIT_DEV="$(PICOGIT_RUN) $(or $(PICOGIT_DEV_BIN),$(BUILD)/host/picogit-dev)" \
	    bash $(TOP)/test/integration/run.sh

# Runs the armv7 binaries under qemu-arm, by default on a Cortex-A9 model
# with the FPU removed: any VFP/NEON instruction in the soft-float build
# would die with SIGILL. Without a local qemu the tests run inside the
# Docker image defined in ./Dockerfile.
QEMU_CPU ?= cortex-a9,vfp=off,vfp-d32=off,neon=off

test-armv7: armv7
ifneq ($(QEMU_ARM),)
	@QEMU_CPU="$(QEMU_CPU)" $(MAKE) --no-print-directory test-unit test-integration PICOGIT_RUN=$(QEMU_ARM) \
	    PICOGIT_BIN=$(BUILD)/armv7/picogit PICOGIT_DEV_BIN=$(BUILD)/armv7/picogit-dev
else
	docker build -q -t picogit-test -f $(TOP)/Dockerfile --target test $(TOP)
	docker run --rm -v $(TOP):/src -w /src -u $$(id -u):$$(id -g) -e HOME=/tmp \
	    -e QEMU_CPU="$(QEMU_CPU)" picogit-test \
	    make --no-print-directory test-unit test-integration PICOGIT_RUN=qemu-arm \
	    PICOGIT_BIN=/src/build/armv7/picogit PICOGIT_DEV_BIN=/src/build/armv7/picogit-dev
endif

# The armv7 tests again with getrandom(2) failing with ENOSYS, as on
# kernels older than 3.17 (see test/oldkernel/enosys.c).
ENOSYS := $(BUILD)/tools/enosys
$(ENOSYS): $(TOP)/test/oldkernel/enosys.c $(PREREQ_CC)
	@mkdir -p $(dir $@)
	@echo "  CC      enosys"
	@$(if $(PREREQ_CC),$(ZIG) cc -target x86_64-linux-musl,$(HOSTCC)) -static -Os -o $@ $<

test-oldkernel: armv7 $(ENOSYS)
ifneq ($(QEMU_ARM),)
	@QEMU_CPU="$(QEMU_CPU)" $(MAKE) --no-print-directory test-unit test-integration \
	    PICOGIT_RUN="$(ENOSYS) $(QEMU_ARM)" \
	    PICOGIT_BIN=$(BUILD)/armv7/picogit PICOGIT_DEV_BIN=$(BUILD)/armv7/picogit-dev
else
	docker build -q -t picogit-test -f $(TOP)/Dockerfile --target test $(TOP)
	docker run --rm -v $(TOP):/src -w /src -u $$(id -u):$$(id -g) -e HOME=/tmp \
	    -e QEMU_CPU="$(QEMU_CPU)" picogit-test \
	    make --no-print-directory test-unit test-integration \
	    PICOGIT_RUN="/src/build/tools/enosys qemu-arm" \
	    PICOGIT_BIN=/src/build/armv7/picogit PICOGIT_DEV_BIN=/src/build/armv7/picogit-dev
endif

# Any other target under its qemu-user emulator, e.g. make test-qemu-riscv64
# (locally if the emulator is installed, otherwise in the Docker image).
QEMU_armv7hf := qemu-arm
QEMU_aarch64 := qemu-aarch64
QEMU_mipsel  := qemu-mipsel
QEMU_mips    := qemu-mips
QEMU_x86     := qemu-i386
QEMU_riscv64 := qemu-riscv64
# CPU models without newer instructions, to prove the baseline holds
QEMU_CPU_x86 := pentium

test-qemu-%: %
	@[ -n "$(QEMU_$*)" ] || { echo "no qemu emulator known for '$*'"; exit 1; }
	@if command -v $(QEMU_$*) >/dev/null; then \
	    $(if $(QEMU_CPU_$*),QEMU_CPU=$(QEMU_CPU_$*)) \
	    $(MAKE) --no-print-directory test-unit test-integration PICOGIT_RUN=$(QEMU_$*) \
	        PICOGIT_BIN=$(BUILD)/$*/picogit PICOGIT_DEV_BIN=$(BUILD)/$*/picogit-dev; \
	else \
	    docker build -q -t picogit-test -f $(TOP)/Dockerfile --target test $(TOP) >/dev/null && \
	    docker run --rm -v $(TOP):/src -w /src -u $$(id -u):$$(id -g) -e HOME=/tmp \
	        $(if $(QEMU_CPU_$*),-e QEMU_CPU=$(QEMU_CPU_$*)) picogit-test \
	        make --no-print-directory test-unit test-integration PICOGIT_RUN=$(QEMU_$*) \
	        PICOGIT_BIN=/src/build/$*/picogit PICOGIT_DEV_BIN=/src/build/$*/picogit-dev; \
	fi

# Clones a public repository over HTTPS with the embedded CA bundle.
test-https: host
	@PICOGIT="$(PICOGIT_RUN) $(or $(PICOGIT_BIN),$(BUILD)/host/picogit)" \
	    bash $(TOP)/test/integration/https.sh

test-https-armv7: armv7
	docker build -q -t picogit-test -f $(TOP)/Dockerfile --target test $(TOP)
	docker run --rm -v $(TOP):/src -w /src -u $$(id -u):$$(id -g) -e HOME=/tmp \
	    -e QEMU_CPU="$(QEMU_CPU)" picogit-test \
	    env PICOGIT="qemu-arm /src/build/armv7/picogit" bash test/integration/https.sh

# Reproducible source tarballs of HEAD; the OpenWrt package downloads the
# .tar.xz (the feed prefers the smallest archive):
#   make dist  ->  dist/picogit-<version>.tar.{gz,xz}
DIST_NAME := picogit-$(PICOGIT_VERSION)
.PHONY: dist
dist:
	@mkdir -p $(TOP)/dist
	@git -C $(TOP) archive --format=tar --prefix=$(DIST_NAME)/ HEAD > $(TOP)/dist/$(DIST_NAME).tar
	@gzip -9n < $(TOP)/dist/$(DIST_NAME).tar > $(TOP)/dist/$(DIST_NAME).tar.gz
	@xz -9 -T1 < $(TOP)/dist/$(DIST_NAME).tar > $(TOP)/dist/$(DIST_NAME).tar.xz
	@rm $(TOP)/dist/$(DIST_NAME).tar
	@cd $(TOP)/dist && sha256sum $(DIST_NAME).tar.gz $(DIST_NAME).tar.xz

# Size budget: every self-contained binary must stay below 1 MiB.
SIZE_LIMIT ?= 1048576

sizes:
	@for t in $(ALL_TARGETS); do f=$(BUILD)/$$t/picogit; \
	    [ -f $$f ] && printf "%-10s %8d bytes  %3d%% of budget\n" $$t $$(stat -c %s $$f) \
	        $$(( $$(stat -c %s $$f) * 100 / $(SIZE_LIMIT) )); done; true

.PHONY: check-size
check-size:
	@fail=0; n=0; for t in $(ALL_TARGETS); do f=$(BUILD)/$$t/picogit; [ -f $$f ] || continue; \
	    n=$$((n+1)); sz=$$(stat -c %s $$f); \
	    if [ $$sz -ge $(SIZE_LIMIT) ]; then echo "  OVER    $$t: $$sz bytes >= $(SIZE_LIMIT)"; fail=1; fi; \
	done; [ $$n -gt 0 ] || { echo "no binaries built"; exit 1; }; \
	[ $$fail = 0 ] && echo "  SIZE    $$n binaries below $(SIZE_LIMIT) bytes"; exit $$fail

clean:
	rm -rf $(addprefix $(BUILD)/,$(ALL_TARGETS)) $(BUILD)/hostlua

distclean:
	rm -rf $(BUILD) $(DL) $(TOP)/.cache
