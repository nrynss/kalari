import Std.Async.Process

open Std

/-! kalari-aashaan: the supervisor inside each microVM. Runs one untrusted job with a
wall-clock cap and an output cap, and prints a JSON verdict.
Std only (no Lean.Json), so the executable stays small. The cap decision and the
JSON escaper below are pure; `lake build` checks the theorems.
The guest needs vm.overcommit_memory=1, or the Lean runtime can't start its reader threads.
Usage: kalari-aashaan <timeout-ms> <output-cap-bytes> <cmd> [args...] -/

structure Wake where
  exited : Option UInt32
  wall : Bool
  stdoutCap : Bool
  stderrCap : Bool
  deriving Repr, DecidableEq

inductive Verdict where
  | exited (code : UInt32)
  | timeout
  | outputCap
  deriving Repr, DecidableEq

def Verdict.json : Verdict → String
  | .exited c => s!"\"exited\",\"exit_code\":{c}"
  | .timeout => "\"killed_timeout\",\"exit_code\":null"
  | .outputCap => "\"killed_output_cap\",\"exit_code\":null"

theorem timeout_json : Verdict.timeout.json = "\"killed_timeout\",\"exit_code\":null" := rfl

theorem outputCap_json : Verdict.outputCap.json = "\"killed_output_cap\",\"exit_code\":null" := rfl

/-- One wake. Exit wins. If the wall-clock cap and an output cap are both
visible and the process has not exited, the wall-clock cap wins. Stdout and
stderr are the same output cap. -/
def classify (w : Wake) : Option Verdict :=
  match w.exited with
  | some code => some (.exited code)
  | none =>
    if w.wall then some .timeout
    else if w.stdoutCap || w.stderrCap then some .outputCap
    else none

def pending (w : Wake) : Bool :=
  w.exited.isNone && !w.wall && !w.stdoutCap && !w.stderrCap

def firstVerdict : List Wake → Option Verdict
  | [] => none
  | w :: rest =>
    match classify w with
    | some v => some v
    | none => firstVerdict rest

/-- Wall-clock passed first: on the first wake that shows an exit or a cap,
the process has not exited and the wall-clock cap is visible. An output cap
on that same wake does not count as earlier. -/
def wallPassedFirst : List Wake → Bool
  | [] => false
  | w :: rest =>
    if pending w then wallPassedFirst rest
    else w.exited.isNone && w.wall

/-- An output cap was crossed first: on the first wake that shows an exit or a
cap, the process has not exited, the wall-clock cap is not visible, and stdout
or stderr has crossed. -/
def outputCrossedFirst : List Wake → Bool
  | [] => false
  | w :: rest =>
    if pending w then outputCrossedFirst rest
    else w.exited.isNone && !w.wall && (w.stdoutCap || w.stderrCap)

theorem classify_timeout_iff (w : Wake) :
    classify w = some .timeout ↔ w.exited = none ∧ w.wall = true := by
  cases h : w.exited <;> cases hw : w.wall <;>
    simp [classify, h, hw]

theorem classify_output_iff (w : Wake) :
    classify w = some .outputCap ↔
      w.exited = none ∧ w.wall = false ∧ (w.stdoutCap = true ∨ w.stderrCap = true) := by
  cases h : w.exited <;> cases hw : w.wall <;>
    cases ho : w.stdoutCap <;> cases he : w.stderrCap <;>
      simp [classify, h, hw, ho, he]

theorem classify_none_iff (w : Wake) :
    classify w = none ↔ pending w = true := by
  cases h : w.exited <;> cases hw : w.wall <;>
    cases ho : w.stdoutCap <;> cases he : w.stderrCap <;>
      simp [classify, pending, h, hw, ho, he]

theorem timeout_flag (w : Wake) :
    (w.exited.isNone && w.wall) = true ↔ classify w = some .timeout := by
  cases h : w.exited <;> cases hw : w.wall <;>
    simp [classify, Option.isNone, h, hw]

theorem output_flag (w : Wake) :
    (w.exited.isNone && !w.wall && (w.stdoutCap || w.stderrCap)) = true ↔
      classify w = some .outputCap := by
  cases h : w.exited <;> cases hw : w.wall <;>
    cases ho : w.stdoutCap <;> cases he : w.stderrCap <;>
      simp [classify, Option.isNone, h, hw, ho, he]

