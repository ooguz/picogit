#
# Copyright (C) 2026 Özcan Oğuz <ozcan@oyd.org.tr>
#

include $(TOPDIR)/rules.mk

PKG_NAME:=picogit
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=https://github.com/ooguz/picogit/releases/download/v$(PKG_VERSION)
PKG_HASH:=e77ca31d4482f396f74312a15a04530fbeff96c0c58137e8a532b012417aad5f

PKG_MAINTAINER:=Özcan Oğuz <ozcan@oyd.org.tr>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

# picogit links the system's Mbed TLS and zlib and uses ca-bundle; Lua 5.4,
# which OpenWrt does not ship, is downloaded separately and built in.
PICOGIT_LUA_VERSION:=5.4.9
PICOGIT_LUA_HASH:=2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/picogit
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Version Control Systems
  TITLE:=Minimal git client (clone, pull, commit -a, push over HTTPS)
  URL:=https://github.com/ooguz/picogit
  DEPENDS:=+libmbedtls +zlib +ca-bundle
endef

define Package/picogit/description
  picogit is a small git client for routers. It can make shallow clones,
  fast-forward pulls, commit the whole work tree (commit -a) and push over
  smart HTTP(S). The repositories it creates are regular git repositories.
endef

define Download/picogit-lua
  FILE:=lua-$(PICOGIT_LUA_VERSION).tar.gz
  URL:=https://www.lua.org/ftp/
  HASH:=$(PICOGIT_LUA_HASH)
endef
$(eval $(call Download,picogit-lua))

define Build/Prepare
	$(call Build/Prepare/Default)
	mkdir -p $(PKG_BUILD_DIR)/dl
	$(CP) $(DL_DIR)/lua-$(PICOGIT_LUA_VERSION).tar.gz $(PKG_BUILD_DIR)/dl/
endef

# Lua bytecode is only portable between little-endian targets.
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) cross \
		SYSTEM_LIBS=1 \
		CC="$(TARGET_CC)" \
		TARGET_CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
		TARGET_LDFLAGS="$(TARGET_LDFLAGS)" \
		HOSTCC="$(HOSTCC)" \
		PICOGIT_VERSION="$(PKG_VERSION)" \
		EMBED_MODE=$(if $(CONFIG_BIG_ENDIAN),source,bytecode)
endef

define Package/picogit/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/build/cross/picogit $(1)/usr/bin/
endef

$(eval $(call BuildPackage,picogit))
