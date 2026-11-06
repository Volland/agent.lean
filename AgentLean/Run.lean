module

public import AgentLean.Codec
public import AgentLean.Context
meta import AgentLean.Meta.Derive

/-!
# The step machine

`step : Env → Run → Event → Run × Array Effect` is the whole behaviour of an agent (ADR 0002). It
performs no IO: every model request, tool call and display event is an `Effect` for the host.

A run holds one or more *frames*: frame 0 is the root agent, further frames are agents running as
tools of other frames (agent-as-tool). Ids of child effects are prefixed `f<k>/`, so the host routes
results back without knowing about frames.

Guarantees proved here:
* `final_done`: every run is over after more events than its step budget (`Run.maxSteps`).
* `done_sticky`: a finished run accepts nothing and emits nothing.
* `allocate_le`: a child agent's budget never exceeds its parent's remaining budget.
-/

@[expose] public section

namespace AgentLean

/-- The agents an application registers, looked up by name (for agent-as-tool). -/
structure Env where
  agents : Array Agent
  deriving Inhabited

def Env.find? (env : Env) (name : String) : Option Agent := env.agents.find? (·.name == name)

inductive Phase where
  /-- Waiting for a user turn. -/
  | idle
  /-- Waiting for a model response. -/
  | model
  /-- Waiting for tool results. -/
  | tools
  /-- Finished. -/
  | done
  deriving BEq, Repr, Inhabited, ToJson, FromJson

structure Usage where
  toolCalls : Nat
  tokens : Nat
  deriving Repr, Inhabited, BEq, ToJson, FromJson

def Usage.zero : Usage := ⟨0, 0⟩

structure Pending where
  id : String
  name : String
  args : String
  done : Bool
  deriving Inhabited, Repr, ToJson, FromJson

/-! JSON for the parts of the state that live in other modules. -/

instance : ToJson ByteArray := ⟨fun b => .str (Base64.encode b)⟩
instance : FromJson ByteArray := ⟨fun j => do Base64.decode (← fromJson? j)⟩
instance : ToJson Mon := ⟨Mon.toJson⟩
instance : FromJson Mon := ⟨Mon.fromJson?⟩
deriving instance ToJson for Sse.Event
deriving instance FromJson for Sse.Event
deriving instance ToJson for Sse.Decoder
deriving instance FromJson for Sse.Decoder
deriving instance ToJson for Codec.PartialCall
deriving instance FromJson for Codec.PartialCall
deriving instance ToJson for Codec.StreamAcc
deriving instance FromJson for Codec.StreamAcc

/-- One agent's part of a run. -/
structure Frame where
  agent : String
  phase : Phase
  history : Array Message
  pending : Array Pending
  /-- The model request this frame waits for ("" if none). -/
  awaiting : String
  sse : Sse.Decoder
  acc : Codec.StreamAcc
  used : Usage
  /-- Budget handed to running child agents and not yet returned. -/
  reserved : Usage
  budget : Budget
  /-- One monitor state per policy of the agent. -/
  mons : Array (Option Mon)
  parent : Option Nat
  parentCall : String
  answer : String
  reason : String
  deriving Inhabited, ToJson, FromJson

/-- A run: the frames plus run-wide counters. -/
structure Run where
  config : RunConfig
  frames : Array Frame
  /-- Accepted events so far. -/
  steps : Nat
  /-- Step budget of the run. -/
  maxSteps : Nat
  reqSeq : Nat
  done : Bool
  /-- Output of a sensitive tool entered the run: the trace must be encrypted at rest. -/
  sensitive : Bool
  deriving Inhabited, ToJson, FromJson

/-! ## Budgets -/

/-- What a child agent may use: its own budget, capped by the parent's remaining budget. -/
def allocate (parent : Budget) (used reserved : Usage) (child : Budget) : Usage :=
  { toolCalls := min child.toolCalls (parent.toolCalls - used.toolCalls - reserved.toolCalls),
    tokens := min child.tokens (parent.tokens - used.tokens - reserved.tokens) }

/-- **Budget composition**: a child never gets more than the parent has left. -/
theorem allocate_le (parent : Budget) (used reserved : Usage) (child : Budget) :
    (allocate parent used reserved child).toolCalls ≤ parent.toolCalls - used.toolCalls - reserved.toolCalls ∧
    (allocate parent used reserved child).tokens ≤ parent.tokens - used.tokens - reserved.tokens :=
  ⟨Nat.min_le_right _ _, Nat.min_le_right _ _⟩