theorem same_wake_wall_wins (w : Wake) (rest : List Wake)
    (hex : w.exited = none) (hw : w.wall = true)
    (ho : w.stdoutCap = true ∨ w.stderrCap = true) :
    firstVerdict (w :: rest) = some .timeout := by
  have hc : classify w = some .timeout := (classify_timeout_iff w).mpr ⟨hex, hw⟩
  cases ho <;> simp [firstVerdict, hc]

theorem stderr_is_output_cap (w : Wake)
    (hex : w.exited = none) (hw : w.wall = false) (he : w.stderrCap = true) :
    classify w = some .outputCap :=
  (classify_output_iff w).mpr ⟨hex, hw, Or.inr he⟩

theorem stdout_is_output_cap (w : Wake)
    (hex : w.exited = none) (hw : w.wall = false) (ho : w.stdoutCap = true) :
    classify w = some .outputCap :=
  (classify_output_iff w).mpr ⟨hex, hw, Or.inl ho⟩

theorem killed_timeout_iff (ws : List Wake) :
    firstVerdict ws = some .timeout ↔ wallPassedFirst ws = true := by
  induction ws with
  | nil => simp [firstVerdict, wallPassedFirst]
  | cons w rest ih =>
    cases h : classify w with
    | none =>
      have hp := (classify_none_iff w).mp h
      simp [firstVerdict, wallPassedFirst, h, hp, ih]
    | some v =>
      cases v with
      | timeout =>
        have hw := (classify_timeout_iff w).mp h
        simp [firstVerdict, wallPassedFirst, h, pending, hw, Option.isNone]
      | outputCap =>
        have ho := (classify_output_iff w).mp h
        rcases ho with ⟨hex, hw, hs | hs⟩
        · simp [firstVerdict, wallPassedFirst, h, pending, hex, hw, hs, Option.isNone]
        · simp [firstVerdict, wallPassedFirst, h, pending, hex, hw, hs, Option.isNone]
      | exited code =>
        cases he : w.exited with
        | none =>
          cases hw : w.wall <;> cases hso : w.stdoutCap <;> cases hse : w.stderrCap <;>
            simp [classify, he, hw, hso, hse] at h
        | some c =>
          simp [classify, he] at h
          subst h
          simp [firstVerdict, wallPassedFirst, classify, he, pending, Option.isNone]

theorem killed_output_cap_iff (ws : List Wake) :
    firstVerdict ws = some .outputCap ↔ outputCrossedFirst ws = true := by
  induction ws with
  | nil => simp [firstVerdict, outputCrossedFirst]
  | cons w rest ih =>
    cases h : classify w with
    | none =>
      have hp := (classify_none_iff w).mp h
      simp [firstVerdict, outputCrossedFirst, h, hp, ih]
    | some v =>
      cases v with
      | outputCap =>
        have ho := (classify_output_iff w).mp h
        rcases ho with ⟨hex, hw, hs | hs⟩
        · simp [firstVerdict, outputCrossedFirst, h, pending, hex, hw, hs, Option.isNone]
        · simp [firstVerdict, outputCrossedFirst, h, pending, hex, hw, hs, Option.isNone]
      | timeout =>
        have ht := (classify_timeout_iff w).mp h
        simp [firstVerdict, outputCrossedFirst, h, pending, ht, Option.isNone]
      | exited code =>
        cases he : w.exited with
        | none =>
          cases hw : w.wall <;> cases hso : w.stdoutCap <;> cases hse : w.stderrCap <;>
            simp [classify, he, hw, hso, hse] at h
        | some c =>
          simp [classify, he] at h
          subst h
          simp [firstVerdict, outputCrossedFirst, classify, he, pending, Option.isNone]

def clampBytes (b : ByteArray) (cap : Nat) : ByteArray :=
  b.extract 0 cap

theorem clampBytes_le (b : ByteArray) (cap : Nat) :
    (clampBytes b cap).size ≤ cap := by
  unfold clampBytes
  rw [ByteArray.size_extract]
  omega

def hexDigit (n : Nat) : Char :=
  match n % 16 with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3'
  | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
  | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b'
  | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'

theorem hexDigit_safe (n : Nat) :
    (hexDigit n).toNat ≥ 0x20 ∧ hexDigit n ≠ '"' ∧ hexDigit n ≠ '\\' := by
  unfold hexDigit
  split <;> decide

def uEscape (n : Nat) : List Char :=
  ['\\', 'u', '0', '0', hexDigit (n / 16), hexDigit n]

