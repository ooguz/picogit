# Pinned third-party sources. Every download is verified against SHA256
# before use; bump version and checksum together.

ZIG_VERSION     := 0.16.0
ZIG_TARBALL     := zig-x86_64-linux-$(ZIG_VERSION).tar.xz
ZIG_URL         := https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_TARBALL)
ZIG_SHA256      := 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

LUA_VERSION     := 5.4.9
LUA_TARBALL     := lua-$(LUA_VERSION).tar.gz
LUA_URL         := https://www.lua.org/ftp/$(LUA_TARBALL)
LUA_SHA256      := 2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6

ZLIB_VERSION    := 1.3.2
ZLIB_TARBALL    := zlib-$(ZLIB_VERSION).tar.gz
ZLIB_URL        := https://github.com/madler/zlib/releases/download/v$(ZLIB_VERSION)/$(ZLIB_TARBALL)
ZLIB_SHA256     := bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16

MBEDTLS_VERSION := 3.6.7
MBEDTLS_TARBALL := mbedtls-$(MBEDTLS_VERSION).tar.bz2
MBEDTLS_URL     := https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$(MBEDTLS_VERSION)/$(MBEDTLS_TARBALL)
MBEDTLS_SHA256  := a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6

# Mozilla CA list as extracted by the curl project.
CACERT_DATE     := 2026-09-25
CACERT_FILE     := cacert-$(CACERT_DATE).pem
CACERT_URL      := https://curl.se/ca/$(CACERT_FILE)
CACERT_SHA256   := a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
