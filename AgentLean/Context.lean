module

public import AgentLean.Types

/-!
# Context window policy

Each model request must fit the model's context limit under a conservative token estimate
(ADR 0010). The request is `system :: (older turns ++ last turn)`, shrunk in this order:

1. elide the oldest tool results of older turns,
2. drop the oldest older turns,
3. elide the oldest tool results of the last turn.

The system prompt and every non-tool message of the last turn (the last user message first of all)
are never removed (`fit_head`, `fit_keeps_last_turn`), and a returned request always fits the
estimate (`fit_fits`). Tool schemas travel outside the history and are always sent.
-/

@[expose] public section

namespace AgentLean.Context

/-- Conservative token estimate: bytes divided by `bpt` (rounded up) plus 4 tokens per message. -/
def estimate (bpt : Nat) (msgs : List Message) : Nat :=
  msgs.foldl (fun n m => n + (m.bytes + bpt - 1) / bpt + 4) 0

def elidedText : String := "[result elided to fit the context window]"

def elideTool : Message → Message
  | .tool i n _ => .tool i n elidedText
  | m => m

/-- Elide the first `k` tool results that are not elided yet. -/
def elideFirst : Nat → List Message → List Message
  | 0, ms => ms
  | _, [] => []
  | k + 1, m :: ms =>
    if m.isTool && m != elideTool m then elideTool m :: elideFirst k ms
    else m :: elideFirst (k + 1) ms

/-- Split into turns: each turn starts at a user message (a leading non-user prefix is its own turn). -/
def turns : List Message → List (List Message)
  | [] => []
  | m :: ms =>
    let rest := turns ms
    match rest with
    | t :: ts => if (t.head?.map Message.isUser) == some true then [m] :: t :: ts else (m :: t) :: ts
    | [] => [[m]]

/-- Index of the last user message. -/
def lastUserIdx (ms : List Message) : Option Nat :=
  (ms.zipIdx.filter (·.1.isUser)).getLast?.map (·.2)

/-- Split history into older messages and the last turn (from the last user message on). -/
def split (ms : List Message) : List Message × List Message :=
  match lastUserIdx ms with
  | some i => (ms.take i, ms.drop i)
  | none => ([], ms)

def candidate (sys : String) (older last : List Message) (k1 d k2 : Nat) : List Message :=
  Message.system sys :: ((turns (elideFirst k1 older)).drop d).flatten ++ elideFirst k2 last

def toolCount (ms : List Message) : Nat := (ms.filter Message.isTool).length

/-- The first candidate that fits, trying less destructive shrinking first. -/
def search (bpt limit : Nat) (sys : String) (older last : List Message) : Option (Nat × Nat × Nat) := Id.run do
  let fits := fun k1 d k2 => estimate bpt (candidate sys older last k1 d k2) ≤ limit
  for k1 in [0:toolCount older + 1] do
    if fits k1 0 0 then return some (k1, 0, 0)
  let k1 := toolCount older
  let nTurns := (turns (elideFirst k1 older)).length
  for d in [0:nTurns + 1] do
    if fits k1 d 0 then return some (k1, d, 0)
  for k2 in [0:toolCount last + 1] do
    if fits k1 nTurns k2 then return some (k1, nTurns, k2)
  return none

-- @tg: implements:: [[openspec:agent-core#Context window policy]]
/-- Build the messages of a request within `limit` estimated tokens, or `none` if even the pinned
content does not fit. -/
def fit (bpt limit : Nat) (sys : String) (hist : List Message) : Option (List Message) :=
  let (older, last) := split hist
  match search bpt limit sys older last with
  | some (k1, d, k2) =>
    let r := candidate sys older last k1 d k2
    if estimate bpt r ≤ limit then some r else none
  | none => none

/-! ## Guarantees -/

theorem elideFirst_keeps (k : Nat) (ms : List Message) (m : Message) (hm : m ∈ ms) (ht : m.isTool = false) :
    m ∈ elideFirst k ms := by
  induction ms generalizing k with
  | nil => cases hm
  | cons x xs ih =>
    cases k with
    | zero => simpa [elideFirst] using hm
    | succ k =>
      simp only [elideFirst]
      rcases List.mem_cons.mp hm with h | h
      · subst h; split <;> simp_all
      · split <;> simp [ih _ h]

theorem fit_some (bpt limit : Nat) (sys : String) (hist r : List Message)
    (h : fit bpt limit sys hist = some r) :
    ∃ k1 d k2, r = candidate sys (split hist).1 (split hist).2 k1 d k2 ∧ estimate bpt r ≤ limit := by
  unfold fit at h
  rcases hs : split hist with ⟨older, last⟩
  rw [hs] at h
  simp only at h
  split at h
  · rename_i k1 d k2 _
    simp at h
    obtain ⟨h1, rfl⟩ := h
    exact ⟨k1, d, k2, rfl, h1⟩
  · simp at h

/-- A returned request always fits the estimate. -/
theorem fit_fits (bpt limit : Nat) (sys : String) (hist r : List Message)
    (h : fit bpt limit sys hist = some r) : estimate bpt r ≤ limit := by
  obtain ⟨_, _, _, _, h2⟩ := fit_some bpt limit sys hist r h
  exact h2

/-- The system prompt is always the first message. -/
theorem fit_head (bpt limit : Nat) (sys : String) (hist r : List Message)
    (h : fit bpt limit sys hist = some r) : r.head? = some (Message.system sys) := by
  obtain ⟨_, _, _, rfl, _⟩ := fit_some bpt limit sys hist r h
  simp [candidate]

/-- Every non-tool message of the last turn (in particular the last user message) is kept. -/
theorem fit_keeps_last_turn (bpt limit : Nat) (sys : String) (hist r : List Message)
    (h : fit bpt limit sys hist = some r) (m : Message) (hm : m ∈ (split hist).2)
    (ht : m.isTool = false) : m ∈ r := by
  obtain ⟨_, _, k2, rfl, _⟩ := fit_some bpt limit sys hist r h
  simp only [candidate, List.mem_cons, List.mem_append]
  simp [elideFirst_keeps k2 _ m hm ht]

end AgentLean.Context