/-- A child's budget never exceeds its own configured budget either. -/
theorem allocate_le_child (parent : Budget) (used reserved : Usage) (child : Budget) :
    (allocate parent used reserved child).toolCalls ≤ child.toolCalls ∧
    (allocate parent used reserved child).tokens ≤ child.tokens :=
  ⟨Nat.min_le_left _ _, Nat.min_le_left _ _⟩

/-! ## Creating a run -/

def Frame.new (ag : Agent) (budget : Budget) (parent : Option Nat) (parentCall : String) : Frame :=
  { agent := ag.name, phase := .idle, history := #[], pending := #[], awaiting := "", sse := {}, acc := {},
    used := Usage.zero, reserved := Usage.zero, budget, mons := ag.policies.map fun _ => none,
    parent, parentCall, answer := "", reason := "" }

def Run.init (env : Env) (cfg : RunConfig) : Except String Run := do
  let some ag := env.find? cfg.agent | throw s!"unknown agent '{cfg.agent}'"
  let declared := ag.tools.filterMap fun t => match t.executor with | .host h => some h | _ => none
  for h in cfg.hostTools.getD #[] do
    unless declared.contains h do
      throw s!"undeclared tool: the host implements '{h}', which agent '{ag.name}' does not declare"
  let b := cfg.budget ag.budget
  return { config := cfg, frames := #[Frame.new ag b none ""], steps := 0, maxSteps := b.steps,
           reqSeq := 0, done := false, sensitive := false }

/-! ## Ids -/

def prefixId (k : Nat) (id : String) : String := if k == 0 then id else s!"f{k}/{id}"

def parseId (id : String) : Nat × String :=
  if id.startsWith "f" then
    match id.splitOn "/" with
    | p :: rest@(_ :: _) =>
      match (p.drop 1).toString.toNat? with
      | some k => (k, "/".intercalate rest)
      | none => (0, id)
    | _ => (0, id)
  else (0, id)

/-! ## The machine -/

abbrev StepM := StateM (Run × Array Effect)

namespace StepM

def emit (e : Effect) : StepM Unit := modify fun (r, es) => (r, es.push e)
def getRun : StepM Run := return (← get).1
def modifyRun (f : Run → Run) : StepM Unit := modify fun (r, es) => (f r, es)
def frame (k : Nat) : StepM Frame := return (← getRun).frames[k]!
def setFrame (k : Nat) (fr : Frame) : StepM Unit := modifyRun fun r => { r with frames := r.frames.set! k fr }
def modifyFrame (k : Nat) (f : Frame → Frame) : StepM Unit := do setFrame k (f (← frame k))

end StepM

open StepM

/-- Policies of `ag` that the candidate observation `o` violates, given the frame's monitors. -/
def violations (ag : Agent) (fr : Frame) (o : Obs) : Array Policy :=
  (ag.policies.zip fr.mons).filterMap fun (p, m) => if (mstep p.rule m o).now then none else some p

def observe (env : Env) (k : Nat) (o : Obs) : StepM Unit := do
  let fr ← frame k
  let some ag := env.find? fr.agent | return
  setFrame k { fr with mons := (ag.policies.zip fr.mons).map fun (p, m) => some (mstep p.rule m o) }

def toolsEstimate (bpt : Nat) (ts : Array ToolDef) : Nat :=
  ts.foldl (fun n t => n + (t.schema.render.utf8ByteSize + t.name.utf8ByteSize + t.description.utf8ByteSize) / bpt + 8) 0

def frameAwaiting (r : Run) (id : String) : Option Nat :=
  if id.isEmpty then none else r.frames.findIdx? fun f => f.awaiting == id && f.phase == .model

mutual

