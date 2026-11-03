import Lean.Data.Json
import Kalari.Backend
import Kalari.Model
import Kalari.Proc

/-! ChangeSource over the `vimanam` CLI.

Two spec paths in, `List ChangeFact` out, from JSON contract v2
(`vimanam diff --format json`). The array is `changes[]`. Derived
`FromJson` on `ChangeFact` keeps `id` and `kind` and ignores every
other key.

`vimanam diff --help` prints `vimanam diff [OPTIONS] [OLD] [NEW]`.
The two paths are the last arguments. That help does not list
`--context` or `--max-tokens`. They are options, so the context argv
puts them before the paths. There is no git-ref form. A protobuf
spec uses the same argv. There is no protobuf recording.

Focused context is `focusedContext`, not a field on `ChangeSource`.
The recordings have no context body. This module does not parse one.

`make` takes a runner `(argv, timeoutMs, outputCap) → IO Proc.Result`.
A non-zero exit is an error whose text contains the stderr. `live`
binds `Proc.run` with an explicit `PATH` and `inheritEnv := false`.
The checks replay `testdata/vimanam` and do not call `live`. -/

namespace Kalari.Vimanam

open Kalari.Model
open Kalari.Backend
open Kalari.Proc (Result Cap)
open Lean

/-- `(argv, timeoutMs, outputCap)`. `live` binds this to `Proc.run`. -/
abbrev Runner :=
  (argv : List String) → (timeoutMs : Nat) → (outputCap : Nat) → IO Result

/-- `vimanam diff --help` names no time limit and no output limit. -/
def diffTimeoutMs : Nat := 30000

/-- One mebibyte. The help names no output limit. -/
def diffOutputCap : Nat := 1048576

#guard diffTimeoutMs == 30000
#guard diffOutputCap == 1048576

/-- Options, then the two spec paths. A `.proto` pair uses this same argv. -/
def diffArgv (old new : String) : List String :=
  ["vimanam", "diff", "--format", "json", old, new]

/-- Same option order as `diffArgv`, plus the focused-context flags. -/
def contextArgv (old new : String) (maxTokens : Nat) : List String :=
  ["vimanam", "diff", "--format", "json", "--context", "--max-tokens", toString maxTokens, old, new]

private def endsWithPaths (argv : List String) (old new : String) : Bool :=
  argv.dropLast.getLast? == some old && argv.getLast? == some new

#guard diffArgv "old.yaml" "new.yaml" ==
  ["vimanam", "diff", "--format", "json", "old.yaml", "new.yaml"]

#guard diffArgv "old.pb" "new.pb" ==
  ["vimanam", "diff", "--format", "json", "old.pb", "new.pb"]

#guard endsWithPaths (diffArgv "old.yaml" "new.yaml") "old.yaml" "new.yaml"

#guard contextArgv "old.yaml" "new.yaml" 2000 ==
  ["vimanam", "diff", "--format", "json", "--context", "--max-tokens", "2000", "old.yaml", "new.yaml"]

#guard (contextArgv "old.graphql" "new.graphql" 2000).contains "--context"

#guard (contextArgv "old.graphql" "new.graphql" 2000).contains "--max-tokens"

#guard endsWithPaths (contextArgv "old.yaml" "new.yaml" 1600) "old.yaml" "new.yaml"

private def bytesText (b : ByteArray) : String :=
  match String.fromUTF8? b with
  | some s => s
  | none => ""

/-- A non-zero exit keeps the stderr text. A cap is not a parsed diff. -/
private def textOf (r : Result) : Except String String :=
  match r.cap with
  | .timeout => .error "vimanam: timeout"
  | .output => .error "vimanam: output cap"
  | .none =>
    match r.exitCode with
    | none => .error "vimanam: no exit"
    | some code =>
      if code == 0 then
        match String.fromUTF8? r.stdout with
        | some s => .ok s
        | none => .error "vimanam: stdout is not utf-8"
      else
        let err := (bytesText r.stderr).trimAscii.toString
        if err.isEmpty then .error s!"vimanam: exit {code}"
        else .error s!"vimanam: exit {code}: {err}"

