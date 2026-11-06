module
public import Lean
public section
open Lean Elab Command
syntax (name := hello) "hello_def " ident : command
@[command_elab hello] meta def elabHello : CommandElab := fun stx => do
  let id : Ident := ⟨stx[1]⟩
  elabCommand (← `(def $id : String := "hi"))
end
