import Lean.Data.Json
import Std.Async.System
import Kalari.Backend
import Kalari.Proc

/-! DecisionClient questions for Clef's System One format.

`failureCause`, `callsChangedOperation`, and `lessonApplies` each build one
body (`model` `clef`, a `state` object, and `questions`) and return a
`DecisionAnswer`. `DecisionClient.ask` is unchanged: its string is still a
recording case name. These three are not that field.

The key is read from the environment variable the caller names. It is written
only into curl's stdin config. The JSON body is a temp file, not an argument.
`live` binds `Proc.run` with an explicit `PATH` and `inheritEnv := false`.
Stdin does not use `setsid`. The checks do not call `live`. -/

namespace Kalari.Clef

open Lean
open Kalari.Backend
open Kalari.Proc (Result Cap)

/-- Clef's model id at `/v1/systemone`. -/
def modelName : String := "clef"

/-- Public System One endpoint. -/
def endpoint : String := "https://api.vultrinference.com/v1/systemone"

/-- The server accepts this many questions in one request. This client does not split. -/
def questionLimit : Nat := 64

/-- Curl's own cap, in seconds. Answers are about a second; this is the ceiling. -/
def curlMaxTimeSec : Nat := 60

/-- Above `curlMaxTimeSec`, so a slow curl exits itself instead of being killed. -/
def requestTimeoutMs : Nat := 70000

/-- Response stdout cap. The request body is not part of it. -/
def responseCap : Nat := 1048576

/-- Stop after this many attempts, including the first. -/
def maxAttempts : Nat := 3

/-- Milliseconds after a 502, 503, or 504. `n` is how many of those have already failed, from 1. -/
def backoffMs (n : Nat) : Nat :=
  1000 * n

/-- Clef reads 262144 tokens. This estimate is 4 characters per token. -/
def charsPerToken : Nat := 4

/-- Token limit measured for `clef`. Over it, the server returns 422. -/
def tokenLimit : Nat := 262144

/-- `tokenLimit * charsPerToken`. State text longer than this is cut from the end. -/
def charCap : Nat := tokenLimit * charsPerToken

#guard charsPerToken == 4
#guard tokenLimit == 262144
#guard charCap == 1048576
#guard charCap == tokenLimit * charsPerToken
#guard questionLimit == 64
#guard maxAttempts == 3
#guard backoffMs 1 == 1000
#guard backoffMs 2 == 2000
#guard curlMaxTimeSec == 60
#guard requestTimeoutMs == 70000
#guard responseCap == 1048576

/-- Keep the prefix. A string already within the cap is returned unchanged. -/
def trimToCap (s : String) : String :=
  if s.length ≤ charCap then
    s
  else
    (s.toSlice.take charCap).toString

private def doubled (n : Nat) : String :=
  match n with
  | 0 => "x"
  | k + 1 =>
    let t := doubled k
    t ++ t

private def overCapText : String :=
  doubled 20 ++ "yyyyyyyy"

#guard (doubled 20).length == charCap
#guard trimToCap "abc" == "abc"
#guard trimToCap "" == ""
#guard (trimToCap (doubled 20)).length == charCap
#guard (doubled 20).startsWith (trimToCap (doubled 20))
#guard overCapText.length == charCap + 8
#guard (trimToCap overCapText).length == charCap
#guard overCapText.startsWith (trimToCap overCapText)
#guard (trimToCap overCapText).startsWith "x"

/-- One level. Recorded `run` values are strings, numbers, or null. -/
private def trimJson (j : Json) : Json :=
  match j with
  | .str s => .str (trimToCap s)
  | .obj kvs =>
    Json.mkObj (kvs.toList.map fun (k, v) =>
      match v with
      | .str s => (k, Json.str (trimToCap s))
      | other => (k, other))
  | other => other

/-- What one attempt waits, in milliseconds. A missing `Retry-After` uses `backoffMs`. -/
def waitMs (status : Nat) (retryAfter : Option String) (failed : Nat) : Nat :=
  if status == 429 then
    match retryAfter with
    | some h =>
      match h.trimAscii.toString.toNat? with
      | some n => n * 1000
      | none => backoffMs failed
    | none => backoffMs failed
  else
    backoffMs failed

