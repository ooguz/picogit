#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install a built picogit package in an OpenWrt rootfs container and run
# openwrt/selftest.sh, as CI does:
#
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
#       ghcr.io/openwrt/rootfs:x86_64-24.10.8 sh /src/tools/openwrt-runtime-test.sh
#
# The package comes from /out (or $1); its dependencies (libmbedtls, zlib,
# ca-bundle) come from the official OpenWrt feeds, as on a device. The
# report is written next to the package.
set -eu

SRC=${SRC:-/src}
OUT=${1:-/out}

# The image has no /var/lock, which opkg needs.
mkdir -p /tmp/lock /var/lock 2>/dev/null || true

if command -v apk >/dev/null 2>&1; then
	pkg=$(ls "$OUT"/picogit-*.apk)
	apk update
	apk add --allow-untrusted "$pkg"
else
	pkg=$(ls "$OUT"/picogit_*.ipk)
	opkg update
	opkg install "$pkg"
fi

command -v picogit
picogit --version

sh "$SRC/openwrt/selftest.sh" -o "$OUT/selftest-report.md"
