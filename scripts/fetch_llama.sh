#!/usr/bin/env bash
# Fetch and build what the in-process local inference adapter (c/llama, ADR 0004) needs:
#   1. llama.cpp at a pinned release, shallow-cloned into build/llama/llama.cpp
#   2. a small instruct GGUF with tool calling into build/llama/models (skipped if present)
#   3. the static libraries llama, ggml and llama-common (Metal on macOS, CPU elsewhere),
#      configured through c/llama/CMakeLists.txt into build/llama/build
# Everything lands under build/llama/ (gitignored). Re-running is cheap: each step is skipped when done.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

# Pinned llama.cpp release (https://github.com/ggml-org/llama.cpp/releases/tag/b12169).
LLAMA_TAG=b12169
LLAMA_COMMIT=3ed7284f2d9e22b2d1a7d05c1416c00c5a9f0bc7

# Qwen2.5-0.5B-Instruct, Q4_K_M (~470 MiB); its chat template supports tools (<tool_call> JSON).
MODEL_URL=https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
MODEL_SHA256=74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db

LLAMA_DIR=$ROOT/build/llama/llama.cpp
MODEL=$ROOT/build/llama/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
BUILD_DIR=${BUILD_DIR:-$ROOT/build/llama/build}
mkdir -p "$ROOT/build/llama/models"

# 1. llama.cpp
if [ ! -d "$LLAMA_DIR/.git" ]; then
  git -c advice.detachedHead=false clone --depth 1 --branch "$LLAMA_TAG" \
    https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi
HEAD=$(git -C "$LLAMA_DIR" rev-parse HEAD)
if [ "$HEAD" != "$LLAMA_COMMIT" ]; then
  echo "llama.cpp at $HEAD, expected $LLAMA_TAG ($LLAMA_COMMIT); remove $LLAMA_DIR and re-run" >&2
  exit 1
fi
echo "llama.cpp $LLAMA_TAG ($LLAMA_COMMIT)"

# 2. model
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
if [ ! -f "$MODEL" ]; then
  curl -fL --retry 3 -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
fi
if [ "${SKIP_MODEL_CHECK:-0}" != 1 ] && [ "$(sha256 "$MODEL")" != "$MODEL_SHA256" ]; then
  echo "checksum mismatch for $MODEL" >&2
  exit 1
fi
echo "model $MODEL"

# 3. static libraries (the same build tree scripts/test_llama.sh builds the adapter and tests in)
JOBS=$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)
cmake -S "$ROOT/c/llama" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CPP_DIR="$LLAMA_DIR" >/dev/null 2>&1 \
  || cmake -S "$ROOT/c/llama" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CPP_DIR="$LLAMA_DIR"
cmake --build "$BUILD_DIR" -j "$JOBS" --target llama ggml llama-common
echo "built llama, ggml, llama-common in $BUILD_DIR"