/-- A JSON string body. `esc` means the previous character was an unescaped backslash.
A quote is legal only in that position. Every character is at least `0x20`. -/
def bodyOk : List Char → Bool → Bool
  | [], esc => !esc
  | c :: cs, esc =>
    if esc then
      decide (c.toNat ≥ 0x20) && bodyOk cs false
    else if c = '"' then
      false
    else if c = '\\' then
      bodyOk cs true
    else
      decide (c.toNat ≥ 0x20) && bodyOk cs false

/-- A `"` that is not escaped by the preceding `\`. -/
def hasRawQuote : List Char → Bool → Bool
  | [], _ => false
  | _ :: cs, true => hasRawQuote cs false
  | c :: cs, false =>
    if c = '"' then true
    else if c = '\\' then hasRawQuote cs true
    else hasRawQuote cs false

theorem bodyOk_plain_cons (c : Char) (cs : List Char)
    (hc : c.toNat ≥ 0x20) (hq : c ≠ '"') (hs : c ≠ '\\')
    (ht : bodyOk cs false = true) :
    bodyOk (c :: cs) false = true := by
  simp [bodyOk, hq, hs, decide_eq_true hc, ht]

theorem bodyOk_escaped_cons (c : Char) (cs : List Char)
    (hc : c.toNat ≥ 0x20) (ht : bodyOk cs false = true) :
    bodyOk (c :: cs) true = true := by
  simp [bodyOk, decide_eq_true hc, ht]

theorem bodyOk_backslash (cs : List Char) (h : bodyOk cs true = true) :
    bodyOk ('\\' :: cs) false = true := by
  simp [bodyOk, h]

theorem uEscape_body (n : Nat) : bodyOk (uEscape n) false = true := by
  have h1 := hexDigit_safe (n / 16)
  have h2 := hexDigit_safe n
  unfold uEscape
  exact bodyOk_backslash _
    (bodyOk_escaped_cons 'u'
      ('0' :: '0' :: hexDigit (n / 16) :: hexDigit n :: []) (by decide)
      (bodyOk_plain_cons '0'
        ('0' :: hexDigit (n / 16) :: hexDigit n :: []) (by decide) (by decide) (by decide)
        (bodyOk_plain_cons '0'
          (hexDigit (n / 16) :: hexDigit n :: []) (by decide) (by decide) (by decide)
          (bodyOk_plain_cons (hexDigit (n / 16))
            [hexDigit n] h1.1 h1.2.1 h1.2.2
            (bodyOk_plain_cons (hexDigit n) [] h2.1 h2.2.1 h2.2.2 rfl)))))

def escapeChars (c : Char) : List Char :=
  if c = '"' then ['\\', '"']
  else if c = '\\' then ['\\', '\\']
  else if c = '\n' then ['\\', 'n']
  else if c = '\r' then ['\\', 'r']
  else if c = '\t' then ['\\', 't']
  else if c.toNat < 0x20 then uEscape c.toNat
  else [c]

theorem escapeChars_body (c : Char) : bodyOk (escapeChars c) false = true := by
  unfold escapeChars
  split
  · simp [bodyOk]
  · split
    · simp [bodyOk]
    · split
      · simp [bodyOk]
      · split
        · simp [bodyOk]
        · split
          · simp [bodyOk]
          · split
            · exact uEscape_body c.toNat
            · rename_i h1 h2 _ _ _ _
              exact bodyOk_plain_cons c [] (by omega) h1 h2 rfl

theorem bodyOk_append (esc : Bool) (a b : List Char)
    (ha : bodyOk a esc = true) (hb : bodyOk b false = true) :
    bodyOk (a ++ b) esc = true := by
  induction a generalizing esc with
  | nil =>
    cases esc with
    | false => simpa [bodyOk] using hb
    | true =>
      simp [bodyOk] at ha
  | cons c cs ih =>
    cases esc with
    | true =>
      simp [bodyOk, List.cons_append, Bool.and_eq_true] at ha ⊢
      exact ⟨ha.1, ih false ha.2⟩
    | false =>
      by_cases hq : c = '"'
      · simp [bodyOk, hq] at ha
      · by_cases hs : c = '\\'
        · simp [bodyOk, List.cons_append, hs] at ha ⊢
          exact ih true ha
        · simp [bodyOk, List.cons_append, hq, hs, Bool.and_eq_true] at ha ⊢
          exact ⟨ha.1, ih false ha.2⟩

def jstrBody (s : String) : List Char :=
  s.toList.flatMap escapeChars

theorem jstrBody_ok (s : String) : bodyOk (jstrBody s) false = true := by
  unfold jstrBody
  have : ∀ cs, bodyOk (List.flatMap escapeChars cs) false = true := by
    intro cs
    induction cs with
    | nil => simp [bodyOk]
    | cons c cs ih =>
      rw [List.flatMap_cons]
      exact bodyOk_append false _ _ (escapeChars_body c) ih
  exact this s.toList

def jstr (s : String) : String :=
  String.ofList ('"' :: jstrBody s ++ ['"'])

theorem jstr_toList (s : String) :
    (jstr s).toList = '"' :: jstrBody s ++ ['"'] := by
  rw [jstr, String.toList_ofList]

theorem bodyOk_chars_safe : ∀ cs esc, bodyOk cs esc = true → ∀ c ∈ cs, c.toNat ≥ 0x20
  | [], _, _, _, hc => by simp at hc
  | c' :: cs, true, h, c, hc => by
    simp [bodyOk, Bool.and_eq_true] at h
    rcases List.mem_cons.mp hc with rfl | hc
    · exact h.1
    · exact bodyOk_chars_safe cs false h.2 c hc
  | c' :: cs, false, h, c, hc => by
    by_cases hq : c' = '"'
    · simp [bodyOk, hq] at h
    · by_cases hs : c' = '\\'
      · simp [bodyOk, hs] at h
        rcases List.mem_cons.mp hc with rfl | hc
        · simp [hs]
        · exact bodyOk_chars_safe cs true h c hc
      · simp [bodyOk, hq, hs, Bool.and_eq_true] at h
        rcases List.mem_cons.mp hc with rfl | hc
        · exact h.1
        · exact bodyOk_chars_safe cs false h.2 c hc

theorem bodyOk_no_raw_quote : ∀ cs esc, bodyOk cs esc = true → hasRawQuote cs esc = false
  | [], true, h => by simp [bodyOk] at h
  | [], false, _ => rfl
  | c' :: cs, true, h => by
    simp [bodyOk, Bool.and_eq_true] at h
    simp [hasRawQuote, bodyOk_no_raw_quote cs false h.2]
  | c' :: cs, false, h => by
    by_cases hq : c' = '"'
    · simp [bodyOk, hq] at h
    · by_cases hs : c' = '\\'
      · simp [bodyOk, hs] at h
        simp [hasRawQuote, hs, bodyOk_no_raw_quote cs true h]
      · simp [bodyOk, hq, hs, Bool.and_eq_true] at h
        simp [hasRawQuote, hq, hs, bodyOk_no_raw_quote cs false h.2]

theorem jstr_no_raw_control (s : String) :
    ∀ c ∈ (jstr s).toList, c.toNat ≥ 0x20 := by
  intro c hc
  rw [jstr_toList] at hc
  rcases List.mem_cons.mp hc with rfl | hc
  · decide
  · rcases List.mem_append.mp hc with hc | hc
    · exact bodyOk_chars_safe _ false (jstrBody_ok s) c hc
    · rcases List.mem_singleton.mp hc with rfl
      decide

theorem jstr_no_raw_quote (s : String) : hasRawQuote (jstrBody s) false = false :=
  bodyOk_no_raw_quote _ _ (jstrBody_ok s)

theorem wrap_last : ∀ cs : List Char, ('"' :: (cs ++ ['"'])).getLast? = some '"'
  | [] => rfl
  | c :: cs => by
    cases cs with
    | nil => rfl
    | cons d ds =>
      simpa [List.cons_append] using wrap_last (d :: ds)

theorem jstr_quotes_are_delimiters (s : String) :
    (jstr s).toList.head? = some '"' ∧
      (jstr s).toList.getLast? = some '"' ∧
      hasRawQuote (jstrBody s) false = false := by
  refine ⟨?_, ?_, jstr_no_raw_quote s⟩
  · rw [jstr_toList]; rfl
  · rw [jstr_toList]; exact wrap_last (jstrBody s)

#guard jstr "\"" = "\"\\\"\""
#guard jstr "\\" = "\"\\\\\""
#guard jstr "\n" = "\"\\n\""
#guard jstr "\u0001" = "\"\\u0001\""
#guard jstr "λ" = "\"λ\""
#guard jstr "hello" = "\"hello\""
#guard (clampBytes (ByteArray.mk #[1, 2, 3, 4]) 2).size = 2
#guard (clampBytes (ByteArray.mk #[1, 2]) 8).size = 2
#guard (clampBytes (ByteArray.mk #[1, 2, 3]) 0).size = 0

def wake (ex : Option UInt32) (wall stdout stderr : Bool) : Wake :=
  { exited := ex, wall, stdoutCap := stdout, stderrCap := stderr }

#guard firstVerdict [wake none true false false] = some .timeout
#guard firstVerdict [wake none false true false] = some .outputCap
#guard firstVerdict [wake none false false true] = some .outputCap
#guard firstVerdict [wake none true true true] = some .timeout
#guard firstVerdict [wake none false false false, wake none true true false] = some .timeout
#guard firstVerdict [wake none false false false, wake none false false true] = some .outputCap
#guard firstVerdict [wake (some 0) true true true] = some (.exited 0)
#guard firstVerdict [] = none
#guard !(jstr "\u0001").toList.contains '\u0001'

/-- Read a pipe up to `cap` bytes. Returns (bytes, hitCap). The bytes are `clampBytes`. -/
partial def readCapped (h : IO.FS.Handle) (cap : Nat) : IO (ByteArray × Bool) := do
  let rec go (acc : ByteArray) : IO (ByteArray × Bool) := do
    let chunk ← h.read 4096
    if chunk.isEmpty then return (clampBytes acc cap, false)
    let acc := acc ++ chunk
    if acc.size > cap then return (clampBytes acc cap, true)
    go acc
  go .empty

/-- Wait for a reader task at most `ms`. A process that escaped the group can keep a pipe open. -/
def awaitBounded (t : Task (Except IO.Error (ByteArray × Bool))) (ms : Nat) :
    IO (ByteArray × Bool × Bool) := do
  let start ← IO.monoMsNow
  while (← IO.monoMsNow) - start < ms do
    if ← IO.hasFinished t then
      return match t.get with
        | .ok (b, c) => (b, c, false)
        | .error _ => (.empty, false, false)
    IO.sleep 10
  return (.empty, false, true)

/-- `true` once the reader has finished and crossed the cap. -/
def readerHit (t : Task (Except IO.Error (ByteArray × Bool))) : IO Bool := do
  if !(← IO.hasFinished t) then
    return false
  match t.get with
  | .ok (_, hit) => return hit
  | .error _ => return false

def main (argv : List String) : IO UInt32 := do
  let (timeoutMs, cap, cmd, args) ← match argv with
    | t :: c :: cmd :: rest => pure (t.toNat!, c.toNat!, cmd, rest.toArray)
    | _ => throw <| .userError "usage: kalari-aashaan <timeout-ms> <output-cap-bytes> <cmd> [args...]"
  let start ← IO.monoMsNow
  let child ← IO.Process.spawn {
    cmd, args
    stdout := .piped, stderr := .piped, stdin := .null
    setsid := true
    inheritEnv := false
    env := #[("PATH", some "/usr/bin:/bin")]
  }
  let outTask ← IO.asTask (readCapped child.stdout cap)
  let errTask ← IO.asTask (readCapped child.stderr cap)
  let mut verdict : Verdict := .timeout
  repeat
    let exited ← child.tryWait
    let wall := decide ((← IO.monoMsNow) - start > timeoutMs)
    let stdoutCap ← readerHit outTask
    let stderrCap ← readerHit errTask
    match classify { exited, wall, stdoutCap, stderrCap } with
    | some (.exited code) =>
      verdict := .exited code
      break
    | some .timeout =>
      child.kill
      verdict := .timeout
      break
    | some .outputCap =>
      child.kill
      verdict := .outputCap
      break
    | none =>
      IO.sleep 10
  if !(verdict matches .exited _) then discard <| child.wait
  let wall := (← IO.monoMsNow) - start
  let (outRaw, outCapped, outHeld) ← awaitBounded outTask 500
  let (errRaw, _, errHeld) ← awaitBounded errTask 500
  let out := clampBytes outRaw cap
  let err := clampBytes errRaw cap
  let ru ← IO.Process.getResourceUsage
  let memLimit ← IO.Process.constrainedMemory
  let s (b : ByteArray) := String.fromUTF8? b |>.getD "<binary>"
  IO.println <| "{\"verdict\":" ++ verdict.json
    ++ s!",\"wall_ms\":{wall}"
    ++ s!",\"stdout\":{jstr (s out)},\"stdout_truncated\":{outCapped}"
    ++ s!",\"stderr\":{jstr (s err)}"
    ++ s!",\"pipe_held_open\":{outHeld || errHeld}"
    ++ s!",\"supervisor_peak_rss_kb\":{ru.peakResidentSetSizeKb}"
    ++ s!",\"cgroup_memory_limit\":{memLimit}}"
  (← IO.getStdout).flush
  -- Reader threads may still be blocked on a pipe an escaped process holds open.
  -- A normal exit waits for them.
  IO.Process.forceExit 0
