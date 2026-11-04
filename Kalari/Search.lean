import Lean.Data.Json
import Std.Async.System
import Kalari.Clef
import Kalari.Model
import Kalari.Proc

/-! Code search from a change to the call sites in the consumer.

The operation is not on `ChangeFact`: that type keeps `id` and `kind` only.
REST searches the endpoint path, GraphQL the field, gRPC the RPC name.
`rg --json -F` runs through `Proc.run`. `live` passes an explicit `PATH`
and does not inherit the parent environment.

A line is certain when a match is the call. It is uncertain when the match
is in a comment, is only a substring of a longer name, or is not the call.
Uncertain lines are not counted. They are kept with the confirmer's noul.
`CallSite` has no line field: `path` is the file, and `detail` is the line
number, a colon, and the line text.

Source globs skip specs and guides. A schema line `settlements(` and a
guide's query sample are not the consumer. The checks run `rg`. They do
not spawn `vimanam`, `msb`, or `curl`, and they do not call Clef's `live`. -/

namespace Kalari.Search

open Lean
open Kalari.Model
open Kalari.Backend
open Kalari.Proc (Result Cap)

/-- What the changed operation is called in the consumer. -/
inductive Format where
  | rest
  | graphql
  | grpc
  deriving Repr, BEq

/-- The text `rg` looks for. `name` is a path, a field, or an RPC name. -/
structure Operation where
  format : Format
  name : String
  deriving Repr, BEq

/-- An `rg` hit that is not the call, with the confirmer's noul. -/
structure UncertainHit where
  site : CallSite
  probability : Float
  deriving Repr

/-- Counted call sites, and the uncertain hits beside them. -/
structure Report where
  radius : BlastRadius
  uncertain : List UncertainHit
  deriving Repr

/-- `(argv, timeoutMs, outputCap)`. `live` binds this to `Proc.run`. -/
abbrev Runner :=
  (argv : List String) → (timeoutMs : Nat) → (outputCap : Nat) → IO Result

/-- One noul per uncertain hit. The checks pass a stub that does not call curl. -/
abbrev Confirmer :=
  (change : String) → (hits : List (String × String)) →
    IO (Except String (List (String × Float)))

/-- Local `rg` on a consumer tree. No matches still returns within this. -/
def searchTimeoutMs : Nat := 10000

/-- One mebibyte. A consumer tree's match list fits. -/
def searchOutputCap : Nat := 1048576

#guard searchTimeoutMs == 10000
#guard searchOutputCap == 1048576

/-- Code only. Specs and guides name the same operation and are not calls. -/
def sourceGlobs : List String := [
  "*.py", "*.pyi", "*.go", "*.rs", "*.java", "*.kt", "*.scala",
  "*.js", "*.jsx", "*.ts", "*.tsx", "*.rb", "*.php", "*.cs", "*.swift",
  "*.cpp", "*.cc", "*.c", "*.h", "*.hpp"
]

/-- Fixed string, JSON events, source globs, then the root. -/
def rgArgv (needle root : String) : List String :=
  ["rg", "--json", "-F", "--color", "never"]
    ++ sourceGlobs.flatMap (fun g => ["--glob", g])
    ++ ["-e", needle, "--", root]

#guard (rgArgv "/v1/payouts" "root").head? == some "rg"
#guard (rgArgv "/v1/payouts" "root").contains "--json"
#guard (rgArgv "/v1/payouts" "root").contains "-F"
#guard (rgArgv "/v1/payouts" "root").contains "*.py"
#guard (rgArgv "/v1/payouts" "root").contains "*.go"
#guard !(rgArgv "/v1/payouts" "root").contains "*.md"
#guard !(rgArgv "/v1/payouts" "root").contains "*.graphql"
#guard !(rgArgv "/v1/payouts" "root").contains "*.yaml"
#guard !(rgArgv "/v1/payouts" "root").contains "*.proto"
#guard (rgArgv "settlements" "root").getLast? == some "root"
#guard (rgArgv "GetLedger" "root").contains "-e"

