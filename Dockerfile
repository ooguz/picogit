# Reproducible build and test environment for picogit.
#
#   docker build -t picogit-build .                  # builds all targets
#   docker build -t picogit-test --target test .     # tools for `make test-armv7`
#
# The base image is pinned by digest; all other inputs (zig, Lua, zlib,
# Mbed TLS, CA bundle) are pinned with checksums in deps.mk.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      make gcc libc6-dev curl ca-certificates xz-utils bzip2 python3 git qemu-user openssl \
 && rm -rf /var/lib/apt/lists/*

FROM base AS test

FROM base AS build
WORKDIR /src
COPY . .
RUN make host armv7 armv7hf aarch64 mipsel mips && make sizes
