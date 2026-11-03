import Lean.Data.Json
import Kalari.Backend
import Kalari.Model
import Kalari.Proc

/-! One fake of each backend. Each replays `testdata/` and misses loudly.

A miss is `no recording for <key>`. It is not an empty list and not a success.
Sandbox recordings are `testdata/msb` (argv, exit, and timing from `index.json`;
bytes from the `.stdout` and `.stderr` files). Decision recordings are
`testdata/clef`. Change recordings are `testdata/vimanam`. There is no memory
recording. These fakes do not spawn a process and do not use the network. -/

namespace Kalari.Fake

open Lean
open Kalari.Backend
open Kalari.Model
open Kalari.Proc

private def fail {α : Type} (msg : String) : IO α :=
  throw <| .userError msg

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def check (cond : Bool) (msg : String) : IO Unit := do
  unless cond do
    fail msg

private def has (hay needle : String) : Bool :=
  needle != "" && (hay.splitOn needle).length > 1

private def findRootFrom (dir : System.FilePath) (left : Nat) : IO System.FilePath := do
  if ← (dir / "lakefile.toml").pathExists then
    return dir
  if left = 0 then
    return dir
  match dir.parent with
  | none => return dir
  | some parent => findRootFrom parent (left - 1)

private def repoRoot : IO System.FilePath := do
  findRootFrom (← IO.currentDir) 8

private def readText (path : System.FilePath) : IO String :=
  IO.FS.readFile path

private def ofExcept {α : Type} (e : Except String α) : IO α := do
  match e with
  | .ok a => return a
  | .error err => fail err

private def miss (key : String) : Except String α :=
  .error s!"no recording for {key}"

/-! Sandbox. The name, caps, allowlist, and argv select one index row.
Two create rows share a name and a memory size; the allowlist tells them apart.
`destroy` is the remove row. The recorded process had already finished, so
`cap` is `none` and the exit code is the one in the index. -/

private structure Rec where
  name : String
  argv : String
  code : Nat
  ms : Nat

private def parseRec (j : Json) : Except String Rec := do
  let name ← (← j.getObjVal? "case").getStr?
  let argv ← (← j.getObjVal? "argv").getStr?
  let code ← (← j.getObjVal? "exit").getNat?
  let ms ← (← j.getObjVal? "ms").getNat?
  return { name, argv, code, ms }

private def loadRecs (root : System.FilePath) : IO (List Rec) := do
  let text ← readText (root / "testdata" / "msb" / "index.json")
  let arr ← ofExcept ((← ofExcept (Json.parse text)).getArr?)
  arr.toList.mapM fun item => ofExcept (parseRec item)

private def toResult (root : System.FilePath) (r : Rec) : IO Result := do
  let stdout ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{r.name}.stdout")
  let stderr ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{r.name}.stderr")
  return {
    exitCode := some (UInt32.ofNat r.code)
    stdout
    stderr
    wallMs := r.ms
    cap := Cap.none
  }

private def serve (pred : Rec → Bool) (key : String) : IO (Except String Result) := do
  let root ← repoRoot
  let recs ← loadRecs root
  match recs.filter pred with
  | [r] => return .ok (← toResult root r)
  | _ => return miss key

private def allowKey (allow : List AllowHost) : String :=
  if allow.isEmpty then "-"
  else String.intercalate "," (allow.map fun h => s!"{h.host}:{h.port}")

private def createPred (name : String) (caps : Caps) (allow : List AllowHost) (r : Rec) : Bool :=
  has r.argv s!"create --name {name}" &&
    has r.argv s!"--memory {caps.memory_mib}M" &&
    (if allow.isEmpty then !has r.argv "--net-rule"
     else has r.argv "--net-rule" &&
       allow.all fun h => has r.argv h.host && has r.argv (toString h.port))

private def sandboxCreate (name : String) (caps : Caps) (allow : List AllowHost) :
    IO (Except String Result) :=
  serve (createPred name caps allow) s!"create {name} {caps.memory_mib} {allowKey allow}"

private def sandboxCopyIn (name src dest : String) : IO (Except String Result) :=
  serve (fun r => has r.argv s!"copy -q {src} {name}:{dest}")
    s!"copy-in {name} {src} {dest}"

private def sandboxExec (name : String) (argv : List String) : IO (Except String Result) := do
  let cmd := String.intercalate " " argv
  let key := if cmd.isEmpty then s!"exec {name}" else s!"exec {name} {cmd}"
  serve (fun r => !cmd.isEmpty && has r.argv s!"exec {name} -- {cmd}") key

