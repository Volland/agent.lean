module

public meta import Lean.Elab.Command
public import AgentLean.Policy

/-!
# The `policy` command and policy notation

Compile-time only (`meta import AgentLean.Meta.Policy`).

```lean
open AgentLean.Formula in
policy confirmBeforePay := requiresBefore "transfer" "confirm_user"
policy noDelete halt := ¬ₚ call! "delete_all"
```

`policy n := f` defines `n : Policy` named `"n"`; `halt` makes violations end the run. Notation:
`call! "x"`, `f ⟹ g`, `f ∧ₚ g`, `f ∨ₚ g`, `¬ₚ f`, `once f`, `prev f`, `f since g`.
-/

public section

namespace AgentLean

syntax:max "call! " str : term
macro_rules | `(call! $s) => `(AgentLean.Formula.isCall $s)

syntax:25 term:26 " ⟹ " term:25 : term
macro_rules | `($f ⟹ $g) => `(AgentLean.Formula.implies $f $g)
syntax:35 term:36 " ∧ₚ " term:35 : term
macro_rules | `($f ∧ₚ $g) => `(AgentLean.Formula.and $f $g)
syntax:30 term:31 " ∨ₚ " term:30 : term
macro_rules | `($f ∨ₚ $g) => `(AgentLean.Formula.or $f $g)
syntax:max "¬ₚ " term:max : term
macro_rules | `(¬ₚ $f) => `(AgentLean.Formula.not $f)
syntax:40 term:41 " since " term:40 : term
macro_rules | `($f since $g) => `(AgentLean.Formula.since $f $g)

syntax (docComment)? "policy " ident (&" halt")? " := " term (" because " str)? : command
macro_rules
  | `($[$doc]? policy $n:ident $[halt%$h]? := $f $[because $r]?) => do
    let onV ← if h.isSome then `(AgentLean.OnViolation.halt) else `(AgentLean.OnViolation.recover)
    let reason : Lean.TSyntax `term := match r with
      | some s => ⟨s.raw⟩
      | none => Lean.quote ""
    `($[$doc]? def $n : AgentLean.Policy :=
        { name := $(Lean.quote n.getId.toString), rule := $f, onViolation := $onV, reason := $reason })

end AgentLean
