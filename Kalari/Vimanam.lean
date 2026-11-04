import Lean.Data.Json
import Kalari.Backend
import Kalari.Model
import Kalari.Proc

/-! ChangeSource over the `vimanam` CLI.

Two spec paths in, `List ChangeFact` out, from JSON contract v2
(`vimanam diff --format json`). The array is `changes[]`. Derived
`FromJson` on `ChangeFact` keeps `id` and `kind` and ignores every
other key, which is why a 2.1.0 object still parses. `ChangeFact` is
not widened with a path.

`vimanam diff --help` prints `vimanam diff [OPTIONS] [OLD] [NEW]`.
The two paths are the last arguments. There is no git-ref form. A
protobuf spec uses the same diff argv. There is no protobuf recording.

`--context` is GraphQL-only in 2.1.0. An OpenAPI diff fails with
"--context is GraphQL-only; OpenAPI and protobuf diffs do not support
it", and `--context` renders Markdown, so it is not combined with
`--format json`. `diff` has no other focused-context flag. A GraphQL
pair uses `vimanam diff --context --max-tokens <n> <old> <new>`,
matching `testdata/vimanam/2.1.0/settlements.context.md`. For REST,
focused context is that JSON diff: the change facts alone.

`make` takes a runner `(argv, timeoutMs, outputCap) → IO Proc.Result`.
A non-zero exit is an error whose text contains the stderr. `live`
binds `Proc.run` with an explicit `PATH` and `inheritEnv := false`.
The checks replay `testdata/vimanam/2.1.0` and do not call `live`. -/

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

/-- `.graphql` and `.graphqls` are the SDL suffixes 2.1.0 accepts.
`--context` is refused on every other format. -/
def isGraphQL (path : String) : Bool :=
  path.endsWith ".graphql" || path.endsWith ".graphqls"

/-- GraphQL: `--context --max-tokens` before the paths. Markdown, not JSON.
REST and protobuf: the JSON diff. Its stdout is the change facts. -/
def contextArgv (old new : String) (maxTokens : Nat) : List String :=
  if isGraphQL old && isGraphQL new then
    ["vimanam", "diff", "--context", "--max-tokens", toString maxTokens, old, new]
  else
    diffArgv old new

private def endsWithPaths (argv : List String) (old new : String) : Bool :=
  argv.dropLast.getLast? == some old && argv.getLast? == some new

#guard diffArgv "old.yaml" "new.yaml" ==
  ["vimanam", "diff", "--format", "json", "old.yaml", "new.yaml"]

#guard diffArgv "old.pb" "new.pb" ==
  ["vimanam", "diff", "--format", "json", "old.pb", "new.pb"]

#guard endsWithPaths (diffArgv "old.yaml" "new.yaml") "old.yaml" "new.yaml"

#guard isGraphQL "schema-v2.graphql" && isGraphQL "dir/a.graphqls"

#guard !isGraphQL "openapi-v2.yaml" && !isGraphQL "api.proto"

#guard contextArgv "old.yaml" "new.yaml" 2000 ==
  ["vimanam", "diff", "--format", "json", "old.yaml", "new.yaml"]

#guard contextArgv "old.yaml" "new.yaml" 1 == contextArgv "old.yaml" "new.yaml" 2000

#guard !(contextArgv "old.yaml" "new.yaml" 2000).contains "--context"

#guard !(contextArgv "old.proto" "new.proto" 2000).contains "--context"

#guard contextArgv "old.proto" "new.proto" 2000 == diffArgv "old.proto" "new.proto"

#guard contextArgv "old.graphql" "new.graphql" 2000 ==
  ["vimanam", "diff", "--context", "--max-tokens", "2000", "old.graphql", "new.graphql"]

#guard (contextArgv "old.graphql" "new.graphql" 2000).contains "--context"

#guard (contextArgv "old.graphql" "new.graphql" 2000).contains "--max-tokens"

#guard !(contextArgv "old.graphql" "new.graphql" 2000).contains "--format"

#guard endsWithPaths (contextArgv "old.yaml" "new.yaml" 1600) "old.yaml" "new.yaml"

#guard endsWithPaths (contextArgv "old.graphql" "new.graphql" 2000) "old.graphql" "new.graphql"

#guard !(isGraphQL "old.yaml" && isGraphQL "new.graphql")

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
GraphQL stdout is the Markdown report plus focused context.
REST stdout is the JSON diff: the change facts, with no `--context`. -/
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
`testdata/vimanam/2.1.0` and does not spawn `vimanam`. A recording it was
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

