module

/-!
# JSON

agent.lean's own JSON: a value type, a byte-level parser and a deterministic printer. It imports
only `Init`, so it stays out of the Lean compiler's libraries (ADR 0005).

* The parser works on UTF-8 bytes, rejects invalid UTF-8 and limits nesting depth, so adversarial
  model output cannot exhaust the stack of a small device.
* Numbers are kept exactly as decimal mantissa and exponent: no floating point on the data path,
  so every target prints the same bytes.
* Objects keep their key order; the printer is compact and deterministic.
-/

@[expose] public section

namespace AgentLean

/-- A JSON number, exactly: `mantissa * 10^exponent`. -/
structure JsonNumber where
  mantissa : Int
  exponent : Int := 0
  deriving BEq, Repr, Inhabited, DecidableEq

/-- A JSON value. Objects keep their key order. -/
inductive Json where
  | null
  | bool (b : Bool)
  | num (n : JsonNumber)
  | str (s : String)
  | arr (xs : Array Json)
  | obj (kvs : Array (String × Json))
  deriving Inhabited, Repr

namespace JsonNumber

def ofInt (i : Int) : JsonNumber := ⟨i, 0⟩

def pow10 : Nat → Nat
  | 0 => 1
  | n + 1 => 10 * pow10 n

/-- The integer value, if the number has no fractional part. -/
def toInt? (n : JsonNumber) : Option Int :=
  if n.exponent ≥ 0 then some (n.mantissa * (pow10 n.exponent.toNat : Int))
  else
    let d : Int := pow10 n.exponent.natAbs
    if n.mantissa % d == 0 then some (n.mantissa / d) else none

/-- Decimal rendering without exponent notation for exponents in [-20, 20]. -/
def render (n : JsonNumber) : String :=
  let sign := if n.mantissa < 0 then "-" else ""
  let digits := toString n.mantissa.natAbs
  if n.exponent == 0 then sign ++ digits
  else if n.exponent > 0 && n.exponent ≤ 20 then sign ++ digits ++ String.ofList (List.replicate n.exponent.toNat '0')
  else if n.exponent < 0 && n.exponent ≥ -20 then
    let k := n.exponent.natAbs
    let padded := if digits.length ≤ k then String.ofList (List.replicate (k + 1 - digits.length) '0') ++ digits else digits
    let intPart := padded.take (padded.length - k)
    let frac := padded.drop (padded.length - k)
    sign ++ intPart.toString ++ "." ++ frac.toString
  else sign ++ digits ++ "e" ++ toString n.exponent

end JsonNumber

namespace Json

partial def beq : Json → Json → Bool
  | null, null => true
  | bool a, bool b => a == b
  | num a, num b => a == b
  | str a, str b => a == b
  | arr a, arr b => a.size == b.size && (a.zip b).all fun (x, y) => beq x y
  | obj a, obj b => a.size == b.size && (a.zip b).all fun ((k, x), (l, y)) => k == l && beq x y
  | _, _ => false

instance : BEq Json := ⟨beq⟩

def int (i : Int) : Json := num (JsonNumber.ofInt i)
def nat (n : Nat) : Json := num (JsonNumber.ofInt n)

/-- Look up a key of an object (the first occurrence). -/
def get? (j : Json) (k : String) : Option Json :=
  match j with
  | obj kvs => (kvs.find? (·.1 == k)).map (·.2)
  | _ => none

/-- Look up a key, treating `null` as absent. -/
def getOpt? (j : Json) (k : String) : Option Json :=
  match j.get? k with
  | some null => none
  | r => r

def getStr? : Json → Option String
  | str s => some s
  | _ => none

def getArr? : Json → Option (Array Json)
  | arr xs => some xs
  | _ => none

def getBool? : Json → Option Bool
  | bool b => some b
  | _ => none

def getInt? : Json → Option Int
  | num n => n.toInt?
  | _ => none

def getNat? (j : Json) : Option Nat := do
  let i ← j.getInt?
  if i ≥ 0 then some i.toNat else none

/-- Insert or replace a key in an object; a non-object becomes a one-key object. -/
def set (j : Json) (k : String) (v : Json) : Json :=
  match j with
  | obj kvs =>
    match kvs.findIdx? (·.1 == k) with
    | some i => obj (kvs.set! i (k, v))
    | none => obj (kvs.push (k, v))
  | _ => obj #[(k, v)]

