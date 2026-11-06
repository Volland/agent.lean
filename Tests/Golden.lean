module

public import Tests.Core
public import Tests.More

/-!
# Golden traces

Writes `traces/<name>.golden`: the run configuration, then each accepted event followed by the
effects it produced, one JSON document per line:

    C <config>
    E <event>
    X <effect>

Every target replays these through its own ABI (C, Swift, Kotlin) and must produce the same
effects byte for byte.
-/

open AgentLean Tests

-- @tg: implements:: [[adr:0015]]
/-- Re-run a handle's trace from scratch and render it as a golden file. -/
def golden (cfg : Json) (h : Handle) : T String := do
  let mut g ← match Handle.create Examples.env cfg.render.toUTF8 with
    | .ok g => pure g | .error e => throw e
  let mut out := s!"C {cfg.render}\n"
  for e in h.trace do
    let line := e.event.toJson.render
    let (g', code) := g.feed line.toUTF8
    unless code == 0 do throw s!"golden replay rejected {line}"
    let (g'', effs) := drain g'
    g := g''
    out := out ++ s!"E {line}\n"
    for x in effs do out := out ++ s!"X {x.render}\n"
  return out

def sessions : List (String × List (String × Json) × (Handle → T Handle)) := [
  ("basic", [], fun h => do
    let (h, es) ← feed h (user "hello")
    let (h, _) ← feed h (llm (← requestId es) (oaText "Hi! How can I help?"))
    return h),
  ("tools-parallel-sensitive", [], fun _ => do return (← More.session).1),
  ("streaming", [("stream", .bool true)], fun h => do
    let (h, es) ← feed h (user "stream please")
    let rid ← requestId es
    let (h, _) ← feed h (chunk rid "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\nda")
    let (h, _) ← feed h (chunkBytes rid "ta: {\"choices\":[{\"delta\":{\"content\":\"lo wörld\"}}]}\n\ndata: [DONE]\n\n".toUTF8)
    let (h, _) ← feed h (llmEnd rid)
    return h),
  ("policy-refusal", [], fun _ => do
    let (h, es) ← More.confirmed "{\"to\":\"bob\",\"amount\":250}"
    let (h, _) ← feed h (llm (← requestId es) (oaText "I cannot send that much."))
    return h),
  ("policy-halt", [], fun h => do
    let (h, _) ← startWith h "wipe" (oaCalls [("d", "delete_all", "{\"scope\":\"all\"}")])
    return h),
  ("agent-as-tool", [], fun h => do
    let (h, es) ← startWith h "research it" (oaCalls [("c1", "research", "{\"task\":\"find x\"}")])
    let (h, es) ← feed h (llm (← requestId es) (oaCalls [("w1", "web_fetch", "{\"url\":\"u1\"}")]))
    let _ := es
    let (h, es) ← feed h (toolRes "f1/w1" (str "x is 42"))
    let (h, es) ← feed h (llm (← requestId es) (oaText "x = 42"))
    let (h, _) ← feed h (llm (← requestId es) (oaText "The answer is 42."))
    return h),
  ("anthropic", [("provider", str "anthropic"), ("endpoint", str "https://api.anthropic.com/v1/messages")], fun h => do
    let (h, es) ← feed h (user "add 2 and 3")
    let (h, es) ← feed h (llm (← requestId es) "{\"type\":\"message\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"add\",\"input\":{\"a\":2,\"b\":3}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7}}")
    let (h, _) ← feed h (llm (← requestId es) "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"5\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":9,\"output_tokens\":1}}")
    return h),
  ("errors", [], fun h => do
    let (h, es) ← startWith h "x" (oaCalls [("c1", "add", "{\"a\":1}"), ("c2", "fly", "{}")])
    let (h, _) ← feed h (llm (← requestId es) "{\"choices\":[{\"message\":")
    return h)]

public def main : IO UInt32 := do
  IO.FS.createDirAll "traces"
  for (name, extra, script) in sessions do
    let r ← (do golden (cfgWith extra) (← script (← newH extra)) : T String).run
    match r with
    | .ok text =>
      IO.FS.writeFile s!"traces/{name}.golden" text
      IO.println s!"wrote traces/{name}.golden ({(text.splitOn "\n").length - 1} lines)"
    | .error e =>
      IO.eprintln s!"{name}: {e}"
      return 1
  return 0