#guard waitMs 429 (some "0") 1 == 0
#guard waitMs 429 (some "5") 1 == 5000
#guard waitMs 429 none 1 == 1000
#guard waitMs 502 none 1 == 1000
#guard waitMs 503 none 2 == 2000
#guard waitMs 504 none 1 == 1000

def isRetry (status : Nat) : Bool :=
  status == 429 || status == 502 || status == 503 || status == 504

#guard isRetry 429
#guard isRetry 502
#guard isRetry 503
#guard isRetry 504
#guard !isRetry 200
#guard !isRetry 422
#guard !isRetry 500

/-- Marker between the body and curl's `-w` trailer. Not a JSON token. -/
def statusMark : String := "--kalari-status--"

/-- Curl write-out appended to the body. `%header{retry-after}` is empty when absent. -/
def curlWriteOut : String :=
  "\n" ++ statusMark ++ "\n%{http_code}\n%header{retry-after}"

/-- Arguments for one POST. `bodyFile` is the JSON. The key is not here. -/
def curlArgv (bodyFile : String) : List String :=
  ["curl", "-sS", "--max-time", toString curlMaxTimeSec, "--config", "-",
   "-H", "Content-Type: application/json",
   "--data-binary", s!"@{bodyFile}",
   "-w", curlWriteOut,
   endpoint]

/-- Stdin config. The key is only in this string. -/
private def curlConfig (key : String) : String :=
  s!"header = \"Authorization: Bearer {key}\"\n"

private def argvHides (argv : List String) (secret : String) : Bool :=
  secret != "" && argv.all fun a => !a.contains secret

/-- The value the argv check uses. It is not a key. It is not printed. -/
private def argvProbe : String := "pasted-key-value-not-real"

#guard argvHides (curlArgv "/tmp/clef-body.json") argvProbe
#guard (curlConfig argvProbe).contains argvProbe
#guard (curlArgv "body.json").contains "--config"
#guard (curlArgv "body.json").contains "--data-binary"
#guard (curlArgv "body.json").contains "@body.json"
#guard (curlArgv "body.json").contains endpoint
#guard curlWriteOut.contains "%{http_code}"
#guard curlWriteOut.contains "%header{retry-after}"
#guard curlWriteOut.contains statusMark

/-- `(argv, stdin config, timeoutMs, outputCap)`. `live` binds this to `Proc.run`. -/
abbrev Runner :=
  (argv : List String) → (stdin : ByteArray) → (timeoutMs : Nat) → (outputCap : Nat) → IO Result

/-- Waits the requested milliseconds. The checks pass one that returns at once. -/
abbrev Delay := Nat → IO Unit

