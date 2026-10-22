#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks that openwrt/picogit/Makefile agrees with deps.mk (Lua version and
# checksum) and, when run on a release tag vX.Y.Z, with the tag version.
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
pkg=$top/openwrt/picogit/Makefile
get() { sed -n "s/^$1 *:\{0,1\}= *//p" "$2" | head -1; }
fail=0
lua_v=$(get LUA_VERSION "$top/deps.mk")
lua_h=$(get LUA_SHA256 "$top/deps.mk")
[ "$(get PICOGIT_LUA_VERSION "$pkg")" = "$lua_v" ] || { echo "openwrt: Lua version differs from deps.mk ($lua_v)"; fail=1; }
[ "$(get PICOGIT_LUA_HASH "$pkg")" = "$lua_h" ] || { echo "openwrt: Lua hash differs from deps.mk"; fail=1; }
tag=$(git -C "$top" describe --tags --exact-match 2>/dev/null || true)
case $tag in
v[0-9]*)
    [ "$(get PKG_VERSION "$pkg")" = "${tag#v}" ] || { echo "openwrt: PKG_VERSION is not ${tag#v}"; fail=1; } ;;
esac
[ $fail = 0 ] && echo "openwrt package: consistent with deps.mk${tag:+ and $tag}"
exit $fail