/-- Ids from `testdata/vimanam/2.1.0`. Not invented. -/
private def payoutsMoved : String :=
  "vc2_a604d335c9ac1b47b192a9f46eca61773f4ccd1db93a772f71808fbdb36b933c"

private def payoutsPagination : String :=
  "vc2_ff47bb628a187fbe4f28e53ef03a6231e2b22188bc0e84446306104ba37029d8"

private def settlementsPagination : String :=
  "vc2_25e58920a86bef7532571b31025312531a0b34db9a10e132ca13c4bea27f795d"

/-- Token budget on `settlements.context.md`. -/
private def contextTokens : Nat := 2000

/-- `id` and `kind` read off each `changes[]` object, not through `FromJson`. -/
private def recordedFacts (text : String) : Except String (List ChangeFact) := do
  let root ← Json.parse text
  let arr ← (← root.getObjVal? "changes").getArr?
  arr.toList.mapM fun item => do
    let id ← (← item.getObjVal? "id").getStr?
    let kind ← (← item.getObjVal? "kind").getStr?
    return { id, kind }

/-- `native.path` when it is a string. A null path (a bare `type_added`) is skipped. -/
private def kindPath (item : Json) : Option (String × String) :=
  match item.getObjVal? "kind" >>= Json.getStr? with
  | .error _ => none
  | .ok kind =>
    match item.getObjVal? "native" with
    | .error _ => none
    | .ok native =>
      match native.getObjVal? "path" >>= Json.getStr? with
      | .ok path => some (kind, path)
      | .error _ => none

private def nativePaths (text : String) : Except String (List (String × String)) := do
  let root ← Json.parse text
  let arr ← (← root.getObjVal? "changes").getArr?
  return arr.toList.filterMap kindPath

private def changeById (text id : String) : Except String Json := do
  let root ← Json.parse text
  let arr ← (← root.getObjVal? "changes").getArr?
  match arr.toList.find? fun item =>
      match item.getObjVal? "id" >>= Json.getStr? with
      | .ok s => s == id
      | .error _ => false with
  | some item => return item
  | none => throw s!"no change {id}"

private def nativePath (item : Json) : Except String String := do
  let native ← item.getObjVal? "native"
  (← native.getObjVal? "path").getStr?

private def detailStr (item : Json) (key : String) : Except String String := do
  let details ← item.getObjVal? "details"
  (← details.getObjVal? key).getStr?

private def readRecording (root : System.FilePath) (name : String) : IO String :=
  IO.FS.readFile (root / "testdata" / "vimanam" / "2.1.0" / name)

private def recordingPath (root : System.FilePath) (name : String) : System.FilePath :=
  root / "testdata" / "vimanam" / "2.1.0" / name

private structure Call where
  argv : List String
  timeoutMs : Nat
  outputCap : Nat
  deriving Repr, BEq

private def argvLine (argv : List String) : String :=
  String.intercalate " " argv

/-- The two 2.1.0 benchmark diffs, and the GraphQL context recording.
Anything else fails the build. REST context is the JSON diff, so it hits
the first arm. -/
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
      | ["vimanam", "diff", "--context", "--max-tokens", tokens, old, new] =>
        if old == settlementsOld && new == settlementsNew && tokens == toString contextTokens then
          pure "settlements.context.md"
        else
          fail s!"no recording for {argvLine argv}"
      | _ => fail s!"no recording for {argvLine argv}"
    let stdout ← IO.FS.readBinFile (recordingPath root name)
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

private def hasFact (facts : List ChangeFact) (id kind : String) : Bool :=
  facts.any fun f => f.id == id && f.kind == kind

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

