module

public import AgentLean.Trace

/-!
# Host ABI (Lean side)

The functions behind `c/agent.h` (ADR 0007). A `Handle` is an immutable Lean value; every call
returns a new one, which the C shim keeps. The library never calls host code and never starts
threads: the host pulls effects with `next` and feeds events with `feed`.

Applications register their agents in an `initialize` block:

```lean
initialize AgentLean.registerAgent myAgent
```
-/

@[expose] public section

namespace AgentLean

initialize registry : IO.Ref Env ← IO.mkRef { agents := #[] }

/-- Make an agent available to `agent_new` (call from an `initialize` block). -/
def registerAgent (a : Agent) : IO Unit := registry.modify fun env =>
  { agents := (env.agents.filter (·.name != a.name)).push a }

/-- Everything a host-side agent handle holds. -/
structure Handle where
  env : Env
  run : Run
  trace : Array Entry
  queue : Array Effect
  qpos : Nat
  error : String
  deriving Inhabited

namespace Handle

def utf8 (b : ByteArray) : Except String String :=
  match String.fromUTF8? b with
  | some s => pure s
  | none => throw "payload is not valid UTF-8"

def parseJson (b : ByteArray) : Except String Json := do Json.parse (← utf8 b)

def create (env : Env) (config : ByteArray) : Except String Handle := do
  let cfg : RunConfig ← fromJson? (← parseJson config)
  let run ← Run.init env cfg
  return { env, run, trace := #[], queue := #[], qpos := 0, error := "" }

/-- Error codes returned by `feed` (also in `agent.h`). -/
def okCode : UInt32 := 0
def invalidCode : UInt32 := 1
def rejectedCode : UInt32 := 2

/-- Feed one event. Invalid or unexpected events leave the handle unchanged (except `error`). -/
def feed (h : Handle) (bytes : ByteArray) : Handle × UInt32 :=
  match parseJson bytes >>= Event.fromJson? with
  | .error e => ({ h with error := s!"invalid event: {e}" }, invalidCode)
  | .ok ev =>
    if !accepts h.run ev then ({ h with error := "event not expected in the current state" }, rejectedCode)
    else
      let entry : Entry := { seq := h.trace.size, event := ev, sensitive := isSensitiveEvent h.env h.run ev,
                             untrusted := isUntrustedEvent h.env h.run ev }
      let (run, effs) := step h.env h.run ev
      let queue := (h.queue.extract h.qpos h.queue.size) ++ effs
      ({ h with run, trace := h.trace.push entry, queue, qpos := 0, error := "" }, okCode)

/-- The next pending effect as JSON, if any. -/
def next (h : Handle) : Option String × Handle :=
  if h.qpos < h.queue.size then
    (some (h.queue[h.qpos]!.toJson.render), { h with qpos := h.qpos + 1 })
  else (none, h)

def snapshot (h : Handle) : String := (snapshotJson h.run h.trace.size).render

/-- Restore from a snapshot plus the trace up to it (or an empty trace when the host keeps it). -/
def restore (env : Env) (snap : ByteArray) : Except String Handle := do
  let (run, _) ← parseSnapshot (← parseJson snap)
  return { env, run, trace := #[], queue := #[], qpos := 0, error := "" }

def traceText (h : Handle) : String := (traceJson h.run.config h.trace).render
def auditText (h : Handle) : String := (auditJson h.run.config h.trace).render

end Handle

/-! ## Exports used by the C shim -/

@[export agentlean_new]
def abiNew (config : ByteArray) : IO (Except String Handle) := do
  return Handle.create (← registry.get) config

@[export agentlean_restore]
def abiRestore (snap : ByteArray) : IO (Except String Handle) := do
  return Handle.restore (← registry.get) snap

@[export agentlean_feed]
def abiFeed (h : Handle) (event : ByteArray) : Handle × UInt32 := h.feed event

@[export agentlean_next]
def abiNext (h : Handle) : Option String × Handle := h.next

@[export agentlean_snapshot]
def abiSnapshot (h : Handle) : String := h.snapshot

@[export agentlean_trace]
def abiTrace (h : Handle) : String := h.traceText

@[export agentlean_audit]
def abiAudit (h : Handle) : String := h.auditText

@[export agentlean_error]
def abiError (h : Handle) : String := h.error

@[export agentlean_done]
def abiDone (h : Handle) : UInt8 := if h.run.done then 1 else 0

@[export agentlean_sensitive]
def abiSensitive (h : Handle) : UInt8 := if h.run.sensitive then 1 else 0

@[export agentlean_trace_len]
def abiTraceLen (h : Handle) : UInt64 := h.trace.size.toUInt64

end AgentLean
