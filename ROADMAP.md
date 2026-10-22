# Roadmap

picogit stays a small tool for small devices. Every feature is weighed
against two constraints:

- **Size budget:** every self-contained binary stays **below 1 MiB**.
  `make check-size` enforces this in CI.
- **Scope:** picogit does what a device needs to keep a directory in sync
  with a git server. Branching workflows, history rewriting and code review
  belong on a workstation.

## Size budget

Current sizes:

| Target | Size | Share of the 1 MiB budget |
|---|---|---|
| riscv64 | 611 KB | 58 % |
| x86 | 635 KB | 60 % |
| aarch64 | 654 KB | 62 % |
| x86_64 | 659 KB | 62 % |
| armv7hf | 669 KB | 63 % |
| armv7 | 689 KB | 65 % |
| mipsel | 898 KB | 85 % |
| mips (big-endian) | 935 KB | 89 % |
| OpenWrt package (system Mbed TLS/zlib) | 258 KB | — |

The application logic is 70 KB of Lua bytecode in total; the largest
modules are `commands` (12 KB), `transport` (9 KB) and `worktree` (9 KB).
A typical new command costs 2–5 KB of bytecode. The MIPS targets are the
tightest: MIPS code is less dense, and big-endian builds embed Lua source
(106 KB) instead of bytecode. Every pull request reports its size change.

## 0.2 — recovering from local mistakes

- **`picogit reset --hard`.** Restore the work tree and index to `HEAD`,
  discarding local modifications of tracked files. Untracked files are
  kept.
- **`picogit reset --hard origin`.** Move the current branch to its
  upstream (`refs/remotes/origin/<branch>`) and check that out, dropping
  local commits. This is the way out after `pull` reports a divergence.
  Combined with `pull` it gives "make this directory equal to the remote".
  The command lists the commits being dropped and the local changes being
  discarded before doing it.
- **`picogit status`.** Show modified, deleted and untracked files, and
  ahead/behind relative to the upstream. Almost free: it reuses the
  `commit -a` snapshot code. Scripts get a stable `--porcelain` form.
- **`picogit log [-n N]`.** One line per commit from `HEAD`, down to the
  shallow boundary.

Estimated cost: 8–12 KB of bytecode for all four.

## 0.3 — network

- **HTTP keep-alive** between the ref discovery and the
  `upload-pack`/`receive-pack` POST. This saves one TLS handshake per
  command, which is noticeable on slow routers (estimated 1–2 KB C).
- **HTTP(S) proxies** (`https_proxy`, `http_proxy`, `no_proxy`) via
  `CONNECT` (estimated 2–3 KB).
- **`pull --depth N`.** Keep a long-lived clone shallow by re-shallowing
  after the fast-forward check, so history no longer grows with every
  pull. This needs a careful fast-forward check, because a deepened fetch
  does not carry the intermediate commits.
- **gzip request bodies** for large negotiations (zlib is already linked).

## 0.4 — storage

- **`picogit gc`.** Remove unreachable loose objects and objects below
  the shallow boundary after the history moved on. Today a long-lived
  clone only grows.
- **Packed storage (optional).** Keep received packs and write `.idx`
  files instead of exploding them into loose objects. This means fewer
  inodes and less flash wear on jffs2. It costs a pack index writer and
  reader (estimated 10–15 KB), so it may become a build option.

## Packaging and distribution

- **OpenWrt packages feed:** submit `openwrt/picogit/Makefile` as
  `net/picogit` after the first release (`opkg install picogit` /
  `apk add picogit`); see [`openwrt/README.md`](openwrt/README.md).
- **Entware** (Asuswrt-Merlin and other firmware with `opkg` on USB or
  `/jffs`): package the static armv7/aarch64/mipsel binaries.
- **Reproducible release builds:** document and verify that two builds of
  the same tag produce identical binaries (inputs are already pinned).
- **Signed releases:** publish signatures and build provenance
  (attestations) for the release binaries.

## Size work

- **Minify embedded Lua source** on big-endian targets (strip comments
  and indentation at build time): about −40 KB on mips.
- **Optional CA bundle:** a build without the embedded Mozilla bundle that
  uses the system store, like the OpenWrt package. This saves about 95 KB
  for distributions that ship a CA store.
- Review which Mbed TLS features are needed: curves, P-521, and RSA-PSS
  only for certificates.

## Possible, not planned

These are open for discussion if there is real demand from device use
cases:
- `.gitattributes` eol conversion
- multiple remotes
- `fetch` without merging
- tags beyond `clone --branch <tag>`

## Out of scope

merge, rebase, branch management, force push, SSH transport, submodules,
LFS, sparse checkout, hooks.
