module

public import Tests.Harness

/-! Scenarios of `agent-core` and `tools`. -/

@[expose] public section

namespace Tests.Core
open AgentLean Tests

-- @tg: verifies:: [[openspec:agent-core#Pure step function#Same inputs give same outputs]] {level: unit}
def sameInputs : Case := ⟨"same inputs give same outputs", do
  let h ← newH
  let (h1, e1) ← feed h (user "hi")
  let (h2, e2) ← feed h (user "hi")
  eq (e1.map Json.render) (e2.map Json.render) "effects"
  eq h1.snapshot h2.snapshot "state"⟩

-- @tg: verifies:: [[openspec:agent-core#Pure step function#No IO from the core]] {level: unit}
def noIO : Case := ⟨"no IO from the core", do
  -- `step` is a pure function (no IO in its type); a user turn becomes a request effect for the host.
  let r ← match Run.init Examples.env (← match (fromJson? (cfgWith []) : Except String RunConfig) with
      | .ok c => pure c | .error e => throw e) with
    | .ok r => pure r | .error e => throw e
  let (_, effs) := step Examples.env r (.user "hello")
  check (effs.size == 1) "one effect"
  match effs[0]! with
  | .llmRequest .. => pure ()
  | _ => throw "expected an llm_request effect"⟩

-- @tg: verifies:: [[openspec:agent-core#ReAct loop#Final answer ends the run]] {level: unit}
def finalAnswer : Case := ⟨"final answer ends the run", do
  let h ← newH
  let (h, es) ← feed h (user "hi")
  let rid ← requestId es
  let (h, es) ← feed h (llm rid (oaText "hello"))
  let c ← completion es
  eq (field c "reason") "final" "reason"
  eq (field c "answer") "hello" "answer"
  let (_, code) := feedCode h (llm rid (oaText "again"))
  eq code 2 "later model event rejected"⟩

-- @tg: verifies:: [[openspec:agent-core#ReAct loop#Tool result triggers next model request]] {level: unit}
def toolTriggersNext : Case := ⟨"tool result triggers next model request", do
  let (h, es) ← startWith (← newH) "confirm" (oaCalls [("c1", "confirm_user", "{\"question\":\"ok?\"}")])
  eq (toolCallIds es) #["c1"] "tool call"
  let (_, es) ← feed h (toolRes "c1" (j "{\"confirmed\":true}"))
  let body ← requestBody es
  check (contains body "\\\"confirmed\\\":true") s!"result in next request: {body}"⟩

-- @tg: verifies:: [[openspec:agent-core#ReAct loop#Cancellation ends the run]] {level: unit}
def cancellation : Case := ⟨"cancellation ends the run", do
  let h ← newH
  let (h, es) ← feed h (user "hi")
  let rid ← requestId es
  let (h, es) ← feed h cancel
  eq (field (← completion es) "reason") "cancelled" "reason"
  let (_, code) := feedCode h (llm rid (oaText "late"))
  eq code 2 "late result ignored"⟩

-- @tg: verifies:: [[openspec:agent-core#Run budgets#Tool-call budget exhausted]] {level: unit}
def toolBudget : Case := ⟨"tool-call budget exhausted", do
  let h ← newH [("maxToolCalls", .nat 1)]
  let (_, es) ← startWith h "two"
    (oaCalls [("c1", "confirm_user", "{\"question\":\"a\"}"), ("c2", "confirm_user", "{\"question\":\"b\"}")])
  eq (toolCallIds es) #["c1"] "only the first call"
  eq (field (← completion es) "reason") "budget" "reason"⟩

-- @tg: verifies:: [[openspec:agent-core#Run budgets#Every run terminates]] {level: unit}
def terminates : Case := ⟨"every run terminates", do
  -- Proved for all event sequences by `AgentLean.final_done`; checked here on a concrete run.
  let h ← newH [("maxSteps", .nat 3)]
  let (h, es) ← feed h (user "hi")
  let rid ← requestId es
  let (h, es) ← feed h (llm rid (oaCalls [("c1", "confirm_user", "{\"question\":\"a\"}")]))
  let _ := es
  let (h, _) ← feed h (toolRes "c1" (j "{\"confirmed\":true}"))
  let (h, es) ← feed h (llm "r2" (oaText "done?"))
  eq (field (← completion es) "reason") "budget" "step budget"
  check h.run.done "run is done"⟩

-- @tg: verifies:: [[openspec:agent-core#Parallel tool calls#Results arrive out of order]] {level: unit}
def outOfOrder : Case := ⟨"results arrive out of order", do
  let (h, es) ← startWith (← newH) "two"
    (oaCalls [("a", "confirm_user", "{\"question\":\"x\"}"), ("b", "web_fetch", "{\"url\":\"https://e.org\"}")])
  eq (toolCallIds es) #["a", "b"] "both calls"
  let (h, es) ← feed h (toolRes "b" (str "page"))
  check (ofType es "llm_request").isEmpty "no request before all results"
  let (_, es) ← feed h (toolRes "a" (j "{\"confirmed\":true}"))
  let body ← requestBody es
  check (contains body "page" && contains body "confirmed") "both results in the next request"⟩

-- @tg: verifies:: [[openspec:agent-core#UI events#Token deltas while streaming]] {level: unit}
def tokenDeltas : Case := ⟨"token deltas while streaming", do
  let h ← newH [("stream", .bool true)]
  let (h, es) ← feed h (user "hi")
  let rid ← requestId es
  let c1 := "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\nda"
  let c2 := "ta: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n"
  let (h, e1) ← feed h (chunk rid c1)
  let (h, e2) ← feed h (chunk rid c2)
  let deltas := (ofType (e1 ++ e2) "ui").map (field · "text")
  eq deltas #["Hel", "lo"] "one delta per decoded chunk"
  let (_, es) ← feed h (llmEnd rid)
  eq (field (← completion es) "answer") "Hello" "assembled answer"⟩

-- @tg: verifies:: [[openspec:agent-core#Agent as tool#Child cannot exceed parent budget]] {level: unit}
def childBudget : Case := ⟨"child cannot exceed parent budget", do
  -- Parent budget 3 calls: `research` uses 1, so the child (configured for 10) gets 2.
  let h ← newH [("maxToolCalls", .nat 3)]
  let (h, es) ← startWith h "research it" (oaCalls [("c1", "research", "{\"task\":\"find x\"}")])
  let rid ← requestId es
  let (h, es) ← feed h (llm rid (oaCalls [("w1", "web_fetch", "{\"url\":\"u1\"}"),
    ("w2", "web_fetch", "{\"url\":\"u2\"}"), ("w3", "web_fetch", "{\"url\":\"u3\"}")]))
  eq (toolCallIds es) #["f1/w1", "f1/w2"] "child limited to the parent's remaining 2 calls"
  let some child := h.run.frames[1]? | throw "no child frame"
  eq child.budget.toolCalls 2 "child budget"
  -- The child ran out, so the parent gets a failed result and asks the model again.
  let body ← requestBody es
  check (contains body "agent_failed") "parent sees the child's failure"⟩

-- @tg: verifies:: [[openspec:agent-core#Context window policy#Oldest tool result elided]] {level: unit}
def elision : Case := ⟨"oldest tool result elided", do
  let big := String.ofList (List.replicate 3000 'x')
  let h ← newH [("contextTokens", .nat 2200), ("maxOutputTokens", .nat 100)]
  let (h, es) ← startWith h "fetch" (oaCalls [("a", "web_fetch", "{\"url\":\"u1\"}")])
  let _ := es
  let (h, es) ← feed h (toolRes "a" (str big))
  let rid ← requestId es
  let (h, es) ← feed h (llm rid (oaCalls [("b", "web_fetch", "{\"url\":\"u2\"}")]))
  let _ := es
  let (_, es) ← feed h (toolRes "b" (str big))
  let body ← requestBody es
  check (contains body Context.elidedText) "first result elided"
  check (contains body "\"content\":\"fetch\"") "user turn kept"⟩

-- @tg: verifies:: [[openspec:agent-core#Context window policy#Pinned content never dropped]] {level: unit}
def pinned : Case := ⟨"pinned content never dropped", do
  -- `Context.fit_head` and `Context.fit_keeps_last_turn` prove this for every history.
  let hist := [Message.user "old question", .assistant "" #[{ id := "a", name := "web_fetch", args := "{}" }],
    .tool "a" "web_fetch" (String.ofList (List.replicate 4000 'y')), .user "new question"]
  match Context.fit 3 300 "SYS" hist with
  | some r =>
    eq (r.head?.map (· == .system "SYS")) (some true) "system first"
    check (r.contains (.user "new question")) "last user turn kept"
  | none => throw "should fit after shrinking"
  -- When the pinned content alone cannot fit, there is no request at all.
  eq (Context.fit 3 5 "SYS" hist).isNone true "overflow detected"⟩

/-! ## tools -/

-- @tg: verifies:: [[openspec:tools#Typed tool arguments#Malformed arguments rejected]] {level: unit}
def malformedArgs : Case := ⟨"malformed arguments rejected", do
  let (_, es) ← startWith (← newH) "add" (oaCalls [("c1", "add", "{\"a\":1}")])
  check (toolCallIds es).isEmpty "no tool executed"
  let body ← requestBody es
  check (contains body "invalid_arguments" && contains body "missing field 'b'") s!"error names field: {body}"⟩

-- @tg: verifies:: [[openspec:tools#Typed tool arguments#Unknown tool name rejected]] {level: unit}
def unknownTool : Case := ⟨"unknown tool name rejected", do
  let (_, es) ← startWith (← newH) "fly" (oaCalls [("c1", "fly", "{}")])
  check (toolCallIds es).isEmpty "no effect"
  let body ← requestBody es
  check (contains body "unknown_tool" && contains body "confirm_user") "lists declared names"⟩

/-- Candidate values for each field, valid and invalid. -/
def candidates : List (String × List (Option Json)) :=
  [("to", [some (str "bob"), some (.nat 3), none]),
   ("amount", [some (.nat 5), some (.int (-1)), some (.nat 4294967296), some (str "5"), none]),
   ("memo", [some (str "m"), some .null, some (.bool true), none])]

def combos : List (List (String × Json)) :=
  candidates.foldr (fun (k, vs) acc => vs.flatMap fun v => acc.map fun rest =>
    match v with | some x => (k, x) :: rest | none => rest) [[]]

-- @tg: verifies:: [[openspec:tools#Schema derived from tool type#Schema matches type]] {level: unit}
def schemaMatches : Case := ⟨"schema matches type", do
  let s := schemaOf Examples.TransferArgs
  eq ((s.get? "required").map Json.render) (some "[\"to\",\"amount\"]") "required fields"
  let mut n := 0
  for kvs in combos ++ [[("to", str "a"), ("amount", .nat 1), ("extra", .bool true)]] do
    let v := obj kvs
    let decodes := (fromJson? v : Except String Examples.TransferArgs).toBool
    eq (Schema.validate s v) decodes s!"schema acceptance vs decoding for {v.render}"
    n := n + 1
  check (n > 50) "enough cases"⟩

-- @tg: verifies:: [[openspec:tools#Tool executors#Pure tool runs without host round trip]] {level: unit}
def pureTool : Case := ⟨"pure tool runs without host round trip", do
  let (_, es) ← startWith (← newH) "add" (oaCalls [("c1", "add", "{\"a\":2,\"b\":3}")])
  check (toolCallIds es).isEmpty "no host effect"
  let body ← requestBody es
  check (contains body "\"content\":\"5\"") s!"result 5 in next request: {body}"⟩

/-- Confirm, then have the model call `transfer` with `args`. -/
def toTransfer (args : String) (extra : List (String × Json) := []) : T (Handle × Array Json) := do
  let (h, _) ← startWith (← newH extra) "pay" (oaCalls [("c1", "confirm_user", "{\"question\":\"pay?\"}")])
  let (h, es) ← feed h (toolRes "c1" (j "{\"confirmed\":true}"))
  let rid ← requestId es
  feed h (llm rid (oaCalls [("t1", "transfer", args)]))

-- @tg: verifies:: [[openspec:tools#Tool executors#Host tool result decoded and checked]] {level: unit}
def hostResult : Case := ⟨"host tool result decoded and checked", do
  let (h, es) ← toTransfer "{\"to\":\"bob\",\"amount\":50}"
  eq (toolCallIds es) #["t1"] "host call emitted"
  let (_, es) ← feed h (toolRes "t1" (j "{\"ok\":true}"))
  check (contains (← requestBody es) "invalid_result") "bad result rejected"⟩

-- @tg: verifies:: [[openspec:tools#Static tool registry#Host offers undeclared tool]] {level: unit}
def undeclared : Case := ⟨"host offers undeclared tool", do
  match Handle.create Examples.env (cfgWith [("hostTools", .arr #[str "bank.transfer", str "evil.tool"])]).render.toUTF8 with
  | .ok _ => throw "creation should fail"
  | .error e => check (contains e "undeclared tool") e⟩

-- @tg: verifies:: [[openspec:tools#Tool contracts#Precondition blocks execution]] {level: unit}
def precondition : Case := ⟨"precondition blocks execution", do
  let (_, es) ← toTransfer "{\"to\":\"bob\",\"amount\":0}"
  check (toolCallIds es).isEmpty "not executed"
  check (contains (← requestBody es) "precondition_failed") "precondition error"⟩

-- @tg: verifies:: [[openspec:tools#Tool contracts#Postcondition failure]] {level: unit}
def postcondition : Case := ⟨"postcondition failure", do
  let (h, _) ← toTransfer "{\"to\":\"bob\",\"amount\":50}"
  let (_, es) ← feed h (toolRes "t1" (j "{\"ok\":true,\"ref\":\"\"}"))
  let body ← requestBody es
  check (contains body "postcondition_failed") "postcondition error"⟩

-- @tg: verifies:: [[openspec:tools#Idempotency declaration#Non-idempotent in-flight call after crash]] {level: integration}
def nonIdempotentResume : Case := ⟨"non-idempotent in-flight call after crash", do
  let (h, _) ← toTransfer "{\"to\":\"bob\",\"amount\":50}"
  let h2 ← match Handle.restore Examples.env h.snapshot.toUTF8 with
    | .ok h => pure h | .error e => throw e
  let (_, es) ← feed h2 resume
  check (toolCallIds es).isEmpty "transfer not re-issued"
  check (contains (← requestBody es) "interrupted") "marked interrupted"⟩

-- @tg: verifies:: [[openspec:tools#Idempotency declaration#Idempotent in-flight call after crash]] {level: integration}
def idempotentResume : Case := ⟨"idempotent in-flight call after crash", do
  let (h, _) ← startWith (← newH) "q" (oaCalls [("c1", "confirm_user", "{\"question\":\"ok?\"}")])
  let h2 ← match Handle.restore Examples.env h.snapshot.toUTF8 with
    | .ok h => pure h | .error e => throw e
  let (_, es) ← feed h2 resume
  eq (toolCallIds es) #["c1"] "re-issued"⟩

-- @tg: verifies:: [[openspec:tools#Data labels#Untrusted label recorded]] {level: unit}
def untrustedLabel : Case := ⟨"untrusted label recorded", do
  let (h, _) ← startWith (← newH) "f" (oaCalls [("w", "web_fetch", "{\"url\":\"u\"}")])
  let (h, _) ← feed h (toolRes "w" (str "<html>"))
  let some e := h.trace.back? | throw "empty trace"
  check e.untrusted "trace entry labelled untrusted"⟩

def cases : List Case := [sameInputs, noIO, finalAnswer, toolTriggersNext, cancellation, toolBudget,
  terminates, outOfOrder, tokenDeltas, childBudget, elision, pinned, malformedArgs, unknownTool,
  schemaMatches, pureTool, hostResult, undeclared, precondition, postcondition, nonIdempotentResume,
  idempotentResume, untrustedLabel]

end Tests.Core