/-- Build an object, dropping `none` fields. -/
def mkObj (fields : List (String × Option Json)) : Json :=
  obj (fields.filterMap fun (k, v) => v.map (k, ·)).toArray

/-! ## Printing -/

def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

/-- Escape a string's content (without quotes). Control characters become `\u00XX`. -/
def escape (s : String) : String :=
  s.foldl (init := "") fun acc c =>
    match c with
    | '"' => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | '\r' => acc ++ "\\r"
    | '\t' => acc ++ "\\t"
    | c =>
      if c.toNat < 0x20 then
        acc ++ "\\u00" ++ (hexDigit (c.toNat / 16)).toString ++ (hexDigit (c.toNat % 16)).toString
      else acc.push c

def quote (s : String) : String := "\"" ++ escape s ++ "\""

/-- Compact, deterministic rendering. -/
partial def render : Json → String
  | null => "null"
  | bool true => "true"
  | bool false => "false"
  | num n => n.render
  | str s => quote s
  | arr xs => "[" ++ ",".intercalate (xs.toList.map render) ++ "]"
  | obj kvs => "{" ++ ",".intercalate (kvs.toList.map fun (k, v) => quote k ++ ":" ++ render v) ++ "}"

instance : ToString Json := ⟨render⟩

/-! ## Parsing -/

/-- Maximum nesting depth accepted by the parser. -/
def maxDepth : Nat := 128

abbrev P := StateT Nat (Except String)

structure Src where
  bytes : ByteArray

def peek (s : Src) : P (Option UInt8) := do
  let i ← get
  return if i < s.bytes.size then some s.bytes[i]! else none

def advance (n : Nat := 1) : P Unit := modify (· + n)

def err {α} (msg : String) : P α := do
  throw s!"json: {msg} at byte {← get}"

def isWs (b : UInt8) : Bool := b == 32 || b == 9 || b == 10 || b == 13

partial def skipWs (s : Src) : P Unit := do
  match ← peek s with
  | some b => if isWs b then advance; skipWs s else pure ()
  | none => pure ()

def expectLit (s : Src) (lit : String) : P Unit := do
  for b in lit.toUTF8 do
    match ← peek s with
    | some c => if c == b then advance else err s!"expected {lit}"
    | none => err s!"expected {lit}"

def hexVal (b : UInt8) : Option Nat :=
  if 48 ≤ b && b ≤ 57 then some (b.toNat - 48)
  else if 97 ≤ b && b ≤ 102 then some (b.toNat - 87)
  else if 65 ≤ b && b ≤ 70 then some (b.toNat - 55)
  else none

def hex4 (s : Src) : P Nat := do
  let mut v := 0
  for _ in [0:4] do
    match ← peek s with
    | some b =>
      match hexVal b with
      | some d => v := v * 16 + d; advance
      | none => err "bad \\u escape"
    | none => err "bad \\u escape"
  return v

/-- Append the UTF-8 encoding of a code point. -/
def pushUtf8 (out : ByteArray) (cp : Nat) : ByteArray :=
  if cp < 0x80 then out.push cp.toUInt8
  else if cp < 0x800 then
    (out.push (0xC0 + cp / 64).toUInt8).push (0x80 + cp % 64).toUInt8
  else if cp < 0x10000 then
    ((out.push (0xE0 + cp / 4096).toUInt8).push (0x80 + (cp / 64) % 64).toUInt8).push (0x80 + cp % 64).toUInt8
  else
    (((out.push (0xF0 + cp / 262144).toUInt8).push (0x80 + (cp / 4096) % 64).toUInt8).push
      (0x80 + (cp / 64) % 64).toUInt8).push (0x80 + cp % 64).toUInt8