/-- `path` is the child's whole `PATH`. Without it, `rg` is not found. -/
def live (path : String) : Runner := fun argv timeoutMs outputCap =>
  Kalari.Proc.run argv (env := #[("PATH", some path)]) (inheritEnv := false)
    (stdin := none) (timeoutMs := timeoutMs) (outputCap := outputCap)

/-- `callsChangedOperation`, keeping only a noul list. -/
def clefConfirmer (runner : Kalari.Clef.Runner) (delay : Kalari.Clef.Delay) (keyEnv : String) :
    Confirmer :=
  fun change hits => do
    match ← Kalari.Clef.callsChangedOperation runner delay keyEnv change hits with
    | .error e => return .error e
    | .ok (.probabilities ps) => return .ok ps
    | .ok (.label ..) => return .error "search: confirmer did not return noul probabilities"
    | .ok (.error status message) =>
      return .error s!"search: confirmer status {status}: {message}"

private def formatName : Format → String
  | .rest => "rest"
  | .graphql => "graphql"
  | .grpc => "grpc"

private def changeText (change : ChangeFact) (op : Operation) : String :=
  s!"{change.id} {change.kind} {formatName op.format} {op.name}"

private def bytesText (b : ByteArray) : String :=
  match String.fromUTF8? b with
  | some s => s
  | none => ""

/-- Exit 1 is no matches. Empty stdout is not an empty hit list. -/
private def textOf (r : Result) : Except String String :=
  match r.cap with
  | .timeout => .error "search: timeout"
  | .output => .error "search: output cap"
  | .none =>
    match r.exitCode with
    | none => .error "search: no exit"
    | some code =>
      if code == 0 || code == 1 then
        match String.fromUTF8? r.stdout with
        | none => .error "search: stdout is not utf-8"
        | some s =>
          if s.trimAscii.toString.isEmpty then
            .error "search: rg produced no output"
          else
            .ok s
      else
        let err := (bytesText r.stderr).trimAscii.toString
        if err.isEmpty then .error s!"search: rg exited {code}"
        else .error s!"search: rg exited {code}: {err}"

private def stripNl (s : String) : String :=
  if s.endsWith "\n" then
    (s.toSlice.dropEnd 1).toString
  else
    s

private structure Raw where
  path : String
  line : Nat
  text : String
  spans : List (Nat × Nat)

private def parseOne (j : Json) : Except String (Option Raw) := do
  let typ ← (← j.getObjVal? "type").getStr?
  if typ != "match" then
    return none
  let data ← j.getObjVal? "data"
  let path ← (← (← data.getObjVal? "path").getObjVal? "text").getStr?
  let text ← (← (← data.getObjVal? "lines").getObjVal? "text").getStr?
  let line ← (← data.getObjVal? "line_number").getNat?
  let arr ← (← data.getObjVal? "submatches").getArr?
  let spans ← arr.toList.mapM fun sm => do
    let start ← (← sm.getObjVal? "start").getNat?
    let stop ← (← sm.getObjVal? "end").getNat?
    return (start, stop)
  return some { path, line, text := stripNl text, spans }

private def parseHits (text : String) : Except String (List Raw) :=
  let rec go : List String → Except String (List Raw)
    | [] => .ok []
    | line :: rest => do
      let tail ← go rest
      if line.isEmpty then
        return tail
      match ← parseOne (← Json.parse line) with
      | none => return tail
      | some raw => return raw :: tail
  go (text.splitOn "\n")

private def isNameByte (b : UInt8) : Bool :=
  let n := b.toNat
  (n >= 48 && n <= 57) || (n >= 65 && n <= 90) || (n >= 97 && n <= 122) || n == 95 || n == 45

/-- A REST path continues through `/`, `.`, `~`, and `%` as well as a name. -/
private def isPathByte (b : UInt8) : Bool :=
  let n := b.toNat
  isNameByte b || n == 47 || n == 46 || n == 126 || n == 37

private def byteAt (line : String) (i : Nat) : Option UInt8 :=
  line.toUTF8[i]?

private def continues (format : Format) (b : UInt8) : Bool :=
  match format with
  | .rest => isPathByte b
  | .graphql => isNameByte b
  | .grpc => isNameByte b

/-- The match is a prefix or suffix of a longer name or path. -/
private def longer (format : Format) (line : String) (start stop : Nat) : Bool :=
  let prev := if start = 0 then none else byteAt line (start - 1)
  let next := byteAt line stop
  (match prev with | some b => continues format b | none => false) ||
    (match next with | some b => continues format b | none => false)

private def atChar (line : String) (i : Nat) (c : Char) : Bool :=
  String.Pos.Raw.get? line ⟨i⟩ == some c

private def tripleAt (line : String) (i : Nat) (c : Char) : Bool :=
  atChar line i c && atChar line (i + 1) c && atChar line (i + 2) c

private inductive Zone where
  | code
  | comment
  | string
  deriving BEq

/-- Where byte `start` sits. A `#` or `//` before it, outside a string, is a comment. -/
private def zoneAt (line : String) (start : Nat) : Zone :=
  let rec go (fuel i : Nat) (q : Option Char) (triple esc : Bool) : Zone :=
    match fuel with
    | 0 => if q.isSome then .string else .code
    | fuel + 1 =>
      if i >= start || i >= line.utf8ByteSize then
        if q.isSome then .string else .code
      else
        match String.Pos.Raw.get? line ⟨i⟩ with
        | none => go fuel (i + 1) q triple false
        | some c =>
          let step := i + c.utf8Size
          if esc then
            go fuel step q triple false
          else if triple then
            match q with
            | none => .code
            | some qc =>
              if c == qc && tripleAt line i qc then
                go fuel (i + 3) none false false
              else if c == '\\' then
                go fuel step q true true
              else
                go fuel step q true false
          else
            match q with
            | some qc =>
              if c == '\\' then
                go fuel step q false true
              else if c == qc then
                go fuel step none false false
              else
                go fuel step q false false
            | none =>
              if c == '#' || (c == '/' && atChar line (i + 1) '/') then
                .comment
              else if (c == '"' || c == '\'') && tripleAt line i c then
                go fuel (i + 3) (some c) true false
              else if c == '"' || c == '\'' then
                go fuel step (some c) false false
              else
                go fuel step none false false
  go (line.utf8ByteSize + 1) 0 none false false

private def nextNonWs (line : String) (i : Nat) : Option Char :=
  let rec go (fuel j : Nat) : Option Char :=
    match fuel with
    | 0 => none
    | fuel + 1 =>
      if j >= line.utf8ByteSize then
        none
      else
        match String.Pos.Raw.get? line ⟨j⟩ with
        | none => go fuel (j + 1)
        | some c =>
          if c == ' ' || c == '\t' || c == '\r' then
            go fuel (j + c.utf8Size)
          else
            some c
  go (line.utf8ByteSize + 1) i

private def restMarks : List String := [
  "urlopen", "urllib", "requests.", "httpx", "axios", "fetch(",
  ".get(", ".post(", ".put(", ".delete(", ".patch(",
  "http.Client", "http.NewRequest", "Request("
]

private def hasRestMark (line : String) : Bool :=
  restMarks.any (fun m => line.contains m)

private def selects (line : String) (stop : Nat) : Bool :=
  match nextNonWs line stop with
  | some '{' => true
  | some '(' => true
  | _ => false

/-- A span is the call for this format. A comment or a longer name is not. -/
private def spanIsCall (format : Format) (line : String) (start stop : Nat) : Bool :=
  match zoneAt line start with
  | .comment => false
  | zone =>
    if longer format line start stop then
      false
    else
      match format with
      | .rest => zone == .string && hasRestMark line
      | .graphql => zone == .string && selects line stop
      | .grpc => zone == .code && nextNonWs line stop == some '('

private def spansOf (hay needle : String) : List (Nat × Nat) :=
  if needle.isEmpty then
    []
  else
    let rec go (parts : List String) (i : Nat) : List (Nat × Nat) :=
      match parts with
      | [] => []
      | [_] => []
      | p :: rest =>
        let start := i + p.utf8ByteSize
        let stop := start + needle.utf8ByteSize
        (start, stop) :: go rest stop
    go (hay.splitOn needle) 0

private def isCall (format : Format) (needle line : String) : Bool :=
  (spansOf line needle).any fun (start, stop) => spanIsCall format line start stop

private def payoutLine : String :=
  "    with urllib.request.urlopen(f\"{base_url}/v1/payouts\", timeout=30) as resp:"

private def queryLine : String :=
  "QUERY = \"{ settlements { id batchDate amountCents currency status } }\""

private def docLine : String :=
  "\"\"\"Copy every settlement from the Clearwell Settlements API into settlements.jsonl.\"\"\""

private def outLine : String :=
  "    ap.add_argument(\"--out\", default=\"settlements.jsonl\")"

private def dictLine : String :=
  "    settlements = graphql(f\"{args.base_url.rstrip('/')}/v1/graphql\", QUERY)[\"settlements\"]"

private def forLine : String :=
  "        for s in settlements:"

private def printLine : String :=
  "    print(f\"reconciled {len(settlements)} settlements\")"

private def commentLine : String :=
  "# The v1 route is /v1/ledger and this comment is not a call."

private def ledgerLine : String :=
  "    with urllib.request.urlopen(f\"{base_url}/v1/ledger\", timeout=30) as resp:"

private def similarLine : String :=
  "QUERY = \"{ /v1/ledgerItems { id } }\""

private def grpcLine : String :=
  "stub.GetLedger(ctx, req)"

#guard isCall .rest "/v1/payouts" payoutLine
#guard !isCall .rest "/v1/payouts" "  /v1/payouts:"
#guard !isCall .rest "/v1/payouts" "# with urllib.request.urlopen(\"/v1/payouts\")"
#guard !isCall .rest "/v1/payouts" "with urllib.request.urlopen(f\"{base_url}/v1/payoutsExport\") as resp:"
#guard isCall .graphql "settlements" queryLine
#guard !isCall .graphql "settlements" docLine
#guard !isCall .graphql "settlements" outLine
#guard !isCall .graphql "settlements" dictLine
#guard !isCall .graphql "settlements" forLine
#guard !isCall .graphql "settlements" printLine
#guard !isCall .graphql "settlements" "  settlements(first: Int = 50, after: String): SettlementConnection!"
#guard !isCall .graphql "settlements" "  settlements(first: 50, after: $after) {"
#guard isCall .rest "/v1/ledger" ledgerLine
#guard !isCall .rest "/v1/ledger" commentLine
#guard !isCall .rest "/v1/ledger" similarLine
#guard isCall .grpc "GetLedger" grpcLine
#guard !isCall .grpc "GetLedger" "stub.GetLedgerExtra(ctx, req)"
#guard !isCall .grpc "GetLedger" "// stub.GetLedger(ctx, req)"
#guard (spansOf payoutLine "/v1/payouts").length == 1
#guard (spansOf dictLine "settlements").length == 2
#guard (spansOf printLine "settlements").length == 2
#guard (spansOf commentLine "/v1/ledger").length == 1
#guard (spansOf similarLine "/v1/ledger").length == 1

private def lineIsCall (format : Format) (raw : Raw) : Bool :=
  raw.spans.any fun (start, stop) => spanIsCall format raw.text start stop

private def before (a b : Raw) : Bool :=
  a.path < b.path || (a.path == b.path && a.line <= b.line)

private def insertRaw (x : Raw) : List Raw → List Raw
  | [] => [x]
  | y :: ys => if before x y then x :: y :: ys else y :: insertRaw x ys

private def sortRaws (xs : List Raw) : List Raw :=
  xs.foldl (fun acc x => insertRaw x acc) []

private def siteOf (raw : Raw) : CallSite :=
  { path := raw.path, detail := some s!"{raw.line}: {raw.text}" }

private def named (raws : List Raw) : List (String × String) :=
  let rec go : List Raw → Nat → List (String × String)
    | [], _ => []
    | r :: rs, i => (s!"h{i}", s!"{r.path}:{r.line}: {r.text}") :: go rs (i + 1)
  go raws 0

private def attach (raws : List Raw) (ps : List (String × Float)) :
    Except String (List UncertainHit) :=
  let rec go : List Raw → Nat → Except String (List UncertainHit)
    | [], _ => .ok []
    | r :: rs, i => do
      let name := s!"h{i}"
      let p ← match ps.lookup name with
        | some p => pure p
        | none => throw s!"search: no probability for {name}"
      let rest ← go rs (i + 1)
      return { site := siteOf r, probability := p } :: rest
  go raws 0

private def confirmHits (confirm : Confirmer) (change : String) (raws : List Raw) :
    IO (Except String (List UncertainHit)) := do
  if raws.isEmpty then
    return .ok []
  match ← confirm change (named raws) with
  | .error e => return .error e
  | .ok ps => return attach raws ps

/-- Search `root` for `op`. Counted hits are the call. Uncertain hits keep a noul. -/
def search (runner : Runner) (confirm : Confirmer) (change : ChangeFact) (op : Operation)
    (root : String) : IO (Except String Report) := do
  if op.name.isEmpty then
    return .error "search: no operation"
  let r ← runner (rgArgv op.name root) searchTimeoutMs searchOutputCap
  match textOf r with
  | .error e => return .error e
  | .ok text =>
    match parseHits text with
    | .error e => return .error e
    | .ok raws =>
      let raws := sortRaws raws
      let mut yes : List Raw := []
      let mut no : List Raw := []
      for raw in raws do
        if lineIsCall op.format raw then
          yes := yes ++ [raw]
        else
          no := no ++ [raw]
      match ← confirmHits confirm (changeText change op) no with
      | .error e => return .error e
      | .ok uncertain =>
        return .ok {
          radius := { change_id := change.id, call_sites := yes.map siteOf }
          uncertain
        }

/-! The checks below run during `lake build`. They run `rg` through `live`.
The confirmer is `clefConfirmer` with a stub runner: `callsChangedOperation`
sees a noul body and curl is not spawned. A missing `rg`, or a directory
`rg` cannot read, fails the build. It is not an empty radius. -/

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

private def quarter : Float :=
  match Json.parse "{\"noul\":0.25}" >>= fun j => (j.getObjVal? "noul") >>= Float.fromJson? with
  | .ok p => p
  | .error _ => 0.0

#guard quarter != 0.0

private def stubKey : String := "stub-not-a-key"

private def stubKeyEnv : String := "KALARI_SEARCH_STUB_KEY"

private def payoutsChange : ChangeFact := {
  id := "vc2_c8668fd9e15e5092fdae689188a12455975deddd2b05c2a5d84f32c00619c647"
  kind := "operation_removed"
}

private def payoutsOp : Operation := { format := .rest, name := "/v1/payouts" }

private def settlementsChange : ChangeFact := {
  id := "vc2_dde51ee2d28bb72d0fd21f638732d9c9e55a0db75d890c9b5d8b153b4d424081"
  kind := "field_type_changed"
}

private def settlementsOp : Operation := { format := .graphql, name := "settlements" }

private def bodyArg (argv : List String) : Except String String :=
  match argv with
  | [] => .error "search: confirmer body missing"
  | "--data-binary" :: arg :: _ =>
    if arg.startsWith "@" && arg.length > 1 then
      .ok (arg.toSlice.drop 1).toString
    else
      .error "search: confirmer body is not a file"
  | _ :: rest => bodyArg rest

private def questionNames (text : String) : Except String (List String) := do
  let j ← Json.parse text
  let qs ← j.getObjVal? "questions"
  let obj ← qs.getObj?
  return obj.toList.map (·.1)

private def noulJson (names : List String) : String :=
  let items := names.map fun n =>
    "\"" ++ n ++ "\":{\"type\":\"noul\",\"noul\":0.25}"
  "{\"model\":\"clef\",\"answers\":{" ++ String.intercalate "," items ++ "}}"

private def framed (body : String) : String :=
  body ++ "\n" ++ Kalari.Clef.statusMark ++ "\n200\n"

/-- Answers `callsChangedOperation` from the request body. Does not spawn curl. -/
private def stubRunner (calls : IO.Ref Nat) : Kalari.Clef.Runner :=
  fun argv stdin timeoutMs outputCap => do
    if argv.any (fun a => a.contains stubKey) then
      fail "search: key appeared in an argv element"
    match String.fromUTF8? stdin with
    | none => fail "search: confirmer stdin is not utf-8"
    | some config =>
      unless config.contains stubKey do
        fail "search: confirmer stdin did not carry the key"
    unless timeoutMs == Kalari.Clef.requestTimeoutMs && outputCap == Kalari.Clef.responseCap do
      fail s!"search: confirmer budget {timeoutMs} {outputCap}"
    unless argv.head? == some "curl" do
      fail "search: confirmer argv is not the clef shape"
    let path ← ofExcept (bodyArg argv)
    let names ← ofExcept (questionNames (← IO.FS.readFile path))
    calls.modify (· + 1)
    return {
      exitCode := some 0
      stdout := (framed (noulJson names)).toUTF8
      stderr := ByteArray.empty
      wallMs := 0
      cap := Cap.none
    }

private def watched (inner : Runner) (cmds : IO.Ref (List String)) : Runner :=
  fun argv timeoutMs outputCap => do
    cmds.modify (· ++ [argv.headD ""])
    unless argv.head? == some "rg" do
      fail s!"search: runner command {argv.headD ""}"
    if argv.any (fun a => a == "vimanam" || a == "msb" || a == "curl") then
      fail "search: runner argv names vimanam, msb, or curl"
    inner argv timeoutMs outputCap

private def expect (name : String) (e : Except String Report) : IO Report := do
  match e with
  | .ok r => return r
  | .error err => fail s!"{name}: {err}"

private def lineOf (site : CallSite) : Option Nat :=
  match site.detail with
  | none => none
  | some d =>
    match d.splitOn ":" with
    | n :: _ => n.trimAscii.toString.toNat?
    | [] => none

private def detailText (site : CallSite) : String :=
  site.detail.getD ""

private def onlySite (name : String) (r : Report) : IO CallSite := do
  match r.radius.call_sites with
  | [s] =>
    check s.detail.isSome s!"{name}: detail"
    return s
  | ss => fail s!"{name}: counted {ss.length}"

private def notCounted (name : String) (r : Report) : IO Unit := do
  for u in r.uncertain do
    if r.radius.call_sites.any (fun s => s.path == u.site.path && s.detail == u.site.detail) then
      fail s!"{name}: uncertain hit was counted"
    check (toString u.probability == toString quarter) s!"{name}: probability {u.probability}"

private def showReport (name : String) (r : Report) : IO Unit := do
  for s in r.radius.call_sites do
    say s!"search {name} counted file={s.path} detail={detailText s}"
  if r.uncertain.isEmpty then
    say s!"search {name} uncertain=0"
  for u in r.uncertain do
    say s!"search {name} uncertain probability={u.probability} file={u.site.path} detail={detailText u.site}"

private def runChecks : IO Unit := do
  let root ← repoRoot
  let saved ← IO.getEnv stubKeyEnv
  try
    Std.Async.System.setEnvVar stubKeyEnv stubKey
    unless (← IO.currentDir).toString == root.toString do
      fail "search: cwd is not the repo root"
    let path ← match ← IO.getEnv "PATH" with
      | some p => if p.isEmpty then fail "search: PATH is not set" else pure p
      | none => fail "search: PATH is not set"
    let cmds ← IO.mkRef ([] : List String)
    let clefCalls ← IO.mkRef 0
    let runner := watched (live path) cmds
    let confirm := clefConfirmer (stubRunner clefCalls) (fun _ => pure ()) stubKeyEnv

    let pay ← expect "payouts" (← search runner confirm payoutsChange payoutsOp
      "bench/workspaces/payout-sync")
    let paySite ← onlySite "payouts" pay
    check (paySite.path == "bench/workspaces/payout-sync/payout_sync.py") s!"payouts path {paySite.path}"
    check (lineOf paySite == some 8) "payouts line"
    check ((detailText paySite).contains "/v1/payouts") "payouts path text"
    check ((detailText paySite).contains "urlopen") "payouts urlopen"
    check pay.uncertain.isEmpty "payouts uncertain"
    check (pay.radius.change_id == payoutsChange.id) "payouts change id"
    showReport "payouts" pay

    let setl ← expect "settlements" (← search runner confirm settlementsChange settlementsOp
      "bench/workspaces/settlement-reconcile")
    let setlSite ← onlySite "settlements" setl
    check (setlSite.path == "bench/workspaces/settlement-reconcile/settlement_reconcile.py")
      s!"settlements path {setlSite.path}"
    check (lineOf setlSite == some 6) "settlements line"
    check ((detailText setlSite).contains "settlements {") "settlements field"
    check (setl.uncertain.length == 5) s!"settlements uncertain {setl.uncertain.length}"
    let lines := setl.uncertain.filterMap (fun u => lineOf u.site)
    check (lines == [1, 22, 24, 26, 28]) s!"settlements uncertain lines {lines}"
    check (setl.radius.change_id == settlementsChange.id) "settlements change id"
    notCounted "settlements" setl
    showReport "settlements" setl

    let decoy ← expect "decoy" (← search runner confirm
      { id := "decoy", kind := "operation_removed" }
      { format := .rest, name := "/v1/ledger" }
      "testdata/search")
    let decoySite ← onlySite "decoy" decoy
    check (decoySite.path == "testdata/search/decoy.py") s!"decoy path {decoySite.path}"
    check (lineOf decoySite == some 3) "decoy line"
    check ((detailText decoySite).contains "urlopen") "decoy call"
    check ((detailText decoySite).contains "/v1/ledger") "decoy path text"
    check (not ((detailText decoySite).contains "ledgerItems")) "decoy counted the similar name"
    check (decoy.uncertain.length == 2) s!"decoy uncertain {decoy.uncertain.length}"
    check (decoy.uncertain.any (fun u => (detailText u.site).contains "this comment is not a call"))
      "decoy comment"
    check (decoy.uncertain.any (fun u => (detailText u.site).contains "ledgerItems"))
      "decoy similar"
    notCounted "decoy" decoy
    showReport "decoy" decoy

    let grpc ← expect "grpc" (← search runner confirm
      { id := "grpc", kind := "operation_removed" }
      { format := .grpc, name := "GetLedger" }
      "testdata/search")
    let grpcSite ← onlySite "grpc" grpc
    check (grpcSite.path == "testdata/search/grpc_call.go") s!"grpc path {grpcSite.path}"
    check (lineOf grpcSite == some 1) "grpc line"
    check ((detailText grpcSite).contains "GetLedger(") "grpc call"
    check grpc.uncertain.isEmpty "grpc uncertain"
    check (grpc.radius.change_id == "grpc") "grpc change id"
    showReport "grpc" grpc

    match ← search runner confirm { id := "x", kind := "k" } { format := .rest, name := "" }
        "testdata/search" with
    | .ok _ => fail "empty operation returned a radius"
    | .error e => check (e == "search: no operation") s!"empty: {e}"

    match ← search runner confirm { id := "x", kind := "k" } payoutsOp "testdata/search/no-such-dir" with
    | .ok _ => fail "missing dir returned a radius"
    | .error e => check (e.startsWith "search: rg exited") s!"missing dir: {e}"

    check ((← cmds.get) == ["rg", "rg", "rg", "rg", "rg"]) "runner commands"
    check ((← clefCalls.get) == 2) "confirmer calls"
    say "search confirmer calls=2 noul=0.25"
  finally
    match saved with
    | some v => Std.Async.System.setEnvVar stubKeyEnv v
    | none => Std.Async.System.unsetEnvVar stubKeyEnv

#eval runChecks

end Kalari.Search
