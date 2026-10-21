#!/bin/sh
# Runs every test/unit/test_*.lua with the development binary, which can
# execute Lua files from disk with the embedded modules available.
#   PICOGIT_DEV_BIN="qemu-arm build/armv7/picogit-dev" sh test/unit/run.sh
dir=$(cd "$(dirname "$0")" && pwd)
bin=${PICOGIT_DEV_BIN:-$dir/../../build/host/picogit-dev}
echo "unit tests with: $bin"
# shellcheck disable=SC2086
exec $bin --dev-run "$dir/runner.lua" "$dir" "$dir"/test_*.lua
