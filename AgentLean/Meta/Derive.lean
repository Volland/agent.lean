module

public meta import Lean.Elab.Deriving.Basic
public meta import Lean.Elab.Command
public import AgentLean.Schema

/-!
# Deriving `ToJson`, `FromJson` and `ToolSchema`

Compile-time only: import it with `meta import AgentLean.Meta.Derive`, so it never reaches the
runtime bundle. Supported:

* structures (one object key per field; `Option` fields may be absent),
* enumerations (inductives whose constructors take no arguments), as JSON strings.

The generated code calls `AgentLean.decodeField`, `fieldSchema` and `fieldOptional` with the
projection functions, so schema and decoder are built from the same field list and types.
-/

public section

open Lean Elab Command Meta

namespace AgentLean.Meta

meta def isEnum (decl : Name) : CommandElabM (Option (Array Name)) := do
  let env ← getEnv
  let some (.inductInfo info) := env.find? decl | return none
  let mut ctors := #[]
  for c in info.ctors do
    let some (.ctorInfo ci) := env.find? c | return none
    if ci.numFields != 0 then return none
    ctors := ctors.push c
  return some ctors

meta def fieldsOf (decl : Name) : CommandElabM (Option (Array Name)) := do
  let env ← getEnv
  if !isStructure env decl then return none
  return some (getStructureFields env decl)

meta def mkToJson (decl : Name) : CommandElabM Bool := do
  let T := mkIdent decl
  if let some fs ← fieldsOf decl then
    let pairs ← fs.mapM fun f =>
      `(term| ($(quote f.toString), AgentLean.toJson ($(mkIdent (decl ++ f)) x)))
    elabCommand (← `(instance : AgentLean.ToJson $T := ⟨fun x => AgentLean.Json.obj #[$pairs,*]⟩))
    return true
  if let some cs ← isEnum decl then
    let alts ← cs.mapM fun c =>
      `(Lean.Parser.Term.matchAltExpr| | $(mkIdent c):ident => AgentLean.Json.str $(quote c.getString!))
    elabCommand (← `(instance : AgentLean.ToJson $T := ⟨fun x => match x with $alts:matchAlt*⟩))
    return true
  return false

meta def mkFromJson (decl : Name) : CommandElabM Bool := do
  let T := mkIdent decl
  if let some fs ← fieldsOf decl then
    let vals ← fs.mapM fun f =>
      `(term| (← AgentLean.decodeField $(mkIdent (decl ++ f)) j $(quote f.toString)))
    let names := fs.map fun f => (quote f.toString : Term)
    elabCommand (← `(instance : AgentLean.FromJson $T := ⟨fun j => do
      AgentLean.checkKnownKeys j #[$names,*]
      pure ⟨$vals,*⟩⟩))
    return true
  if let some cs ← isEnum decl then
    let alts ← cs.mapM fun c =>
      `(Lean.Parser.Term.matchAltExpr| | $(quote c.getString!):str => pure $(mkIdent c):ident)
    elabCommand (← `(instance : AgentLean.FromJson $T := ⟨fun j => match j with
      | .str s => match s with
        $alts:matchAlt*
        | other => throw s!"unknown value '{other}'"
      | _ => throw "expected string"⟩))
    return true
  return false

-- @tg: implements:: [[openspec:tools#Schema derived from tool type]]
meta def mkToolSchema (decl : Name) : CommandElabM Bool := do
  let T := mkIdent decl
  if let some fs ← fieldsOf decl then
    let triples ← fs.mapM fun f =>
      `(term| ($(quote f.toString), AgentLean.fieldSchema $(mkIdent (decl ++ f)),
               AgentLean.fieldOptional $(mkIdent (decl ++ f))))
    elabCommand (← `(instance : AgentLean.ToolSchema $T := ⟨AgentLean.objectSchema #[$triples,*]⟩))
    return true
  if let some cs ← isEnum decl then
    let names := cs.map fun c => (quote c.getString! : Term)
    elabCommand (← `(instance : AgentLean.ToolSchema $T :=
      ⟨AgentLean.Json.mkObj [("type", some (.str "string")),
        ("enum", some (.arr ((#[$names,*] : Array String).map AgentLean.Json.str)))]⟩))
    return true
  return false

meta def handler (mk : Name → CommandElabM Bool) (decls : Array Name) : CommandElabM Bool := do
  let mut ok := true
  for d in decls do
    ok := ok && (← mk d)
  return ok

meta initialize
  registerDerivingHandler ``AgentLean.ToJson (handler mkToJson)
  registerDerivingHandler ``AgentLean.FromJson (handler mkFromJson)
  registerDerivingHandler ``AgentLean.ToolSchema (handler mkToolSchema)

end AgentLean.Meta
