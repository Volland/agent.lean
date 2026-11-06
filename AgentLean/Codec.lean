module

public import AgentLean.Types
public import AgentLean.Sse

/-!
# Provider codecs

Lean owns the wire format (ADR 0003): requests are encoded and responses decoded here, so every
host only moves bytes and every platform behaves the same. Two formats:

* OpenAI-compatible Chat Completions (OpenAI, Ollama, llama-server, vLLM, LM Studio, OpenRouter),
* Anthropic Messages.

Streaming responses are decoded from SSE events into a `StreamAcc` and finished into a `Reply`.
Anything undecodable is an `Except.error`, never a crash and never a tool call.
-/

@[expose] public section

namespace AgentLean.Codec

/-- An encoded model request. -/
structure Request where
  url : String
  auth : String
  headers : Array (String × String)
  body : String
  deriving Inhabited

def s (x : String) : Option Json := some (.str x)

/-! ## OpenAI-compatible -/

namespace OpenAI

def tools (ts : Array ToolDef) : Json :=
  .arr (ts.map fun t => Json.mkObj [("type", s "function"), ("function", some (Json.mkObj
    [("name", s t.name), ("description", s t.description), ("parameters", some t.schema)]))])

def message : Message → Json
  | .system t => Json.mkObj [("role", s "system"), ("content", s t)]
  | .user t => Json.mkObj [("role", s "user"), ("content", s t)]
  | .assistant t cs =>
    Json.mkObj [("role", s "assistant"),
      ("content", some (if t.isEmpty && !cs.isEmpty then .null else .str t)),
      ("tool_calls", if cs.isEmpty then none else some (.arr (cs.map fun c => Json.mkObj
        [("id", s c.id), ("type", s "function"),
         ("function", some (Json.mkObj [("name", s c.name), ("arguments", s c.args)]))])))]
  | .tool i _ c => Json.mkObj [("role", s "tool"), ("tool_call_id", s i), ("content", s c)]

