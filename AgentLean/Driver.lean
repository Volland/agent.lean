module

public import AgentLean

/-!
# Lean driver

Runs an agent end to end from Lean on Linux and macOS (ADR 0007): HTTP and TLS through libcurl,
`io` tools in-process, host tools through a callback. The driver is the only place a credential
is resolved: effects only name it, and the driver adds the header just before sending.

Streaming requests are sent as such; the whole SSE body is fed as one chunk (the decoder gives the
same result for any split, `Sse.feed_chunks`).
-/

@[expose] public section

namespace AgentLean.Driver

/-- POST through libcurl: `(status, body)`, status 0 for a transport error (body is the message). -/
@[extern "agentlean_http_post"]
opaque httpPost (url : @& String) (headers : @& Array (String × String)) (body : @& String) (timeoutS : UInt32) :
    IO (UInt32 × String)

/-- How the driver reaches the outside world. -/
structure Config where
  /-- Resolve a credential name (from the effect) to its secret. -/
  credential : String → IO (Option String) := fun name =>
    IO.getEnv s!"AGENT_CREDENTIAL_{name.toUpper}"
  /-- Run a host tool: `(host id, args) ↦ result`. -/
  hostTool : String → Json → IO (Except String Json) := fun id _ => pure (.error s!"no host tool '{id}'")
  /-- Display-only events (text deltas, tool start and end). -/
  onUi : Json → IO Unit := fun _ => pure ()
  /-- Transport; libcurl by default. Tests replace it. -/
  post : String → Array (String × String) → String → IO (UInt32 × String) := fun u h b => httpPost u h b 120
  /-- Called with every accepted event and the effects it produced (for logging or golden files). -/
  record : String → Array String → IO Unit := fun _ _ => pure ()

def authHeaders (scheme secret : String) : Array (String × String) :=
  if scheme == "x-api-key" then #[("x-api-key", secret)] else #[("authorization", s!"Bearer {secret}")]

def findTool (env : Env) (name : String) : Option ToolDef :=
  env.agents.findSome? (·.tool? name)

/-- Feed an event and collect the effects it produced. -/
partial def feedCollect (h : Handle) (ev : Json) : Except String (Handle × Array Json) := do
  let (h, code) := h.feed ev.render.toUTF8
  if code != 0 then throw s!"event rejected ({code}): {h.error}"
  let rec go (h : Handle) (acc : Array Json) : Handle × Array Json :=
    match h.next with
    | (some e, h) => go h (acc.push ((Json.parse e).toOption.getD .null))
    | (none, h) => (h, acc)
  return go h #[]

def obj (kvs : List (String × Json)) : Json := .obj kvs.toArray

/-- Perform one effect; returns the event to feed back, if any, and the completion if it ended. -/
def perform (d : Config) (env : Env) (e : Json) : IO (Option Json × Option Json) := do
  let ty := ((e.get? "type").bind Json.getStr?).getD ""
  let s := fun k => ((e.get? k).bind Json.getStr?).getD ""
  match ty with
  | "llm_request" =>
    let id := s "id"
    let headers := match e.get? "headers" with
      | some (.obj kvs) => kvs.filterMap fun (k, v) => v.getStr?.map (k, ·)
      | _ => #[]
    let auth ← match ← d.credential (s "credential") with
      | some secret => pure (authHeaders (s "auth") secret)
      | none => pure #[]
    let (status, body) ← d.post (s "url") (headers ++ auth) (s "body")
    if status == 0 then
      return (some (obj [("type", .str "llm_error"), ("id", .str id), ("message", .str body)]), none)
    if (e.get? "stream").bind Json.getBool? == some true && status < 400 then
      return (some (obj [("type", .str "llm_chunk"), ("id", .str id), ("data", .str body)]), none)
    return (some (obj [("type", .str "llm_response"), ("id", .str id), ("status", .nat status.toNat),
      ("body", .str body)]), none)
  | "tool_call" =>
    let id := s "id"
    let args := (e.get? "args").getD (.obj #[])
    let result ← match s "executor" with
      | "io" => match findTool env (s "name") with
        | some t => pure ((← t.runIO args).mapError (·.toJson.render))
        | none => pure (.error s!"unknown io tool {s "name"}")
      | _ => d.hostTool (s "host_id") args
    return match result with
      | .ok r => (some (obj [("type", .str "tool_result"), ("id", .str id), ("result", r)]), none)
      | .error m => (some (obj [("type", .str "tool_error"), ("id", .str id), ("message", .str m)]), none)
  | "ui" => d.onUi e; return (none, none)
  | "complete" => return (none, some e)
  | _ => return (none, none)

-- @tg: implements:: [[openspec:host-abi#Lean driver]]
/-- Run one user turn to its completion. Returns the handle and the `complete` effect. -/
partial def runTurn (d : Config) (h : Handle) (text : String) : IO (Handle × Json) := do
  let ev := obj [("type", .str "user"), ("text", .str text)]
  let (h, effs) ← IO.ofExcept (feedCollect h ev)
  d.record ev.render (effs.map Json.render)
  let rec loop (h : Handle) (queue : List Json) : IO (Handle × Json) := do
    match queue with
    | [] => throw (IO.userError "agent stopped without completing")
    | e :: rest =>
      let (next, done) ← perform d h.env e
      if let some c := done then return (h, c)
      match next with
      | none => loop h rest
      | some ev =>
        if ev.get? "type" == some (.str "llm_chunk") then
          let (h, e1) ← IO.ofExcept (feedCollect h ev)
          d.record ev.render (e1.map Json.render)
          let endEv := obj [("type", .str "llm_end"), ("id", (ev.get? "id").getD .null)]
          let (h, e2) ← IO.ofExcept (feedCollect h endEv)
          d.record endEv.render (e2.map Json.render)
          loop h (rest ++ (e1 ++ e2).toList)
        else
          let (h, more) ← IO.ofExcept (feedCollect h ev)
          d.record ev.render (more.map Json.render)
          loop h (rest ++ more.toList)
  loop h effs.toList

/-- Create a handle for `config` (a `RunConfig` as JSON) with the agents in `env`. -/
def start (env : Env) (config : Json) : IO Handle := IO.ofExcept (Handle.create env config.render.toUTF8)

end AgentLean.Driver