partial def strBody (s : Src) (acc : ByteArray) : P ByteArray := do
  match ← peek s with
  | none => err "unterminated string"
  | some 34 => advance; return acc
  | some 92 =>
    advance
    match ← peek s with
    | some 34 => advance; strBody s (acc.push 34)
    | some 92 => advance; strBody s (acc.push 92)
    | some 47 => advance; strBody s (acc.push 47)
    | some 98 => advance; strBody s (acc.push 8)
    | some 102 => advance; strBody s (acc.push 12)
    | some 110 => advance; strBody s (acc.push 10)
    | some 114 => advance; strBody s (acc.push 13)
    | some 116 => advance; strBody s (acc.push 9)
    | some 117 =>
      advance
      let hi ← hex4 s
      if 0xD800 ≤ hi && hi < 0xDC00 then
        expectLit s "\\u"
        let lo ← hex4 s
        if 0xDC00 ≤ lo && lo < 0xE000 then
          strBody s (pushUtf8 acc (0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)))
        else err "invalid surrogate pair"
      else if 0xDC00 ≤ hi && hi < 0xE000 then err "lone low surrogate"
      else strBody s (pushUtf8 acc hi)
    | _ => err "bad escape"
  | some b =>
    if b < 32 then err "control character in string" else
    advance; strBody s (acc.push b)

def parseStr (s : Src) : P String := do
  advance -- opening quote
  let bytes ← strBody s ByteArray.empty
  match String.fromUTF8? bytes with
  | some t => return t
  | none => err "invalid UTF-8 in string"

def isDigit (b : UInt8) : Bool := 48 ≤ b && b ≤ 57

partial def digits (s : Src) (acc : Nat) (count : Nat) : P (Nat × Nat) := do
  match ← peek s with
  | some b => if isDigit b then advance; digits s (acc * 10 + (b.toNat - 48)) (count + 1) else return (acc, count)
  | none => return (acc, count)

def number (s : Src) : P JsonNumber := do
  let neg ← do
    if (← peek s) == some 45 then advance; pure true else pure false
  let (intPart, n) ← digits s 0 0
  if n == 0 then err "expected digit"
  let mut mant : Nat := intPart
  let mut exp : Int := 0
  if (← peek s) == some 46 then
    advance
    let (frac, k) ← digits s 0 0
    if k == 0 then err "expected digit after '.'"
    mant := mant * (10 ^ k) + frac
    exp := -(k : Int)
  match ← peek s with
  | some 101 | some 69 =>
    advance
    let eneg ← do
      match ← peek s with
      | some 45 => advance; pure true
      | some 43 => advance; pure false
      | _ => pure false
    let (e, k) ← digits s 0 0
    if k == 0 then err "expected exponent digits"
    exp := exp + (if eneg then -(e : Int) else e)
  | _ => pure ()
  return ⟨if neg then -(mant : Int) else mant, exp⟩

mutual
partial def value (s : Src) (depth : Nat) : P Json := do
  skipWs s
  match ← peek s with
  | none => err "unexpected end of input"
  | some 110 => expectLit s "null"; return null
  | some 116 => expectLit s "true"; return bool true
  | some 102 => expectLit s "false"; return bool false
  | some 34 => return Json.str (← parseStr s)
  | some 91 => array s depth
  | some 123 => object s depth
  | some b => if b == 45 || isDigit b then return num (← number s) else err "unexpected character"

partial def array (s : Src) (depth : Nat) : P Json := do
  if depth ≥ maxDepth then err "nesting too deep"
  advance
  skipWs s
  if (← peek s) == some 93 then advance; return arr #[]
  let mut xs : Array Json := #[]
  repeat
    xs := xs.push (← value s (depth + 1))
    skipWs s
    match ← peek s with
    | some 44 => advance
    | some 93 => advance; break
    | _ => err "expected ',' or ']'"
  return arr xs

partial def object (s : Src) (depth : Nat) : P Json := do
  if depth ≥ maxDepth then err "nesting too deep"
  advance
  skipWs s
  if (← peek s) == some 125 then advance; return obj #[]
  let mut kvs : Array (String × Json) := #[]
  repeat
    skipWs s
    unless (← peek s) == some 34 do err "expected string key"
    let k ← parseStr s
    skipWs s
    unless (← peek s) == some 58 do err "expected ':'"
    advance
    kvs := kvs.push (k, ← value s (depth + 1))
    skipWs s
    match ← peek s with
    | some 44 => advance
    | some 125 => advance; break
    | _ => err "expected ',' or '}'"
  return obj kvs
end

