module

public import AgentLean.Run
public import AgentLean.Sha256

/-!
# Trace, snapshots and replay

The trace is the append-only list of accepted events and the source of truth (ADR 0010). A run's
state is the fold of `step` over it; a snapshot is that fold cached. Because `step` is a pure
function, replay is deterministic, and resuming from a snapshot gives exactly the states and
effects of replaying everything (`stepAll_append`).
-/

@[expose] public section

namespace AgentLean

def traceFormat : String := "agent.lean/trace"
def snapshotFormat : String := "agent.lean/snapshot"
def formatVersion : Nat := 1

/-- Step through events, collecting effects. -/
def stepAll (env : Env) (r : Run) : List Event → Run × Array Effect
  | [] => (r, #[])
  | e :: es =>
    let (r1, e1) := step env r e
    let (r2, e2) := stepAll env r1 es
    (r2, e1 ++ e2)

theorem stepAll_fst (env : Env) (r : Run) (es : List Event) : (stepAll env r es).1 = final env r es := by
  induction es generalizing r with
  | nil => rfl
  | cons e es ih => simp [stepAll, final, ih]

/-- **Resume equals replay**: stepping `a` then `b` from the state after `a` gives the same final
state and the same effects, in the same order, as stepping `a ++ b` at once. -/
theorem stepAll_append (env : Env) (r : Run) (a b : List Event) :
    stepAll env r (a ++ b) =
      ((stepAll env (stepAll env r a).1 b).1, (stepAll env r a).2 ++ (stepAll env (stepAll env r a).1 b).2) := by
  induction a generalizing r with
  | nil => simp [stepAll]
  | cons e es ih => simp [stepAll, ih, Array.append_assoc]

/-- Replay is a function of its inputs: the same configuration and events always give the same
states and effects. -/
theorem replay_deterministic (env : Env) (r : Run) (es : List Event) (x y : Run × Array Effect)
    (hx : x = stepAll env r es) (hy : y = stepAll env r es) : x = y := by
  rw [hx, hy]

/-! ## Trace entries -/

/-- One accepted event with the data labels of the tool whose result it carries. -/
structure Entry where
  seq : Nat
  event : Event
  sensitive : Bool
  untrusted : Bool := false
  deriving Inhabited

def Entry.toJson (e : Entry) : Json :=
  Json.mkObj [("seq", some (.nat e.seq)), ("event", some e.event.toJson),
    ("sensitive", if e.sensitive then some (.bool true) else none),
    ("untrusted", if e.untrusted then some (.bool true) else none)]

def Entry.fromJson? (j : Json) : Except String Entry := do
  let ev ← match j.get? "event" with
    | some v => Event.fromJson? v
    | none => throw "trace entry without event"
  return { seq := ← j.field "seq", event := ev, sensitive := ((j.get? "sensitive").bind Json.getBool?).getD false,
           untrusted := ((j.get? "untrusted").bind Json.getBool?).getD false }

/-- The tool whose result an event carries, if any. -/
def resultTool? (env : Env) (r : Run) : Event → Option ToolDef
  | .toolResult id _ =>
    let (k, callId) := parseId id
    match r.frames[k]? with
    | some fr =>
      match fr.pending.find? (·.id == callId), env.find? fr.agent with
      | some p, some ag => ag.tool? p.name
      | _, _ => none
    | none => none
  | _ => none

/-- Whether an event carries the output of a sensitive tool. -/
def isSensitiveEvent (env : Env) (r : Run) (e : Event) : Bool :=
  ((resultTool? env r e).map (·.sensitive)).getD false

/-- Whether an event carries the output of a tool declared untrusted. -/
def isUntrustedEvent (env : Env) (r : Run) (e : Event) : Bool :=
  ((resultTool? env r e).map (·.untrusted)).getD false

def traceJson (cfg : RunConfig) (entries : Array Entry) : Json :=
  Json.mkObj [("format", some (.str traceFormat)), ("version", some (.nat formatVersion)),
    ("config", some (toJson cfg)), ("events", some (.arr (entries.map Entry.toJson)))]

/-- The trace for audit: payloads of sensitive tool results are replaced by their SHA-256. -/
def auditJson (cfg : RunConfig) (entries : Array Entry) : Json :=
  let ev (e : Entry) : Json :=
    match e.sensitive, e.event with
    | true, .toolResult id res =>
      Json.mkObj [("seq", some (.nat e.seq)), ("sensitive", some (.bool true)),
        ("event", some (Json.mkObj [("type", some (.str "tool_result")), ("id", some (.str id)),
          ("result_sha256", some (.str (Sha256.hexOf res.render)))]))]
    | _, _ => e.toJson
  Json.mkObj [("format", some (.str (traceFormat ++ "+audit"))), ("version", some (.nat formatVersion)),
    ("config", some (toJson cfg)), ("events", some (.arr (entries.map ev)))]

def checkFormat (j : Json) (fmt : String) : Except String Unit := do
  let f : String ← j.field "format"
  unless f == fmt do throw s!"expected format '{fmt}', got '{f}'"
  let v : Nat ← j.field "version"
  unless v == formatVersion do throw s!"unsupported {fmt} version {v} (this library reads version {formatVersion})"

def parseTrace (j : Json) : Except String (RunConfig × Array Entry) := do
  checkFormat j traceFormat
  let cfg ← j.field "config"
  let evs : Array Json ← j.field "events"
  return (cfg, ← evs.mapM Entry.fromJson?)

/-- Replay a whole trace from a fresh run. -/
def replay (env : Env) (j : Json) : Except String (Run × Array Effect) := do
  let (cfg, entries) ← parseTrace j
  let r ← Run.init env cfg
  return stepAll env r (entries.toList.map (·.event))

def snapshotJson (r : Run) (traceLen : Nat) : Json :=
  Json.mkObj [("format", some (.str snapshotFormat)), ("version", some (.nat formatVersion)),
    ("trace_len", some (.nat traceLen)), ("run", some (toJson r))]

def parseSnapshot (j : Json) : Except String (Run × Nat) := do
  checkFormat j snapshotFormat
  return (← j.field "run", ← j.field "trace_len")

end AgentLean