private def sandboxCopyOut (name guest host : String) : IO (Except String Result) :=
  serve (fun r => has r.argv s!"copy -q {name}:{guest} {host}")
    s!"copy-out {name} {guest} {host}"

private def sandboxDestroy (name : String) : IO (Except String Result) :=
  serve (fun r => has r.argv s!"remove {name}") s!"destroy {name}"

/-- Replays `testdata/msb`. -/
def sandbox : SandboxBackend where
  create := sandboxCreate
  copyIn := sandboxCopyIn
  exec := sandboxExec
  copyOut := sandboxCopyOut
  destroy := sandboxDestroy

/-! Decisions. The question-set name is the response file's name.
A choice body is a label; a noul body is probabilities; anything else with a
status is an error status. `over-length` is not in `index.json`; its response
file is still a recording. -/

private structure RawAnswer where
  name : String
  kind : String
  value : Json

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

private def decodeAnswer (j : Json) : Except String DecisionAnswer := do
  let status ← (← j.getObjVal? "status").getNat?
  let body ← j.getObjVal? "body"
  if status != 200 then
    let message ← (← (← body.getObjVal? "error").getObjVal? "message").getStr?
    return DecisionAnswer.error status message
  let answers ← body.getObjVal? "answers"
  let kvs ← answers.getObj?
  let parsed ← kvs.toList.mapM fun (name, v) => do
    if name.isEmpty then throw "answer has no name"
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
    throw "recorded answer is not a label, probabilities, or an error status"

private def decisionAsk (case : String) : IO (Except String DecisionAnswer) := do
  let root ← repoRoot
  let path := root / "testdata" / "clef" / s!"{case}.response.json"
  if !(← path.pathExists) then
    return miss case
  let text ← readText path
  match Json.parse text >>= decodeAnswer with
  | .ok answer => return .ok answer
  | .error _ => return .error s!"{case}: recorded answer did not parse"

/-- Replays `testdata/clef`. -/
def decisions : DecisionClient where
  ask := decisionAsk

/-! Memory. No recording directory exists, so every call misses. -/

private def memoryMiss (op key : String) : IO (Except String α) :=
  pure (miss s!"{op} {key}")

/-- Every call misses, naming the operation and the key. -/
def memory : MemoryClient where
  derive := memoryMiss "derive"
  inspect := memoryMiss "inspect"
  «recall» := memoryMiss "recall"
  against := memoryMiss "against"

/-! Changes. The two strings are spec paths. The next-cursor probe keeps the
same-path v1 and pairs it with its own v2; that is the pair that was recorded. -/

private def changeFile (old new : String) : Option String :=
  match old, new with
  | "bench/workspaces/payout-sync/specs/openapi-v1.yaml",
    "bench/workspaces/payout-sync/specs/openapi-v2.yaml" =>
      some "testdata/vimanam/payouts.json"
  | "bench/workspaces/settlement-reconcile/specs/schema-v1.graphql",
    "bench/workspaces/settlement-reconcile/specs/schema-v2.graphql" =>
      some "testdata/vimanam/settlements.json"
  | "testdata/vimanam/probes/payouts-samepath-v1.yaml",
    "testdata/vimanam/probes/payouts-samepath-v2.yaml" =>
      some "testdata/vimanam/probes/payouts-samepath.json"
  | "testdata/vimanam/probes/payouts-samepath-v1.yaml",
    "testdata/vimanam/probes/payouts-samepath-nextcursor-v2.yaml" =>
      some "testdata/vimanam/probes/payouts-samepath-nextcursor.json"
  | "testdata/vimanam/probes/settlements-edges-v1.graphql",
    "testdata/vimanam/probes/settlements-edges-v2.graphql" =>
      some "testdata/vimanam/probes/settlements-edges.json"
  | _, _ => none

private def decodeChanges (j : Json) : Except String (List ChangeFact) := do
  let arr ← (← j.getObjVal? "changes").getArr?
  arr.toList.mapM fun item => fromJson? item

private def changeDiff (old new : String) : IO (Except String (List ChangeFact)) := do
  let some rel := changeFile old new
    | return miss s!"{old} {new}"
  let root ← repoRoot
  let text ← readText (root / rel)
  match Json.parse text >>= decodeChanges with
  | .ok facts => return .ok facts
  | .error _ => return .error s!"{old} {new}: recorded changes did not parse"

