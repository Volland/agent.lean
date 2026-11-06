#!/usr/bin/env bash
# No `sorry` in runtime or theorem modules, and the main theorems use only Lean's standard axioms.
# @tg: verifies:: [[openspec:portable-build#No unproven runtime code#sorry fails build]] {level: e2e}
# @tg: implements:: [[openspec:portable-build#No unproven runtime code]]
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
# 1. textual: `sorry`/`admit` outside comments and strings in library sources
if grep -rnE '^[^-"]*\b(sorry|admit)\b' AgentLean AgentLean.lean Examples 2>/dev/null | grep -v -- '--' ; then
  echo "check_proofs: sorry/admit found"; fail=1
fi
# 2. the compiler's own report
if lake build AgentLean AgentLean.Meta Examples 2>&1 | grep -E "declaration uses 'sorry'|declaration uses \`sorry\`"; then
  echo "check_proofs: a declaration uses sorry"; fail=1
fi
# 3. axioms of the main theorems
out=$(lake env lean Tests/Axioms.lean 2>&1)
echo "$out"
if ! echo "$out" | python3 -c '
import re, sys
ok = {"propext", "Classical.choice", "Quot.sound"}
bad, seen = [], 0
for line in sys.stdin:
    m = re.search(r"depends on axioms: \[(.*)\]", line)
    if m:
        seen += 1
        bad += [a.strip() for a in m.group(1).split(",") if a.strip() not in ok]
    elif "does not depend on any axioms" in line:
        seen += 1
    elif "error" in line:
        bad.append(line.strip())
if bad or seen == 0:
    print("non-standard axioms or errors:", bad or "no theorems checked")
    sys.exit(1)
'; then fail=1; fi
[ $fail -eq 0 ] && echo "check_proofs: ok"
exit $fail
