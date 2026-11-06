module

public import Examples.Agents

/-! Test harness: drive the example agents through the same `Handle` API the C ABI uses. -/

@[expose] public section

namespace Tests
open AgentLean

abbrev T := ExceptT String IO

structure Case where
  name : String
  run : T Unit

def check (c : Bool) (msg : String) : T Unit := unless c do throw msg

def eq {α} [BEq α] [ToString α] (got want : α) (what : String) : T Unit :=
  unless got == want do throw s!"{what}: expected {want}, got {got}"

def j (s : String) : Json := match Json.parse s with
  | .ok v => v
  | .error e => panic! s!"bad test JSON {e}: {s}"

def str (s : String) : Json := .str s

def obj (kvs : List (String × Json)) : Json := .obj kvs.toArray

def baseCfg : List (String × Json) :=
  [("agent", str "assistant"), ("model", str "test-model"),
   ("endpoint", str "http://localhost:8080/v1/chat/completions")]

def cfgWith (extra : List (String × Json)) : Json :=
  obj (baseCfg.filter (fun (k, _) => !extra.any (·.1 == k)) ++ extra)

def newH (extra : List (String × Json) := []) : T Handle :=
  match Handle.create Examples.env (cfgWith extra).render.toUTF8 with
  | .ok h => pure h
  | .error e => throw s!"create failed: {e}"

/-- Drain all pending effects as JSON. -/
partial def drain (h : Handle) (acc : Array Json := #[]) : Handle × Array Json :=
  match h.next with
  | (some e, h) => drain h (acc.push (j e))
  | (none, h) => (h, acc)

def feedCode (h : Handle) (ev : Json) : Handle × UInt32 := h.feed ev.render.toUTF8

/-- Feed an event that must be accepted; return the effects it produced. -/
def feed (h : Handle) (ev : Json) : T (Handle × Array Json) := do
  let (h, code) := feedCode h ev
  unless code == 0 do throw s!"event rejected ({code}): {h.error}: {ev.render}"
  return drain h

def user (t : String) : Json := obj [("type", str "user"), ("text", str t)]
def llm (id body : String) : Json := obj [("type", str "llm_response"), ("id", str id), ("status", .nat 200), ("body", str body)]
def chunk (id : String) (data : String) : Json := obj [("type", str "llm_chunk"), ("id", str id), ("data", str data)]
def chunkBytes (id : String) (data : ByteArray) : Json :=
  obj [("type", str "llm_chunk"), ("id", str id), ("b64", str (Base64.encode data))]
def llmEnd (id : String) : Json := obj [("type", str "llm_end"), ("id", str id)]
def toolRes (id : String) (res : Json) : Json := obj [("type", str "tool_result"), ("id", str id), ("result", res)]
def toolErr (id msg : String) : Json := obj [("type", str "tool_error"), ("id", str id), ("message", str msg)]
def cancel : Json := obj [("type", str "cancel")]
def resume : Json := obj [("type", str "resume")]

/-- An OpenAI-compatible reply with text only. -/
def oaText (t : String) : String :=
  (obj [("choices", .arr #[obj [("message", obj [("role", str "assistant"), ("content", str t)]),
    ("finish_reason", str "stop")]]), ("usage", obj [("total_tokens", .nat 10)])]).render

/-- An OpenAI-compatible reply with tool calls `(id, name, args)`. -/
def oaCalls (calls : List (String × String × String)) : String :=
  (obj [("choices", .arr #[obj [("message", obj [("role", str "assistant"), ("content", .null),
      ("tool_calls", .arr (calls.toArray.map fun (i, n, a) =>
        obj [("id", str i), ("type", str "function"), ("function", obj [("name", str n), ("arguments", str a)])]))]),
    ("finish_reason", str "tool_calls")]]), ("usage", obj [("total_tokens", .nat 10)])]).render

def ty (e : Json) : String := ((e.get? "type").bind Json.getStr?).getD ""
def ofType (es : Array Json) (t : String) : Array Json := es.filter (ty · == t)
def field (e : Json) (k : String) : String := ((e.get? k).bind Json.getStr?).getD ""

def requestId (es : Array Json) : T String := do
  let some r := (ofType es "llm_request").back? | throw s!"no llm_request among {es.map Json.render}"
  return field r "id"

def requestBody (es : Array Json) : T String := do
  let some r := (ofType es "llm_request").back? | throw "no llm_request"
  return field r "body"

def completion (es : Array Json) : T Json := do
  let some c := (ofType es "complete").back? | throw s!"no completion among {es.map Json.render}"
  return c

def toolCallIds (es : Array Json) : Array String := (ofType es "tool_call").map (field · "id")

def contains (hay needle : String) : Bool := (hay.splitOn needle).length > 1

/-- Start a turn and answer the first request with `body`. -/
def startWith (h : Handle) (text body : String) : T (Handle × Array Json) := do
  let (h, es) ← feed h (user text)
  let rid ← requestId es
  feed h (llm rid body)

end Tests
