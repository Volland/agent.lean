module

public import AgentLean.Tool
meta import AgentLean.Meta.Derive

/-!
# Messages, events, effects and run configuration

Everything that crosses the host boundary has a JSON form here. Events are what the host feeds in,
effects are what the core asks the host to do (ADR 0002, ADR 0007).
-/

@[expose] public section

namespace AgentLean

/-! ## Base64 (stream chunks may split UTF-8 characters, so they travel as base64) -/

namespace Base64

def alphabet : String := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def sym (n : Nat) : Char := (alphabet.toList.toArray)[n % 64]!

def encode (b : ByteArray) : String := Id.run do
  let mut out : String := ""
  let mut i := 0
  while i + 2 < b.size do
    let n := (b[i]!.toNat <<< 16) ||| (b[i+1]!.toNat <<< 8) ||| b[i+2]!.toNat
    out := out.push (sym (n >>> 18))
    out := out.push (sym (n >>> 12))
    out := out.push (sym (n >>> 6))
    out := out.push (sym n)
    i := i + 3
  let rest := b.size - i
  if rest == 1 then
    let n := b[i]!.toNat <<< 16
    out := out.push (sym (n >>> 18))
    out := out.push (sym (n >>> 12))
    out := out ++ "=="
  else if rest == 2 then
    let n := (b[i]!.toNat <<< 16) ||| (b[i+1]!.toNat <<< 8)
    out := out.push (sym (n >>> 18))
    out := out.push (sym (n >>> 12))
    out := out.push (sym (n >>> 6))
    out := out ++ "="
  return out

def val (c : UInt8) : Option Nat :=
  if 65 ≤ c && c ≤ 90 then some (c.toNat - 65)
  else if 97 ≤ c && c ≤ 122 then some (c.toNat - 71)
  else if 48 ≤ c && c ≤ 57 then some (c.toNat + 4)
  else if c == 43 then some 62
  else if c == 47 then some 63
  else none

def decode (s : String) : Except String ByteArray := do
  let bytes := s.toUTF8
  let mut out := ByteArray.empty
  let mut acc := 0
  let mut bits := 0
  for c in bytes do
    if c == 61 then break
    if c == 10 || c == 13 then continue
    match val c with
    | some v =>
      acc := ((acc <<< 6) ||| v) % 16777216
      bits := bits + 6
      if bits ≥ 8 then
        bits := bits - 8
        out := out.push ((acc >>> bits) % 256).toUInt8
    | none => throw "base64: invalid character"
  return out

end Base64

/-! ## Messages -/

/-- A tool call requested by the model; `args` is exactly the text the model produced. -/
structure CallReq where
  id : String
  name : String
  args : String
  deriving Inhabited, Repr, BEq, ToJson, FromJson

/-- Provider-neutral conversation history. -/
inductive Message where
  | system (text : String)
  | user (text : String)
  | assistant (text : String) (calls : Array CallReq)
  | tool (callId : String) (name : String) (content : String)
  deriving Inhabited, Repr, BEq

namespace Message

def isTool : Message → Bool
  | tool .. => true
  | _ => false

def isUser : Message → Bool
  | user _ => true
  | _ => false

/-- Bytes the message contributes to a request (for the token estimate). -/
def bytes : Message → Nat
  | system t | user t => t.utf8ByteSize
  | assistant t cs => t.utf8ByteSize + cs.foldl (fun n c => n + c.id.utf8ByteSize + c.name.utf8ByteSize + c.args.utf8ByteSize) 0
  | tool i n c => i.utf8ByteSize + n.utf8ByteSize + c.utf8ByteSize

instance : ToJson Message where
  toJson
    | system t => Json.mkObj [("role", some (.str "system")), ("text", some (.str t))]
    | user t => Json.mkObj [("role", some (.str "user")), ("text", some (.str t))]
    | assistant t cs => Json.mkObj [("role", some (.str "assistant")), ("text", some (.str t)),
        ("calls", some (toJson cs))]
    | tool i n c => Json.mkObj [("role", some (.str "tool")), ("id", some (.str i)), ("name", some (.str n)),
        ("content", some (.str c))]

instance : FromJson Message where
  fromJson? j := do
    match (← j.field "role" : String) with
    | "system" => system <$> j.field "text"
    | "user" => user <$> j.field "text"
    | "assistant" => return assistant (← j.field "text") (← j.field "calls")
    | "tool" => return tool (← j.field "id") (← j.field "name") (← j.field "content")
    | r => throw s!"unknown role '{r}'"