-- @tg: implements:: [[openspec:llm-codecs#OpenAI-compatible codec]]
def encode (cfg : RunConfig) (msgs : Array Message) (ts : Array ToolDef) : Request :=
  let stream := cfg.stream'
  let body := Json.mkObj [
    ("model", s cfg.model),
    ("messages", some (.arr (msgs.map message))),
    ("tools", if ts.isEmpty then none else some (tools ts)),
    ("max_tokens", some (.nat cfg.maxOutputTokens')),
    ("stream", some (.bool stream)),
    ("stream_options", if stream then some (Json.mkObj [("include_usage", some (.bool true))]) else none)]
  { url := cfg.endpoint, auth := "bearer", headers := #[("content-type", "application/json")],
    body := body.render }

/-- Arguments may arrive as a JSON string (the standard) or, from some servers, as an object. -/
def argsText (j : Option Json) : String :=
  match j with
  | some (.str a) => a
  | some v => v.render
  | none => "{}"

-- @tg: implements:: [[openspec:llm-codecs#OpenAI-compatible codec]]
-- @tg: implements:: [[openspec:llm-codecs#Malformed model output]]
def decode (reqId : String) (body : String) : Except String Reply := do
  let j ← Json.parse body
  if let some e := j.getOpt? "error" then
    throw s!"provider error: {((e.get? "message").bind Json.getStr?).getD e.render}"
  let some (.arr choices) := j.get? "choices" | throw "missing choices"
  let some ch := choices[0]? | throw "empty choices"
  let some m := ch.get? "message" | throw "missing message"
  let text := ((m.getOpt? "content").bind Json.getStr?).getD ""
  let calls ← match m.getOpt? "tool_calls" with
    | some (.arr cs) => cs.mapIdxM fun i c => do
      let some f := c.get? "function" | throw "tool call without function"
      let some name := (f.get? "name").bind Json.getStr? | throw "tool call without name"
      let id := ((c.get? "id").bind Json.getStr?).getD s!"{reqId}-call{i}"
      pure { id, name, args := argsText (f.get? "arguments") : CallReq }
    | _ => pure #[]
  let usage := (j.get? "usage").bind (·.get? "total_tokens") |>.bind Json.getNat?
  let finish := ((ch.get? "finish_reason").bind Json.getStr?).getD ""
  return { text, calls, usage, finish }

end OpenAI

/-! ## Anthropic Messages -/

namespace Anthropic

def tools (ts : Array ToolDef) : Json :=
  .arr (ts.map fun t => Json.mkObj
    [("name", s t.name), ("description", s t.description), ("input_schema", some t.schema)])

def input (args : String) : Json :=
  match Json.parse args with
  | .ok v@(.obj _) => v
  | _ => Json.obj #[]

/-- Messages without the system prompt; consecutive tool results share one user message. -/
def messages (msgs : Array Message) : Array Json := Id.run do
  let mut out : Array Json := #[]
  let mut results : Array Json := #[]
  for m in msgs do
    match m with
    | .tool i _ c =>
      results := results.push (Json.mkObj [("type", s "tool_result"), ("tool_use_id", s i), ("content", s c)])
    | _ =>
      if !results.isEmpty then
        out := out.push (Json.mkObj [("role", s "user"), ("content", some (.arr results))])
        results := #[]
      match m with
      | .user t => out := out.push (Json.mkObj [("role", s "user"),
          ("content", some (.arr #[Json.mkObj [("type", s "text"), ("text", s t)]]))])
      | .assistant t cs =>
        let textBlocks := if t.isEmpty then #[] else #[Json.mkObj [("type", s "text"), ("text", s t)]]
        let useBlocks := cs.map fun c => Json.mkObj
          [("type", s "tool_use"), ("id", s c.id), ("name", s c.name), ("input", some (input c.args))]
        out := out.push (Json.mkObj [("role", s "assistant"), ("content", some (.arr (textBlocks ++ useBlocks)))])
      | _ => pure ()
  if !results.isEmpty then
    out := out.push (Json.mkObj [("role", s "user"), ("content", some (.arr results))])
  return out

def system (msgs : Array Message) : String :=
  "\n".intercalate (msgs.toList.filterMap fun | .system t => some t | _ => none)

def encode (cfg : RunConfig) (msgs : Array Message) (ts : Array ToolDef) : Request :=
  let sys := system msgs
  let body := Json.mkObj [
    ("model", s cfg.model),
    ("max_tokens", some (.nat cfg.maxOutputTokens')),
    ("system", if sys.isEmpty then none else s sys),
    ("messages", some (.arr (messages msgs))),
    ("tools", if ts.isEmpty then none else some (tools ts)),
    ("stream", some (.bool cfg.stream'))]
  { url := cfg.endpoint, auth := "x-api-key",
    headers := #[("content-type", "application/json"), ("anthropic-version", "2023-06-01")],
    body := body.render }

-- @tg: implements:: [[openspec:llm-codecs#Anthropic Messages codec]]
def decode (body : String) : Except String Reply := do
  let j ← Json.parse body
  if (j.get? "type").bind Json.getStr? == some "error" then
    let e := (j.get? "error").getD .null
    throw s!"provider error: {((e.get? "message").bind Json.getStr?).getD e.render}"
  let some (.arr blocks) := j.get? "content" | throw "missing content"
  let mut text := ""
  let mut calls : Array CallReq := #[]
  for b in blocks do
    match (b.get? "type").bind Json.getStr? with
    | some "text" => text := text ++ ((b.get? "text").bind Json.getStr?).getD ""
    | some "tool_use" =>
      let some id := (b.get? "id").bind Json.getStr? | throw "tool_use without id"
      let some name := (b.get? "name").bind Json.getStr? | throw "tool_use without name"
      calls := calls.push { id, name, args := ((b.get? "input").getD (.obj #[])).render }
    | _ => pure ()
  let u := (j.get? "usage").getD .null
  let usage := match (u.get? "input_tokens").bind Json.getNat?, (u.get? "output_tokens").bind Json.getNat? with
    | some a, some b => some (a + b)
    | _, _ => none
  return { text, calls, usage, finish := ((j.get? "stop_reason").bind Json.getStr?).getD "" }

end Anthropic

/-! ## Common entry points -/

def encode (cfg : RunConfig) (msgs : Array Message) (ts : Array ToolDef) : Request :=
  match cfg.provider' with
  | .openai => OpenAI.encode cfg msgs ts
  | .anthropic => Anthropic.encode cfg msgs ts

-- @tg: implements:: [[adr:0003]]
-- @tg: implements:: [[adr:0004]]
-- @tg: implements:: [[openspec:llm-codecs#Transport neutrality]]
def decode (p : Provider) (reqId body : String) : Except String Reply :=
  match p with
  | .openai => OpenAI.decode reqId body
  | .anthropic => Anthropic.decode body

/-! ## Streaming -/

/-- A tool call being assembled from stream fragments. -/
structure PartialCall where
  index : Nat
  id : String := ""
  name : String := ""
  args : String := ""
  deriving Inhabited, Repr

structure StreamAcc where
  text : String := ""
  calls : Array PartialCall := #[]
  inputTokens : Nat := 0
  usage : Option Nat := none
  finish : String := ""
  done : Bool := false
  error : Option String := none
  deriving Inhabited, Repr

namespace StreamAcc

def upsert (acc : StreamAcc) (idx : Nat) (f : PartialCall → PartialCall) : StreamAcc :=
  match acc.calls.findIdx? (·.index == idx) with
  | some i => { acc with calls := acc.calls.modify i f }
  | none => { acc with calls := acc.calls.push (f { index := idx }) }

def fail (acc : StreamAcc) (e : String) : StreamAcc := { acc with error := acc.error <|> some e }

def openai (acc : StreamAcc) (ev : Sse.Event) : StreamAcc × Array String := Id.run do
  if ev.data.trimAscii.toString == "[DONE]" then return ({ acc with done := true }, #[])
  let j ← match Json.parse ev.data with
    | .ok j => pure j
    | .error e => return (acc.fail s!"bad stream chunk: {e}", #[])
  if let some e := j.getOpt? "error" then
    return (acc.fail s!"provider error: {((e.get? "message").bind Json.getStr?).getD e.render}", #[])
  let mut acc := acc
  let mut deltas : Array String := #[]
  if let some n := (j.get? "usage").bind (·.get? "total_tokens") |>.bind Json.getNat? then
    acc := { acc with usage := some n }
  if let some (.arr chs) := j.get? "choices" then
    if let some ch := chs[0]? then
      if let some f := (ch.getOpt? "finish_reason").bind Json.getStr? then acc := { acc with finish := f }
      if let some d := ch.get? "delta" then
        if let some t := (d.getOpt? "content").bind Json.getStr? then
          if !t.isEmpty then
            acc := { acc with text := acc.text ++ t }
            deltas := deltas.push t
        if let some (.arr tcs) := d.getOpt? "tool_calls" then
          for tc in tcs do
            let idx := ((tc.get? "index").bind Json.getNat?).getD acc.calls.size
            let id? := (tc.getOpt? "id").bind Json.getStr?
            let f := (tc.getOpt? "function").getD .null
            let name? := (f.getOpt? "name").bind Json.getStr?
            let frag := match f.getOpt? "arguments" with
              | some (.str a) => a
              | some v => v.render
              | none => ""
            acc := acc.upsert idx fun c =>
              { c with id := id?.getD c.id, name := name?.getD c.name, args := c.args ++ frag }
  return (acc, deltas)

def anthropic (acc : StreamAcc) (ev : Sse.Event) : StreamAcc × Array String := Id.run do
  let j ← match Json.parse ev.data with
    | .ok j => pure j
    | .error e => return (acc.fail s!"bad stream event: {e}", #[])
  let ty := ((j.get? "type").bind Json.getStr?).getD ev.event
  match ty with
  | "message_start" =>
    let n := ((j.get? "message").bind (·.get? "usage") |>.bind (·.get? "input_tokens") |>.bind Json.getNat?).getD 0
    return ({ acc with inputTokens := n }, #[])
  | "content_block_start" =>
    let idx := ((j.get? "index").bind Json.getNat?).getD 0
    let b := (j.get? "content_block").getD .null
    if (b.get? "type").bind Json.getStr? == some "tool_use" then
      let id := ((b.get? "id").bind Json.getStr?).getD ""
      let name := ((b.get? "name").bind Json.getStr?).getD ""
      return (acc.upsert idx fun c => { c with id, name }, #[])
    return (acc, #[])
  | "content_block_delta" =>
    let idx := ((j.get? "index").bind Json.getNat?).getD 0
    let d := (j.get? "delta").getD .null
    match (d.get? "type").bind Json.getStr? with
    | some "text_delta" =>
      let t := ((d.get? "text").bind Json.getStr?).getD ""
      return ({ acc with text := acc.text ++ t }, if t.isEmpty then #[] else #[t])
    | some "input_json_delta" =>
      let t := ((d.get? "partial_json").bind Json.getStr?).getD ""
      return (acc.upsert idx fun c => { c with args := c.args ++ t }, #[])
    | _ => return (acc, #[])
  | "message_delta" =>
    let acc := match ((j.get? "delta").bind (·.get? "stop_reason")).bind Json.getStr? with
      | some r => { acc with finish := r }
      | none => acc
    let out := ((j.get? "usage").bind (·.get? "output_tokens")).bind Json.getNat?
    return ({ acc with usage := out.map (· + acc.inputTokens) }, #[])
  | "message_stop" => return ({ acc with done := true }, #[])
  | "error" =>
    let e := (j.get? "error").getD .null
    return (acc.fail s!"provider error: {((e.get? "message").bind Json.getStr?).getD e.render}", #[])
  | _ => return (acc, #[])

-- @tg: implements:: [[openspec:llm-codecs#Streaming decoding]]
/-- Apply one SSE event; returns the text deltas it carried. -/
def apply (p : Provider) (acc : StreamAcc) (ev : Sse.Event) : StreamAcc × Array String :=
  match p with
  | .openai => acc.openai ev
  | .anthropic => acc.anthropic ev

/-- The reply assembled so far. -/
def toReply (acc : StreamAcc) (reqId : String) : Except String Reply := do
  if let some e := acc.error then throw e
  let calls := (acc.calls.qsort (·.index < ·.index)).mapIdx fun i c =>
    ({ id := if c.id.isEmpty then s!"{reqId}-call{i}" else c.id, name := c.name,
       args := if c.args.isEmpty then "{}" else c.args } : CallReq)
  if calls.any (·.name.isEmpty) then throw "stream ended with an unnamed tool call"
  return { text := acc.text, calls, usage := acc.usage, finish := acc.finish }

end StreamAcc

end AgentLean.Codec