/-- Replays `testdata/vimanam`. -/
def changes : ChangeSource where
  diff := changeDiff

/-! The checks below run during `lake build`. -/

private def expectOk {α : Type} (what : String) (e : Except String α) : IO α := do
  match e with
  | .ok a => return a
  | .error err => fail s!"{what}: {err}"

private def expectMiss {α : Type} (what key : String) (e : Except String α) : IO Unit := do
  match e with
  | .ok _ => fail s!"{what}: expected a miss, got a success"
  | .error err =>
    check (err == s!"no recording for {key}") s!"{what}: {err}"

private def bytesText (b : ByteArray) : String :=
  match String.fromUTF8? b with
  | some s => s
  | none => ""

private def near (got exp : Float) : Bool :=
  let d := got - exp
  let d := if d < 0.0 then -d else d
  d < 0.001

private def recorded (case : String) : IO Rec := do
  let recs ← loadRecs (← repoRoot)
  match recs.find? fun r => r.name == case with
  | some r => return r
  | none => fail s!"index has no {case}"

private def sameBytes (got : Result) (r : Rec) : IO Unit := do
  let root ← repoRoot
  let stdout ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{r.name}.stdout")
  let stderr ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{r.name}.stderr")
  check (got.exitCode == some (UInt32.ofNat r.code)) s!"{r.name}: exit"
  check (got.wallMs == r.ms) s!"{r.name}: wall"
  check (got.stdout == stdout) s!"{r.name}: stdout bytes"
  check (got.stderr == stderr) s!"{r.name}: stderr bytes"
  check (got.cap == Cap.none) s!"{r.name}: cap"

private def chosenIsMax (label : String) (probs : List (String × Float)) : Bool :=
  match probs.find? fun p => p.1 == label with
  | none => false
  | some chosen => probs.all fun p => chosen.2 ≥ p.2

private def payoutsV1 : String := "bench/workspaces/payout-sync/specs/openapi-v1.yaml"
private def payoutsV2 : String := "bench/workspaces/payout-sync/specs/openapi-v2.yaml"
private def settlementsV1 : String := "bench/workspaces/settlement-reconcile/specs/schema-v1.graphql"
private def settlementsV2 : String := "bench/workspaces/settlement-reconcile/specs/schema-v2.graphql"
private def sameV1 : String := "testdata/vimanam/probes/payouts-samepath-v1.yaml"
private def sameV2 : String := "testdata/vimanam/probes/payouts-samepath-v2.yaml"
private def cursorV2 : String := "testdata/vimanam/probes/payouts-samepath-nextcursor-v2.yaml"
private def edgesV1 : String := "testdata/vimanam/probes/settlements-edges-v1.graphql"
private def edgesV2 : String := "testdata/vimanam/probes/settlements-edges-v2.graphql"

private def fact (id kind : String) : ChangeFact := { id, kind }

private def expectFacts (what : String) (got want : List ChangeFact) : IO Unit := do
  check (got == want) s!"{what}: id and kind list"

private def hasFact (facts : List ChangeFact) (id kind : String) : Bool :=
  facts.any fun f => f.id == id && f.kind == kind

