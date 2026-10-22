# Contributing to picogit

Bug reports and fixes are welcome. Report bugs in the
[issue tracker](https://github.com/ooguz/picogit/issues). Include the
output of `uname -a`, `picogit --version` and, for network or protocol
problems, the command run with `PICOGIT_TRACE=1` (it never contains
tokens). A security problem goes through [`SECURITY.md`](SECURITY.md), not a
public issue.

Before you start a larger change, open an issue to discuss it. picogit
deliberately does few things (see the README's scope and
[`ROADMAP.md`](ROADMAP.md)), and every feature is weighed against the
1 MiB size budget.

## Development setup

Linux x86_64 with `make`, `curl`, `tar` (xz, bzip2), `python3`, a native C
compiler, `git` and `openssl`:

```sh
git clone https://github.com/ooguz/picogit.git
cd picogit
make host        # downloads the pinned toolchain and sources on first use
make test        # unit and integration tests
```

For the router targets you also need qemu-user, or Docker, which the
Makefile falls back to:

```sh
make armv7 && make test-armv7
make riscv64 && make test-qemu-riscv64
```

## Checks

CI runs these, and a change should pass them locally first:

```sh
make test                  # host: unit + integration
make test-armv7            # armv7 under qemu on a Cortex-A9 without FPU
make test-oldkernel        # armv7 with getrandom() unavailable
make host armv7 armv7hf aarch64 mipsel mips x86 riscv64 && make check-size
sh tools/check-openwrt-package.sh
```

`make check-size` fails if any binary reaches 1 MiB. Report the size
change of every target in the pull request (`make sizes` before and
after).

## Code

- **Layout.** C code is in `src/c`, application logic is Lua 5.4 in
  `src/lua`. Keep the C core small and generic: streaming, hashing, TLS,
  system calls. Git logic belongs in Lua.
- **Errors.** User-facing errors use `util.die("...")` (no Lua position).
  Messages never contain credentials; use `util.redact_url` for URLs.
- **Repository compatibility.** Anything that writes to `.git` must keep
  real git happy. Integration tests check every scenario with
  `git fsck --strict` and `git status --porcelain`.
- **Tests.** New behaviour needs a test. Unit tests go in `test/unit`;
  scenarios go against the local server in `test/integration/t_*.sh`. A
  bug fix needs a test that fails without the fix.
- **Style.** Follow the surrounding style (`.editorconfig`): 4 spaces in C,
  2 in Lua. Every file carries an SPDX license header.

## Dependencies

Lua, zlib, Mbed TLS, the CA bundle and the zig toolchain are pinned by
version and SHA-256 in [`deps.mk`](deps.mk). To update one:
1. Change the version and checksum together, verifying the checksum
   against the upstream publication.
2. Run the full test set.
3. For Lua, also update `openwrt/picogit/Makefile`
   (`tools/check-openwrt-package.sh` checks this).

## Pull requests

- One topic per pull request, with commits that build and pass tests on
  their own.
- Explain why in the description, not only what changed.
- By contributing you agree that your contribution is licensed under the
  project's license, GPL-3.0-or-later.

## Releases

Maintainers tag `vX.Y.Z` (semver). CI builds all targets, runs the tests,
and attaches the binaries, `SHA256SUMS` and the source tarball to the
GitHub release. The OpenWrt package is then updated with the new version
and tarball hash; see [`openwrt/README.md`](openwrt/README.md).

Everyone taking part in the project follows the
[code of conduct](CODE_OF_CONDUCT.md).
