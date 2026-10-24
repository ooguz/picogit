# OpenWrt package

`picogit/Makefile` is the package in the form intended for the OpenWrt
[packages feed](https://github.com/openwrt/packages), as `net/picogit`.

Unlike the standalone static binaries, the package links OpenWrt's own
libraries, so that their security updates reach picogit:

- `libmbedtls` (OpenWrt ships Mbed TLS 3.6 with TLS 1.3)
- `zlib`
- `ca-bundle` (`/etc/ssl/certs/ca-certificates.crt`)

OpenWrt does not ship Lua 5.4, so Lua is still built into the binary. The
result is about 260 KB installed (a 128 KB `.ipk` on arm_cortex-a9),
instead of 690 KB for the self-contained binary.

The upstream build is `make cross SYSTEM_LIBS=1` from the release tarball.
`SYSTEM_LIBS=1` works for other distributions too.

To test the package on a device, see [TESTING.md](TESTING.md): it has
ready-made packages for the common architectures and a self-test script
whose report goes into an issue.

## Testing with the SDK

The quickest way is the official SDK container, as in CI
([`.github/workflows/openwrt.yml`](../.github/workflows/openwrt.yml)); the
image tag is the package architecture and the OpenWrt version:

```sh
mkdir -p out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
    ghcr.io/openwrt/sdk:mipsel_24kc-25.12.6 sh /src/tools/openwrt-sdk-build.sh
```

This builds the release tarball named in the Makefile. To build the
current tree instead, or with an SDK tarball, use the SDK of the target you
care about (the example is `bcm53xx`, the
SoC family of many ASUS routers):

```sh
# in the picogit tree: a source tarball of HEAD named like the release
make dist PICOGIT_VERSION=0.1.0

# in the OpenWrt SDK directory
echo "src-link picogit /path/to/picogit/openwrt" >> feeds.conf.default
./scripts/feeds update base picogit
./scripts/feeds install picogit
cp /path/to/picogit/dist/picogit-0.1.0.tar.xz dl/
make defconfig
make package/picogit/compile V=s
ls bin/packages/*/picogit/
```

`PKG_HASH:=skip` lets the SDK accept the local tarball. Before submitting,
set `PKG_HASH` to the SHA-256 of the released tarball.

To run the integration tests against the built package, unpack the
`picogit`, `libmbedtls21`, `zlib`, `ca-bundle`, `libgcc1` and `libc` packages
into a directory. Then run the tests under qemu with that directory as
`QEMU_LD_PREFIX`:

```sh
QEMU_LD_PREFIX=$ROOT make test-integration PICOGIT_RUN=qemu-arm \
    PICOGIT_BIN=$ROOT/usr/bin/picogit PICOGIT_DEV_BIN=build/armv7/picogit-dev
```

The 0.1.0 package was verified this way with the 24.10.8 `bcm53xx` SDK:
58/58 integration tests and the HTTPS tests passed with OpenWrt's
libmbedtls 3.6.7, zlib and ca-bundle, on a Cortex-A9 model without FPU.

## Submitting

1. Tag the release (`git tag v0.1.0 && git push origin v0.1.0`). CI attaches
   `picogit-0.1.0.tar.gz` and `picogit-0.1.0.tar.xz` to the GitHub release.
2. Put the SHA-256 of the `.tar.xz` into `PKG_HASH`.
   `tools/check-openwrt-package.sh` checks that `PKG_VERSION` matches the
   tag and that the Lua pin matches `deps.mk`. Once that is on `main`, run
   the `openwrt` workflow by hand with "publish" to attach the packages for
   testers to the release.
3. Copy `picogit/Makefile` to `net/picogit/Makefile` in a fork of
   `openwrt/packages`. Build-test it on at least one target, and open a pull
   request following the feed's
   [CONTRIBUTING.md](https://github.com/openwrt/packages/blob/master/CONTRIBUTING.md):
   one commit `picogit: add new package`, signed off (`git commit -s`).
4. After it is merged, users install it with `opkg install picogit` (24.10)
   or `apk add picogit` (25.12 and later).