private def runChecks : IO Unit := do
  let caps : Caps := { timeout_ms := 800, output_cap_bytes := 4096, memory_mib := 256 }
  let allow : List AllowHost := [{ host := "203.0.113.10", port := 18090 }]

  let created ← expectOk "create-ok" (← sandbox.create "rec-msb" caps allow)
  let createRow ← recorded "create-ok"
  sameBytes created createRow
  check (created.exitCode == some 0 && created.wallMs == 457) "create-ok: exit 0 at 457 ms"
  check (created.stdout.isEmpty && created.stderr.isEmpty) "create-ok: empty output"
  check (has createRow.argv "create --name rec-msb" && has createRow.argv "--memory 256M" &&
    has createRow.argv "203.0.113.10") "create-ok: argv"
  say "sandbox create-ok exit=0 wallMs=457 stdoutEmpty=true stderrEmpty=true"

  let copied ← expectOk "copy-in-ok" (← sandbox.copyIn "rec-msb" "in.txt" "/tmp/in.txt")
  sameBytes copied (← recorded "copy-in-ok")
  check (copied.exitCode == some 0 && copied.wallMs == 13) "copy-in-ok: exit 0 at 13 ms"
  say "sandbox copy-in-ok exit=0 wallMs=13"

  let copiedOut ← expectOk "copy-out-ok" (← sandbox.copyOut "rec-msb" "/tmp/in.txt" "./out.txt")
  sameBytes copiedOut (← recorded "copy-out-ok")
  check (copiedOut.exitCode == some 0 && copiedOut.wallMs == 11) "copy-out-ok: exit 0 at 11 ms"
  say "sandbox copy-out-ok exit=0 wallMs=11"

  let exit3 ← expectOk "exec-exit3"
    (← sandbox.exec "rec-msb" ["sh", "-c", "echo out; echo err >&2; exit 3"])
  let exit3Row ← recorded "exec-exit3"
  sameBytes exit3 exit3Row
  check (exit3.exitCode == some 3 && exit3.wallMs == 20) "exec-exit3: exit 3 at 20 ms"
  check (exit3.stdout == "out\n".toUTF8 && exit3.stderr == "err\n".toUTF8)
    "exec-exit3: stdout and stderr kept apart"
  check (has exit3Row.argv "exit 3") "exec-exit3: argv"
  say "sandbox exec-exit3 exit=3 wallMs=20 stdout=out stderr=err cap=none"

  let unknown ← expectOk "exec-unknown" (← sandbox.exec "no-such-sandbox" ["true"])
  let unknownRow ← recorded "exec-unknown"
  sameBytes unknown unknownRow
  check (unknown.exitCode == some 1 && unknown.stdout.isEmpty) "exec-unknown: exit 1, empty stdout"
  check (has (bytesText unknown.stderr) "no-such-sandbox") "exec-unknown: error does not name the miss"
  say "sandbox exec-unknown exit=1 names=no-such-sandbox"

  expectMiss "exec-miss" "exec no-such-sandbox false" (← sandbox.exec "no-such-sandbox" ["false"])
  say "sandbox miss=no recording for exec no-such-sandbox false"

  expectMiss "create-miss" "create rec-msb 128 203.0.113.10:18090"
    (← sandbox.create "rec-msb" { caps with memory_mib := 128 } allow)
  say "sandbox miss=no recording for create rec-msb 128 203.0.113.10:18090"

  let dup ← expectOk "create-duplicate" (← sandbox.create "rec-msb" caps [])
  sameBytes dup (← recorded "create-duplicate")
  check (dup.exitCode == some 1 && has (bytesText dup.stderr) "already exists")
    "create-duplicate: not create-ok"
  say "sandbox create-duplicate exit=1"

  let removed ← expectOk "destroy" (← sandbox.destroy "rec-msb")
  sameBytes removed (← recorded "remove-ok")
  check (removed.exitCode == some 0 && removed.wallMs == 7) "destroy: remove exit 0"
  say "sandbox destroy exit=0 wallMs=7"

  let labels : List (String × String) := [
    ("failure-api-change-duplicates", "api_change"),
    ("failure-api-change-hang", "api_change"),
    ("failure-api-change-truncated", "api_change"),
    ("failure-unrelated-bug", "unrelated_bug"),
    ("failure-flaky", "flaky"),
    ("failure-test-setup", "test_setup"),
  ]
  for (case, label) in labels do
    match ← expectOk case (← decisions.ask case) with
    | .label got probs conf =>
      check (got == label) s!"{case}: label {got}"
      check (probs.length == 4) s!"{case}: probabilities"
      check (chosenIsMax label probs) s!"{case}: label is not the mode"
      check (conf > 0.5) s!"{case}: confidence"
    | other => fail s!"{case}: {reprStr other}"
    say s!"decision {case} label={label}"
  match ← expectOk "failure-api-change-duplicates" (← decisions.ask "failure-api-change-duplicates") with
  | .label _ _ conf => check (near conf 0.917) "duplicates: confidence"
  | other => fail s!"duplicates confidence: {reprStr other}"

  let nouls : List (String × List (String × Float)) := [
    ("calls-changed-operation", [
      ("hit_comment", 0.066), ("hit_table_name", 0.008),
      ("hit_v1_call", 0.969), ("hit_v2_already", 0.947)]),
    ("calls-changed-operation-graphql", [
      ("hit_other_query", 0.024), ("hit_query", 0.980)]),
    ("lesson-applies", [
      ("to_refunds_connection", 0.973), ("to_rename", 0.026), ("to_settlements", 0.980)]),
  ]
  for (case, want) in nouls do
    match ← expectOk case (← decisions.ask case) with
    | .probabilities got =>
      check (got.length == want.length) s!"{case}: count"
      for (name, exp) in want do
        match got.find? fun p => p.1 == name with
        | some (_, p) => check (near p exp) s!"{case}: {name}"
        | none => fail s!"{case}: missing {name}"
      check (got.map (·.1) == (byName want).map (·.1)) s!"{case}: name order"
    | other => fail s!"{case}: {reprStr other}"
    say s!"decision {case} probabilities={want.length}"

  match ← expectOk "over-length" (← decisions.ask "over-length") with
  | .error status message =>
    check (status == 422) "over-length: status"
    check (message == "the request takes 300140 tokens, more than the 262144 this model reads")
      "over-length: message"
  | other => fail s!"over-length: {reprStr other}"
  say "decision over-length status=422"

  expectMiss "decision-miss" "not-a-case" (← decisions.ask "not-a-case")
  say "decision miss=no recording for not-a-case"

  let payouts ← expectOk "payouts" (← changes.diff payoutsV1 payoutsV2)
  expectFacts "payouts" payouts [
    fact "vc2_c8668fd9e15e5092fdae689188a12455975deddd2b05c2a5d84f32c00619c647" "operation_removed",
    fact "vc2_f227d2cfc40c71b9172f1f16834c626a0b18dd657e2a074c3b9e316da113cd69" "operation_added",
    fact "vc2_ef1fdb68c80a738a6e6182b5f3e8f81f141aaee6c6bafe1ae8bd0dbc7a01a2d7" "type_added",
  ]
  say "change payouts n=3 operation_removed"

  let settled ← expectOk "settlements" (← changes.diff settlementsV1 settlementsV2)
  expectFacts "settlements" settled [
    fact "vc2_c3e0f582fbd65cf9d886ed6f46cf7223c81b112fde8709fc7a1e2d5b55a41b59" "argument_added",
    fact "vc2_a3083d1dd65d83dc9a8a6aa199fa5f00c6b8f5d2fbc19dc8e6092f6eb867ee32" "argument_added",
    fact "vc2_70de83cb459de538495fe0601ac7e463180b94be8b0328ff1655bb0cbf39ed90" "type_added",
    fact "vc2_809e81681c21c88650c10aaf1f3cbbcd6d5b650d9588ca3606e01f05be71a813" "type_added",
    fact "vc2_dde51ee2d28bb72d0fd21f638732d9c9e55a0db75d890c9b5d8b153b4d424081" "field_type_changed",
  ]
  say "change settlements n=5 argument_added"

  let probe ← expectOk "payouts-probe" (← changes.diff sameV1 cursorV2)
  check (probe.length == 10) "payouts probe: count"
  check (hasFact probe "vc2_03e273d5658ac9349bfef95e1780793db8aad41ac574138c3399d53ec0e2f87f"
    "pagination_changed") "payouts probe: pagination_changed"
  say "change payouts-probe n=10 pagination_changed"

  let same ← expectOk "samepath" (← changes.diff sameV1 sameV2)
  check (same.length == 9) "samepath: count"
  check (!same.any fun f => f.kind == "pagination_changed") "samepath: unexpected pagination"
  say "change samepath n=9"

  let edges ← expectOk "edges" (← changes.diff edgesV1 edgesV2)
  check (edges.length == 7) "edges: count"
  check (hasFact edges "vc2_20ba1c46e06cf3fd01051f1892c163ceb0ccfcfe9067d498034585219dba02eb"
    "pagination_changed") "edges: pagination_changed"
  say "change edges n=7 pagination_changed"

  expectMiss "change-miss" "specs/missing-v1.yaml specs/missing-v2.yaml"
    (← changes.diff "specs/missing-v1.yaml" "specs/missing-v2.yaml")
  say "change miss=no recording for specs/missing-v1.yaml specs/missing-v2.yaml"

  expectMiss "memory-derive" "derive paging-lesson" (← memory.derive "paging-lesson")
  expectMiss "memory-inspect" "inspect pagination_changed" (← memory.inspect "pagination_changed")
  expectMiss "memory-recall" "recall page-token" (← memory.«recall» "page-token")
  expectMiss "memory-against" "against paging-lesson" (← memory.against "paging-lesson")
  say "memory miss derive inspect recall against"

#eval runChecks

end Kalari.Fake
