# OpenWrt package for picogit.
#
# Use it from a local feed that points at the openwrt/ directory of this
# source tree, e.g. in the OpenWrt SDK:
#
#   echo "src-link picogit /path/to/picogit/openwrt" >> feeds.conf.default
#   ./scripts/feeds update picogit && ./scripts/feeds install picogit
#   make package/picogit/compile V=s
#
# The package is built from the same sources and pinned dependencies
# (../deps.mk) as the standalone binaries, with the SDK's cross compiler.

include $(TOPDIR)/rules.mk

PKG_NAME:=picogit
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

# The picogit source tree this package directory lives in (openwrt/picogit/).
# realpath follows the feed symlinks back to the real tree.
PICOGIT_SRC ?= $(realpath $(CURDIR)/../..)
include $(PICOGIT_SRC)/deps.mk

include $(INCLUDE_DIR)/package.mk

define Package/picogit
  SECTION:=utils
  CATEGORY:=Utilities
  SUBMENU:=Version Control Systems
  TITLE:=Minimal git client (clone, pull, commit -a, push over HTTP(S))
endef

define Package/picogit/description
  picogit is a small, self-contained git client for embedded devices. It
  supports shallow clone, fast-forward pull, commit -a and push over smart
  HTTP(S) and carries its own TLS stack and CA bundle.
endef

define Download/picogit-lua
  FILE:=$(LUA_TARBALL)
  URL:=$(dir $(LUA_URL))
  HASH:=$(LUA_SHA256)
endef
$(eval $(call Download,picogit-lua))

define Download/picogit-zlib
  FILE:=$(ZLIB_TARBALL)
  URL:=$(dir $(ZLIB_URL))
  HASH:=$(ZLIB_SHA256)
endef
$(eval $(call Download,picogit-zlib))

define Download/picogit-mbedtls
  FILE:=$(MBEDTLS_TARBALL)
  URL:=$(dir $(MBEDTLS_URL))
  HASH:=$(MBEDTLS_SHA256)
endef
$(eval $(call Download,picogit-mbedtls))

define Download/picogit-cacert
  FILE:=$(CACERT_FILE)
  URL:=$(dir $(CACERT_URL))
  HASH:=$(CACERT_SHA256)
endef
$(eval $(call Download,picogit-cacert))

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/dl
	$(CP) $(PICOGIT_SRC)/Makefile $(PICOGIT_SRC)/deps.mk $(PICOGIT_SRC)/LICENSE \
		$(PICOGIT_SRC)/config $(PICOGIT_SRC)/src $(PICOGIT_SRC)/tools $(PKG_BUILD_DIR)/
	$(CP) $(DL_DIR)/$(LUA_TARBALL) $(DL_DIR)/$(ZLIB_TARBALL) \
		$(DL_DIR)/$(MBEDTLS_TARBALL) $(DL_DIR)/$(CACERT_FILE) $(PKG_BUILD_DIR)/dl/
endef

# Lua bytecode is only portable between little-endian targets.
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) cross \
		CC="$(TARGET_CC)" \
		TARGET_CFLAGS="$(TARGET_CFLAGS)" \
		TARGET_LDFLAGS="$(TARGET_LDFLAGS)" \
		HOSTCC="$(HOSTCC)" \
		PYTHON=python3 \
		PICOGIT_VERSION="$(PKG_VERSION)-$(PKG_RELEASE)" \
		EMBED_MODE=$(if $(CONFIG_BIG_ENDIAN),source,bytecode)
endef

define Package/picogit/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/build/cross/picogit $(1)/usr/bin/
endef

$(eval $(call BuildPackage,picogit))