/-- End frame `k`. The root's end is a `complete` effect; a child's end is its parent's tool result. -/
partial def finish (env : Env) (k : Nat) (reason answer detail : String) : StepM Unit := do
  let fr ← frame k
  match fr.parent with
  | none =>
    -- A final answer ends the task but lets a new user turn start; anything else ends the run.
    let final := reason == "final"
    setFrame k { fr with phase := if final then .idle else .done, answer, reason, awaiting := "", pending := #[] }
    unless final do
      modifyRun fun r => { r with done := true, frames := r.frames.map fun f => { f with phase := .done, awaiting := "" } }
    emit (.complete reason answer detail)
  | some p =>
    setFrame k { fr with phase := .done, answer, reason, awaiting := "", pending := #[] }
    modifyFrame p fun pf => { pf with
      used := ⟨pf.used.toolCalls + fr.used.toolCalls, pf.used.tokens + fr.used.tokens⟩,
      reserved := ⟨pf.reserved.toolCalls - fr.budget.toolCalls, pf.reserved.tokens - fr.budget.tokens⟩ }
    let content := if reason == "final" then answer
      else (Json.mkObj [("error", some (.str "agent_failed")), ("reason", some (.str reason)),
        ("detail", some (.str detail))]).render
    deliver env p fr.parentCall content (reason == "final") false true

/-- Record the result of call `callId` in frame `k` and continue when all results are in. -/
partial def deliver (env : Env) (k : Nat) (callId content : String) (ok untrusted cont : Bool) : StepM Unit := do
  let fr ← frame k
  if fr.phase == .done then return
  match fr.pending.findIdx? (fun p => p.id == callId && !p.done) with
  | none => return
  | some i =>
    let p := fr.pending[i]!
    setFrame k { fr with pending := fr.pending.set! i { p with done := true },
                         history := fr.history.push (.tool callId p.name content) }
    observe env k (.result p.name untrusted)
    emit (.ui (.toolEnd (prefixId k callId) p.name ok))
    if cont then continueIfReady env k

partial def continueIfReady (env : Env) (k : Nat) : StepM Unit := do
  let fr ← frame k
  if fr.phase == .tools && fr.pending.all (·.done) then
    setFrame k { fr with pending := #[] }
    request env k

/-- Issue the next model request of frame `k`. -/
partial def request (env : Env) (k : Nat) : StepM Unit := do
  let r ← getRun
  let fr := r.frames[k]!
  let some ag := env.find? fr.agent | finish env k "error" "" s!"unknown agent '{fr.agent}'"
  let cfg := r.config
  let bpt := cfg.bytesPerToken'
  let limit := cfg.contextTokens' - cfg.maxOutputTokens' - toolsEstimate bpt ag.tools
  match Context.fit bpt limit ag.system fr.history.toList with
  | none => finish env k "context_overflow" "" "the system prompt and last user turn exceed the context window"
  | some msgs =>
    let req := Codec.encode cfg msgs.toArray ag.tools
    let id := s!"r{r.reqSeq + 1}"
    modifyRun fun r => { r with reqSeq := r.reqSeq + 1 }
    setFrame k { fr with phase := .model, awaiting := id, sse := {}, acc := {} }
    emit (.llmRequest id req.url cfg.credential' req.auth req.headers req.body cfg.stream')

/-- Start agent `childName` as the tool call `c` of frame `k`. -/
partial def spawn (env : Env) (k : Nat) (c : CallReq) (childName : String) (args : Json) : StepM Unit := do
  let some cag := env.find? childName
    | deliver env k c.id (ToolFailure.failed s!"unknown agent '{childName}'").toJson.render false false false
  let fr ← frame k
  let alloc := allocate fr.budget fr.used fr.reserved cag.budget
  setFrame k { fr with reserved := ⟨fr.reserved.toolCalls + alloc.toolCalls, fr.reserved.tokens + alloc.tokens⟩ }
  let task := ((args.get? "task").bind Json.getStr?).getD args.render
  let child := { Frame.new cag { cag.budget with toolCalls := alloc.toolCalls, tokens := alloc.tokens } (some k) c.id with
    history := #[.user task] }
  modifyRun fun r => { r with frames := r.frames.push child }
  let ck := (← getRun).frames.size - 1
  emit (.ui (.toolStart (prefixId k c.id) c.name))
  observe env ck (.user task)
  request env ck

/-- Handle one tool call requested by the model in frame `k`. -/
partial def handleCall (env : Env) (k : Nat) (ag : Agent) (c : CallReq) : StepM Unit := do
  let fail := fun (f : ToolFailure) => deliver env k c.id f.toJson.render false false false
  let some t := ag.tool? c.name | fail (.unknownTool c.name ag.toolNames)
  let args ← match Json.parse c.args with
    | .ok a => pure a
    | .error e => fail (.invalidArguments s!"arguments are not valid JSON: {e}"); return
  if let .error f := t.check args then fail f; return
  let fr ← frame k
  let o := Obs.call c.name args
  let bad := violations ag fr o
  if let some p := bad.find? (·.onViolation == .halt) then
    observe env k (.refused c.name)
    finish env k "policy_halt" "" s!"policy '{p.name}' halted the run"
    return
  if let some p := bad[0]? then
    observe env k (.refused c.name)
    fail (.refused p.name p.reason)
    return
  if fr.used.toolCalls + fr.reserved.toolCalls + 1 > fr.budget.toolCalls then
    finish env k "budget" "" "tool-call budget exhausted"
    return
  observe env k o
  modifyFrame k fun f => { f with used := { f.used with toolCalls := f.used.toolCalls + 1 } }
  match t.executor with
  | .pure =>
    emit (.ui (.toolStart (prefixId k c.id) c.name))
    match t.runPure args with
    | .ok res =>
      match t.checkResult args res with
      | .ok () =>
        if t.sensitive then modifyRun fun r => { r with sensitive := true }
        deliver env k c.id res.render true t.untrusted false
      | .error f => deliver env k c.id f.toJson.render false false false
    | .error f => deliver env k c.id f.toJson.render false false false
  | .io | .host _ =>
    emit (.ui (.toolStart (prefixId k c.id) c.name))
    emit (.toolCall (prefixId k c.id) c.name args t.executor)
  | .agent name => spawn env k c name args

/-- Act on a decoded model reply in frame `k`. -/
partial def onReply (env : Env) (k : Nat) (reply : Reply) : StepM Unit := do
  let r ← getRun
  let fr := r.frames[k]!
  let some ag := env.find? fr.agent | finish env k "error" "" "unknown agent"
  let bpt := r.config.bytesPerToken'
  let spent := reply.usage.getD (Context.estimate bpt fr.history.toList + (reply.text.utf8ByteSize + bpt - 1) / bpt)
  let fr := { fr with used := { fr.used with tokens := fr.used.tokens + spent }, awaiting := "" }
  setFrame k fr
  observe env k .reply
  if fr.used.tokens + fr.reserved.tokens > fr.budget.tokens then
    finish env k "budget" reply.text "token budget exhausted"
    return
  if reply.calls.isEmpty then
    setFrame k { fr with history := fr.history.push (.assistant reply.text #[]) }
    finish env k "final" reply.text ""
    return
  setFrame k { fr with history := fr.history.push (.assistant reply.text reply.calls), phase := .tools,
                       pending := reply.calls.map fun c => { id := c.id, name := c.name, args := c.args, done := false } }
  for c in reply.calls do
    if (← frame k).phase != .tools then break
    handleCall env k ag c
  if (← frame k).phase == .tools then continueIfReady env k

/-- After a crash: re-issue what can be re-issued, fail what must not be repeated. -/
partial def resumeFrame (env : Env) (k : Nat) : StepM Unit := do
  let fr ← frame k
  match fr.phase with
  | .model => request env k
  | .tools =>
    let some ag := env.find? fr.agent | return
    for p in fr.pending do
      if p.done then continue
      match ag.tool? p.name with
      | some t =>
        match t.executor with
        | .agent _ => pure ()
        | .pure => pure ()
        | ex =>
          if t.idempotent then
            emit (.toolCall (prefixId k p.id) p.name ((Json.parse p.args).toOption.getD (.obj #[])) ex)
          else deliver env k p.id ToolFailure.interrupted.toJson.render false false false
      | none => pure ()
    continueIfReady env k
  | _ => pure ()

end

/-- Feed stream bytes to frame `k`'s decoder; emit text deltas. -/
def onChunk (r : Run) (k : Nat) (data : ByteArray) : StepM Unit := do
  let fr ← frame k
  let (evs, sse) := Sse.drain (Sse.feed fr.sse data)
  let mut acc := fr.acc
  for ev in evs do
    let (acc', ds) := acc.apply r.config.provider' ev
    acc := acc'
    for d in ds do emit (.ui (.textDelta d))
  setFrame k { fr with sse, acc }

/-- Handle one accepted event (the run is not done and the step budget is not exhausted). -/
def handle (env : Env) (e : Event) : StepM Unit := do
  let r ← getRun
  match e with
  | .user text =>
    modifyFrame 0 fun f => { f with history := f.history.push (.user text), answer := "", reason := "" }
    observe env 0 (.user text)
    request env 0
  | .llmResponse id status body =>
    let some k := frameAwaiting r id | return
    if status ≥ 400 then
      finish env k "error" "" s!"model request failed with status {status}: {(body.take 300).toString}"
    else match Codec.decode r.config.provider' id body with
      | .ok reply => onReply env k reply
      | .error err => finish env k "error" "" s!"undecodable model response: {err}"
  | .llmChunk id data =>
    let some k := frameAwaiting r id | return
    onChunk r k data
  | .llmEnd id =>
    let some k := frameAwaiting r id | return
    onChunk r k "\n\n".toUTF8
    let fr ← frame k
    match fr.acc.toReply id with
    | .ok reply => onReply env k reply
    | .error err => finish env k "error" "" s!"undecodable model stream: {err}"
  | .llmError id msg =>
    let some k := frameAwaiting r id | return
    finish env k "error" "" s!"model request failed: {msg}"
  | .toolResult id res =>
    let (k, callId) := parseId id
    let some fr := r.frames[k]? | return
    let some p := fr.pending.find? (fun p => p.id == callId && !p.done) | return
    let some ag := env.find? fr.agent | return
    let some t := ag.tool? p.name | return
    let args := (Json.parse p.args).toOption.getD (.obj #[])
    match t.checkResult args res with
    | .ok () =>
      if t.sensitive then modifyRun fun r => { r with sensitive := true }
      deliver env k callId res.render true t.untrusted true
    | .error f => deliver env k callId f.toJson.render false false true
  | .toolError id msg =>
    let (k, callId) := parseId id
    deliver env k callId (ToolFailure.failed msg).toJson.render false false true
  | .cancel => finish env 0 "cancelled" "" "cancelled by the host"
  | .resume =>
    for k in [0:r.frames.size] do
      resumeFrame env k

/-- Whether the run accepts an event now. The ABI rejects other events without changing state. -/
def accepts (r : Run) (e : Event) : Bool :=
  !r.done && match e with
  | .user _ => r.frames[0]!.phase == .idle
  | .llmResponse id .. | .llmChunk id _ | .llmEnd id | .llmError id _ => (frameAwaiting r id).isSome
  | .toolResult id _ | .toolError id _ =>
    let (k, callId) := parseId id
    match r.frames[k]? with
    | some fr => fr.phase == .tools && fr.pending.any fun p => p.id == callId && !p.done
    | none => false
  | .cancel | .resume => true

/-- One step. A finished run ignores events; past the step budget the run ends without acting. -/
def step (env : Env) (r : Run) (e : Event) : Run × Array Effect :=
  if r.done then (r, #[])
  else if r.steps ≥ r.maxSteps then
    ({ r with done := true },
     #[.complete "budget" r.frames[0]!.answer "step budget exhausted"])
  else
    let (r', effs) := (handle env e).run (r, #[]) |>.2
    ({ r' with steps := r.steps + 1, maxSteps := r.maxSteps }, effs)

/-- The state after a list of events. -/
def final (env : Env) (r : Run) (es : List Event) : Run := es.foldl (fun r e => (step env r e).1) r

/-! ## Termination -/

theorem done_sticky (env : Env) (r : Run) (e : Event) (h : r.done = true) : step env r e = (r, #[]) := by
  simp [step, h]

theorem final_done_of_done (env : Env) (r : Run) (es : List Event) (h : r.done = true) :
    (final env r es).done = true := by
  induction es generalizing r with
  | nil => simpa [final]
  | cons e es ih =>
    simp only [final, List.foldl_cons] at *
    rw [done_sticky env r e h]
    exact ih r h

/-- **Termination**: every run is over after more events than its remaining step budget. -/
theorem final_done (env : Env) (r : Run) (es : List Event) (h : es.length > r.maxSteps - r.steps) :
    (final env r es).done = true := by
  induction es generalizing r with
  | nil => simp at h
  | cons e es ih =>
    simp only [final, List.foldl_cons]
    by_cases hd : r.done = true
    · rw [done_sticky env r e hd]; exact final_done_of_done env r es hd
    · by_cases hs : r.steps ≥ r.maxSteps
      · have : (step env r e).1.done = true := by simp [step, hd, hs]
        exact final_done_of_done env _ es this
      · have hstep : (step env r e).1 =
            { ((handle env e).run (r, #[])).2.1 with steps := r.steps + 1, maxSteps := r.maxSteps } := by
          simp [step, hd, hs]
        rw [hstep]
        apply ih
        simp only [List.length_cons] at h
        simp
        omega

end AgentLean
