module

public import AgentLean.Driver
public import Examples.Agents

/-!
Run the example assistant through the Lean driver.

    driver_demo [--endpoint URL] [--model M] [--provider openai|anthropic] [--golden FILE] PROMPT

The credential named `openai` is read from `AGENT_CREDENTIAL_OPENAI`. Host tools are stubbed.
With `--golden`, the run is written in the golden-trace format so the C ABI can replay it.
-/

open AgentLean

def hostTool (id : String) (_args : Json) : IO (Except String Json) :=
  pure <| match id with
    | "ui.confirm" => .ok (Json.mkObj [("confirmed", some (.bool true))])
    | "net.fetch" => .ok (.str "stub page")
    | "bank.transfer" => .ok (Json.mkObj [("ok", some (.bool true)), ("ref", some (.str "TX1"))])
    | other => .error s!"no host tool '{other}'"

partial def parseArgs : List String → List (String × String) → List String → List (String × String) × List String
  | k :: v :: rest, m, pos =>
    if k.startsWith "--" then parseArgs rest (((k.drop 2).toString, v) :: m) pos
    else parseArgs (v :: rest) m (pos ++ [k])
  | [k], m, pos => (m, pos ++ [k])
  | [], m, pos => (m, pos)

def opt (m : List (String × String)) (k d : String) : String := (m.lookup k).getD d

public def main (args : List String) : IO UInt32 := do
  let (opts, pos) := parseArgs args [] []
  let endpoint := opt opts "endpoint" "http://127.0.0.1:18080/v1/chat/completions"
  let provider := opt opts "provider" "openai"
  let cfg := Json.mkObj [("agent", some (.str "assistant")), ("model", some (.str (opt opts "model" "mock"))),
    ("endpoint", some (.str endpoint)), ("provider", some (.str provider))]
  let lines ← IO.mkRef #[s!"C {cfg.render}"]
  let d : Driver.Config := {
    hostTool
    onUi := fun e => match (e.get? "kind").bind Json.getStr?, (e.get? "text").bind Json.getStr? with
      | some "text_delta", some t => IO.print t
      | _, _ => pure ()
    record := fun ev effs => lines.modify fun ls => (ls.push s!"E {ev}") ++ effs.map (s!"X {·}") }
  let h ← Driver.start Examples.env cfg
  let (_, done) ← Driver.runTurn d h (" ".intercalate pos)
  IO.println s!"\n{done.render}"
  if let some path := opts.lookup "golden" then
    IO.FS.writeFile path ("\n".intercalate (← lines.get).toList ++ "\n")
  return if (done.get? "reason") == some (.str "final") then 0 else 1