end Message

/-! ## Events (host → core) -/

inductive Event where
  /-- A user turn. -/
  | user (text : String)
  /-- A complete (non-streamed) model response for request `id`. -/
  | llmResponse (id : String) (status : Nat) (body : String)
  /-- A chunk of a streamed model response for request `id`, as raw bytes. -/
  | llmChunk (id : String) (data : ByteArray)
  /-- The stream for request `id` ended. -/
  | llmEnd (id : String)
  /-- The request `id` failed in transport. -/
  | llmError (id : String) (message : String)
  /-- Result of tool call `id`. -/
  | toolResult (id : String) (result : Json)
  /-- Tool call `id` failed in the host. -/
  | toolError (id : String) (message : String)
  /-- The host cancels the run. -/
  | cancel
  /-- The host restored the run after a crash: re-issue what may be re-issued. -/
  | resume
  deriving Inhabited

namespace Event

/-- Canonical JSON; chunks are base64 so any byte split survives. -/
def toJson : Event → Json
  | user t => Json.mkObj [("type", some (.str "user")), ("text", some (.str t))]
  | llmResponse i s b => Json.mkObj [("type", some (.str "llm_response")), ("id", some (.str i)),
      ("status", some (.nat s)), ("body", some (.str b))]
  | llmChunk i d => Json.mkObj [("type", some (.str "llm_chunk")), ("id", some (.str i)),
      ("b64", some (.str (Base64.encode d)))]
  | llmEnd i => Json.mkObj [("type", some (.str "llm_end")), ("id", some (.str i))]
  | llmError i m => Json.mkObj [("type", some (.str "llm_error")), ("id", some (.str i)), ("message", some (.str m))]
  | toolResult i r => Json.mkObj [("type", some (.str "tool_result")), ("id", some (.str i)), ("result", some r)]
  | toolError i m => Json.mkObj [("type", some (.str "tool_error")), ("id", some (.str i)), ("message", some (.str m))]
  | cancel => Json.mkObj [("type", some (.str "cancel"))]
  | resume => Json.mkObj [("type", some (.str "resume"))]

def fromJson? (j : Json) : Except String Event := do
  match (← j.field "type" : String) with
  | "user" => user <$> j.field "text"
  | "llm_response" => return llmResponse (← j.field "id") ((← j.fieldOpt "status").getD 200) (← j.field "body")
  | "llm_chunk" =>
    let id ← j.field "id"
    match (← j.fieldOpt "b64" : Option String) with
    | some b => return llmChunk id (← Base64.decode b)
    | none => return llmChunk id (← j.field "data" : String).toUTF8
  | "llm_end" => llmEnd <$> j.field "id"
  | "llm_error" => return llmError (← j.field "id") (← j.field "message")
  | "tool_result" => return toolResult (← j.field "id") (← j.field "result")
  | "tool_error" => return toolError (← j.field "id") (← j.field "message")
  | "cancel" => return cancel
  | "resume" => return resume
  | t => throw s!"unknown event type '{t}'"

instance : ToJson Event := ⟨toJson⟩
instance : FromJson Event := ⟨fromJson?⟩

end Event

/-! ## Effects (core → host) -/

inductive UiEvent where
  | textDelta (text : String)
  | toolStart (id : String) (name : String)
  | toolEnd (id : String) (name : String) (ok : Bool)
  deriving Inhabited, Repr, BEq

