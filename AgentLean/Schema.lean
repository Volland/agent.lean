module

public import AgentLean.Json

/-!
# Tool schemas

`ToolSchema α` gives the JSON Schema of a tool's input type. Schemas for structures are derived
(`deriving ToolSchema`, in `AgentLean.Meta`) from the same field list the derived `FromJson` decodes,
so a value fits the schema exactly when it decodes. `Schema.validate` checks a value against a
schema; the tests use it to compare schema acceptance with decoding on generated values.
-/

@[expose] public section

namespace AgentLean

class ToolSchema (α : Type) where
  schema : Json

def schemaOf (α : Type) [ToolSchema α] : Json := ToolSchema.schema α

instance : ToolSchema String := ⟨Json.mkObj [("type", some (.str "string"))]⟩
instance : ToolSchema Bool := ⟨Json.mkObj [("type", some (.str "boolean"))]⟩
instance : ToolSchema Int := ⟨Json.mkObj [("type", some (.str "integer"))]⟩
instance : ToolSchema Nat := ⟨Json.mkObj [("type", some (.str "integer")), ("minimum", some (.nat 0))]⟩
instance : ToolSchema UInt8 :=
  ⟨Json.mkObj [("type", some (.str "integer")), ("minimum", some (.nat 0)), ("maximum", some (.nat 255))]⟩
instance : ToolSchema UInt16 :=
  ⟨Json.mkObj [("type", some (.str "integer")), ("minimum", some (.nat 0)), ("maximum", some (.nat 65535))]⟩
instance : ToolSchema UInt32 :=
  ⟨Json.mkObj [("type", some (.str "integer")), ("minimum", some (.nat 0)), ("maximum", some (.nat 4294967295))]⟩
instance : ToolSchema UInt64 :=
  ⟨Json.mkObj [("type", some (.str "integer")), ("minimum", some (.nat 0)),
    ("maximum", some (.nat 18446744073709551615))]⟩
instance : ToolSchema Json := ⟨Json.obj #[]⟩
instance {α} [ToolSchema α] : ToolSchema (Option α) := ⟨ToolSchema.schema α⟩
instance {α} [ToolSchema α] : ToolSchema (Array α) :=
  ⟨Json.mkObj [("type", some (.str "array")), ("items", some (ToolSchema.schema α))]⟩
instance {α} [ToolSchema α] : ToolSchema (List α) :=
  ⟨Json.mkObj [("type", some (.str "array")), ("items", some (ToolSchema.schema α))]⟩

/-- Whether a field type may be absent from an object (only `Option`). -/
class OptionalField (α : Type) where
  optional : Bool

instance (priority := low) {α} : OptionalField α := ⟨false⟩
instance {α} : OptionalField (Option α) := ⟨true⟩

/-! ## Helpers called by derived instances (keyed on projection functions) -/

def fieldSchema {σ β} [ToolSchema β] (_proj : σ → β) : Json := ToolSchema.schema β
def fieldOptional {σ β} [OptionalField β] (_proj : σ → β) : Bool := OptionalField.optional β

/-- Decode field `k` with the projection's type; an absent optional field decodes as `null`. -/
def decodeField {σ β} [FromJson β] [OptionalField β] (_proj : σ → β) (j : Json) (k : String) :
    Except String β :=
  match j.getOpt? k with
  | some v => match fromJson? v with
    | .ok b => pure b
    | .error e => throw s!"{k}: {e}"
  | none => if OptionalField.optional β then
      match fromJson? Json.null with
      | .ok b => pure b
      | .error e => throw s!"{k}: {e}"
    else throw s!"missing field '{k}'"

-- @tg: implements:: [[openspec:tools#Schema derived from tool type]]
/-- An object schema from (name, schema, optional) triples; closed to unknown properties. -/
def objectSchema (fields : Array (String × Json × Bool)) : Json :=
  Json.mkObj [
    ("type", some (.str "object")),
    ("properties", some (.obj (fields.map fun (k, s, _) => (k, s)))),
    ("required", some (.arr ((fields.filter fun (_, _, o) => !o).map fun (k, _, _) => .str k))),
    ("additionalProperties", some (.bool false))]

/-- Reject unknown keys, so decoding agrees with `additionalProperties: false`. -/
def checkKnownKeys (j : Json) (known : Array String) : Except String Unit :=
  match j with
  | .obj kvs => match kvs.find? (fun (k, _) => !known.contains k) with
    | some (k, _) => throw s!"unknown field '{k}'"
    | none => pure ()
  | _ => throw "expected object"

/-! ## Validation -/

namespace Schema

def typeOk (ty : String) (v : Json) : Bool :=
  match ty, v with
  | "string", .str _ => true
  | "boolean", .bool _ => true
  | "integer", .num n => n.toInt?.isSome
  | "number", .num _ => true
  | "array", .arr _ => true
  | "object", .obj _ => true
  | "null", .null => true
  | _, _ => false

/-- Validate `v` against the schema subset agent.lean emits: `type`, `properties`, `required`,
`additionalProperties: false`, `items`, `minimum`, `maximum`, `enum`. -/
partial def validate (s v : Json) : Bool := Id.run do
  if let some (.str ty) := s.get? "type" then
    unless typeOk ty v do return false
  if let some (.arr opts) := s.get? "enum" then
    unless opts.any (· == v) do return false
  if let some i := v.getInt? then
    if let some lo := (s.get? "minimum").bind Json.getInt? then
      if i < lo then return false
    if let some hi := (s.get? "maximum").bind Json.getInt? then
      if i > hi then return false
  if let .arr xs := v then
    if let some items := s.get? "items" then
      unless xs.all (validate items) do return false
  if let .obj kvs := v then
    let props := match s.get? "properties" with | some (.obj ps) => ps | _ => #[]
    if let some (.arr req) := s.get? "required" then
      for r in req do
        if let .str k := r then
          unless kvs.any (·.1 == k) do return false
    if s.get? "additionalProperties" == some (.bool false) then
      unless kvs.all (fun (k, _) => props.any (·.1 == k)) do return false
    for (k, x) in kvs do
      if let some (_, ps) := props.find? (·.1 == k) then
        unless x == .null || validate ps x do return false
  return true

end Schema

end AgentLean