/-- `changes[]` only. Other keys on each object are ignored by `FromJson`. -/
private def decodeChanges (text : String) : Except String (List ChangeFact) := do
  let root ← Json.parse text
  let arr ← (← root.getObjVal? "changes").getArr?
  arr.toList.mapM fun item => fromJson? item

def make (runner : Runner) : ChangeSource where
  diff := fun old new => do
    let r ← runner (diffArgv old new) diffTimeoutMs diffOutputCap
    match textOf r with
    | .error e => return .error e
    | .ok text => return decodeChanges text

/-- Runs the context argv and returns the process stdout.
The recordings have no context body, so this does not parse one. -/
def focusedContext (runner : Runner) (old new : String) (maxTokens : Nat) :
    IO (Except String String) := do
  let r ← runner (contextArgv old new maxTokens) diffTimeoutMs diffOutputCap
  return textOf r

/-- `path` is the child's whole `PATH`. The parent environment is not inherited,
so without it the child cannot find `vimanam`. The checks do not call this. -/
def live (path : String) : Runner := fun argv timeoutMs outputCap =>
  Proc.run argv (env := #[("PATH", some path)]) (inheritEnv := false) (stdin := none)
    (timeoutMs := timeoutMs) (outputCap := outputCap)

/-! The checks below run during `lake build`. The runner reads
`testdata/vimanam` and does not spawn `vimanam`. A recording it was
not given fails the build. `live` is not applied. -/

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

private def payoutsOld : String := "bench/workspaces/payout-sync/specs/openapi-v1.yaml"
private def payoutsNew : String := "bench/workspaces/payout-sync/specs/openapi-v2.yaml"
private def settlementsOld : String := "bench/workspaces/settlement-reconcile/specs/schema-v1.graphql"
private def settlementsNew : String := "bench/workspaces/settlement-reconcile/specs/schema-v2.graphql"

/-- `id` and `kind` read off each `changes[]` object, not through `FromJson`. -/
private def recordedFacts (text : String) : Except String (List ChangeFact) := do
  let root ← Json.parse text
  let arr ← (← root.getObjVal? "changes").getArr?
  arr.toList.mapM fun item => do
    let id ← (← item.getObjVal? "id").getStr?
    let kind ← (← item.getObjVal? "kind").getStr?
    return { id, kind }

private def readRecording (root : System.FilePath) (name : String) : IO String :=
  IO.FS.readFile (root / "testdata" / "vimanam" / name)

private structure Call where
  argv : List String
  timeoutMs : Nat
  outputCap : Nat
  deriving Repr, BEq

private def argvLine (argv : List String) : String :=
  String.intercalate " " argv

/-- Only the two benchmark diffs. Anything else fails the build. -/
private def replay (root : System.FilePath) (calls : IO.Ref (List Call)) : Runner :=
  fun argv timeoutMs outputCap => do
    calls.modify fun xs => xs ++ [Call.mk argv timeoutMs outputCap]
    let name ← match argv with
      | ["vimanam", "diff", "--format", "json", old, new] =>
        if old == payoutsOld && new == payoutsNew then
          pure "payouts.json"
        else if old == settlementsOld && new == settlementsNew then
          pure "settlements.json"
        else
          fail s!"no recording for {old} {new}"
      | _ => fail s!"no recording for {argvLine argv}"
    let stdout ← IO.FS.readBinFile (root / "testdata" / "vimanam" / name)
    return {
      exitCode := some 0
      stdout
      stderr := .empty
      wallMs := 0
      cap := .none
    }

private def expectOk (what : String) (e : Except String (List ChangeFact)) : IO (List ChangeFact) := do
  match e with
  | .ok facts => return facts
  | .error err => fail s!"{what}: {err}"

private def notASpec : String := "error: not a spec"

/-- Exit 1 and the stderr the task names. No change list. -/
private def malformed : Runner := fun argv timeoutMs outputCap => do
  unless argv == diffArgv "specs/broken-v1.yaml" "specs/broken-v2.yaml" do
    fail s!"malformed argv {argvLine argv}"
  unless timeoutMs == diffTimeoutMs && outputCap == diffOutputCap do
    fail s!"malformed budget {timeoutMs} {outputCap}"
  return {
    exitCode := some 1
    stdout := .empty
    stderr := notASpec.toUTF8
    wallMs := 0
    cap := .none
  }

/-- Records the context argv, then the same non-zero exit. No context body. -/
private def contextProbe : Runner := fun argv timeoutMs outputCap => do
  unless argv == contextArgv "old.yaml" "new.yaml" 1600 do
    fail s!"context argv {argvLine argv}"
  unless timeoutMs == diffTimeoutMs && outputCap == diffOutputCap do
    fail s!"context budget {timeoutMs} {outputCap}"
  return {
    exitCode := some 1
    stdout := .empty
    stderr := notASpec.toUTF8
    wallMs := 0
    cap := .none
  }

private def runChecks : IO Unit := do
  let root ← repoRoot
  let calls ← IO.mkRef ([] : List Call)
  let src := make (replay root calls)

  let payoutsText ← readRecording root "payouts.json"
  let payoutsWant ← ofExcept (recordedFacts payoutsText)
  let payouts ← expectOk "payouts" (← src.diff payoutsOld payoutsNew)
  check (payouts.length == 3) "payouts: count"
  check (payouts.any (·.kind == "operation_removed")) "payouts: operation_removed"
  check (payouts == payoutsWant) "payouts: id and kind"
  say "vimanam payouts n=3 operation_removed"

  let settlementsText ← readRecording root "settlements.json"
  let settlementsWant ← ofExcept (recordedFacts settlementsText)
  let settlements ← expectOk "settlements" (← src.diff settlementsOld settlementsNew)
  check (settlements.length == 5) "settlements: count"
  check (settlements.any (·.kind == "argument_added")) "settlements: argument_added"
  check (settlements == settlementsWant) "settlements: id and kind"
  say "vimanam settlements n=5 argument_added"

  let log ← calls.get
  match log with
  | [c0, c1] =>
    check (c0.argv == diffArgv payoutsOld payoutsNew) "payouts argv"
    check (c0.timeoutMs == diffTimeoutMs && c0.outputCap == diffOutputCap) "payouts budget"
    check (c1.argv == diffArgv settlementsOld settlementsNew) "settlements argv"
    check (c1.timeoutMs == diffTimeoutMs && c1.outputCap == diffOutputCap) "settlements budget"
    check (endsWithPaths c0.argv payoutsOld payoutsNew) "payouts paths last"
    check (endsWithPaths c1.argv settlementsOld settlementsNew) "settlements paths last"
  | _ => fail s!"call count {log.length}"
  say s!"vimanam argv {argvLine (diffArgv payoutsOld payoutsNew)}"
  say s!"vimanam budget timeoutMs={diffTimeoutMs} outputCap={diffOutputCap}"

  match ← (make malformed).diff "specs/broken-v1.yaml" "specs/broken-v2.yaml" with
  | .ok facts => fail s!"malformed: got {facts.length} facts"
  | .error err =>
    check (err.contains "not a spec") s!"malformed: {err}"
    check (err.contains notASpec) s!"malformed stderr: {err}"
    check (err != "failed") "malformed: generic failed"
    say s!"vimanam malformed {err}"

  match ← focusedContext contextProbe "old.yaml" "new.yaml" 1600 with
  | .ok _ => fail "context probe returned stdout"
  | .error err =>
    check (err.contains "not a spec") s!"context: {err}"
  say "vimanam context argv=--context --max-tokens"

  let missed ← try
    let _ ← src.diff "specs/missing-v1.yaml" "specs/missing-v2.yaml"
    pure none
  catch e =>
    pure (some (toString e))
  match missed with
  | none => fail "missing recording returned"
  | some msg =>
    check (msg == "no recording for specs/missing-v1.yaml specs/missing-v2.yaml") s!"miss: {msg}"
    say s!"vimanam miss={msg}"

#eval runChecks

end Kalari.Vimanam
