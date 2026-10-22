# picogit

[![Release](https://img.shields.io/github/v/release/ooguz/picogit)](https://github.com/ooguz/picogit/releases) [![build](https://github.com/ooguz/picogit/actions/workflows/build.yml/badge.svg)](https://github.com/ooguz/picogit/actions/workflows/build.yml) ![License](https://img.shields.io/github/license/ooguz/picogit) ![GitHub Sponsors](https://img.shields.io/github/sponsors/ooguz) <a href="https://www.buymeacoffee.com/ooguz" target="_blank"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" alt="Buy Me A Coffee" style="height: 20px !important;width: 85px !important;" ></a>

A minimal git client for routers and other small Linux devices: a single
statically linked binary (~0.7 MB) that can **clone**, **pull**
(fast-forward), **commit -a** and **push** over smart HTTP(S). No `git`,
`curl`, `lua`, libc or CA bundle is needed on the device.

It is written in Lua 5.4 on top of a small C core (zlib, SHA-1, an HTTP
client with Mbed TLS). The Lua code is precompiled and embedded in the
binary.

Repositories created by picogit are ordinary git repositories: real git
sees a clean `git status`, and `git fsck --strict` passes.

```
picogit clone https://github.com/me/router-config.git /jffs/config
cd /jffs/config
nvram show 2>/dev/null | sort > nvram.txt
picogit commit -a -m "nightly backup"
picogit push
```

## Contents

- [Commands](#commands)
- [Installation](#installation)
  - [ASUS (Asuswrt / Asuswrt-Merlin)](#asus-asuswrt--asuswrt-merlin)
  - [OpenWrt](#openwrt)
- [Authentication and configuration](#authentication-and-configuration)
- [Building](#building)
- [Testing](#testing)
- [How it works](#how-it-works)
- [Limitations and roadmap](#limitations-and-roadmap)
- [Contributing](#contributing)
- [Support the project](#support-the-project)
- [License](#license)
- [Türkçe](#türkçe)

## Commands

```
picogit [options] <command> [<args>]

  clone [--depth N] [--branch B] <url> [<dir>]
  pull
  commit -a -m <message>
  push

options (before or after the command):
  -C <dir>          run as if started in <dir>
  --cacert <file>   trust the CAs in <file> instead of the built-in bundle
  --insecure        do not verify TLS certificates
  -q, --quiet       no progress or informational output
  --version, -h/--help
```

**clone** makes a shallow clone with `--depth 1` by default; `--depth 0`
clones the full history. Only the requested branch is fetched (the remote's
default branch unless `--branch` is given). `--branch` also accepts a tag,
which is checked out as a detached HEAD. Cloning an empty repository works;
the first `commit -a` and `push` then create the branch.

**pull** updates the current branch from its upstream
(`branch.<name>.merge`) and only fast-forwards. If local and remote history
have diverged it stops with an error and changes nothing. New objects are
downloaded into a quarantine directory and only kept after the
fast-forward check succeeds. Local modifications to files the pull would
change, and untracked files in the way, are refused before anything is
touched. Unrelated local changes are kept. Shallow clones stay usable:
the pulled commits are added on top.

**commit -a** commits the whole work tree. Unlike `git commit -a` this
**includes new (untracked) files**, because picogit has no `add` command.
Files matched by `.gitignore` (at any level) or `.git/info/exclude` are left
out, but files that are already tracked stay tracked. Deleted files are
removed from the commit. The command exits with status 1 if there is
nothing to commit.

**push** sends the current branch to its upstream. Only fast-forward pushes
are possible (there is no force). If the remote branch has moved, run
`picogit pull` first. Hook messages and errors from the server are shown,
and the server's `report-status` is checked.

Exit status is 0 on success and 1 on any error.

## Installation

Download the binary for your CPU from the releases page, or build it (see
below):

| Binary                  | Devices                                                     |
|-------------------------|-------------------------------------------------------------|
| `picogit-linux-armv7`   | ARMv7 routers (soft-float; runs with or without an FPU) — ASUS BCM470x/BCM675x, OpenWrt ipq40xx, mvebu, bcm53xx, … |
| `picogit-linux-armv7hf` | ARMv7 with VFPv3 (optional; no practical speed gain)         |
| `picogit-linux-aarch64` | 64-bit ARM userland (OpenWrt filogic, mediatek, ipq807x, …) |
| `picogit-linux-mipsel`  | MIPS32r2 little-endian (OpenWrt ramips: MT7621, MT76x8)      |
| `picogit-linux-mips`    | MIPS32r2 big-endian (OpenWrt ath79)                          |
| `picogit-linux-x86_64`  | 64-bit PCs, x86 routers and NAS                              |
| `picogit-linux-x86`     | 32-bit x86 (i586 and newer: old thin clients, Geode/Vortex86 boards, OpenWrt x86/legacy) |
| `picogit-linux-riscv64` | 64-bit RISC-V Linux (rv64gc: VisionFive, Milk-V, OpenWrt d1/jh7110) |

`uname -m` reports `armv7l` on 32-bit ARM. Some newer ASUS models run an
aarch64 kernel with a 32-bit userland; they also need the **armv7** binary
(check `file /bin/busybox` or `cat /proc/cpuinfo`).

The binaries are fully static, so the device needs nothing else. They do
not rely on recent kernel features. `getrandom()` (Linux 3.17+) falls
back to `/dev/urandom`. `statx` and the 64-bit time syscalls fall back to
their older equivalents (handled by musl). The code is tested with kernels
as old as 2.6.36 in mind (see [Kernel compatibility](#kernel-compatibility)).

### ASUS (Asuswrt / Asuswrt-Merlin)

1. Enable SSH (Administration → System) and, on Asuswrt-Merlin, *Enable JFFS
   custom scripts and configs*.
2. Choose a persistent location:
   - `/jffs` (internal flash, survives reboots and firmware updates, usually
     only tens of MB, and flash wears out), or
   - a USB drive, mounted at `/tmp/mnt/<label>/` (recommended for anything
     bigger than a few MB or written often).

   **Do not use `/tmp`:** it is RAM. picogit itself never stages downloads
   in `/tmp`; temporary files live inside the repository's `.git` directory.
3. Copy the binary (Dropbear needs `scp -O`):

   ```sh
   scp -O picogit-linux-armv7 admin@router:/jffs/bin/picogit
   ssh admin@router chmod +x /jffs/bin/picogit
   ```
   or download it on the router: `curl -fLo /jffs/bin/picogit <url>`
   (`wget` from BusyBox cannot do HTTPS on many firmwares).
4. On Merlin, add `/jffs/bin` to `PATH` in `/jffs/configs/profile.add`:
   `export PATH=/jffs/bin:$PATH`.

Router-specific notes:

- **Home directory:** `HOME` is `/root` (or `/tmp/home/root`), which is RAM
  on Asuswrt. A `~/.netrc` there disappears on reboot. Keep credentials on
  `/jffs` and point `NETRC` at them, or set `PICOGIT_TOKEN` in your script
  (see below).
- **Clock:** routers start with a wrong clock until NTP has synchronised,
  and TLS certificates are then "not yet valid". picogit reports this
  explicitly ("the device clock says 1970-01-01 … check the system time /
  NTP"). In scripts, wait for NTP first, e.g. on Merlin:
  `until [ "$(nvram get ntp_ready)" = 1 ]; do sleep 5; done`.
- **File systems:** FAT/exFAT/NTFS USB drives cannot store symlinks or the
  executable bit. `clone` detects this like `git init` does and sets
  `core.symlinks=false` / `core.filemode=false` (and `core.ignorecase=true`
  on case-insensitive file systems). Symlinks are then checked out as small
  text files.
- **Cron** (Merlin): `cru a gitbackup "15 3 * * * /jffs/scripts/backup.sh"`.

A backup script could look like this:

```sh
#!/bin/sh
export PATH=/jffs/bin:$PATH
export NETRC=/jffs/.netrc            # machine github.com login x password <token>
export PICOGIT_AUTHOR_NAME="RT-BE58U" PICOGIT_AUTHOR_EMAIL="router@example.com"
until [ "$(nvram get ntp_ready)" = 1 ]; do sleep 10; done
cd /tmp/mnt/usb/router-config || exit 1
picogit -q pull || exit 1
nvram show 2>/dev/null | grep -v -e '_pass' -e 'wpa_psk' | sort > nvram.txt
cp /jffs/scripts/* scripts/ 2>/dev/null
picogit -q commit -a -m "backup $(date +%F)" && picogit -q push
```

### OpenWrt

**Package.** `openwrt/picogit/Makefile` is a package for the OpenWrt
packages feed. It links OpenWrt's own `libmbedtls` and `zlib` and uses
`ca-bundle`, so it is only about 260 KB, and library security fixes reach it
through OpenWrt. Until it is accepted into the feed, build it with the SDK
as described in [`openwrt/README.md`](openwrt/README.md). Then install it:
`opkg install picogit_*.ipk` on 24.10, or the `.apk` with `apk add` on
25.12 and later. The package was verified with the 24.10.8 `bcm53xx` SDK
against OpenWrt's libmbedtls 3.6.7: the full integration suite passed under
qemu.

**Static binary.** Alternatively, copy the matching static binary to
`/usr/bin/picogit`. The overlay file system keeps it across reboots, but
not across sysupgrade unless it is listed in `/etc/sysupgrade.conf`. To use
the system CA store instead of the embedded one:
`picogit --cacert /etc/ssl/certs/ca-certificates.crt clone …`.

`/root` is persistent on OpenWrt, so `~/.netrc` works.

## Authentication and configuration

HTTP Basic credentials are taken from, in this order:

1. the URL: `https://user:token@host/repo.git`. This works, but the URL
   (with the token) is stored in `.git/config` like git does, and picogit
   prints a warning;
2. `PICOGIT_TOKEN`, with the user name from `PICOGIT_USERNAME`, the URL, or
   `git` (GitHub, GitLab and Gitea accept any user name with a token);
3. `~/.netrc` (or the file named by `NETRC`): `machine github.com login me
   password <token>`.

Credentials are sent only to the host of the repository URL. They are
dropped if the server redirects to another host, and a redirect from
https to http is refused. Tokens never appear in messages, errors or
`PICOGIT_TRACE` output.

| Variable | Meaning |
|---|---|
| `PICOGIT_TOKEN`, `PICOGIT_USERNAME` | HTTP credentials |
| `NETRC` | path of the netrc file (default `~/.netrc`) |
| `PICOGIT_AUTHOR_NAME`, `PICOGIT_AUTHOR_EMAIL` | commit identity (otherwise `[user]` in `.git/config`, then `~/.gitconfig`) |
| `PICOGIT_TIMEOUT` | network timeout in seconds (default 120) |
| `PICOGIT_TRACE=1` | protocol, memory and HTTP trace on stderr |
| `PICOGIT_DEBUG=1` | Lua traceback on errors |
| `TZ` | time zone for commit timestamps (e.g. `TZ=UTC-3` for +03:00) |

## Building

Requirements on the build machine (x86_64 Linux): `make`, `curl`, `tar`
with `xz`/`bzip2`, `python3` and a native C compiler (`cc`, used for a
build-time Lua). The cross compiler does not need to be installed.

```sh
make armv7          # -> build/armv7/picogit
make host armv7 armv7hf aarch64 mipsel mips x86 riscv64
make sizes
```

On first use the Makefile downloads and checks (SHA-256, see
[`deps.mk`](deps.mk)):

| Component | Version | Why |
|---|---|---|
| zig (as `zig cc`) | 0.16.0 | cross compiler with musl for every target in one 50 MB download, no toolchain build |
| Lua | 5.4.9 | interpreter for the application logic |
| zlib | 1.3.2 | inflate/deflate; `avail_in` gives the bytes consumed per pack entry |
| Mbed TLS | 3.6.7 (LTS) | TLS 1.2 + 1.3 client, also used by OpenWrt |
| Mozilla CA bundle | curl's `cacert-2026-09-25.pem` | embedded trust store |

Typical sizes of the stripped static binaries:

| Target | Size |
|---|---|
| armv7 (soft-float, Thumb-2) | 689 KB |
| armv7hf | 669 KB |
| aarch64 | 654 KB |
| mipsel | 898 KB |
| mips (big-endian, Lua source embedded) | 935 KB |
| x86 (i586) | 635 KB |
| riscv64 | 611 KB |
| x86_64 | 659 KB |

The armv7 binary breaks down roughly as follows: Lua 180 KB, Mbed TLS
230 KB, zlib 47 KB, picogit C code 27 KB, the CA bundle 95 KB (zlib
compressed DER), embedded Lua bytecode 67 KB, and the rest musl.

**Docker:** `docker build -t picogit-build .` builds all targets in a
pinned Debian image.

**Other toolchains:** `CC` can be overridden, for example with
musl-cross-make:

```sh
make armv7 CC=arm-linux-musleabi-gcc TARGET_CFLAGS="-march=armv7-a -mfloat-abi=soft -mthumb"
make cross CC=mips-linux-musl-gcc TARGET_CFLAGS="-march=mips32r2" EMBED_MODE=source
```

`EMBED_MODE=source` embeds Lua source instead of bytecode. Bytecode is
only portable between little-endian targets.

**System libraries.** `make cross SYSTEM_LIBS=1 CC=...` links Mbed TLS
(3.x) and zlib from the system, dynamically. The binary then uses the CA
store at `SYSTEM_CAFILE` (default `/etc/ssl/certs/ca-certificates.crt`).
Only the Lua sources are downloaded. This is how distributions should build
picogit; the OpenWrt package does the same. With Debian's mbedtls 3.6 the
binary is 266 KB, and it passes the whole test suite.

**Release tooling:**
- `make dist` writes a reproducible source tarball of `HEAD`
  (`dist/picogit-<version>.tar.gz`).
- `make check-size` fails if any built binary reaches the 1 MiB budget.

## Testing

```sh
make test              # unit + integration tests with the host binary
make test-armv7        # the same tests, armv7 binary under qemu-arm
make test-qemu-riscv64 # the same for any other target (x86, aarch64, mipsel, ...)
make test-oldkernel    # armv7 again, with getrandom() returning ENOSYS
make test-https        # clone public repositories from GitHub over HTTPS
make test-https-armv7  # the same with the armv7 binary
```

The integration tests run a local smart-HTTP server
([`test/server/git_http_server.py`](test/server/git_http_server.py), which
wraps `git http-backend` and supports TLS, Basic auth, redirects, chunked
or close-delimited responses, and a v0-only mode). Each scenario checks the
result with real git (`git fsck --strict`, `git status --porcelain`, or a
fresh `git clone` of the remote). The scenarios cover:

- clone: shallow, full and depth 2; branch and tag; empty repository;
  binary files; executable bit; symlinks; subdirectories; deleted files;
  delta chains; redirects; protocol v0; Basic auth via URL, token and netrc;
  submodules (skipped)
- pull: every kind of change (including file↔directory swaps); divergence;
  local changes; untracked files in the way
- commit -a: the committed tree is compared with `git add -A && git
  write-tree`; `.gitignore`; identity sources; filemode and symlinks
  settings
- push: from a shallow clone; to an empty repository; hook rejection; auth;
  a round trip with real git

Unit tests cover pkt-line, side-band, deltas, pack read/write, index and
config round trips, and gitignore matching.

`make test-qemu-x86` runs on a Pentium model (no `cmov` or other i686
instructions) to hold the i586 baseline. `make test-armv7` runs qemu with
a Cortex-A9 model **without an FPU**
(`QEMU_CPU=cortex-a9,vfp=off,vfp-d32=off,neon=off`). A single VFP/NEON
instruction in the soft-float build would crash with SIGILL; the
hard-float build indeed does. Without a local `qemu-arm`, the tests run in
the Docker image from the `Dockerfile`.

CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)) builds
all targets and runs every suite. On `v*` tags it attaches the binaries
and `SHA256SUMS` to a release.

## How it works

```
src/c/        C core, exposed to Lua as `picogit.core`
  main.c        Lua state; require() only sees the embedded modules
  zlib_bind.c   inflate/deflate, streaming object I/O (pack -> loose,
                file -> blob, loose -> file, loose -> pack entry)
  sha1_bind.c   SHA-1 (Mbed TLS implementation)
  http.c        HTTP/1.1 over TCP or TLS, streaming bodies, CA handling
  fs.c, rand.c  lstat/readdir/symlink/..., getrandom with urandom fallback
src/lua/
  main.lua      command line          commands.lua  clone/pull/commit/push
  transport.lua smart HTTP protocol   pktline.lua   pkt-line, side-band-64k
  pack.lua      pack reader/writer    delta.lua     delta application
  odb.lua       loose objects         refs.lua      refs, packed-refs, shallow
  index.lua     index v2              worktree.lua  checkout/update/snapshot
  config.lua    .git/config           ignore.lua    .gitignore matching
  fetch.lua     fetch helpers         repo.lua      layout, probes
  http.lua      URLs, redirects       util.lua      helpers
```

**Protocol.** picogit speaks smart HTTP only. Fetching prefers protocol
v2: `ls-refs` with a ref prefix returns just the wanted branch. On hosts
with many refs this matters: GitHub advertises every `refs/pull/*`, which
is 256 KB even for the small `octocat/Hello-World`. If a server does not
answer with v2, picogit falls back to v0. Push uses v0 because
receive-pack has no v2. All requests are single-round (`done` is sent at
once), with `side-band-64k` and `ofs-delta`. Thin packs are never
requested.

**Objects** are stored as loose objects, as git itself does for small
repositories. Downloaded packs are written to
`.git/objects/pack/tmp_pack_*` on the target file system, exploded and
deleted. Unpacking works like `git index-pack`. The first pass streams
non-delta objects straight into loose objects in C, and finds the end of
each entry from the number of bytes zlib consumed. The second pass
resolves each delta tree from its base, holding only one base/result pair
of a delta chain in memory at a time. Push writes a pack without deltas
that contains only the objects the remote lacks: commits back to the
remote tip, plus per-commit tree diffs.

**TLS.** Mbed TLS 3.6 LTS, configured as a client only
([`config/pg_mbedtls_config.h`](config/pg_mbedtls_config.h)): TLS 1.2 and
1.3, ECDHE with RSA/ECDSA, AES-GCM and ChaCha20-Poly1305, P-256/384/521 and
X25519. BearSSL would be about 100 KB smaller, but it has no TLS 1.3 and no
release since 2018. Randomness comes from the kernel (`getrandom`, else
`/dev/urandom`) through PSA's external RNG hook, so there is no entropy or
DRBG code. The CA bundle is embedded as zlib-compressed DER and only
inflated and parsed when an HTTPS connection is made. `--cacert` replaces
it.

**Memory.** Large files are never loaded completely. Blobs are streamed
between files, packs and loose objects with fixed 16 KB buffers, and zlib
streams are reused instead of being reallocated for every object.
Measured peak RSS:

| Operation | Peak RSS |
|---|---|
| clone of a repository with one 120 MB file | 13 MB |
| `--depth 1` clone of openwrt.git (10,300 files, 14 MB pack) | 23 MB |
| `commit -a` in that clone | 35 MB |

These figures were measured on x86_64; 32-bit targets use less. For
routers with 64 MB of RAM, repositories of a few thousand files are
comfortable. Only delta resolution needs whole objects in memory, which
git needs as well.

**Float ABI.** The default armv7 build is soft-float with all FPU features
disabled at compile time (`-mcpu=generic+v7a-vfp2-vfp3-…`). The only VFP
instructions left are in musl's `setjmp`/`longjmp`, and they run only if
the kernel reports `HWCAP_VFP`. Since the binary is static, the device's
userland ABI does not matter, and picogit does essentially no floating
point work.

### Kernel compatibility

System calls used (determined with `qemu-arm -strace` over clone, commit,
push, pull and HTTPS):
`open close read readv write writev _llseek mmap2 munmap fcntl64 ioctl
statx getdents64 mkdir rename unlink chmod symlink readlink getcwd chdir
socket connect setsockopt getsockopt sendto recvfrom recvmsg bind poll
clock_gettime64 getrandom rt_sigaction set_tid_address exit_group`.

Three of them are newer than 2.6.36, and each has a fallback:

| Syscall | Since | Fallback |
|---|---|---|
| `getrandom` | 3.17 | picogit reads `/dev/urandom` (tested: `make test-oldkernel`) |
| `statx` | 4.11 | musl falls back to `fstatat64` (`src/stat/fstatat.c`) |
| `clock_gettime64` | 5.1 | musl falls back to `clock_gettime` / `gettimeofday` |

`SOCK_CLOEXEC`/`O_CLOEXEC` need 2.6.27 or newer. The ARM build uses
ldrex/strex and the TLS register, not the kuser helpers, so it also runs
on aarch64 kernels with `CONFIG_KUSER_HELPERS=n`. qemu-user cannot hide
`statx`/`clock_gettime64` from the program, so these two fallbacks are
verified from the musl sources, not by tests.

### git compatibility

- The index is written as version 2 without extensions. Version 3 and git's
  extensions (TREE, UNTR, …) are read, the extensions are dropped.
- `.git/shallow`, `packed-refs`, symbolic refs and
  `refs/remotes/origin/HEAD` are maintained like git does. Reflogs are not
  written, which git tolerates.
- `core.filemode`, `core.symlinks` and `core.ignorecase` are probed at clone
  time and respected.
- Racy-git: stat data from the same timestamp as the index (nanoseconds
  where the file system has them) is re-checked by content.

### Hostile servers and repositories

- **Tree entries.** Names that could escape the work tree (`..`, `.git`,
  names containing `/`) are refused, and so are trees with duplicate names.
- **Symlinked directories.** Directories are created and traversed without
  following symbolic links: a repository cannot write outside the work tree
  or into `.git` through a symlinked directory. Files are created with
  `O_EXCL|O_NOFOLLOW`.
- **Ref names.** Ref names coming from the server (for example the remote
  `HEAD` symref) must pass git's `check-ref-format` rules before they
  become file names.
- **Pull safety.** Before `pull` touches anything, it checks every path it
  will write: local modifications, untracked files and directories in the
  way, and symlinked parent directories. A refused pull leaves the work
  tree, index and refs unchanged.
- **HTTP parsing.** Responses are parsed strictly: lengths and chunk sizes
  must be plain digits, and headers are limited to 64 KB. Malformed or
  truncated responses end in an error, never in undefined behaviour.
- **Credentials and redirects.** Credentials are bound to the original
  `scheme://host:port`, and a redirect from https to http is refused,
  whatever the case of the scheme.

The integration tests contain hostile-repository scenarios
(`test/integration/t_security.sh`) and malformed-server scenarios
(`/__evil/*` in the test server).

## Limitations and roadmap

Not supported, by design: merge, rebase, branch management, tags beyond
cloning one, SSH, submodules (gitlinks are kept but not checked out), LFS,
force push, sparse checkout.

Not implemented at the moment:

- `reset`, `status` and `log` (planned for 0.2)
- HTTP proxies, HTTP keep-alive, gzip request bodies, credential helpers
- `.gitattributes` (eol conversion, filters) and `core.autocrlf`
- SHA-256 repositories; index version 4
- multiple remotes or refspecs: pull and push always use the branch's
  upstream
- limits on object sizes chosen by the server: a hostile server can fill
  the disk or memory (the operation then fails with an error, as with git)
- reflogs, hooks and `gc`. Objects are stored loose, so a long-lived clone
  grows; recloning shallow from time to time is cheap

[`ROADMAP.md`](ROADMAP.md) has the plan and the size budget: every binary
stays below 1 MiB, and CI enforces it with `make check-size`.

## Contributing

Bug reports and pull requests are welcome; read
[`CONTRIBUTING.md`](CONTRIBUTING.md) first. Report security problems
privately as described in [`SECURITY.md`](SECURITY.md). Everyone taking part
follows the [code of conduct](CODE_OF_CONDUCT.md).

## Support the project

If picogit is useful to you, you can support its development through
[GitHub Sponsors](https://github.com/sponsors/ooguz),
[Buy Me a Coffee](https://buymeacoffee.com/ooguz) or
[PayPal](https://paypal.me/ozcanoguz).

## License

picogit is free software: GNU General Public License v3.0 or later
([`LICENSE`](LICENSE)).

Bundled third-party code in the binary: Lua (MIT), zlib (zlib license),
Mbed TLS (Apache-2.0, compatible with GPLv3), Mozilla CA certificates as
published by the curl project (MPL-2.0).

## Türkçe

**picogit**, router'lar gibi küçük Linux cihazları için minimal bir git
istemcisidir. Tek dosyalık, statik linklenmiş bir binary'dir (~0.7 MB).
Smart HTTP(S) üzerinden yalnızca dört işlem yapar: `clone`, `pull` (sadece
fast-forward), `commit -a` ve `push`. Cihazda git, curl, lua, libc veya CA
paketi gerekmez.

**Hangi binary?** ASUS router'lar ve ARMv7 cihazlar için
`picogit-linux-armv7` kullanın. Bu sürüm soft-float'tır, FPU olsa da
olmasa da çalışır. aarch64 kernel üzerinde 32-bit userland çalışan
modellerde de armv7 sürümü gerekir. OpenWrt'de cihazın mimarisine göre
aarch64, mipsel veya mips sürümünü seçin.

**Kurulum (ASUS):** SSH'ı açın. Merlin kullanıyorsanız *JFFS custom
scripts* seçeneğini de etkinleştirin. Binary'yi `/jffs/bin/picogit` gibi
kalıcı bir yere ya da USB diske (`/tmp/mnt/<etiket>/`) kopyalayıp
`chmod +x` verin. Büyük ya da sık yazılan repolar için flash yerine USB
disk tercih edin. `/tmp` RAM'dir, repoyu oraya koymayın. picogit geçici
dosyalarını `/tmp`'ye değil, reponun `.git` dizinine yazar.

**Kimlik doğrulama:** Kimlik bilgileri şu sırayla aranır: URL içindeki
`user:token@`, `PICOGIT_TOKEN` ortam değişkeni (kullanıcı adı için
`PICOGIT_USERNAME`) ve `~/.netrc`. ASUS'ta `HOME` RAM'de olduğundan netrc
dosyasını `/jffs/.netrc` gibi kalıcı bir yerde tutun ve `NETRC` ortam
değişkeniyle gösterin. Token'lar hiçbir mesajda veya logda görünmez.
URL'ye token yazarsanız git'teki gibi `.git/config`'e kaydedilir ve
picogit bu konuda uyarır.

**Saat:** Router'ın saati NTP senkronize olana kadar yanlıştır ve bu
sürede TLS sertifikaları geçersiz görünür. picogit bu durumu açıkça bildirir
("cihaz saatini/NTP'yi kontrol edin" anlamındaki mesaj). Script'lerde önce
NTP'yi bekleyin. Merlin'de:
`until [ "$(nvram get ntp_ready)" = 1 ]; do sleep 5; done`.

**Önemli farklar:**
- `commit -a` **yeni (izlenmeyen) dosyaları da** commit'ler, çünkü `add`
  komutu yoktur. `.gitignore` kurallarına uyulur.
- `pull` yalnızca fast-forward yapar. Geçmiş ayrışmışsa hiçbir şeye
  dokunmadan hata verir.
- `push` force desteklemez.
- `clone` varsayılan olarak `--depth 1` ile yapılır; tam geçmiş için
  `--depth 0` verin.

**OpenWrt paketi:** `openwrt/picogit` OpenWrt'nin kendi `libmbedtls`,
`zlib` ve `ca-bundle` paketlerini kullanır; yaklaşık 260 KB'tır.
Packages feed'ine gönderilmek üzere hazırdır (bkz. `openwrt/README.md`).

**Katkı ve destek:** Hata bildirimi ve katkılar için önce
[`CONTRIBUTING.md`](CONTRIBUTING.md) dosyasını okuyun; güvenlik açıklarını
[`SECURITY.md`](SECURITY.md)'deki gibi gizli bildirin. Planlar
[`ROADMAP.md`](ROADMAP.md)'dedir. Projeyi
[GitHub Sponsors](https://github.com/sponsors/ooguz),
[Buy Me a Coffee](https://buymeacoffee.com/ooguz) veya
[PayPal](https://paypal.me/ozcanoguz) ile destekleyebilirsiniz.

**Derleme:** `make armv7` komutu sabitlenmiş zig, Lua, zlib, Mbed TLS ve CA
paketini checksum kontrolüyle indirip `build/armv7/picogit` dosyasını
üretir. `make test-armv7` tüm testleri FPU'su kapatılmış bir Cortex-A9
emülasyonunda çalıştırır. Ayrıntılar yukarıdaki İngilizce bölümlerdedir.
