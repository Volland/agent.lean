module

public import Tests.Core
public import Tests.More

/-! Runs every scenario test; exits non-zero if any fails. -/

open Tests

public def main : IO UInt32 := do
  let all := Core.cases ++ More.cases
  let mut failed := 0
  for c in all do
    match ← c.run.run with
    | .ok () => IO.println s!"  ok    {c.name}"
    | .error e =>
      failed := failed + 1
      IO.println s!"  FAIL  {c.name}: {e}"
  IO.println s!"{all.length - failed}/{all.length} scenarios passed"
  return if failed == 0 then 0 else 1