/-- Records the GraphQL context argv, then the same non-zero exit. -/
private def contextProbe : Runner := fun argv timeoutMs outputCap => do
  unless argv == contextArgv "old.graphql" "new.graphql" 1600 do
    fail s!"context argv {argvLine argv}"
  unless argv.contains "--context" && argv.contains "--max-tokens" do
    fail s!"context flags {argvLine argv}"
  unless !(argv.contains "--format") do
    fail s!"context format {argvLine argv}"
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
  check (payouts.length == 11) "payouts: count"
  check (payouts == payoutsWant) "payouts: id and kind"
  check (hasFact payouts payoutsPagination "pagination_changed") "payouts: pagination_changed"
  check (hasFact payouts payoutsMoved "operation_moved") "payouts: operation_moved"
  let moved ← ofExcept (changeById payoutsText payoutsMoved)
  let movedKind ← ofExcept (moved.getObjVal? "kind" >>= Json.getStr?)
  let movedNew ← ofExcept (nativePath moved)
  let movedOld ← ofExcept (detailStr moved "old_path")
  check (movedKind == "operation_moved") "moved: kind"
  check (movedOld == "/v1/payouts") "moved: old_path"
  check (movedNew == "/v2/payouts") "moved: native.path"
  let page ← ofExcept (changeById payoutsText payoutsPagination)
  let pageKind ← ofExcept (page.getObjVal? "kind" >>= Json.getStr?)
  let pagePath ← ofExcept (nativePath page)
  check (pageKind == "pagination_changed") "pagination: kind"
  check (pagePath == "/v2/payouts") "pagination: native.path"
  let paths ← ofExcept (nativePaths payoutsText)
  check (paths.length == 10) "payouts: path count"
  check (paths.all fun (_, path) => path == "/v2/payouts") "payouts: inner paths"
  check (!(paths.any fun (_, path) => path == "/v1/payouts")) "payouts: old path absent"
  check (paths.any fun (kind, _) => kind == "argument_added") "payouts: argument on new path"
  check (paths.any fun (kind, _) => kind == "field_added") "payouts: field on new path"
  say s!"vimanam payouts n=11 pagination_changed={payoutsPagination}"
  say s!"vimanam moved old=/v1/payouts new=/v2/payouts id={payoutsMoved}"

  let settlementsText ← readRecording root "settlements.json"
  let settlementsWant ← ofExcept (recordedFacts settlementsText)
  let settlements ← expectOk "settlements" (← src.diff settlementsOld settlementsNew)
  check (settlements.length == 6) "settlements: count"
  check (settlements == settlementsWant) "settlements: id and kind"
  check (hasFact settlements settlementsPagination "pagination_changed") "settlements: pagination_changed"
  check (settlements.any (·.kind == "argument_added")) "settlements: argument_added"
  say s!"vimanam settlements n=6 pagination_changed={settlementsPagination}"

  match ← focusedContext (replay root calls) payoutsOld payoutsNew contextTokens with
  | .error err => fail s!"rest context: {err}"
  | .ok text =>
    check (text == payoutsText) "rest context: recording"
    let facts ← expectOk "rest context" (decodeChanges text)
    check (facts == payouts) "rest context: change facts"
    check (hasFact facts payoutsPagination "pagination_changed") "rest context: pagination_changed"
    check (!(contextArgv payoutsOld payoutsNew contextTokens).contains "--context") "rest context: no --context"
  say "vimanam rest context=facts"

  let contextWant ← readRecording root "settlements.context.md"
  match ← focusedContext (replay root calls) settlementsOld settlementsNew contextTokens with
  | .error err => fail s!"graphql context: {err}"
  | .ok text =>
    check (text == contextWant) "graphql context: settlements.context.md"
    check (text.contains "## Focused context") "graphql context: heading"
    check (text.contains "pagination_changed") "graphql context: pagination_changed"
  say "vimanam graphql context argv=--context --max-tokens"

  let log ← calls.get
  match log with
  | [c0, c1, c2, c3] =>
    check (c0.argv == diffArgv payoutsOld payoutsNew) "payouts argv"
    check (c0.timeoutMs == diffTimeoutMs && c0.outputCap == diffOutputCap) "payouts budget"
    check (c1.argv == diffArgv settlementsOld settlementsNew) "settlements argv"
    check (c1.timeoutMs == diffTimeoutMs && c1.outputCap == diffOutputCap) "settlements budget"
    check (endsWithPaths c0.argv payoutsOld payoutsNew) "payouts paths last"
    check (endsWithPaths c1.argv settlementsOld settlementsNew) "settlements paths last"
    check (c2.argv == diffArgv payoutsOld payoutsNew) "rest context argv"
    check (!(c2.argv.contains "--context")) "rest context argv has no --context"
    check (c2.timeoutMs == diffTimeoutMs && c2.outputCap == diffOutputCap) "rest context budget"
    check (c3.argv == contextArgv settlementsOld settlementsNew contextTokens) "graphql context argv"
    check (c3.argv.contains "--context" && c3.argv.contains "--max-tokens") "graphql context flags"
    check (!(c3.argv.contains "--format")) "graphql context is not json"
    check (endsWithPaths c3.argv settlementsOld settlementsNew) "graphql context paths last"
    check (c3.timeoutMs == diffTimeoutMs && c3.outputCap == diffOutputCap) "graphql context budget"
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

  match ← focusedContext contextProbe "old.graphql" "new.graphql" 1600 with
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
