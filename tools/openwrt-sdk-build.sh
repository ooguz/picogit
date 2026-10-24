#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the OpenWrt package in an OpenWrt SDK, as CI does:
#
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
#       ghcr.io/openwrt/sdk:arm_cortex-a9-24.10.8 sh /src/tools/openwrt-sdk-build.sh
#
# The SDK image's working directory is the SDK. The package is built from
# openwrt/picogit/Makefile, so the source is the release tarball named
# there. The .ipk or .apk is copied to /out (or $1), with the package
# architecture in the name of an .apk too.
set -eu

SRC=${SRC:-/src}
OUT=${1:-/out}

# The default feeds file fetches the whole openwrt.git history for "base";
# only its packages are needed. Use the GitHub mirrors, as OpenWrt CI does.
# 24.10: "src-git-full base URL;TAG", 25.12: "src-git --root=package base URL^COMMIT".
sed -n '/^src-git[a-z-]*\( --[^ ]*\)* base /{
	s/^src-git-full /src-git /
	s,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,
	p
}' feeds.conf.default >feeds.conf
grep -q ' base ' feeds.conf || { echo "no base feed in feeds.conf.default" >&2; exit 1; }
echo "src-link picogit $SRC/openwrt" >>feeds.conf

./scripts/feeds update base picogit >feeds.log 2>&1 || { tail -n 30 feeds.log; exit 1; }
./scripts/feeds install picogit
make defconfig >/dev/null

arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config)
echo "building picogit for $arch"

make package/picogit/download V=s
make package/picogit/check V=s
if ! make package/picogit/compile -j"$(nproc)" V=s >build.log 2>&1; then
	tail -n 80 build.log
	exit 1
fi
if grep -E 'warning:' build.log | grep -E 'src/c/|picogit'; then
	echo "::warning::compiler warnings in picogit"
fi

mkdir -p "$OUT"
found=
for f in $(find bin/packages -type f \( -name 'picogit_*.ipk' -o -name 'picogit-[0-9]*.apk' \)); do
	base=$(basename "$f")
	case $base in
	*.apk) base="${base%.apk}_$arch.apk" ;;
	esac
	cp "$f" "$OUT/$base"
	echo "$OUT/$base"
	found=1
done
[ -n "$found" ] || { echo "no picogit package was built" >&2; exit 1; }