-- @tg: implements:: [[adr:0011]]
-- @tg: implements:: [[openspec:host-abi#Credentials by reference]]
inductive Effect where
  /-- POST `body` to `url`. `credential` names the secret the host injects as `auth` header
  scheme (`bearer` or `x-api-key`); the core never sees the secret. -/
  | llmRequest (id : String) (url : String) (credential : String) (auth : String)
      (headers : Array (String × String)) (body : String) (stream : Bool)
  /-- Run a tool in the host (or the Lean driver for `io` tools). -/
  | toolCall (id : String) (name : String) (args : Json) (executor : Executor)
  /-- Display-only event. -/
  | ui (e : UiEvent)
  /-- The run is over. -/
  | complete (reason : String) (answer : String) (detail : String)
  deriving Inhabited

namespace Effect

def executorJson : Executor → List (String × Option Json)
  | .pure => [("executor", some (.str "pure"))]
  | .io => [("executor", some (.str "io"))]
  | .host h => [("executor", some (.str "host")), ("host_id", some (.str h))]
  | .agent a => [("executor", some (.str "agent")), ("agent", some (.str a))]

def toJson : Effect → Json
  | llmRequest i u c a hs b s => Json.mkObj [("type", some (.str "llm_request")), ("id", some (.str i)),
      ("url", some (.str u)), ("credential", some (.str c)), ("auth", some (.str a)),
      ("headers", some (.obj (hs.map fun (k, v) => (k, .str v)))), ("body", some (.str b)),
      ("stream", some (.bool s))]
  | toolCall i n a e => Json.mkObj ([("type", some (.str "tool_call")), ("id", some (.str i)),
      ("name", some (.str n)), ("args", some a)] ++ executorJson e)
  | ui (.textDelta t) => Json.mkObj [("type", some (.str "ui")), ("kind", some (.str "text_delta")),
      ("text", some (.str t))]
  | ui (.toolStart i n) => Json.mkObj [("type", some (.str "ui")), ("kind", some (.str "tool_start")),
      ("id", some (.str i)), ("name", some (.str n))]
  | ui (.toolEnd i n ok) => Json.mkObj [("type", some (.str "ui")), ("kind", some (.str "tool_end")),
      ("id", some (.str i)), ("name", some (.str n)), ("ok", some (.bool ok))]
  | complete r a d => Json.mkObj [("type", some (.str "complete")), ("reason", some (.str r)),
      ("answer", some (.str a)), ("detail", if d.isEmpty then none else some (.str d))]

instance : ToJson Effect := ⟨toJson⟩

end Effect

/-! ## Run configuration (host → core, at creation) -/

inductive Provider where
  | openai
  | anthropic
  deriving BEq, Repr, Inhabited, ToJson, FromJson

/-- Per-run settings from the host. Optional fields fall back to the defaults shown in `RunConfig`'s
accessors. Budget fields can only tighten the agent's own budget. -/
structure RunConfig where
  agent : String
  model : String
  endpoint : String
  provider : Option Provider
  credential : Option String
  stream : Option Bool
  contextTokens : Option Nat
  maxOutputTokens : Option Nat
  bytesPerToken : Option Nat
  maxSteps : Option Nat
  maxToolCalls : Option Nat
  maxTokens : Option Nat
  /-- Host tool ids the application implements; each must be declared by the agent. -/
  hostTools : Option (Array String)
  deriving Inhabited, Repr, ToJson, FromJson

namespace RunConfig

def provider' (c : RunConfig) : Provider := c.provider.getD .openai
def credential' (c : RunConfig) : String := c.credential.getD (match c.provider' with
  | .openai => "openai" | .anthropic => "anthropic")
def stream' (c : RunConfig) : Bool := c.stream.getD false
def contextTokens' (c : RunConfig) : Nat := c.contextTokens.getD 8192
def maxOutputTokens' (c : RunConfig) : Nat := c.maxOutputTokens.getD 1024
def bytesPerToken' (c : RunConfig) : Nat := max 1 (c.bytesPerToken.getD 3)

/-- The effective budget: the agent's budget, tightened by the host's overrides. -/
def budget (c : RunConfig) (b : Budget) : Budget :=
  { steps := min b.steps (c.maxSteps.getD b.steps),
    toolCalls := min b.toolCalls (c.maxToolCalls.getD b.toolCalls),
    tokens := min b.tokens (c.maxTokens.getD b.tokens) }

end RunConfig

/-- A decoded model response, provider-neutral. -/
structure Reply where
  text : String := ""
  calls : Array CallReq := #[]
  /-- Total tokens used by the request, if the provider reported it. -/
  usage : Option Nat := none
  finish : String := ""
  deriving Inhabited, Repr

instance : ToJson Budget where
  toJson b := Json.mkObj [("steps", some (.nat b.steps)), ("toolCalls", some (.nat b.toolCalls)),
    ("tokens", some (.nat b.tokens))]

instance : FromJson Budget where
  fromJson? j := return { steps := ← j.field "steps", toolCalls := ← j.field "toolCalls", tokens := ← j.field "tokens" }

end AgentLean
