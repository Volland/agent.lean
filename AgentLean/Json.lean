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

def needsEscape (b : UInt8) : Bool := b < 0x20 || b == 34 || b == 92

/-- Escape a string's content (without quotes). Control characters become `\u00XX`. Works on
bytes and copies unescaped runs whole. -/
def firstEscape? (s : String) : Option Nat := Id.run do
  for i in [0:s.utf8ByteSize] do
    if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then
      if needsEscape (s.getUTF8Byte ⟨i⟩ h) then return some i
  return none

def escapeChars (s : String) : String :=
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

/-- Escape a string's content (without quotes). Strings without characters to escape are returned
as they are, without allocating. -/
def escape (s : String) : String :=
  match firstEscape? s with
  | none => s
  | some _ => escapeChars s

def quote (s : String) : String := "\"" ++ escape s ++ "\""

-- @tg: implements:: [[adr:0005]]
-- @tg: implements:: [[openspec:portable-build#Cross-platform conformance]]
/-- Compact, deterministic rendering: the same bytes on every target. -/
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

namespace Parse

abbrev R (α : Type) := Except String (α × Nat)

def err {α} (msg : String) (i : Nat) : R α := .error s!"json: {msg} at byte {i}"

def isWs (b : UInt8) : Bool := b == 32 || b == 9 || b == 10 || b == 13

partial def skipWs (b : ByteArray) (i : Nat) : Nat :=
  if i < b.size && isWs b[i]! then skipWs b (i + 1) else i

def lit (b : ByteArray) (i : Nat) (word : String) : Bool := Id.run do
  let w := word.toUTF8
  if i + w.size > b.size then return false
  for k in [0:w.size] do
    if b[i + k]! != w[k]! then return false
  return true

def hexVal (c : UInt8) : Option Nat :=
  if 48 ≤ c && c ≤ 57 then some (c.toNat - 48)
  else if 97 ≤ c && c ≤ 102 then some (c.toNat - 87)
  else if 65 ≤ c && c ≤ 70 then some (c.toNat - 55)
  else none

def hex4 (b : ByteArray) (i : Nat) : Option Nat := do
  if i + 4 > b.size then none
  let a ← hexVal b[i]!; let c ← hexVal b[i+1]!; let d ← hexVal b[i+2]!; let e ← hexVal b[i+3]!
  return ((a * 16 + c) * 16 + d) * 16 + e

def isStrPlain (c : UInt8) : Bool := c != 34 && c != 92 && c ≥ 32

/-- Parse a string body starting after the opening quote. Copies runs of plain bytes at once. -/
partial def strBody (b : ByteArray) (i : Nat) (acc : ByteArray) : R ByteArray :=
  let j := (b.findIdx? (fun c => !isStrPlain c) i).getD b.size
  let acc := if j > i then acc ++ b.extract i j else acc
  if j ≥ b.size then err "unterminated string" j
  else
    let c := b[j]!
    if c == 34 then .ok (acc, j + 1)
    else if c < 32 then err "control character in string" j
    else -- backslash
      if j + 1 ≥ b.size then err "bad escape" j else
      match b[j+1]! with
      | 34 => strBody b (j + 2) (acc.push 34)
      | 92 => strBody b (j + 2) (acc.push 92)
      | 47 => strBody b (j + 2) (acc.push 47)
      | 98 => strBody b (j + 2) (acc.push 8)
      | 102 => strBody b (j + 2) (acc.push 12)
      | 110 => strBody b (j + 2) (acc.push 10)
      | 114 => strBody b (j + 2) (acc.push 13)
      | 116 => strBody b (j + 2) (acc.push 9)
      | 117 =>
        match hex4 b (j + 2) with
        | none => err "bad \\u escape" j
        | some hi =>
          if 0xD800 ≤ hi && hi < 0xDC00 then
            if lit b (j + 6) "\\u" then
              match hex4 b (j + 8) with
              | some lo =>
                if 0xDC00 ≤ lo && lo < 0xE000 then
                  strBody b (j + 12) (pushUtf8 acc (0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)))
                else err "invalid surrogate pair" j
              | none => err "bad \\u escape" j
            else err "lone high surrogate" j
          else if 0xDC00 ≤ hi && hi < 0xE000 then err "lone low surrogate" j
          else strBody b (j + 6) (pushUtf8 acc hi)
      | _ => err "bad escape" j

def str (b : ByteArray) (i : Nat) : R String :=
  match strBody b (i + 1) ByteArray.empty with
  | .ok (bytes, k) => match String.fromUTF8? bytes with
    | some t => .ok (t, k)
    | none => err "invalid UTF-8 in string" i
  | .error e => .error e

def isDigit (c : UInt8) : Bool := 48 ≤ c && c ≤ 57

partial def digits (b : ByteArray) (i : Nat) (acc count : Nat) : Nat × Nat × Nat :=
  if i < b.size && isDigit b[i]! then digits b (i + 1) (acc * 10 + (b[i]!.toNat - 48)) (count + 1)
  else (acc, count, i)

def number (b : ByteArray) (i : Nat) : Except String (JsonNumber × Nat) := do
  let neg := i < b.size && b[i]! == 45
  let i := if neg then i + 1 else i
  let (intPart, n, i) := digits b i 0 0
  if n == 0 then throw s!"json: expected digit at byte {i}"
  let mut mant := intPart
  let mut exp : Int := 0
  let mut i := i
  if i < b.size && b[i]! == 46 then
    let (frac, k, j) := digits b (i + 1) 0 0
    if k == 0 then throw s!"json: expected digit after '.' at byte {j}"
    mant := intPart * 10 ^ k + frac
    exp := -(k : Int)
    i := j
  if i < b.size && (b[i]! == 101 || b[i]! == 69) then
    let (eneg, i0) := if i + 1 < b.size && b[i+1]! == 45 then (true, i + 2)
      else if i + 1 < b.size && b[i+1]! == 43 then (false, i + 2) else (false, i + 1)
    let (e, k, j) := digits b i0 0 0
    if k == 0 then throw s!"json: expected exponent digits at byte {j}"
    exp := exp + (if eneg then -(e : Int) else e)
    i := j
  return (⟨if neg then -(mant : Int) else mant, exp⟩, i)

mutual
partial def value (b : ByteArray) (i : Nat) (depth : Nat) : R Json :=
  let i := skipWs b i
  if i ≥ b.size then err "unexpected end of input" i else
  match b[i]! with
  | 110 => if lit b i "null" then .ok (.null, i + 4) else err "expected null" i
  | 116 => if lit b i "true" then .ok (.bool true, i + 4) else err "expected true" i
  | 102 => if lit b i "false" then .ok (.bool false, i + 5) else err "expected false" i
  | 34 => (str b i).map fun (s, k) => (Json.str s, k)
  | 91 => array b i depth
  | 123 => object b i depth
  | c => if c == 45 || isDigit c then (number b i).map fun (n, k) => (Json.num n, k)
         else err "unexpected character" i

partial def arrayRest (b : ByteArray) (i : Nat) (depth : Nat) (xs : Array Json) : Except String (Json × Nat) := do
  let (v, i) ← value b i (depth + 1)
  let xs := xs.push v
  let i := skipWs b i
  if i < b.size && b[i]! == 44 then arrayRest b (i + 1) depth xs
  else if i < b.size && b[i]! == 93 then .ok (.arr xs, i + 1)
  else err "expected ',' or ']'" i

partial def array (b : ByteArray) (i : Nat) (depth : Nat) : R Json :=
  if depth ≥ maxDepth then err "nesting too deep" i else
  let i := skipWs b (i + 1)
  if i < b.size && b[i]! == 93 then .ok (.arr #[], i + 1) else arrayRest b i depth #[]

partial def objectRest (b : ByteArray) (i : Nat) (depth : Nat) (kvs : Array (String × Json)) : Except String (Json × Nat) := do
  let i := skipWs b i
  unless i < b.size && b[i]! == 34 do throw s!"json: expected string key at byte {i}"
  let (k, i) ← str b i
  let i := skipWs b i
  unless i < b.size && b[i]! == 58 do throw s!"json: expected ':' at byte {i}"
  let (v, i) ← value b (i + 1) (depth + 1)
  let kvs := kvs.push (k, v)
  let i := skipWs b i
  if i < b.size && b[i]! == 44 then objectRest b (i + 1) depth kvs
  else if i < b.size && b[i]! == 125 then .ok (.obj kvs, i + 1)
  else err "expected ',' or '}'" i

partial def object (b : ByteArray) (i : Nat) (depth : Nat) : R Json :=
  if depth ≥ maxDepth then err "nesting too deep" i else
  let i := skipWs b (i + 1)
  if i < b.size && b[i]! == 125 then .ok (.obj #[], i + 1) else objectRest b i depth #[]
end

end Parse

/-- Parse a complete JSON document from UTF-8 bytes. Trailing non-whitespace is an error. -/
def parseBytes (bytes : ByteArray) : Except String Json := do
  let (v, i) ← Parse.value bytes 0 0
  let i := Parse.skipWs bytes i
  if i < bytes.size then throw s!"json: trailing data at byte {i}" else pure v

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
