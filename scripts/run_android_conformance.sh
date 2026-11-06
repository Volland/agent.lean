#!/usr/bin/env bash
# Push the NDK-built conformance runner and the golden traces to a device or emulator and run them.
#   scripts/run_android_conformance.sh BUILD_DIR
set -euo pipefail
cd "$(dirname "$0")/.."
B=${1:?build dir}
adb push "$B/conformance" "$B/threads" "$B/ref_agent" /data/local/tmp/ >/dev/null
adb shell mkdir -p /data/local/tmp/traces
adb push traces/*.golden /data/local/tmp/traces/ >/dev/null
adb shell "cd /data/local/tmp && chmod 755 conformance threads ref_agent && ./conformance traces/*.golden && ./threads traces/tools-parallel-sensitive.golden traces/agent-as-tool.golden && ./ref_agent"
