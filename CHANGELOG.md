# Changelog

All notable changes are listed here. The project follows
[semantic versioning](https://semver.org/).

## [Unreleased]

- `openwrt/selftest.sh` and `openwrt/TESTING.md`: a self-test for OpenWrt
  devices and a guide for people testing the package, with an issue form
  for the reports
- CI builds the OpenWrt package with the 24.10 and 25.12 SDKs for 13
  architectures, and runs the self-test in OpenWrt rootfs containers
- the build ignores a `TARGET` set in the environment, as the OpenWrt SDK
  containers do

## [0.1.0] - 2026-10-23

First public release.

- `clone` (shallow by default; `--depth`, `--branch`, tags, empty
  repositories), fast-forward `pull`, `commit -a`, and `push` with
  report-status, over smart HTTP(S)
- protocol v2 for fetching, with a v0 fallback; v0 for push
- self-contained static binaries for armv7 (soft-float), armv7hf, aarch64,
  mipsel, mips, x86 (i586), riscv64 and x86_64, all below 1 MiB
- embedded Mozilla CA bundle, `--cacert`, `--insecure`, and a hint about
  the device clock on certificate date errors
- credentials from the URL, `PICOGIT_TOKEN` or `~/.netrc`, never shown in
  output
- protections against hostile servers and repositories: no writes through
  symlinked directories, ref name validation, strict HTTP parsing
- `SYSTEM_LIBS=1` build against the system Mbed TLS, zlib and CA store,
  and an OpenWrt package (`openwrt/picogit`) for the packages feed

[0.1.0]: https://github.com/ooguz/picogit/releases/tag/v0.1.0
