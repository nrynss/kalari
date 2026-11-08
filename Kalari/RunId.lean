/-! Purposeful run IDs: `run-` plus 10 lowercase hex chars.

The temp directory stays a temp directory: nothing reads its name. A run ID
is drawn from `/dev/urandom` (5 bytes as 10 hex chars), with no new
dependency. `isRunId` is the single format predicate; `generate` draws one
candidate. Uniqueness against the evidence store and live sandbox names is
checked by the caller (`Kalari.Tools.Run`), which retries a few times and
then fails closed. Old `tmp.XX…` records are never rewritten; the permissive
validators in `Lesson`, `Recall` and `Http` keep resolving them. -/

namespace Kalari.RunId

/-- Prefix of every purposeful run ID. -/
def runPrefix : String := "run-"

/-- Suffix length: 5 random bytes as 10 lowercase hex chars. -/
def suffixLen : Nat := 10

/-- Full length: `run-` plus 10 hex chars. -/
def fullLen : Nat := 14

private def isHexLower (c : Char) : Bool :=
  c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- The single format predicate for purposeful run IDs. Old `tmp.XX…` IDs
are not `isRunId`, but they still resolve through the permissive envelope
validators; this predicate only identifies the new shape. -/
def isRunId (s : String) : Bool :=
  s.take 4 == runPrefix && s.length == fullLen &&
    (s.toList.drop 4).all isHexLower

#guard isRunId "run-7f3a2c91be"
#guard isRunId "run-0000000000"
#guard isRunId "run-ffffffffff"
#guard !isRunId ""
#guard !isRunId "run-"
#guard !isRunId "run-7F3A2C91BE"
#guard !isRunId "run-7f3a2c91b"
#guard !isRunId "run-7f3a2c91bex"
#guard !isRunId "tmp.XXh51tnj"
#guard !isRunId "run-xyz"
#guard !isRunId "run_7f3a2c91be"

private def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3' | 4 => '4'
  | 5 => '5' | 6 => '6' | 7 => '7' | 8 => '8' | 9 => '9'
  | 10 => 'a' | 11 => 'b' | 12 => 'c' | 13 => 'd' | 14 => 'e'
  | _ => 'f'

/-- Lowercase hex of raw random bytes. Pure, so the gate checks the shape. -/
def encodeHex (data : ByteArray) : String :=
  String.ofList (data.toList.flatMap fun b => [hexChar (b.toNat / 16), hexChar (b.toNat % 16)])

#guard encodeHex (ByteArray.mk #[0, 255, 16, 171, 205]) == "00ff10abcd"
#guard encodeHex ByteArray.empty == ""

/-- Read exactly `n` bytes from `/dev/urandom`, looping on short reads. -/
def readUrandom (n : Nat) : IO ByteArray := do
  if n == 0 then return ByteArray.empty
  let h ← IO.FS.Handle.mk "/dev/urandom" .read
  let mut acc := ByteArray.empty
  while acc.size < n do
    let need : USize := (n - acc.size).toUSize
    let chunk ← h.read need
    if chunk.isEmpty then
      throw (.userError "short read from /dev/urandom")
    acc := acc ++ chunk
  return acc

/-- Draw one candidate `run-` plus 10 lowercase hex chars from `/dev/urandom`. -/
def generate : IO String := do
  let bytes ← readUrandom 5
  if bytes.size != 5 then throw (.userError "short read from /dev/urandom")
  return runPrefix ++ encodeHex bytes

/-- Sandbox name for a run ID. `kalari-run-…` stays short, lowercase
alphanumeric plus `-`: well within msb name rules and length. -/
def sandboxName (runId : String) : String :=
  "kalari-" ++ runId

#guard sandboxName "run-7f3a2c91be" == "kalari-run-7f3a2c91be"
#guard (sandboxName "run-7f3a2c91be").length == 21
#guard (sandboxName "run-7f3a2c91be").toList.all fun c => c.isAlphanum || c == '-'

/-- How many candidates to draw before failing closed on collision. -/
def maxAttempts : Nat := 8

/-- Draw a fresh ID, skipping any `taken` candidate. Fails closed after
`maxAttempts` collisions with a clear error. -/
def fresh (taken : String → Bool) (draw : IO String := generate) : IO (Except String String) := do
  let mut attempt := 0
  while attempt < maxAttempts do
    let candidate ← try draw catch _ => return .error "run ID generation failed: /dev/urandom unreadable"
    unless isRunId candidate do
      attempt := attempt + 1
      continue
    if !taken candidate then return .ok candidate
    attempt := attempt + 1
  return .error s!"run ID collision: no fresh run ID after {maxAttempts} attempts"

private def formatChecks : IO Unit := do
  unless isRunId "run-0123456789" do throw (.userError "new run ID rejected")
  unless isRunId "run-abcdefabcd" do throw (.userError "new run ID rejected")
  if isRunId "tmp.XXh51tnj" then throw (.userError "old temp ID misclassified as new")
  -- Old temp IDs are not new IDs, but the envelope validators still accept
  -- both: alphanumerics plus `-`, `_`, `.`.
  let envelope := fun (s : String) =>
    !s.isEmpty && s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')
  unless envelope "run-7f3a2c91be" && envelope "tmp.XXh51tnj" do
    throw (.userError "envelope must accept both new and old run IDs")
  -- Uniqueness retries: first two draws taken, third fresh.
  let draws ← IO.mkRef (["run-0000000000", "run-1111111111", "run-2222222222"] : List String)
  let draw : IO String := do
    match ← draws.get with
    | [] => return "run-3333333333"
    | head :: tail => draws.set tail; return head
  let taken := fun (s : String) => s == "run-0000000000" || s == "run-1111111111"
  match ← fresh taken draw with
  | .ok id => unless id == "run-2222222222" do throw (.userError "uniqueness retry did not skip taken IDs")
  | .error _ => throw (.userError "uniqueness retry failed")
  -- Exhaustion fails closed with a clear error.
  match ← fresh (fun _ => true) (pure "run-0000000000") with
  | .error e =>
    unless e.contains "run ID collision" do throw (.userError "collision error unclear")
  | .ok _ => throw (.userError "exhausted draws produced an ID")
  -- A live candidate passes the format on the way out.
  let live ← generate
  unless isRunId live do throw (.userError "generated run ID has the wrong shape")
  unless (sandboxName live).startsWith "kalari-run-" &&
      (sandboxName live).length <= 64 do
    throw (.userError "sandbox name out of msb shape")
  IO.println "runid: format, old-ID envelope, uniqueness retry, exhaustion, live draw, sandbox shape"

#eval formatChecks

end Kalari.RunId
