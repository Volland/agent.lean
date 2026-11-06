module

/-!
# Server-sent events

An incremental decoder for `text/event-stream`. It is a fold of one byte-level transition over the
input, so how the host splits the stream into chunks cannot change the result: chunk boundaries
inside an event, inside a line or inside a UTF-8 character all give the same events
(`Sse.feed_append`). Lines are decoded as UTF-8 only once complete.
-/

@[expose] public section

namespace AgentLean.Sse

/-- One dispatched event: its `event:` name (empty if none) and its joined `data:` lines. -/
structure Event where
  event : String := ""
  data : String
  deriving BEq, Repr, Inhabited

/-- Decoder state. Dispatched events accumulate in `out`. -/
structure Decoder where
  line : ByteArray := ByteArray.empty
  event : ByteArray := ByteArray.empty
  data : ByteArray := ByteArray.empty
  hasData : Bool := false
  lastCR : Bool := false
  out : Array Event := #[]
  deriving Inhabited

def utf8 (b : ByteArray) : String := (String.fromUTF8? b).getD ""

/-- Index of the first `:` in a line, if any. -/
def colonIdx (line : ByteArray) : Option Nat := line.findIdx? (· == 58)

/-- Handle one complete line (without its terminator). -/
def processLine (d : Decoder) : Decoder :=
  let line := d.line
  let d := { d with line := ByteArray.empty }
  if line.size == 0 then
    if d.hasData || d.event.size > 0 then
      { d with out := d.out.push { event := utf8 d.event, data := utf8 d.data },
               event := ByteArray.empty, data := ByteArray.empty, hasData := false }
    else d
  else
    let (name, value) :=
      match colonIdx line with
      | some i =>
        let v := line.extract (i + 1) line.size
        let v := if v.size > 0 && v[0]! == 32 then v.extract 1 v.size else v
        (line.extract 0 i, v)
      | none => (line, ByteArray.empty)
    if name == "data".toUTF8 then
      let data := if d.hasData then d.data.push 10 else d.data
      { d with data := data ++ value, hasData := true }
    else if name == "event".toUTF8 then { d with event := value }
    else d

/-- The byte-level transition. `\n`, `\r` and `\r\n` all end a line. -/
def feedByte (d : Decoder) (b : UInt8) : Decoder :=
  if b == 10 then
    if d.lastCR then { d with lastCR := false } else processLine d
  else if b == 13 then { processLine d with lastCR := true }
  else { d with line := d.line.push b, lastCR := false }

/-- Feed a chunk of bytes. -/
def feed (d : Decoder) (chunk : ByteArray) : Decoder := chunk.data.foldl feedByte d

/-- Take the dispatched events out of the decoder. -/
def drain (d : Decoder) : Array Event × Decoder := (d.out, { d with out := #[] })

/-- Chunk-split invariance: feeding `a` then `b` equals feeding `a ++ b`. -/
theorem feed_append (d : Decoder) (a b : ByteArray) : feed (feed d a) b = feed d (a ++ b) := by
  simp [feed, ByteArray.data_append]

theorem feed_empty (d : Decoder) : feed d ByteArray.empty = d := rfl

theorem feed_chunks_acc (d : Decoder) (acc : ByteArray) (chunks : List ByteArray) :
    chunks.foldl feed (feed d acc) = feed d (chunks.foldl (· ++ ·) acc) := by
  induction chunks generalizing acc with
  | nil => rfl
  | cons c cs ih => simp only [List.foldl_cons, feed_append, ih]

/-- Decoding a stream split into any list of chunks equals decoding it whole. -/
theorem feed_chunks (d : Decoder) (chunks : List ByteArray) :
    chunks.foldl feed d = feed d (chunks.foldl (· ++ ·) ByteArray.empty) := by
  rw [← feed_chunks_acc, feed_empty]

end AgentLean.Sse
