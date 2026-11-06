module

public import AgentLean.Schema
public import AgentLean.Policy

/-!
# Tools and agents

A `Tool α β` is declared in Lean with its input and output types, its executor, a required
idempotency flag, data labels and optional contracts (ADR 0006). The core works with the erased
`ToolDef`, which carries the derived schema and the decode-and-check functions.
-/

@[expose] public section

namespace AgentLean

-- @tg: implements:: [[adr:0006]]
-- @tg: implements:: [[openspec:tools#Tool executors]]
/-- Where a tool runs. -/
inductive Executor where
  /-- Inside the core, during `step`: no host round trip. -/
  | pure
  /-- In the Lean driver (`AgentLean.Driver`), as an `IO` action. -/
  | io
  /-- In the host application; `id` names the host's implementation. -/
  | host (id : String)
  /-- Another registered agent, run as a child of this one. -/
  | agent (name : String)
  deriving BEq, Repr, Inhabited

-- @tg: implements:: [[openspec:tools#Tool contracts]]
-- @tg: implements:: [[openspec:tools#Idempotency declaration]]
-- @tg: implements:: [[openspec:tools#Data labels]]
/-- A typed tool. `idempotent` has no default: every tool author decides whether a call that was
in flight during a crash may be re-issued. -/
structure Tool (α β : Type) where
  name : String
  description : String
  executor : Executor
  idempotent : Bool
  /-- Output may contain untrusted content (web pages, emails, ...). -/
  untrusted : Bool := false
  /-- Output is sensitive: traces holding it are flagged for encryption at rest. -/
  sensitive : Bool := false
  /-- Precondition on decoded arguments, a decidable predicate. -/
  pre : α → Bool := fun _ => true
  /-- Postcondition on arguments and result. -/
  post : α → β → Bool := fun _ _ => true
  /-- Implementation for `Executor.pure`. -/
  run : α → Except String β := fun _ => .error "no pure implementation"
  /-- Implementation for `Executor.io`. -/
  runIO : α → IO (Except String β) := fun _ => pure (.error "no io implementation")

/-- Why a tool call produced no result. -/
inductive ToolFailure where
  | invalidArguments (detail : String)
  | unknownTool (name : String) (known : Array String)
  | precondition
  | postcondition
  | invalidResult (detail : String)
  | failed (detail : String)
  | refused (policy : String) (reason : String)
  | interrupted
  | budget
  deriving Inhabited, Repr

namespace ToolFailure

def kind : ToolFailure → String
  | invalidArguments _ => "invalid_arguments"
  | unknownTool .. => "unknown_tool"
  | precondition => "precondition_failed"
  | postcondition => "postcondition_failed"
  | invalidResult _ => "invalid_result"
  | failed _ => "tool_error"
  | refused .. => "policy_refused"
  | interrupted => "interrupted"
  | budget => "budget_exhausted"

/-- The JSON the model sees in place of a result. -/
def toJson : ToolFailure → Json
  | f@(invalidArguments d) | f@(invalidResult d) | f@(failed d) =>
    Json.mkObj [("error", some (.str f.kind)), ("detail", some (.str d))]
  | f@(unknownTool n known) =>
    Json.mkObj [("error", some (.str f.kind)), ("name", some (.str n)),
      ("available", some (.arr (known.map .str)))]
  | f@(refused p r) =>
    Json.mkObj [("error", some (.str f.kind)), ("policy", some (.str p)),
      ("reason", if r.isEmpty then none else some (.str r))]
  | f => Json.mkObj [("error", some (.str f.kind))]

end ToolFailure

/-- A tool with its types erased, as the core uses it. -/
structure ToolDef where
  name : String
  description : String
  schema : Json
  executor : Executor
  idempotent : Bool
  untrusted : Bool
  sensitive : Bool
  /-- Decode the arguments and check the precondition. -/
  check : Json → Except ToolFailure Unit
  /-- Run a pure tool on arguments that passed `check`. -/
  runPure : Json → Except ToolFailure Json
  /-- Run an io tool on arguments that passed `check`. -/
  runIO : Json → IO (Except ToolFailure Json)
  /-- Decode a result and check the postcondition. -/
  checkResult : Json → Json → Except ToolFailure Unit

instance : Inhabited ToolDef where
  default := { name := "", description := "", schema := .null, executor := .pure, idempotent := true,
               untrusted := false, sensitive := false, check := fun _ => pure (),
               runPure := fun _ => throw (.failed "none"), runIO := fun _ => pure (throw (.failed "none")),
               checkResult := fun _ _ => pure () }

namespace Tool

variable {α β : Type} [FromJson α] [ToolSchema α] [ToJson β] [FromJson β]

def decodeArgs (j : Json) : Except ToolFailure α :=
  match (fromJson? j : Except String α) with
  | .ok a => pure a
  | .error e => throw (.invalidArguments e)

-- @tg: implements:: [[openspec:tools#Typed tool arguments]]
-- @tg: implements:: [[openspec:tools#Tool contracts]]
/-- Erase a typed tool. -/
def erase (t : Tool α β) : ToolDef where
  name := t.name
  description := t.description
  schema := schemaOf α
  executor := t.executor
  idempotent := t.idempotent
  untrusted := t.untrusted
  sensitive := t.sensitive
  check j := do
    let a : α ← decodeArgs j
    unless t.pre a do throw .precondition
  runPure j := do
    let a : α ← decodeArgs j
    match t.run a with
    | .ok b => pure (toJson b)
    | .error e => throw (.failed e)
  runIO j := do
    match (decodeArgs j : Except ToolFailure α) with
    | .error e => pure (throw e)
    | .ok a => return match ← t.runIO a with
      | .ok b => pure (toJson b)
      | .error e => throw (.failed e)
  checkResult j r := do
    let a : α ← decodeArgs j
    let b : β ← match (fromJson? r : Except String β) with
      | .ok b => pure b
      | .error e => throw (.invalidResult e)
    unless t.post a b do throw .postcondition

end Tool

/-- Limits for one run. -/
structure Budget where
  /-- Accepted events. -/
  steps : Nat := 64
  /-- Tool calls (refused and failed calls do not count). -/
  toolCalls : Nat := 32
  /-- Model tokens, as reported by the provider or estimated. -/
  tokens : Nat := 200000
  deriving Repr, Inhabited, BEq

/-- An agent definition, compiled into the application. -/
structure Agent where
  name : String
  system : String
  tools : Array ToolDef
  policies : Array Policy := #[]
  budget : Budget := {}
  deriving Inhabited

namespace Agent

def tool? (a : Agent) (name : String) : Option ToolDef := a.tools.find? (·.name == name)

def toolNames (a : Agent) : Array String := a.tools.map (·.name)

end Agent

end AgentLean

namespace AgentLean

/-- Input of an agent used as a tool. -/
def agentToolSchema : Json :=
  objectSchema #[("task", Json.mkObj [("type", some (.str "string")),
    ("description", some (.str "What the agent should do"))], false)]

/-- Use the registered agent `agentName` as a tool of another agent. The child gets the `task`
argument as its user turn and returns its final answer as the result. -/
def Agent.asTool (agentName : String) (toolName : String) (description : String)
    (idempotent : Bool := false) : ToolDef :=
  { name := toolName, description, schema := agentToolSchema, executor := .agent agentName,
    idempotent, untrusted := false, sensitive := false,
    check := fun j => do
      checkKnownKeys j #["task"] |>.mapError ToolFailure.invalidArguments
      match (j.get? "task").bind Json.getStr? with
      | some _ => pure ()
      | none => throw (.invalidArguments "missing field 'task'")
    runPure := fun _ => throw (.failed "agent tools run as child agents")
    runIO := fun _ => pure (throw (.failed "agent tools run as child agents"))
    checkResult := fun _ _ => pure () }

end AgentLean
