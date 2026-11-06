#!/usr/bin/env bash
# End-to-end tests of the in-process local inference adapter (c/llama, ADR 0004).
#
# Transport neutrality: llama_run drives the example assistant with every llm_request served by the
# local model and writes the run as a golden trace; a second run must write the identical file
# (deterministic local transport), and llama_conformance must replay it through the C ABI with
# identical effects -- the same response bytes delivered as ordinary llm_response events, as an HTTP
# host would deliver them.
# Constrained decoding: llama_constrained checks every tool call the model emits against the tool's
# schema.
#
# Run scripts/fetch_llama.sh first (llama.cpp, model, static libs).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
BUILD_DIR=${BUILD_DIR:-$ROOT/build/llama/build}
MODEL=${MODEL:-$ROOT/build/llama/models/qwen2.5-0.5b-instruct-q4_k_m.gguf}
OUT=$ROOT/build/llama/out
PROMPT=${PROMPT:-"What is 17 plus 25? Use the add tool."}
mkdir -p "$OUT"

[ -f "$MODEL" ] || { echo "model not found: $MODEL (run scripts/fetch_llama.sh)" >&2; exit 1; }
JOBS=$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)
cmake -S "$ROOT/c/llama" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release >"$OUT/build.log" 2>&1 \
  || { cat "$OUT/build.log" >&2; exit 1; }
cmake --build "$BUILD_DIR" -j "$JOBS" --target llama_run llama_constrained llama_conformance >>"$OUT/build.log" 2>&1 \
  || { tail -40 "$OUT/build.log" >&2; exit 1; }

now() { python3 -c 'import time; print(time.time())'; }
secs() { python3 -c "print(f'{$2 - $1:.1f}s')"; }

echo "== transport neutrality: run 1"
t=$(now)
"$BUILD_DIR/llama_run" --model "$MODEL" --golden "$OUT/run1.golden" "$PROMPT" 2>"$OUT/run1.log"
echo "   ($(secs "$t" "$(now)"))"
echo "== transport neutrality: run 2"
t=$(now)
"$BUILD_DIR/llama_run" --model "$MODEL" --golden "$OUT/run2.golden" "$PROMPT" 2>"$OUT/run2.log" >/dev/null
echo "   ($(secs "$t" "$(now)"))"
if cmp -s "$OUT/run1.golden" "$OUT/run2.golden"; then
  echo "   identical golden files ($(wc -l <"$OUT/run1.golden" | tr -d ' ') lines)"
else
  echo "FAIL: the two local runs differ" >&2
  diff "$OUT/run1.golden" "$OUT/run2.golden" | head -20 >&2
  exit 1
fi
echo "== transport neutrality: replay the local run as ordinary events"
"$BUILD_DIR/llama_conformance" "$OUT/run1.golden"

echo "== constrained decoding"
t=$(now)
"$BUILD_DIR/llama_constrained" --model "$MODEL" 2>"$OUT/constrained.log"
echo "   ($(secs "$t" "$(now)"))"
echo "all llama tests passed"
