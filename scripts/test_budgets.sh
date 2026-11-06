#!/usr/bin/env bash
# The budget check must fail when the reference agent outgrows its size budget, and when the linked
# runtime symbols differ from the manifest. Uses copies of the budget files.
#   scripts/test_budgets.sh BUILD_DIR TARGET
set -euo pipefail
cd "$(dirname "$0")/.."
B=${1:?build dir}; T=${2:?target}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp bench/budgets.json "$tmp/budgets.json"; cp -R bundle/runtime-surface "$tmp/surface"
run() { python3 scripts/check_budgets.py --build "$B" --target "$T" --no-bench --budgets "$tmp/budgets.json" --surface-dir "$tmp/surface" "$@"; }
# record this machine's measurements as the baseline in the copies, then check that changes fail
run --update >/dev/null
run >/dev/null || { echo "FAIL: baseline should pass"; exit 1; }

size_regression() {
  # @tg: verifies:: [[openspec:portable-build#Binary size budget#Size regression fails CI]] {level: integration}
  python3 - "$tmp/budgets.json" "$T" <<'PY'
import json, sys
p, t = sys.argv[1], sys.argv[2]
b = json.load(open(p)); b["targets"][t]["size_bytes"] = int(b["targets"][t]["size_bytes"] * 0.8)
json.dump(b, open(p, "w"))
PY
  if out=$(run); then echo "FAIL: size regression not detected"; exit 1; fi
  echo "$out" | grep -q "size .* > budget" && echo "ok: size regression fails: $(echo "$out" | grep FAIL)"
  run --update >/dev/null
}

surface_change() {
  # @tg: verifies:: [[openspec:portable-build#Runtime surface manifest#New runtime symbol fails CI]] {level: integration}
  sed -i.bak '1d' "$tmp/surface/$T.txt"
  if out=$(run); then echo "FAIL: runtime surface change not detected"; exit 1; fi
  echo "$out" | grep -q "runtime surface changed" && echo "ok: new runtime symbol fails: $(echo "$out" | grep FAIL | cut -c1-120)"
}

size_regression
surface_change
