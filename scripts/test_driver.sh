#!/usr/bin/env bash
# The Lean driver runs the example agent against a scripted endpoint (HTTP via libcurl, an io tool
# in-process, a pure tool in the core); the C ABI then replays the recorded run and must produce
# the same effects byte for byte.
# @tg: verifies:: [[openspec:host-abi#Lean driver#Driver runs agent against endpoint]] {level: integration}
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-18080}
python3 scripts/mock_llm.py "$PORT" & MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT" -X POST -d '{}' && break || sleep 0.1; done
mkdir -p build
AGENT_CREDENTIAL_OPENAI=test-key .lake/build/bin/driver_demo --endpoint "http://127.0.0.1:$PORT/v1/chat/completions" \
  --golden build/driver.golden "add 2 and 3 and look up the region"
CONFORMANCE=${CONFORMANCE:-build/host/conformance}
if [ -x "$CONFORMANCE" ]; then
  "$CONFORMANCE" build/driver.golden
else
  echo "skip C replay: $CONFORMANCE not built"
fi
