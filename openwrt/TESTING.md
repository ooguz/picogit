# Testing the OpenWrt package

picogit is on its way into the OpenWrt packages feed, and reports from real
devices help that. This page explains how to install the package on an
OpenWrt router, run the self-test, and send the result. It takes about ten
minutes. Reports from devices where everything worked are just as useful as
problem reports.

You need:

- an OpenWrt **24.10** or **25.12** device with internet access, about
  300 KB free in the overlay and 2 MB free in `/tmp`;
- SSH access as root.

OpenWrt 23.05 and older ship Mbed TLS 2.28, which the package does not
support. Use the [static binary](../README.md#openwrt) there.

## 1. Find your version and architecture

```sh
. /etc/openwrt_release; echo "$DISTRIB_RELEASE $DISTRIB_ARCH"
```

This prints, for example, `24.10.8 arm_cortex-a9`. The OpenWrt version
picks the package format: **24.10 uses `.ipk`** files (opkg), **25.12 uses
`.apk`** files (apk).

## 2. Download the package

The [release page](https://github.com/ooguz/picogit/releases/latest) has a
package for each of these architectures:

| Architecture | Common devices |
|---|---|
| `aarch64_cortex-a53` | mediatek/filogic (MT7981, MT7986), qualcommax (IPQ807x), mvebu Armada 3700 |
| `aarch64_cortex-a72` | Raspberry Pi 4 (bcm27xx/bcm2711), mvebu Armada 7k/8k |
| `aarch64_generic` | rockchip (NanoPi R4S/R5S/R6S), armsr/armv8 |
| `arm_cortex-a7` | mediatek MT7623/MT7629, sunxi |
| `arm_cortex-a7_neon-vfpv4` | ipq40xx (many AC routers), Raspberry Pi 2 |
| `arm_cortex-a9` | bcm53xx (Netgear R7000, ASUS RT-AC68U, ...) |
| `arm_cortex-a9_vfpv3-d16` | mvebu Armada 38x (Linksys WRT1900AC/WRT3200ACM, Turris Omnia) |
| `arm_cortex-a15_neon-vfpv4` | ipq806x (Netgear R7800, TP-Link C2600) |
| `i386_pentium4` | x86/generic |
| `mips_24kc` | ath79 (most Atheros/Qualcomm MIPS routers), lantiq |
| `mipsel_24kc` | ramips MT7621 and MT76x8 (Xiaomi, TP-Link, GL.iNet, ...) |
| `mipsel_74kc` | bcm47xx MIPS74K, ramips RT3883 |
| `x86_64` | x86/64 (PCs, virtual machines) |

On the router, replace `ARCH` with your architecture:

```sh
cd /tmp
# OpenWrt 24.10
wget https://github.com/ooguz/picogit/releases/download/v0.1.0/picogit_0.1.0-r1_ARCH.ipk
# OpenWrt 25.12
wget https://github.com/ooguz/picogit/releases/download/v0.1.0/picogit-0.1.0-r1_ARCH.apk
```

If `wget` cannot fetch HTTPS URLs, download the file on a computer and
copy it with `scp -O picogit* root@192.168.1.1:/tmp/`.

If your architecture is not in the table, build the package with the
SDK of your target as described in [README.md](README.md#testing-with-the-sdk),
or test the static binary and say so in the report.

## 3. Install it

The package manager also installs the dependencies (`libmbedtls`, `zlib`,
`ca-bundle`), so update the package lists first.

```sh
# OpenWrt 24.10
opkg update && opkg install /tmp/picogit_0.1.0-r1_*.ipk
# OpenWrt 25.12 (the release package is not signed with an OpenWrt key)
apk update && apk add --allow-untrusted /tmp/picogit-0.1.0-r1_*.apk

picogit --version
```

## 4. Run the self-test

```sh
wget -O /tmp/selftest.sh https://raw.githubusercontent.com/ooguz/picogit/main/openwrt/selftest.sh
sh /tmp/selftest.sh
```

The [script](selftest.sh) needs only BusyBox and takes under a minute. It
works in a directory under `/tmp` and removes it at the end. It:

- shallow-clones and fully clones this repository from GitHub, and pulls;
- commits a new, a changed and a deleted file, plus an ignored file that
  must stay out of the commit (locally, nothing is pushed);
- checks that picogit refuses servers with an expired, a self-signed and
  a wrong-host certificate (from [badssl.com](https://badssl.com); skip
  these with `-n`);
- records the time and peak memory of each step, and your OpenWrt version,
  target, device model, CPU, memory and package versions.

It writes the report to `/tmp/picogit-selftest-report.md`.

### Optional: test push

Push needs a repository you can write to. Create an empty scratch
repository on GitHub (or GitLab, Gitea, Forgejo, ...), and a token that can
write only to it: on GitHub, a
[fine-grained token](https://github.com/settings/personal-access-tokens/new)
with "Contents: Read and write" for that one repository. Then:

```sh
read -s PICOGIT_TOKEN && export PICOGIT_TOKEN   # paste the token, press Enter
sh /tmp/selftest.sh -p https://github.com/YOU/picogit-scratch.git
unset PICOGIT_TOKEN
```

The script pushes one commit that adds a file under `picogit-selftest/`,
checks it with a fresh clone, and pushes a second commit that removes the
file. The token never appears in the output or the report. Delete the
token when you are done.

## 5. Send the report

Open an [OpenWrt test report](https://github.com/ooguz/picogit/issues/new?template=openwrt_test.yml)
and paste the report:

```sh
cat /tmp/picogit-selftest-report.md
```

Please read it first: it contains no secrets, but it names your device and
OpenWrt version. If you used picogit for something real (backing up
`/etc/config`, deploying scripts from a repository, ...), a sentence about
that helps too.

## Cleaning up

```sh
opkg remove picogit    # 24.10
apk del picogit        # 25.12
rm -f /tmp/picogit* /tmp/selftest.sh
```

The dependencies stay installed. `libmbedtls` and `zlib` are often used by
other packages too.

## When something fails

- **Certificate errors on every server**: the clock is probably wrong. TLS
  needs the right date; check `date` and the NTP settings.
- **`opkg install` cannot find `libmbedtls21`**: run `opkg update` first.
  On 23.05 or older, use the static binary.
- **Out of space**: the package needs about 300 KB in the overlay. Check
  with `df -h /overlay /tmp`.
- Run the failing command with `PICOGIT_TRACE=1` to see the protocol
  exchange (it does not show credentials) and add it to the report.

Security problems go to a private advisory instead
([SECURITY.md](../SECURITY.md)).

## For maintainers: how the packages are built

[`.github/workflows/openwrt.yml`](../.github/workflows/openwrt.yml) builds
`picogit/Makefile` with the official OpenWrt SDK containers for 24.10 and
25.12, on every architecture in the table above. For x86_64,
aarch64_generic, arm_cortex-a15_neon-vfpv4 and mips_24kc, it then installs
the package in an OpenWrt rootfs container (under qemu where needed), with
its dependencies from the official feeds, and runs the self-test there. A
manual run with "publish" attaches the packages and `SHA256SUMS-openwrt`
to the release named by `PKG_VERSION`.

The same steps work locally with Docker:

```sh
mkdir -p out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
    ghcr.io/openwrt/sdk:arm_cortex-a9-24.10.8 sh /src/tools/openwrt-sdk-build.sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
    ghcr.io/openwrt/rootfs:x86_64-24.10.8 sh /src/tools/openwrt-runtime-test.sh
```

The second command needs an x86_64 package in `out/`, or qemu-user with
binfmt and `--platform linux/ARCH` for other architectures.

## Türkçe özet

OpenWrt 24.10 veya 25.12 çalışan bir cihazınız varsa paketi test edip
sonucu bildirebilirsiniz:

1. `. /etc/openwrt_release; echo "$DISTRIB_RELEASE $DISTRIB_ARCH"` ile
   sürümü ve mimariyi öğrenin.
2. [Release sayfasından](https://github.com/ooguz/picogit/releases/latest)
   mimarinize uygun paketi `/tmp`'ye indirin: 24.10 için `.ipk`, 25.12 için
   `.apk`.
3. Kurun: 24.10'da `opkg update && opkg install /tmp/picogit_*.ipk`,
   25.12'de `apk update && apk add --allow-untrusted /tmp/picogit-*.apk`.
4. Testi çalıştırın:
   `wget -O /tmp/selftest.sh https://raw.githubusercontent.com/ooguz/picogit/main/openwrt/selftest.sh && sh /tmp/selftest.sh`.
   Push'u da denemek isterseniz yukarıdaki "Optional: test push" adımlarını
   izleyin; yalnızca o depoya yazabilen bir token kullanın.
5. `/tmp/picogit-selftest-report.md` dosyasının içeriğini bir
   [OpenWrt test raporu](https://github.com/ooguz/picogit/issues/new?template=openwrt_test.yml)
   açarak yapıştırın.

Rapor token içermez ama cihaz modelinizi ve OpenWrt sürümünüzü gösterir.
Sorunsuz çalıştığını bildiren raporlar da çok işe yarar.
