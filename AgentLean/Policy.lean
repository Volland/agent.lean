module

public import AgentLean.Json

/-!
# Policies

Policies say which tool calls an agent may make, with which arguments and in which order. A policy
is a past-time temporal formula over the run's observations (`Obs`), evaluated whenever a tool call
is about to be made, with the candidate call as the newest observation.

* `Formula.eval` is the specification: the formula's value over the whole trace (newest first).
* `mstep` is the monitor: it keeps one small state per subformula and updates it per observation,
  so checking costs time proportional to the formula, independent of the trace length.
* `monitor_sound` proves the monitor's verdict equals `eval` over the whole trace (ADR 0009).
-/

@[expose] public section

namespace AgentLean

/-- What policies observe about a run, one entry per accepted event. -/
inductive Obs where
  /-- A user turn starts. -/
  | user (text : String)
  /-- A tool call (the candidate when checking, then committed if allowed). -/
  | call (name : String) (args : Json)
  /-- A tool result arrived; `untrusted` comes from the tool's data label. -/
  | result (name : String) (untrusted : Bool)
  /-- The model replied. -/
  | reply
  /-- A call was refused by a policy and never executed. -/
  | refused (name : String)
  deriving Inhabited

/-- Past-time temporal formulas over observations. -/
inductive Formula where
  | tt
  | ff
  /-- A predicate on the newest observation; the label is for messages. -/
  | atom (label : String) (p : Obs → Bool)
  | not (f : Formula)
  | and (f g : Formula)
  | or (f g : Formula)
  /-- `f` held at the previous observation (false at the first). -/
  | prev (f : Formula)
  /-- `f` held at some observation so far, including now. -/
  | once (f : Formula)
  /-- `f` held at every observation so far, including now. -/
  | hist (f : Formula)
  /-- `g` held at some observation, and `f` at every observation after it up to now. -/
  | since (f g : Formula)
  /-- The number of observations where `f` held since the last one where `g` held is at most `n`. -/
  | countSince (f g : Formula) (n : Nat)
  deriving Inhabited

namespace Formula

/-! ## Specification -/

def anySuffix (p : List Obs → Bool) : List Obs → Bool
  | [] => false
  | o :: r => p (o :: r) || anySuffix p r

def allSuffix (p : List Obs → Bool) : List Obs → Bool
  | [] => true
  | o :: r => p (o :: r) && allSuffix p r

def sinceAux (pf pg : List Obs → Bool) : List Obs → Bool
  | [] => false
  | o :: r => pg (o :: r) || (pf (o :: r) && sinceAux pf pg r)

def countAux (pf pg : List Obs → Bool) : List Obs → Nat
  | [] => 0
  | o :: r => if pg (o :: r) then 0 else (if pf (o :: r) then 1 else 0) + countAux pf pg r

