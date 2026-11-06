#!/usr/bin/env bash
# A runtime module that imports Lean, or a Std module outside bundle/std-allowlist.txt, must make the
# bundle step fail and name the import chain. Uses the spike project as a scratch Lake project.
# @tg: verifies:: [[openspec:portable-build#Runtime import allowlist#Forbidden import fails build]] {level: integration}
set -euo pipefail
cd "$(dirname "$0")/.."
trap 'rm -f spike/Spike/ForbiddenStd.lean spike/Spike/ForbiddenLean.lean' EXIT
cat > spike/Spike/ForbiddenStd.lean <<'LEAN'
module
public import Std.Data.HashMap
public def table : Std.HashMap String Nat := {}
LEAN
cat > spike/Spike/ForbiddenLean.lean <<'LEAN'
module
public import Lean.Data.Json
public def doc : Lean.Json := Lean.Json.null
LEAN
(cd spike && lake build Spike.ForbiddenStd Spike.ForbiddenLean >/dev/null)
check() {
  local root=$1 want=$2
  if out=$(python3 scripts/bundle.py --project spike --root "$root" --out build/allowlist-test 2>&1); then
    echo "FAIL: bundling $root should have failed"; exit 1
  fi
  echo "$out" | grep -q "$want" || { echo "FAIL: unexpected message: $out"; exit 1; }
  echo "ok: $root rejected: $(echo "$out" | tail -1)"
}
check Spike.ForbiddenStd "Spike.ForbiddenStd -> Std.Data.HashMap"
check Spike.ForbiddenLean "forbidden"