/-- Parse a complete JSON document from UTF-8 bytes. Trailing non-whitespace is an error. -/
def parseBytes (bytes : ByteArray) : Except String Json := do
  let src : Src := ⟨bytes⟩
  let (v, pos) ← (do let v ← value src 0; skipWs src; pure v).run 0
  if pos < bytes.size then throw s!"json: trailing data at byte {pos}" else pure v

/-- Parse a complete JSON document. -/
def parse (s : String) : Except String Json := parseBytes s.toUTF8

end Json

/-! ## Conversion classes -/

class ToJson (α : Type) where
  toJson : α → Json

class FromJson (α : Type) where
  fromJson? : Json → Except String α

export ToJson (toJson)
export FromJson (fromJson?)

instance : ToJson Json := ⟨id⟩
instance : FromJson Json := ⟨pure⟩
instance : ToJson String := ⟨Json.str⟩
instance : FromJson String := ⟨fun j => match j with | .str s => pure s | _ => throw "expected string"⟩
instance : ToJson Bool := ⟨Json.bool⟩
instance : FromJson Bool := ⟨fun j => match j with | .bool b => pure b | _ => throw "expected boolean"⟩
instance : ToJson Int := ⟨Json.int⟩
instance : FromJson Int := ⟨fun j => match j.getInt? with | some i => pure i | none => throw "expected integer"⟩
instance : ToJson Nat := ⟨Json.nat⟩
instance : FromJson Nat := ⟨fun j => match j.getNat? with | some n => pure n | none => throw "expected non-negative integer"⟩

def boundedNat (j : Json) (bound : Nat) (what : String) : Except String Nat :=
  match j.getNat? with
  | some n => if n < bound then pure n else throw s!"{what} out of range"
  | none => throw "expected non-negative integer"

instance : ToJson UInt8 := ⟨fun n => Json.nat n.toNat⟩
instance : FromJson UInt8 := ⟨fun j => (·.toUInt8) <$> boundedNat j 256 "UInt8"⟩
instance : ToJson UInt16 := ⟨fun n => Json.nat n.toNat⟩
instance : FromJson UInt16 := ⟨fun j => (·.toUInt16) <$> boundedNat j 65536 "UInt16"⟩
instance : ToJson UInt32 := ⟨fun n => Json.nat n.toNat⟩
instance : FromJson UInt32 := ⟨fun j => (·.toUInt32) <$> boundedNat j 4294967296 "UInt32"⟩
instance : ToJson UInt64 := ⟨fun n => Json.nat n.toNat⟩
instance : FromJson UInt64 := ⟨fun j => (·.toUInt64) <$> boundedNat j 18446744073709551616 "UInt64"⟩

instance {α} [ToJson α] : ToJson (Option α) := ⟨fun | some a => toJson a | none => .null⟩
instance {α} [FromJson α] : FromJson (Option α) := ⟨fun | .null => pure none | j => some <$> fromJson? j⟩
instance {α} [ToJson α] : ToJson (Array α) := ⟨fun xs => .arr (xs.map toJson)⟩
instance {α} [FromJson α] : FromJson (Array α) :=
  ⟨fun j => match j with | .arr xs => xs.mapM fromJson? | _ => throw "expected array"⟩
instance {α} [ToJson α] : ToJson (List α) := ⟨fun xs => .arr (xs.toArray.map toJson)⟩
instance {α} [FromJson α] : FromJson (List α) :=
  ⟨fun j => match j with | .arr xs => Array.toList <$> xs.mapM fromJson? | _ => throw "expected array"⟩

namespace Json

/-- Decode a required field. -/
def field {α} [FromJson α] (j : Json) (k : String) : Except String α :=
  match j.get? k with
  | some v => match fromJson? v with
    | .ok a => pure a
    | .error e => throw s!"{k}: {e}"
  | none => throw s!"missing field '{k}'"

/-- Decode an optional field (absent or `null` give `none`). -/
def fieldOpt {α} [FromJson α] (j : Json) (k : String) : Except String (Option α) :=
  match j.getOpt? k with
  | some v => match fromJson? v with
    | .ok a => pure (some a)
    | .error e => throw s!"{k}: {e}"
  | none => pure none

end Json

end AgentLean