/-- `path` is the child's whole `PATH`. The parent environment is not inherited.
The checks do not call this. -/
def live (path : String) : Runner := fun argv stdin timeoutMs outputCap =>
  Proc.run argv (env := #[("PATH", some path)]) (inheritEnv := false)
    (stdin := some stdin) (timeoutMs := timeoutMs) (outputCap := outputCap)

private def frame (body : String) (status : Nat) (retryAfter : Option String) : String :=
  body ++ "\n" ++ statusMark ++ "\n" ++ toString status ++ "\n" ++ retryAfter.getD ""

private def unframe (out : String) : Except String (Nat × String × Option String) := do
  let mark := "\n" ++ statusMark ++ "\n"
  match out.splitOn mark with
  | [body, tail] =>
    let lines := tail.splitOn "\n"
    let status ← match lines.head?.bind (·.toNat?) with
      | some n => pure n
      | none => throw "clef: status missing"
    let header := lines[1]?.getD ""
    let retry := if header.isEmpty then none else some header
    pure (status, body, retry)
  | _ => throw "clef: status missing"

#guard match unframe (frame "{\"a\":1}" 429 (some "0")) with
  | .ok (429, "{\"a\":1}", some "0") => true
  | _ => false

#guard match unframe (frame "{\"a\":1}" 200 none) with
  | .ok (200, "{\"a\":1}", none) => true
  | _ => false

private def bytesText (b : ByteArray) : String :=
  match String.fromUTF8? b with
  | some s => s
  | none => ""

private def transport (r : Result) : Except String (Nat × String × Option String) := do
  match r.cap with
  | .timeout => throw "clef: timeout"
  | .output => throw "clef: output cap"
  | .none =>
    match r.exitCode with
    | none => throw "clef: no exit"
    | some code =>
      if code != 0 then
        let err := (bytesText r.stderr).trimAscii.toString
        if err.isEmpty then throw s!"clef: curl exited {code}"
        else throw s!"clef: curl exited {code}: {err}"
      else
        match String.fromUTF8? r.stdout with
        | none => throw "clef: stdout is not utf-8"
        | some out => unframe out

private def post (runner : Runner) (key body : String) : IO Result := do
  if key.isEmpty then
    throw <| .userError "clef: key is empty"
  let (handle, tmp) ← IO.FS.createTempFile
  try
    handle.putStr body
    handle.flush
    let argv := curlArgv (toString tmp)
    if argv.any (·.contains key) then
      throw <| .userError "clef: key appeared in an argv element"
    runner argv (curlConfig key).toUTF8 requestTimeoutMs responseCap
  finally
    IO.FS.removeFile tmp

private def readKey (keyEnv : String) : IO String := do
  match ← IO.getEnv keyEnv with
  | some k =>
    if k.isEmpty then throw <| .userError s!"{keyEnv} is not set"
    return k
  | none => throw <| .userError s!"{keyEnv} is not set"

private def insertByName (x : String × Float) (xs : List (String × Float)) :
    List (String × Float) :=
  match xs with
  | [] => [x]
  | y :: ys => if x.1 ≤ y.1 then x :: xs else y :: insertByName x ys

private def byName (xs : List (String × Float)) : List (String × Float) :=
  xs.foldl (fun acc x => insertByName x acc) []

private def probList (j : Json) : Except String (List (String × Float)) := do
  let obj ← j.getObj?
  let items ← obj.toList.mapM fun (k, v) => do
    let n ← v.getNum?
    return (k, n.toFloat)
  return byName items

private structure RawAnswer where
  name : String
  kind : String
  value : Json

/-- `{status, body}` as the recordings are shaped. Choice is a label.
Noul numbers are the body values, sorted by question name. A non-200 is
`error` with `body.error.message`. -/
private def decodeWrapped (j : Json) : Except String DecisionAnswer := do
  let status ← (← j.getObjVal? "status").getNat?
  let body ← j.getObjVal? "body"
  if status != 200 then
    let message ← (← (← body.getObjVal? "error").getObjVal? "message").getStr?
    return DecisionAnswer.error status message
  let answers ← body.getObjVal? "answers"
  let kvs ← answers.getObj?
  let parsed ← kvs.toList.mapM fun (name, v) => do
    if name.isEmpty then throw "clef: answer has no name"
    let kind ← (← v.getObjVal? "type").getStr?
    return ({ name, kind, value := v } : RawAnswer)
  let kinds := parsed.foldl (init := ([] : List String)) fun acc item =>
    if acc.any (· == item.kind) then acc else acc ++ [item.kind]
  match kinds, parsed with
  | ["choice"], [one] =>
    let label ← (← one.value.getObjVal? "choice").getStr?
    let probs ← probList (← one.value.getObjVal? "probabilities")
    let confidence ← (← one.value.getObjVal? "confidence").getNum?
    return DecisionAnswer.label label probs confidence.toFloat
  | ["noul"], _ =>
    let items ← parsed.mapM fun item => do
      let n ← (← item.value.getObjVal? "noul").getNum?
      return (item.name, n.toFloat)
    return DecisionAnswer.probabilities (byName items)
  | _, _ =>
    throw "clef: response is not a label, probabilities, or an error status"

private def decodeStatus (status : Nat) (body : String) : Except String DecisionAnswer := do
  let j ← match Json.parse body with
    | .ok j => pure j
    | .error _ => throw "clef: response did not parse"
  decodeWrapped (Json.mkObj [("status", toJson status), ("body", j)])

private def decodeRecording (text : String) : Except String DecisionAnswer := do
  let j ← match Json.parse text with
    | .ok j => pure j
    | .error _ => throw "clef: response did not parse"
  decodeWrapped j

private def submitFrom (runner : Runner) (delay : Delay) (key body : String) :
    Nat → IO (Except String DecisionAnswer)
  | 0 => pure (.error "clef: no attempt")
  | n + 1 => do
    let raw ← post runner key body
    match transport raw with
    | .error e => return .error e
    | .ok (status, resp, retry) =>
      if !isRetry status || n == 0 then
        return decodeStatus status resp
      delay (waitMs status retry (maxAttempts - n))
      submitFrom runner delay key body n

private def withinLimit (n : Nat) : Except String Unit :=
  if n == 0 then
    .error "clef: no questions"
  else if n > questionLimit then
    .error s!"clef: {n} questions is over {questionLimit}"
  else
    .ok ()

private def failureCriteria : List (String × String) := [
  ("api_change", "the consumer does not handle the API change"),
  ("test_setup", "our test environment, network allowlist or fixtures are wrong"),
  ("flaky", "a transient or timing failure that would pass on retry"),
  ("unrelated_bug", "a bug in the consumer unrelated to the API change"),
]

private def failureQuestion : Json :=
  Json.mkObj [
    ("type", Json.str "choice"),
    ("instructions", Json.str "Why did this run fail?"),
    ("criteria", Json.mkObj (failureCriteria.map fun (k, v) => (k, Json.str v))),
  ]

private def failureBody (change : String) (run : Json) (code : String) : Json :=
  Json.mkObj [
    ("model", Json.str modelName),
    ("state", Json.mkObj [
      ("change", Json.str (trimToCap change)),
      ("run", trimJson run),
      ("code", Json.str (trimToCap code)),
    ]),
    ("questions", Json.mkObj [
      ("failure_cause", failureQuestion),
    ]),
  ]

private def noulQuestion (instructions : String) : Json :=
  Json.mkObj [
    ("type", Json.str "noul"),
    ("instructions", Json.str instructions),
  ]

private def callsBody (change : String) (hits : List (String × String)) : Json :=
  let hits := hits.map fun (n, text) => (n, trimToCap text)
  Json.mkObj [
    ("model", Json.str modelName),
    ("state", Json.mkObj [
      ("change", Json.str (trimToCap change)),
      ("hits", Json.mkObj (hits.map fun (n, text) => (n, Json.str text))),
    ]),
    ("questions", Json.mkObj (hits.map fun (n, _) =>
      (n, noulQuestion s!"Does the code at hits.{n} call the operation described in change?"))),
  ]

private def lessonBody (lesson : String) (changes : List (String × String)) : Json :=
  let changes := changes.map fun (n, text) => (n, trimToCap text)
  Json.mkObj [
    ("model", Json.str modelName),
    ("state", Json.mkObj [
      ("lesson", Json.str (trimToCap lesson)),
      ("changes", Json.mkObj (changes.map fun (n, text) => (n, Json.str text))),
    ]),
    ("questions", Json.mkObj (changes.map fun (n, _) =>
      (n, noulQuestion s!"Does the lesson apply to the change at changes.{n}?"))),
  ]

/-- Why the run failed. One `choice` question, `failure_cause`. -/
def failureCause (runner : Runner) (delay : Delay) (keyEnv : String)
    (change : String) (run : Json) (code : String) : IO (Except String DecisionAnswer) := do
  let key ← readKey keyEnv
  submitFrom runner delay key (failureBody change run code).compress maxAttempts

/-- Whether each hit calls the changed operation. One `noul` per hit, in one request. -/
def callsChangedOperation (runner : Runner) (delay : Delay) (keyEnv : String)
    (change : String) (hits : List (String × String)) : IO (Except String DecisionAnswer) := do
  match withinLimit hits.length with
  | .error e => return .error e
  | .ok _ =>
    let key ← readKey keyEnv
    submitFrom runner delay key (callsBody change hits).compress maxAttempts

/-- Whether the lesson applies to each change. One `noul` per change, in one request. -/
def lessonApplies (runner : Runner) (delay : Delay) (keyEnv : String)
    (lesson : String) (changes : List (String × String)) : IO (Except String DecisionAnswer) := do
  match withinLimit changes.length with
  | .error e => return .error e
  | .ok _ =>
    let key ← readKey keyEnv
    submitFrom runner delay key (lessonBody lesson changes).compress maxAttempts

/-! The checks below run during `lake build`. The runner reads `testdata/clef`
and does not spawn curl. A recording it was not given fails the build.
`live` is not applied. The delay records the wait and returns. -/

private def fail {α : Type} (msg : String) : IO α :=
  throw <| .userError msg

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def check (cond : Bool) (msg : String) : IO Unit := do
  unless cond do
    fail msg

private def ofExcept {α : Type} (e : Except String α) : IO α := do
  match e with
  | .ok a => return a
  | .error err => fail err

private def findRootFrom (dir : System.FilePath) (left : Nat) : IO System.FilePath := do
  if ← (dir / "lakefile.toml").pathExists then
    return dir
  if left = 0 then
    return dir
  match dir.parent with
  | none => return dir
  | some parent => findRootFrom parent (left - 1)

private def repoRoot : IO System.FilePath := do
  let dir ← findRootFrom (← IO.currentDir) 8
  unless ← (dir / "lakefile.toml").pathExists do
    fail "no lakefile.toml"
  return dir

private def keyEnvName : String := "KALARI_CLEF_KEY"

private def clefFile (root : System.FilePath) (name : String) : System.FilePath :=
  root / "testdata" / "clef" / name

private def loadJson (path : System.FilePath) : IO Json := do
  let text ← IO.FS.readFile path
  ofExcept (Json.parse text)

private def replayNames : List String := [
  "failure-api-change-duplicates",
  "failure-api-change-hang",
  "failure-api-change-truncated",
  "failure-unrelated-bug",
  "failure-flaky",
  "failure-test-setup",
  "calls-changed-operation",
  "calls-changed-operation-graphql",
  "lesson-applies",
]

private def findBodyFile (argv : List String) : Except String String :=
  match argv with
  | [] => .error "clef: no body file"
  | "--data-binary" :: arg :: _ =>
    if arg.startsWith "@" && arg.length > 1 then
      .ok (arg.toSlice.drop 1).toString
    else
      .error "clef: body is not a file"
  | _ :: rest => findBodyFile rest

private def refuseKey (argv : List String) (stdin : ByteArray) : IO Unit := do
  if argv.any (fun a => a.contains argvProbe) then
    fail "clef: key appeared in an argv element"
  match String.fromUTF8? stdin with
  | none => fail "clef: config is not utf-8"
  | some config =>
    unless config.contains argvProbe do
      fail "clef: config did not carry the key"
    unless argvHides argv argvProbe do
      fail "clef: key appeared in an argv element"

private def replay (root : System.FilePath) : Runner := fun argv stdin timeoutMs outputCap => do
  refuseKey argv stdin
  unless timeoutMs == requestTimeoutMs && outputCap == responseCap do
    fail s!"clef: budget {timeoutMs} {outputCap}"
  unless argv.contains "--config" && argv.contains endpoint && argv.contains "--data-binary" do
    fail "clef: argv shape"
  let path ← ofExcept (findBodyFile argv)
  let body ← ofExcept (Json.parse (← IO.FS.readFile path))
  let mut found : Option String := none
  for name in replayNames do
    let req ← loadJson (clefFile root s!"{name}.request.json")
    if found.isNone && req == body then
      found := some name
  let name ← match found with
    | some name => pure name
    | none => fail "no recording"
  let wrapped ← loadJson (clefFile root s!"{name}.response.json")
  let status ← ofExcept ((← ofExcept (wrapped.getObjVal? "status")).getNat?)
  let resp ← ofExcept (wrapped.getObjVal? "body")
  return {
    exitCode := some 0
    stdout := (frame resp.compress status none).toUTF8
    stderr := ByteArray.empty
    wallMs := 0
    cap := Cap.none
  }

private def recorded (root : System.FilePath) (name : String) : IO DecisionAnswer := do
  let text ← IO.FS.readFile (clefFile root s!"{name}.response.json")
  ofExcept (decodeRecording text)

private def expectOk (name : String) (e : Except String DecisionAnswer) : IO DecisionAnswer := do
  match e with
  | .ok a => return a
  | .error err => fail s!"{name}: {err}"

private def stringMap (j : Json) : Except String (List (String × String)) := do
  let obj ← j.getObj?
  obj.toList.mapM fun (k, v) => do
    let s ← v.getStr?
    return (k, s)

private def runFailure (runner : Runner) (delay : Delay) (root : System.FilePath)
    (name : String) : IO DecisionAnswer := do
  let req ← loadJson (clefFile root s!"{name}.request.json")
  let state ← ofExcept (req.getObjVal? "state")
  let change ← ofExcept ((← ofExcept (state.getObjVal? "change")).getStr?)
  let run ← ofExcept (state.getObjVal? "run")
  let code ← ofExcept ((← ofExcept (state.getObjVal? "code")).getStr?)
  let ans ← expectOk name (← failureCause runner delay keyEnvName change run code)
  check (ans == (← recorded root name)) s!"{name}: not the recorded answer"
  return ans

private def runCalls (runner : Runner) (delay : Delay) (root : System.FilePath)
    (name : String) : IO DecisionAnswer := do
  let req ← loadJson (clefFile root s!"{name}.request.json")
  let state ← ofExcept (req.getObjVal? "state")
  let change ← ofExcept ((← ofExcept (state.getObjVal? "change")).getStr?)
  let hits ← ofExcept (stringMap (← ofExcept (state.getObjVal? "hits")))
  let ans ← expectOk name (← callsChangedOperation runner delay keyEnvName change hits)
  check (ans == (← recorded root name)) s!"{name}: not the recorded answer"
  return ans

private def runLesson (runner : Runner) (delay : Delay) (root : System.FilePath)
    (name : String) : IO DecisionAnswer := do
  let req ← loadJson (clefFile root s!"{name}.request.json")
  let state ← ofExcept (req.getObjVal? "state")
  let lesson ← ofExcept ((← ofExcept (state.getObjVal? "lesson")).getStr?)
  let changes ← ofExcept (stringMap (← ofExcept (state.getObjVal? "changes")))
  let ans ← expectOk name (← lessonApplies runner delay keyEnvName lesson changes)
  check (ans == (← recorded root name)) s!"{name}: not the recorded answer"
  return ans

private structure Step where
  status : Nat
  retryAfter : Option String
  body : String

private def errorJson (message : String) : String :=
  (Json.mkObj [("error", Json.mkObj [("message", Json.str message)])]).compress

private def choiceOk : String :=
  (Json.mkObj [
    ("model", Json.str modelName),
    ("answers", Json.mkObj [
      ("failure_cause", Json.mkObj [
        ("type", Json.str "choice"),
        ("choice", Json.str "api_change"),
        ("probabilities", Json.mkObj [
          ("api_change", toJson (1 : Nat)),
          ("flaky", toJson (0 : Nat)),
          ("test_setup", toJson (0 : Nat)),
          ("unrelated_bug", toJson (0 : Nat)),
        ]),
        ("confidence", toJson (1 : Nat)),
      ]),
    ]),
  ]).compress

private def scripted (steps : List Step) (calls : IO.Ref Nat) : Runner :=
  fun argv stdin timeoutMs outputCap => do
    refuseKey argv stdin
    unless timeoutMs == requestTimeoutMs && outputCap == responseCap do
      fail s!"clef: budget {timeoutMs} {outputCap}"
    let i ← calls.get
    calls.set (i + 1)
    match steps[i]? with
    | none => fail "clef: no scripted reply"
    | some step =>
      return {
        exitCode := some 0
        stdout := (frame step.body step.status step.retryAfter).toUTF8
        stderr := ByteArray.empty
        wallMs := 0
        cap := Cap.none
      }

private def recordingDelay (seen : IO.Ref (List Nat)) : Delay :=
  fun ms => seen.modify (· ++ [ms])

private def runChecks : IO Unit := do
  let root ← repoRoot
  let saved ← IO.getEnv keyEnvName
  try
    Std.Async.System.setEnvVar keyEnvName argvProbe
    let waits ← IO.mkRef ([] : List Nat)
    let delay := recordingDelay waits
    let runner := replay root

    let dup ← runFailure runner delay root "failure-api-change-duplicates"
    match dup with
    | .label lab probs _ =>
      check (lab == "api_change") s!"duplicates: {lab}"
      check (probs.length == 4) "duplicates: probabilities"
    | other => fail s!"duplicates: {reprStr other}"
    say "clef failure-api-change-duplicates label=api_change"

    let labels : List (String × String) := [
      ("failure-api-change-hang", "api_change"),
      ("failure-api-change-truncated", "api_change"),
      ("failure-unrelated-bug", "unrelated_bug"),
      ("failure-flaky", "flaky"),
      ("failure-test-setup", "test_setup"),
    ]
    for (name, label) in labels do
      match ← runFailure runner delay root name with
      | .label got probs _ =>
        check (got == label) s!"{name}: {got}"
        check (probs.length == 4) s!"{name}: probabilities"
      | other => fail s!"{name}: {reprStr other}"

    let calls ← runCalls runner delay root "calls-changed-operation"
    match calls with
    | .probabilities probs => check (probs.length == 4) s!"calls: {probs.length}"
    | other => fail s!"calls: {reprStr other}"
    match ← runCalls runner delay root "calls-changed-operation-graphql" with
    | .probabilities probs => check (probs.length == 2) s!"calls-graphql: {probs.length}"
    | other => fail s!"calls-graphql: {reprStr other}"
    say "clef calls-changed-operation probabilities=4"

    match ← runLesson runner delay root "lesson-applies" with
    | .probabilities probs => check (probs.length == 3) s!"lesson: {probs.length}"
    | other => fail s!"lesson: {reprStr other}"
    say "clef lesson-applies probabilities=3"

    let overText ← IO.FS.readFile (clefFile root "over-length.response.json")
    match ← ofExcept (decodeRecording overText) with
    | .error status message =>
      check (status == 422) s!"over-length: {status}"
      check (message == "the request takes 300140 tokens, more than the 262144 this model reads")
        "over-length: message"
    | other => fail s!"over-length: {reprStr other}"
    say "clef over-length status=422"

    say s!"clef trim length={(trimToCap overCapText).length}"

    let idle ← waits.get
    check idle.isEmpty "recording: unexpected retry"
    say "clef argv key=absent"

    let missed ← try
      discard <| failureCause runner delay keyEnvName "not-a-recorded-change" (Json.mkObj []) ""
      pure none
    catch e =>
      pure (some (toString e))
    match missed with
    | none => fail "missing recording returned"
    | some msg => check (msg == "no recording") s!"miss: {msg}"

    let oneStep (status : Nat) (retry : Option String) (message : String) : Step :=
      { status, retryAfter := retry, body := errorJson message }

    let retryOnce (status : Nat) (retry : Option String) (wantDelay : Nat) : IO Unit := do
      let calls ← IO.mkRef 0
      let waited ← IO.mkRef ([] : List Nat)
      let steps := [
        oneStep status retry "slow",
        { status := 200, retryAfter := none, body := choiceOk },
      ]
      let ans ← expectOk "retry" (← failureCause (scripted steps calls) (recordingDelay waited)
        keyEnvName "change" (Json.mkObj []) "code")
      match ans with
      | .label lab _ _ => check (lab == "api_change") s!"retry {status}: {lab}"
      | other => fail s!"retry {status}: {reprStr other}"
      check ((← calls.get) == 2) s!"retry {status}: attempts"
      check ((← waited.get) == [wantDelay]) s!"retry {status}: delay"
    retryOnce 429 (some "0") 0
    retryOnce 502 none (backoffMs 1)
    say "clef retry second=api_change"

    let calls ← IO.mkRef 0
    let waited ← IO.mkRef ([] : List Nat)
    let stuck := [
      oneStep 502 none "bad gateway",
      oneStep 503 none "bad gateway",
      oneStep 504 none "bad gateway",
    ]
    match ← expectOk "retry-cap" (← failureCause (scripted stuck calls) (recordingDelay waited)
        keyEnvName "change" (Json.mkObj []) "code") with
    | .error status message =>
      check (status == 504) s!"retry-cap: {status}"
      check (message == "bad gateway") "retry-cap: message"
    | other => fail s!"retry-cap: {reprStr other}"
    check ((← calls.get) == 3) "retry-cap: attempts"
    check ((← waited.get) == [backoffMs 1, backoffMs 2]) "retry-cap: delays"

    let once ← IO.mkRef 0
    let waited ← IO.mkRef ([] : List Nat)
    match ← expectOk "no-retry" (← failureCause (scripted [oneStep 422 none "too long"] once)
        (recordingDelay waited) keyEnvName "change" (Json.mkObj []) "code") with
    | .error status _ => check (status == 422) s!"no-retry: {status}"
    | other => fail s!"no-retry: {reprStr other}"
    check ((← once.get) == 1) "no-retry: attempts"
    check (← waited.get).isEmpty "no-retry: delay"
  finally
    match saved with
    | some v => Std.Async.System.setEnvVar keyEnvName v
    | none => Std.Async.System.unsetEnvVar keyEnvName

#eval runChecks

end Kalari.Clef