-- @tg: implements:: [[openspec:policies#Temporal trace policies]]
/-- The value of a formula over a trace given newest first. -/
def eval : Formula → List Obs → Bool
  | tt, _ => true
  | ff, _ => false
  | atom _ p, tr => match tr with
    | o :: _ => p o
    | [] => false
  | not f, tr => !eval f tr
  | and f g, tr => eval f tr && eval g tr
  | or f g, tr => eval f tr || eval g tr
  | prev f, tr => match tr with
    | _ :: r => match r with
      | [] => false
      | _ :: _ => eval f r
    | [] => false
  | once f, tr => anySuffix (eval f) tr
  | hist f, tr => allSuffix (eval f) tr
  | since f g, tr => sinceAux (eval f) (eval g) tr
  | countSince f g n, tr => decide (countAux (eval f) (eval g) tr ≤ n)

/-! ## Building formulas (the L1/L2 policy vocabulary) -/

def implies (f g : Formula) : Formula := or (not f) g

/-- The newest observation is a call to `name`. -/
def isCall (name : String) : Formula :=
  atom s!"call {name}" fun | .call n _ => n == name | _ => false

/-- The newest observation is a call to `name` whose arguments satisfy `p` (an L1 guard). -/
def callWhere (name : String) (label : String) (p : Json → Bool) : Formula :=
  atom s!"call {name} where {label}" fun | .call n a => n == name && p a | _ => false

/-- Any tool call. -/
def anyCall : Formula := atom "any call" fun | .call _ _ => true | _ => false

/-- The newest observation is a user turn. -/
def userTurn : Formula := atom "user turn" fun | .user _ => true | _ => false

/-- The newest observation is a result labelled untrusted. -/
def untrustedResult : Formula := atom "untrusted result" fun | .result _ u => u | _ => false

-- @tg: implements:: [[openspec:policies#Taint-based information flow]]
/-- Untrusted data has entered the context since the last user turn. -/
def tainted : Formula := since (not userTurn) untrustedResult

/-- Guard on a numeric argument. -/
def argNat (key : String) (p : Nat → Bool) : Json → Bool := fun a =>
  match a.get? key >>= Json.getNat? with
  | some n => p n
  | none => false

/-- Guard on a string argument. -/
def argStr (key : String) (p : String → Bool) : Json → Bool := fun a =>
  match a.get? key >>= Json.getStr? with
  | some s => p s
  | none => false

/-- `name` may only be called if `before` was called since the last user turn. -/
def requiresBefore (name before : String) : Formula :=
  implies (isCall name) (prev (since (not userTurn) (isCall before)))

/-- At most `n` calls to `name` per user turn (counting the candidate). -/
def atMostPerTurn (name : String) (n : Nat) : Formula :=
  implies (isCall name) (countSince (isCall name) userTurn n)

-- @tg: implements:: [[openspec:policies#Taint-based information flow]]
/-- After untrusted data, `name` needs a `confirm` call that came after the untrusted data. -/
def confirmAfterUntrusted (name confirm : String) : Formula :=
  implies (isCall name) (not (prev (since (not (isCall confirm)) untrustedResult)))

-- @tg: implements:: [[openspec:policies#Per-call guards]]
/-- Every call to `name` must satisfy the argument guard `p`. -/
def guard (name : String) (label : String) (p : Json → Bool) : Formula :=
  implies (isCall name) (callWhere name label p)

end Formula

/-! ## Monitor -/

/-- Monitor state: one node per subformula with its current value (and a counter for counts). -/
inductive Mon where
  | leaf (now : Bool)
  | one (now : Bool) (c : Mon)
  | two (now : Bool) (l r : Mon)
  | cnt (now : Bool) (k : Nat) (l r : Mon)
  deriving Inhabited, Repr, BEq

namespace Mon

def now : Mon → Bool
  | leaf v | one v _ | two v _ _ | cnt v _ _ _ => v

def c1 : Option Mon → Option Mon
  | some (one _ c) => some c
  | _ => none

def l2 : Option Mon → Option Mon
  | some (two _ l _) => some l
  | some (cnt _ _ l _) => some l
  | _ => none

def r2 : Option Mon → Option Mon
  | some (two _ _ r) => some r
  | some (cnt _ _ _ r) => some r
  | _ => none

def nowD (d : Bool) : Option Mon → Bool
  | some m => m.now
  | none => d

def kD : Option Mon → Nat
  | some (cnt _ k _ _) => k
  | _ => 0

/-- JSON form for snapshots. -/
partial def toJson : Mon → Json
  | leaf v => .arr #[.bool v]
  | one v c => .arr #[.bool v, toJson c]
  | two v l r => .arr #[.bool v, toJson l, toJson r]
  | cnt v k l r => .arr #[.bool v, .nat k, toJson l, toJson r]

partial def fromJson? : Json → Except String Mon
  | .arr #[.bool v] => pure (leaf v)
  | .arr #[.bool v, c] => one v <$> fromJson? c
  | .arr #[.bool v, l, r] => do pure (two v (← fromJson? l) (← fromJson? r))
  | .arr #[.bool v, k, l, r] => do
    let some k := k.getNat? | throw "monitor: bad counter"
    pure (cnt v k (← fromJson? l) (← fromJson? r))
  | _ => throw "monitor: bad state"

end Mon

-- @tg: implements:: [[openspec:policies#Monitor soundness]]
/-- One monitor step: the new state after observing `o`, given the previous state (none at the start). -/
def mstep : Formula → Option Mon → Obs → Mon
  | .tt, _, _ => .leaf true
  | .ff, _, _ => .leaf false
  | .atom _ p, _, o => .leaf (p o)
  | .not f, s, o => let c := mstep f (Mon.c1 s) o; .one (!c.now) c
  | .and f g, s, o =>
    let l := mstep f (Mon.l2 s) o; let r := mstep g (Mon.r2 s) o; .two (l.now && r.now) l r
  | .or f g, s, o =>
    let l := mstep f (Mon.l2 s) o; let r := mstep g (Mon.r2 s) o; .two (l.now || r.now) l r
  | .prev f, s, o => let c := mstep f (Mon.c1 s) o; .one (Mon.nowD false (Mon.c1 s)) c
  | .once f, s, o => let c := mstep f (Mon.c1 s) o; .one (c.now || Mon.nowD false s) c
  | .hist f, s, o => let c := mstep f (Mon.c1 s) o; .one (c.now && Mon.nowD true s) c
  | .since f g, s, o =>
    let l := mstep f (Mon.l2 s) o; let r := mstep g (Mon.r2 s) o
    .two (r.now || (l.now && Mon.nowD false s)) l r
  | .countSince f g n, s, o =>
    let l := mstep f (Mon.l2 s) o; let r := mstep g (Mon.r2 s) o
    let k := if r.now then 0 else (if l.now then 1 else 0) + Mon.kD s
    .cnt (decide (k ≤ n)) k l r

/-- Run the monitor over a trace given newest first. -/
def runMon (f : Formula) : List Obs → Option Mon
  | [] => none
  | o :: r => some (mstep f (runMon f r) o)

/-! ## Soundness -/

/-- The state the monitor should be in after a nonempty trace, defined from `eval`. -/
def spec : Formula → List Obs → Mon
  | .tt, _ => .leaf true
  | .ff, _ => .leaf false
  | .atom l p, tr => .leaf (Formula.eval (.atom l p) tr)
  | .not f, tr => .one (Formula.eval (.not f) tr) (spec f tr)
  | .and f g, tr => .two (Formula.eval (.and f g) tr) (spec f tr) (spec g tr)
  | .or f g, tr => .two (Formula.eval (.or f g) tr) (spec f tr) (spec g tr)
  | .prev f, tr => .one (Formula.eval (.prev f) tr) (spec f tr)
  | .once f, tr => .one (Formula.eval (.once f) tr) (spec f tr)
  | .hist f, tr => .one (Formula.eval (.hist f) tr) (spec f tr)
  | .since f g, tr => .two (Formula.eval (.since f g) tr) (spec f tr) (spec g tr)
  | .countSince f g n, tr =>
    .cnt (Formula.eval (.countSince f g n) tr) (Formula.countAux (Formula.eval f) (Formula.eval g) tr)
      (spec f tr) (spec g tr)

def specOpt (f : Formula) : List Obs → Option Mon
  | [] => none
  | tr@(_ :: _) => some (spec f tr)

theorem spec_now (f : Formula) (tr : List Obs) : (spec f tr).now = f.eval tr := by
  cases f <;> rfl

theorem nowD_specOpt (f : Formula) (d : Bool) (tr : List Obs) (h : tr = [] → d = f.eval []) :
    Mon.nowD d (specOpt f tr) = f.eval tr := by
  cases tr with
  | nil => simp [specOpt, Mon.nowD, h]
  | cons o r => simp [specOpt, Mon.nowD, spec_now]

theorem mstep_spec (f : Formula) (o : Obs) (r : List Obs) :
    mstep f (specOpt f r) o = spec f (o :: r) := by
  induction f with
  | tt => rfl
  | ff => rfl
  | atom l p => rfl
  | not f ih =>
    have hc : Mon.c1 (specOpt (.not f) r) = specOpt f r := by cases r <;> rfl
    simp [mstep, hc, ih, spec, spec_now, Formula.eval]
  | and f g ihf ihg =>
    have hl : Mon.l2 (specOpt (.and f g) r) = specOpt f r := by cases r <;> rfl
    have hr : Mon.r2 (specOpt (.and f g) r) = specOpt g r := by cases r <;> rfl
    simp [mstep, hl, hr, ihf, ihg, spec, spec_now, Formula.eval]
  | or f g ihf ihg =>
    have hl : Mon.l2 (specOpt (.or f g) r) = specOpt f r := by cases r <;> rfl
    have hr : Mon.r2 (specOpt (.or f g) r) = specOpt g r := by cases r <;> rfl
    simp [mstep, hl, hr, ihf, ihg, spec, spec_now, Formula.eval]
  | prev f ih =>
    have hc : Mon.c1 (specOpt (.prev f) r) = specOpt f r := by cases r <;> rfl
    simp only [mstep, hc, ih, spec]
    cases r with
    | nil => rfl
    | cons x xs => simp [specOpt, Mon.nowD, spec_now, Formula.eval]
  | once f ih =>
    have hc : Mon.c1 (specOpt (.once f) r) = specOpt f r := by cases r <;> rfl
    have hp : Mon.nowD false (specOpt (.once f) r) = (Formula.once f).eval r :=
      nowD_specOpt _ _ _ (fun h => by subst h; rfl)
    simp [mstep, hc, ih, hp, spec, spec_now, Formula.eval, Formula.anySuffix]
  | hist f ih =>
    have hc : Mon.c1 (specOpt (.hist f) r) = specOpt f r := by cases r <;> rfl
    have hp : Mon.nowD true (specOpt (.hist f) r) = (Formula.hist f).eval r :=
      nowD_specOpt _ _ _ (fun h => by subst h; rfl)
    simp [mstep, hc, ih, hp, spec, spec_now, Formula.eval, Formula.allSuffix]
  | since f g ihf ihg =>
    have hl : Mon.l2 (specOpt (.since f g) r) = specOpt f r := by cases r <;> rfl
    have hr : Mon.r2 (specOpt (.since f g) r) = specOpt g r := by cases r <;> rfl
    have hp : Mon.nowD false (specOpt (.since f g) r) = (Formula.since f g).eval r :=
      nowD_specOpt _ _ _ (fun h => by subst h; rfl)
    simp [mstep, hl, hr, ihf, ihg, hp, spec, spec_now, Formula.eval, Formula.sinceAux]
  | countSince f g n ihf ihg =>
    have hl : Mon.l2 (specOpt (.countSince f g n) r) = specOpt f r := by cases r <;> rfl
    have hr : Mon.r2 (specOpt (.countSince f g n) r) = specOpt g r := by cases r <;> rfl
    have hk : Mon.kD (specOpt (.countSince f g n) r) =
        Formula.countAux (Formula.eval f) (Formula.eval g) r := by cases r <;> rfl
    simp only [mstep, hl, hr, ihf, ihg, hk, spec, spec_now]
    simp [Formula.eval, Formula.countAux]
    exact decide_eq_decide.mpr Iff.rfl

/-- The monitor is in the specified state after every trace. -/
theorem runMon_eq_specOpt (f : Formula) (tr : List Obs) : runMon f tr = specOpt f tr := by
  induction tr with
  | nil => rfl
  | cons o r ih => rw [runMon, ih, mstep_spec]; rfl

-- @tg: implements:: [[adr:0009]]
-- @tg: implements:: [[openspec:policies#Monitor soundness]]
/-- **Monitor soundness**: checking a candidate observation `o` with the monitor state of the trace
so far gives exactly the formula's value over the whole trace including `o`. -/
theorem monitor_sound (f : Formula) (o : Obs) (tr : List Obs) :
    (mstep f (runMon f tr) o).now = f.eval (o :: tr) := by
  rw [runMon_eq_specOpt, mstep_spec, spec_now]

/-! ## Policies -/

inductive OnViolation where
  /-- Refuse the call, tell the model why, and continue the run. -/
  | recover
  /-- End the run. -/
  | halt
  deriving BEq, Repr, Inhabited

/-- A named rule checked before every tool call, with the candidate call as the newest observation. -/
structure Policy where
  name : String
  rule : Formula
  onViolation : OnViolation := .recover
  /-- Why the rule exists; sent to the model with a refusal. -/
  reason : String := ""
  deriving Inhabited

end AgentLean
