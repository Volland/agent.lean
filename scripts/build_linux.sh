#!/usr/bin/env bash
# Build a bundle for Linux (static musl, Alpine) in Docker and run the conformance suite, the
# thread test, the reference agent and the budget check.
#   scripts/build_linux.sh BUNDLE_DIR PLATFORM [--update] [--no-bench]
# PLATFORM is a Docker platform: linux/arm64, linux/amd64, linux/arm/v7, linux/riscv64.
# The container has only Alpine, clang and CMake: no Lean, so this also proves the bundle builds without it.
# @tg: implements:: [[openspec:portable-build#Target matrix]]
# @tg: verifies:: [[openspec:portable-build#Source bundle#Build without Lean]] {level: e2e}
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE=${1:?bundle dir}; PLATFORM=${2:?platform}; shift 2
case "$PLATFORM" in
  linux/arm64) TARGET=linux-aarch64 ;; linux/amd64) TARGET=linux-x86_64 ;;
  linux/arm/v7) TARGET=linux-armv7 ;; linux/riscv64) TARGET=linux-riscv64 ;;
  *) echo "unknown platform $PLATFORM"; exit 2 ;;
esac
OUT=build/$TARGET
docker run --rm --platform "$PLATFORM" -v "$PWD":/w -w /w alpine:3.20 sh -euc "
  apk add -q --no-cache clang cmake make musl-dev g++ linux-headers python3 binutils >/dev/null
  cmake -S $BUNDLE -B $OUT -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_EXE_LINKER_FLAGS=-static >/dev/null
  cmake --build $OUT -j \$(nproc) 2>&1 | grep -E 'error|warning: undefined' || true
  $OUT/conformance traces/*.golden
  $OUT/threads traces/tools-parallel-sensitive.golden traces/agent-as-tool.golden
  $OUT/ref_agent
  python3 scripts/check_budgets.py --build $OUT --target $TARGET $*
"
