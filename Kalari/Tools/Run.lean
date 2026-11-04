import Kalari.Evidence
import Kalari.Gate
import Kalari.Sandbox.Microsandbox
import Std.Net.Addr
import Std.Data.HashMap

/-! Contained consumer runs and mandatory migration checks. -/

namespace Kalari.Tools.Run

open Lean Kalari.Model Kalari.Proc
open Kalari.Sandbox

private def guestWorkspace := "/workspace"
private def supervisor := "/usr/local/bin/kalari-aashaan"
private def artifactCap := 4 * 1024 * 1024

/-- A trusted host starts a dedicated observed API for this run and returns a
closure that stops it and reads its bounded trace. The service must ensure the
candidate actually targets that instance; this is never supplied by an agent. -/
abbrev Observer := String → IO (Except String (IO (Except String String)))

private structure PageEvent where
  request : String
  response : String
  first : String
  last : String
  count : Nat
  ids : List String
  drained : Bool
  deriving FromJson

/-- Validate one complete, unbranched cursor chain. A response is evidence of
what the API sent, not of how the consumer used it. -/
def pageObservations (trace : String) : Except String (List String) := do
  if trace.utf8ByteSize > 262144 || !trace.endsWith "\n" then throw "missing, truncated or oversized page trace"
  let lines := (trace.splitOn "\n").dropLast
  if lines.isEmpty || lines.length > 256 then throw "empty or oversized page trace"
  let events ← lines.mapM fun line => Json.parse line >>= (fromJson? (α := PageEvent))
  let mut previous := ""
  let mut previousIds : List String := []
  let mut overlap := false
  let mut terminal := false
  let mut seen : List String := []
  for event in events do
    if terminal || event.request != previous || event.response.isEmpty || seen.contains event.response || event.count == 0 || event.first.isEmpty || event.last.isEmpty then
      throw "ambiguous or incomplete page trace"
    if event.ids.length != event.count || event.ids.eraseDups.length != event.ids.length ||
        event.ids.head? != some event.first || event.ids.getLast? != some event.last then
      throw "invalid page IDs"
    if !previous.isEmpty then
      let repeated := event.ids.filter previousIds.contains
      if repeated.length == 1 && repeated.head? == previousIds.getLast? && repeated.head? == some event.first then overlap := true
    seen := event.response :: seen
    previous := event.response
    previousIds := event.ids
    terminal := event.drained
  unless terminal do throw "page trace has no drained response"
  return (if overlap then ["boundary_overlap_one"] else []) ++ ["final_page_token"]

/-- Session-owned inputs. The candidate and baseline workspace paths point to
separate prepared consumer trees; `checkWorkspace` points to a host-owned tree
of trusted lesson-check programs. The baseline is pristine and targets v1 of
the same dataset. Each consumer writes `artifact`, a JSONL file at the root of
its guest workspace. None of these settings or the recalled checks come from
the tool arguments. -/
structure Context where
  workspace : String
  baseline : RunRequest
  /-- Host-owned directory containing trusted lesson-check programs. -/
  checkWorkspace : String
  artifact : String
  checks : List Check
  maxCaps : Caps
  allowedNet : List AllowHost
  secrets : List String
  image : String := Microsandbox.imageName
  aashaanHost : String
  evidence : Kalari.Evidence.Store
  sessionId : String
  changeKinds : List String
  observer : Option Observer := none

/-- External operations can replay through the same orchestration as live runs. -/
structure Runtime where
  runner : Microsandbox.Runner
  resolve : String → IO (List String)
  wait : Nat → IO Unit := fun ms => IO.sleep ms.toUInt32

/-- Run commands with the storage permissions msb expects and no inherited keys. -/
def live (path : String) : Runtime :=
  let run := Microsandbox.live path
  { runner := fun argv =>
      let argv := match argv with
        | "msb" :: "exec" :: rest => ["msb", "exec", "--quiet", "--no-tty", "--no-stdin"] ++ rest
        | _ => argv
      run (["/bin/sh", "-c", "umask 022; exec \"$@\"", "sh"] ++ argv)
    resolve := fun host => do
      let result ← run ["getent", "ahostsv4", host] 5000 16384
      if result.cap != .none || result.exitCode != some 0 then return []
      let lines := ((String.fromUTF8? result.stdout).getD "").splitOn "\n"
      return lines.map fun line => (line.splitOn " ").headD "" }

structure Difference where
  missing : Nat
  extra : Nat
  duplicates : Nat
  changed : Nat
  deriving BEq, Repr

private abbrev Records := Std.HashMap String (Json × Nat)

private def readRecords (data : String) : Except String Records := do
  let mut records : Records := {}
  for line in data.splitOn "\n" do
    if !line.trimAscii.isEmpty then
      let row ← (Json.parse line).mapError fun _ => "invalid JSONL record"
      let id ← (row.getObjValAs? String "id").mapError fun _ => "record has no string ID"
      if id.isEmpty then throw "record has an empty ID"
      records := records.insert id (row, (records[id]?.map Prod.snd).getD 0 + 1)
  return records

/-- Compare full records by ID, counting duplicate deliveries beyond the first. -/
def compareRecords (baseline candidate : String) : Except String Difference := do
  let expected ← readRecords baseline
  let actual ← readRecords candidate
  unless expected.toList.all (fun (_, _, count) => count == 1) do
    throw "v1 returned duplicate IDs"
  let missing := expected.toList.countP fun (id, _) => !actual.contains id
  let extra := actual.toList.countP fun (id, _) => !expected.contains id
  let duplicates := actual.fold (fun n _ (_, count) => n + (count - 1)) 0
  let changed := actual.toList.countP fun (id, record, _) =>
    (expected[id]?.map fun (old, _) => old != record).getD false
  return { missing, extra, duplicates, changed }

private def Difference.passed (d : Difference) : Bool :=
  d == ⟨0, 0, 0, 0⟩

private def Difference.summary (d : Difference) : String :=
  s!"{d.missing} missing, {d.extra} extra, {d.duplicates} duplicates, {d.changed} changed"

private def differentialId := "differential-v1"

private def permit (ctx : Context) (request : RunRequest) : Except String Unit := do
  let (allowed, reason) := Gate.decide request ctx.maxCaps ctx.allowedNet ctx.secrets
  unless allowed do throw s!"refused: {reason.getD "gate"}"
  if request.command.isEmpty || request.command.headD "" == "" then throw "refused: empty command"
  if request.caps.timeout_ms == 0 || request.caps.memory_mib == 0 then throw "refused: caps"
  if (request.workspace :: request.command).any (·.contains '\x00') then throw "refused: invalid argument"

private def admit (ctx : Context) (request : RunRequest) : Except String Unit := do
  unless request.workspace == ctx.workspace do throw "refused: workspace"
  permit ctx request
  permit ctx ctx.baseline
  if ctx.baseline.workspace == ctx.workspace then throw "setup: v1 requires a separate workspace"
  if ctx.checkWorkspace.isEmpty || ctx.checkWorkspace == ctx.workspace ||
      ctx.checkWorkspace == ctx.baseline.workspace then
    throw "setup: checks require a separate trusted workspace"
  unless Gate.segmentOk ctx.artifact && ctx.artifact.toList.all
      (fun c => c.isAlphanum || c == '.' || c == '-' || c == '_') do
    throw "setup: invalid JSONL artifact name"
  for check in ctx.checks do
    permit ctx { request with workspace := ctx.checkWorkspace, command := check.command }

private def resolveAllowlist (runtime : Runtime) (hosts : List AllowHost) :
    ExceptT String IO (List AllowHost) := do
  let mut rules := []
  for entry in hosts do
    unless entry.port > 0 && entry.port <= 65535 && !entry.host.isEmpty &&
        entry.host.toList.all (fun c => c.isAlphanum || c == '.' || c == '-') &&
        !entry.host.startsWith "-" do
      throw "setup: invalid API host or port"
    let answers ← match Std.Net.IPv4Addr.ofString entry.host with
      | some ip => pure [toString ip]
      | none => runtime.resolve entry.host
    let ips := answers.filterMap Std.Net.IPv4Addr.ofString
    if ips.isEmpty then throw "setup: API host has no IPv4 address"
    rules := rules ++ ips.map fun ip => { entry with host := toString ip }
  return rules.eraseDups

private def successful (v : Verdict) : Bool :=
  v.verdict == "exited" && v.exit_code == some 0 && !v.pipe_held_open && !v.stdout_truncated

private def summary (v : Verdict) : String :=
  match v.verdict with
  | "killed_timeout" => "The aashaan killed the run when it reached the time cap."
  | "killed_output_cap" => "The aashaan killed the run when it reached the output cap."
  | _ => s!"Exited with code {v.exit_code.getD 1}."

private def scrub (secrets : List String) (s : String) : String :=
  secrets.foldl (fun acc key => if key.isEmpty then acc else acc.replace key "[redacted]") s

private def clip (bytes : Nat) (s : String) : String :=
  let raw := s.toUTF8
  if raw.size <= bytes then s
  else ((List.range 4).findSome? fun n => String.fromUTF8? (raw.extract 0 (bytes - n))).getD ""

private def execOk (backend : Kalari.Backend.SandboxBackend) (name stage : String)
    (command : List String) : ExceptT String IO Result := do
  let result : Except String Result ← liftM (backend.exec name command)
  match result with
  | .ok r =>
    if r.cap == .none && r.exitCode == some 0 then return r
    throw s!"sandbox {stage}: msb exec failed"
  | .error _ => throw s!"sandbox {stage}: msb exec failed"

private def requireStep (stage : String) (result : Except String Result) : ExceptT String IO Unit :=
  match result with
  | .ok r =>
    if r.cap == .none && r.exitCode == some 0 then pure ()
    else throw s!"sandbox {stage} failed"
  | .error _ => throw s!"sandbox {stage} failed"

private def cleanupFailure : Result :=
  { cap := .none, exitCode := some 1, stdout := ByteArray.empty,
    stderr := ByteArray.empty, wallMs := 0 }

private def duplicateCreate (r : Result) : Bool := Id.run do
  let message := (String.fromUTF8? r.stderr).getD "" ++
    (String.fromUTF8? r.stdout).getD ""
  return message.contains "already exists"

/-- An msb create timeout or transport failure may have created the sandbox.
Remove that unique run name unless msb explicitly says it belongs to an existing
sandbox; that name is not ours to delete. -/
private def createSandbox (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost) : ExceptT String IO Unit := do
  let attempted : Except String Result ← try
    pure (.ok (← runtime.runner (Microsandbox.createArgv name request.caps.memory_mib allow ctx.image)
      Microsandbox.controlTimeoutMs (4096 + 12 * request.caps.output_cap_bytes)))
  catch _ => pure (.error "create runner failed")
  let created := attempted.toOption
  if let some result := created then
    if result.cap == .none && result.exitCode == some 0 then return
    if duplicateCreate result then throw "sandbox create: name already exists; left untouched"
  let removed ← liftM <| try
    runtime.runner ["msb", "remove", "-f", name] Microsandbox.controlTimeoutMs 4096
  catch _ => pure cleanupFailure
  requireStep "create cleanup" (.ok removed)
  throw "sandbox create failed"

private def guestArg (workspace arg : String) : String :=
  if arg == workspace then guestWorkspace
  else match arg.dropPrefix? (workspace ++ "/") with
    | some suffix => guestWorkspace ++ "/" ++ suffix.toString
    | none => arg

private def supervise (backend : Kalari.Backend.SandboxBackend) (name : String)
    (request : RunRequest) (secrets : List String) : ExceptT String IO Verdict := do
  let args := request.command.map (guestArg request.workspace)
  -- The Python image installs Python in /usr/local/bin, outside aashaan's PATH.
  let args := if args.head? == some "python3" then "/usr/local/bin/python3" :: args.drop 1 else args
  let r ← execOk backend name "supervisor" <|
    [supervisor, toString request.caps.timeout_ms, toString request.caps.output_cap_bytes,
     "/bin/sh", "-c", "cd /workspace && exec \"$@\"", "sh"] ++ args
  let decoded : Except String Verdict := do
    let some text := String.fromUTF8? r.stdout | throw "invalid UTF-8"
    let v : Verdict ← Json.parse text >>= fromJson?
    unless (v.verdict == "exited" && v.exit_code.isSome) ||
      (["killed_timeout", "killed_output_cap"].contains v.verdict && v.exit_code.isNone) do
      throw "invalid supervisor verdict"
    return v
  match decoded with
  | .error _ => throw "sandbox supervisor: invalid verdict"
  | .ok v =>
    let capped := clip request.caps.output_cap_bytes ∘ scrub secrets
    return { v with stdout := capped v.stdout, stderr := capped v.stderr }

private structure Execution where
  verdict : Verdict
  artifact : Except String String

private def readArtifact (backend : Kalari.Backend.SandboxBackend) (name path : String) :
    ExceptT String IO String := do
  -- Bound transfer independently of the log cap. The host never opens a guest-selected path.
  let result ← execOk backend name "artifact"
    ["/bin/sh", "-c", "test -f \"$1\" && test ! -L \"$1\" && exec head -c \"$2\" -- \"$1\"",
     "sh", path, toString (artifactCap + 1)]
  if result.stdout.size > artifactCap then throw "record artifact exceeds the size limit"
  match String.fromUTF8? result.stdout with
  | none => throw "record artifact is not UTF-8"
  | some text => return text

private def execute (runtime : Runtime) (ctx : Context) (name : String) (request : RunRequest)
    (allow : List AllowHost) (artifactHost : Option String := none)
    (collectArtifact : Bool := true) : ExceptT String IO Execution := do
  -- The host deadline lets aashaan kill, collect pipes, and emit its verdict.
  -- JSON can escape each byte of both logs as six bytes.
  let backend := Microsandbox.make runtime.runner (request.caps.timeout_ms + 5000)
    (4096 + 12 * request.caps.output_cap_bytes) ctx.image
  let artifactBackend := Microsandbox.make runtime.runner 5000 (artifactCap + 1) ctx.image
  createSandbox runtime ctx name request allow
  let outcome : Except String Execution ← liftM <| try
    let steps : ExceptT String IO Execution := do
      requireStep "workspace copy" (← liftM (backend.copyIn name request.workspace guestWorkspace))
      requireStep "supervisor copy" (← liftM (backend.copyIn name ctx.aashaanHost supervisor))
      discard <| execOk backend name "overcommit" Microsandbox.overcommitCommand
      discard <| execOk backend name "supervisor permissions" ["chmod", "755", supervisor]
      let path := guestWorkspace ++ "/" ++ ctx.artifact
      discard <| execOk backend name "clear stale artifact" ["rm", "-f", "--", path]
      if let some source := artifactHost then
        requireStep "check artifact copy" (← liftM (backend.copyIn name source path))
      let verdict ← supervise backend name request ctx.secrets
      let artifact : Except String String ← if !collectArtifact then pure (.error "artifact collection disabled")
        else if successful verdict then liftM (readArtifact artifactBackend name path).run
        else pure (.error "consumer did not complete successfully")
      return { verdict, artifact }
    steps.run
  catch _ =>
    pure (.error "sandbox execution failed")
  -- A successful exec leaves the microVM running. Plain remove refuses it.
  let removed ← runtime.runner ["msb", "remove", "-f", name] Microsandbox.controlTimeoutMs 4096
  requireStep "cleanup" (.ok removed)
  match outcome with
  | .ok result => return result
  | .error e => throw e

structure Report where
  run_id : String
  verdict : Verdict
  checks : List CheckResult
  passed : Bool
  summary : String
  deriving ToJson

private def evidence (ctx : Context) (id kind : String) (payload : Json) : IO Unit :=
  Kalari.Evidence.append ctx.evidence {
    kind, session_id := ctx.sessionId, run_id := id, change_kinds := ctx.changeKinds, payload
  }

private def checkResult (id : String) (passed : Bool) (detail : Option String) : CheckResult :=
  { check_id := id, passed := passed, detail := detail }

/-- Run one trusted lesson check in a fresh guest populated only from the
host-owned check workspace and the candidate's bounded output artifact. -/
private def runOneCheck (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost) (source : System.FilePath)
    (check : Check) : IO CheckResult := do
  let checkRequest : RunRequest := { request with
    workspace := ctx.checkWorkspace, command := check.command }
  let execution ← try
    (execute runtime ctx name checkRequest allow (some source.toString) false).run
  catch _ => pure (.error "sandbox check failed")
  return match execution with
    | .error reason => checkResult check.id false (some reason)
    | .ok checked => checkResult check.id (successful checked.verdict)
        (some (summary checked.verdict))

private def runChecks (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost) (dir : System.FilePath)
    (artifact : Except String String) : IO (List CheckResult) := do
  let mut results := []
  for (check, index) in ctx.checks.zipIdx do
    let result ← match artifact with
      | .error reason => pure (checkResult check.id false
          (some ("Skipped because no successful artifact was available: " ++ reason)))
      | .ok contents => do
        let source := dir / s!"check-{index}-artifact.jsonl"
        IO.FS.writeFile source contents
        runOneCheck runtime ctx (name ++ s!"-check-{index}") request allow source check
    results := results ++ [result]
  return results

private def compareRun (runtime : Runtime) (ctx : Context) (name : String)
    (allow : List AllowHost) (candidate : Execution) : IO CheckResult := do
  let diff : Except String Difference ← match candidate.artifact with
    | .error e => pure (.error e)
    | .ok actual => do
      let baseline ← (execute runtime ctx (name ++ "-v1") ctx.baseline allow).run
      pure <| do
        let baseline ← baseline
        let old ← baseline.artifact.mapError fun e => "v1: " ++ e
        compareRecords old actual
  return match diff with
  | .ok d => { check_id := differentialId, passed := d.passed, detail := some d.summary }
  | .error e => { check_id := differentialId, passed := false, detail := some e }

/-- The exact MCP argument shape is `RunRequest`. Refusals happen before any
runner, resolver, evidence append, or sandbox action. -/
def run (runtime : Runtime) (ctx : Context) (request : RunRequest) : IO (Except String Report) :=
  match admit ctx request with
  | .error e => pure (.error e)
  | .ok () => IO.FS.withTempDir fun dir => (do
    let allow ← resolveAllowlist runtime request.allowlist
    let baselineAllow ← resolveAllowlist runtime ctx.baseline.allowlist
    let runId := dir.fileName.getD "run"
    let name := "kalari-" ++ runId
    requireStep "image pull" (← liftM (Microsandbox.ensureImage runtime.runner ctx.image 4096 runtime.wait))
    let finish ← match ctx.observer with
      | none => pure none
      | some start =>
        match ← liftM (start runId) with
        | .error e => throw s!"observer start: {e}"
        | .ok stop => pure (some stop)
    let candidateResult ← liftM <| try (execute runtime ctx name request allow).run
      catch _ => pure (.error "sandbox execution failed")
    -- Always stop the host observer, including when sandbox execution failed.
    let traceResult : Option (Except String String) ← match finish with
      | none => pure none
      | some stop =>
        let result ← liftM <| try stop catch _ => pure (.error "observer stop failed")
        pure (some result)
    let candidate ← match candidateResult with
      | .error e => throw e
      | .ok c => pure c
    let lessonResults ← runChecks runtime ctx name request allow dir candidate.artifact
    let diff ← compareRun runtime ctx name baselineAllow candidate
    let checks := lessonResults ++ [diff]
    let observations ← if successful candidate.verdict && checks.all (·.passed) then
      match traceResult with
      | none => pure none
      | some (.error e) => throw s!"observer: {e}"
      | some (.ok trace) =>
        match pageObservations trace with
        | .error e => throw s!"observer: {e}"
        | .ok facts => pure (some facts)
      else pure none
    let record : RunRecord := {
      request, verdict := candidate.verdict, checks := ctx.checks, check_results := checks
      timings := { wall_ms := candidate.verdict.wall_ms }
    }
    evidence ctx runId "run" (toJson record)
    for check in checks do
      evidence ctx runId "check" (toJson check)
    if let some facts := observations then
      evidence ctx runId "page-observation" (Json.mkObj [("source", Json.str "payouts-api"), ("behaviors", toJson facts)])
    return {
      run_id := runId, verdict := candidate.verdict, checks
      passed := successful candidate.verdict && checks.all (·.passed)
      summary := summary candidate.verdict
    } : ExceptT String IO Report).run

/-- Adapter for the service's MCP handler once session state is wired. -/
def call (runtime : Runtime) (ctx : Context) (args : Json) : IO (Except String String) :=
  match fromJson? args with
  | .error _ => pure (.error "invalid sandbox request")
  | .ok request => return (← run runtime ctx request).map (fun r => (toJson r).compress)


private def verify (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (.userError message)

private def expectOk (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error e => throw (.userError e)

private def row (i : Nat) : String :=
  (Json.mkObj [("id", toJson s!"P{i}"), ("amount", toJson (100 + i))]).compress ++ "\n"

private def fixtureVerdict (kind : String) (code : Option Nat) (out : String := "") : Verdict :=
  { verdict := kind, exit_code := code, stdout := out, stderr := "", wall_ms := 800
    stdout_truncated := false, pipe_held_open := false, supervisor_peak_rss_kb := 5500
    cgroup_memory_limit := 0 }

private def fixtureResult (stdout : String := "") : Result :=
  { cap := .none, exitCode := some 0, stdout := stdout.toUTF8, stderr := ByteArray.empty, wallMs := 1 }

private def fixtureFailure (stderr : String) : Result :=
  { (fixtureResult "") with exitCode := some 1, stderr := stderr.toUTF8 }

private def fixtureRuntime (calls : IO.Ref (List String)) (variant : String)
    (caps : Caps) (truth duplicates : String) (tampered existsRef : IO.Ref Bool) : Runtime where
  resolve := fun host => do
    verify (host == "api.example.test") "unexpected DNS query"
    calls.modify (· ++ ["resolve"])
    return ["203.0.113.10", "203.0.113.10"]
  wait := fun _ => throw (.userError "unexpected image retry")
  runner := fun argv timeout output => do
    let (stage, reply) ← match argv with
      | ["msb", "pull", image] =>
        verify (image == Microsandbox.imageName) "wrong image pull"
        pure ("pull", fixtureResult "")
      | "msb" :: "create" :: "--name" :: name :: _ => do
        verify (name.startsWith "kalari-") "sandbox name missing prefix"
        verify (argv == Microsandbox.createArgv name caps.memory_mib
          [{ host := "203.0.113.10", port := 18080 }]) "create lacks restricted network, image, or memory"
        let stage := if name.contains "-check-" then "create-check"
          else if name.endsWith "-v1" then "create-v1" else "create-v2"
        if variant == "create-timeout" && stage == "create-v2" then do
          existsRef.set true
          pure (stage, { (fixtureResult "") with cap := .timeout, exitCode := none })
        else if variant == "create-duplicate" && stage == "create-v2" then do
          existsRef.set true
          pure (stage, fixtureFailure "sandbox already exists")
        else do
          existsRef.set true
          pure (stage, fixtureResult "")
      | ["msb", "copy", "-q", host, guest] => do
        let baseline := guest.contains "-v1:"
        let checking := guest.contains "-check-"
        if host == "/trusted/aashaan" then do
          verify (guest.endsWith (":" ++ supervisor)) "supervisor copy target"
          if checking && variant == "tamper" then
            verify (← tampered.get) "tampered candidate was not isolated before check"
          pure ("copy-supervisor", fixtureResult "")
        else if checking && guest.endsWith ":/workspace/payouts.jsonl" then do
          verify (host.startsWith "/tmp/") "check artifact was not staged as controlled material"
          pure ("copy-artifact", fixtureResult "")
        else do
          let expected := if checking then "/checks" else if baseline then "/baseline" else "/candidate"
          verify (host == expected && guest.endsWith ":/workspace") "wrong workspace copy"
          pure (if checking then "copy-check-workspace" else if baseline then "copy-baseline" else "copy-candidate",
            fixtureResult "")
      | "msb" :: "exec" :: name :: "--" :: cmd => do
        if cmd == Microsandbox.overcommitCommand then pure ("overcommit", fixtureResult "")
        else if cmd == ["chmod", "755", supervisor] then pure ("chmod", fixtureResult "")
        else if cmd == ["rm", "-f", "--", "/workspace/payouts.jsonl"] then
          pure ("clear", fixtureResult "")
        else if cmd.head? == some supervisor then do
          verify (timeout > caps.timeout_ms && output > caps.output_cap_bytes) "no supervisor transport headroom"
          verify (cmd.take 7 == [supervisor, toString caps.timeout_ms, toString caps.output_cap_bytes,
            "/bin/sh", "-c", "cd /workspace && exec \"$@\"", "sh"]) "missing supervisor invocation"
          let script ← match cmd.drop 7 with
            | ["/usr/local/bin/python3", script] => pure script
            | _ => throw (.userError "unexpected consumer argv")
          let verdict ←
            if name.contains "-check-" then do
              verify (script == "lesson.py") "check did not use the trusted check command"
              pure (fixtureVerdict "exited" (some (if ["correct", "tamper"].contains variant then 0 else 1)))
            else if name.endsWith "-v1" then do
              verify (script == "/workspace/v1_unchanged.py") "wrong baseline consumer"
              pure (fixtureVerdict "exited" (some 0))
            else do
              verify (script == s!"/workspace/{variant}.py") "wrong candidate consumer"
              if variant == "tamper" then tampered.set true
              pure <| if variant == "cursor_loop" then fixtureVerdict "killed_timeout" none
                else if variant == "v1_unchanged" then fixtureVerdict "exited" (some 1)
                else fixtureVerdict "exited" (some 0) "synced payouts"
          pure (if name.contains "-check-" then "lesson" else if name.endsWith "-v1" then "baseline-consumer" else "consumer",
            fixtureResult (toJson verdict).compress)
        else if cmd.take 2 == ["/bin/sh", "-c"] &&
            cmd.drop 3 == ["sh", "/workspace/payouts.jsonl", toString (artifactCap + 1)] then do
          verify (output == artifactCap + 1) "artifact transfer is unbounded"
          let data := if name.endsWith "-v1" then truth
            else if variant == "no_dedupe" then truth ++ duplicates
            else if ["single_page", "short_page_stop"].contains variant then
              String.join ((List.range 100).map row)
            else truth
          pure ("artifact", fixtureResult data)
        else throw (.userError "unexpected exec")
      | ["msb", "remove", "-f", name] => do
        let cleanup := variant == "create-timeout" && !name.contains "-check-" && !name.endsWith "-v1"
        if cleanup then verify (← existsRef.get) "ambiguous create did not leave a sandbox to clean"
        else verify (← existsRef.get) "removed sandbox was not created"
        existsRef.set false
        pure (if cleanup then "create-cleanup" else if name.contains "-check-" then "remove-check"
          else if name.endsWith "-v1" then "remove-v1" else "remove-v2", fixtureResult "")
      | _ => throw (.userError "unexpected msb command")
    calls.modify (· ++ [stage])
    return reply

private def exercise : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let caps : Caps := { timeout_ms := 800, output_cap_bytes := 64, memory_mib := 256 }
  let allow : List AllowHost := [{ host := "api.example.test", port := 18080 }]
  let req : RunRequest := { workspace := "/candidate", command := [], caps, allowlist := allow }
  let ctx : Context := {
    workspace := req.workspace
    baseline := { req with workspace := "/baseline", command := ["python3", "/baseline/v1_unchanged.py"] }
    checkWorkspace := "/checks"
    artifact := "payouts.jsonl"
    checks := [{ id := "exactly-once", assertion := "Each ID appears once", command := ["python3", "lesson.py"] }]
    maxCaps := caps, allowedNet := allow, secrets := [], aashaanHost := "/trusted/aashaan"
    evidence := store, sessionId := "test-session", changeKinds := ["pagination_changed"]
  }
  let truth := String.join ((List.range 2431).map row)
  let duplicateRows := String.join ((List.range 24).map fun i => row ((i + 1) * 99))
  for variant in ["cursor_loop", "no_dedupe", "correct", "single_page", "short_page_stop", "v1_unchanged", "tamper"] do
    let calls ← IO.mkRef []
    let tampered ← IO.mkRef false
    let existsRef ← IO.mkRef false
    let runtime := fixtureRuntime calls variant caps truth duplicateRows tampered existsRef
    let request := { req with command := ["python3", s!"/candidate/{variant}.py"] }
    let text ← expectOk (← call runtime ctx (toJson request))
    let payload ← expectOk (Json.parse text)
    let id ← expectOk (payload.getObjValAs? String "run_id")
    let verdict ← expectOk (payload.getObjValAs? Verdict "verdict")
    let checks ← expectOk (payload.getObjValAs? (List CheckResult) "checks")
    let passed ← expectOk (payload.getObjValAs? Bool "passed")
    let current ← calls.get
    let setup := ["copy-candidate", "copy-supervisor", "overcommit", "chmod", "clear", "consumer"]
    let checkSetup := ["create-check", "copy-check-workspace", "copy-supervisor", "overcommit", "chmod", "clear", "copy-artifact", "lesson", "remove-check"]
    let first := ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["artifact", "remove-v2"]
    let [lesson, diff] := checks | throw (.userError "expected both checks")
    verify (lesson.check_id == "exactly-once" && diff.check_id == differentialId) "wrong check IDs"
    if variant == "cursor_loop" then
      verify (verdict.verdict == "killed_timeout" && !passed && !lesson.passed && !diff.passed) "cursor_loop outcome"
      verify (current == ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["remove-v2"])
        "timeout ran checks, retrieved artifact, or leaked sandbox"
      let message ← expectOk (payload.getObjValAs? String "summary")
      verify (message == "The aashaan killed the run when it reached the time cap.") "timeout message"
    else if variant == "v1_unchanged" then do
      verify (verdict.verdict == "exited" && verdict.exit_code == some 1 && !passed &&
        !lesson.passed && !diff.passed) "unchanged v1 consumer outcome"
      verify (current == ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["remove-v2"])
        "failed v1 consumer ran checks or leaked sandbox"
    else do
      let expected := variant == "correct" || variant == "tamper"
      verify (verdict.verdict == "exited" && verdict.exit_code == some 0) "consumer did not exit successfully"
      verify (passed == expected && lesson.passed == expected && diff.passed == expected) "wrong checks verdict"
      let missingCount := if ["single_page", "short_page_stop"].contains variant then 2331 else 0
      let duplicateCount := if variant == "no_dedupe" then 24 else 0
      verify (diff.detail == some s!"{missingCount} missing, 0 extra, {duplicateCount} duplicates, 0 changed")
        s!"wrong differential counts for {variant}: {diff.detail.getD "none"}"
      verify (current == first ++ checkSetup ++ ["create-v1", "copy-baseline", "copy-supervisor",
        "overcommit", "chmod", "clear", "baseline-consumer", "artifact", "remove-v1"])
        "incorrect isolated-check/baseline lifecycle"
      if variant == "tamper" then do
        verify (← tampered.get) "tamper candidate did not run"

    let records := Kalari.Evidence.byRun (← Kalari.Evidence.load store) id
    verify (records.map (·.kind) == ["run", "check", "check"]) "run/check evidence missing"
    IO.println s!"run {variant}: {verdict.verdict}, passed={passed}, {diff.detail.getD ""}"
  let calls ← IO.mkRef []
  let tampered ← IO.mkRef false
  let existsRef ← IO.mkRef false
  let aliasedChecks := { ctx with checkWorkspace := ctx.workspace }
  let badCheckRoot ← run (fixtureRuntime calls "correct" caps truth truth tampered existsRef) aliasedChecks
    { req with command := ["python3", "correct.py"] }
  verify ((badCheckRoot matches .error "setup: checks require a separate trusted workspace") &&
    (← calls.get).isEmpty) "check workspace alias reached runtime"
  let denied := { req with command := ["python3", "correct.py"], allowlist := [{ host := "other.test", port := 18080 }] }
  let rejected ← run (fixtureRuntime calls "correct" caps truth truth tampered existsRef) ctx denied
  verify ((rejected matches .error "refused: allowlist") && (← calls.get).isEmpty) "refusal reached runtime"
  verify ((← Kalari.Evidence.load store).records.length == 21) "refusal wrote evidence"
  IO.println "run refused: allowlist, runner and resolver calls=0, no evidence appended"
  for variant in ["create-timeout", "create-duplicate"] do
    let createCalls ← IO.mkRef []
    let changed ← IO.mkRef false
    let existingRef ← IO.mkRef false
    let failed ← run (fixtureRuntime createCalls variant caps truth truth changed existingRef) ctx
      { req with command := ["python3", "correct.py"] }
    let actualCalls ← createCalls.get
    if variant == "create-timeout" then do
      verify ((failed matches .error "sandbox create failed") && !(← existingRef.get))
        "timed-out create was not force-cleaned"
      verify (actualCalls == ["resolve", "resolve", "pull", "create-v2", "create-cleanup"])
        "ambiguous create cleanup sequence"
    else do
      verify ((failed matches .error "sandbox create: name already exists; left untouched") && (← existingRef.get))
        "known duplicate sandbox was removed or misreported"
      verify (actualCalls == ["resolve", "resolve", "pull", "create-v2"])
        "duplicate-name failure attempted cleanup"
  IO.println "run create-timeout: force cleanup; duplicate name: preserved"
  let trace := "{\"request\":\"\",\"response\":\"a\",\"first\":\"1\",\"last\":\"2\",\"ids\":[\"1\",\"2\"],\"count\":2,\"drained\":false}\n{\"request\":\"a\",\"response\":\"b\",\"first\":\"2\",\"last\":\"3\",\"ids\":[\"2\",\"3\"],\"count\":2,\"drained\":true}\n"
  verify ((pageObservations trace).toOption == some ["boundary_overlap_one", "final_page_token"]) "valid trace rejected"
  verify ((pageObservations "").isOk == false) "missing trace accepted"
  verify ((pageObservations (trace.replace "\"drained\":true" "\"drained\":false")).isOk == false) "unterminated chain accepted"
  verify ((pageObservations (trace.toSlice.dropEnd 1).toString).isOk == false) "truncated trace accepted"
  verify ((pageObservations (trace.replace "\"request\":\"a\"" "\"request\":\"x\"")).isOk == false) "ambiguous trace accepted"
  let stopped ← IO.mkRef false
  let observer : Observer := fun _ => pure (.ok (do stopped.set true; pure (.ok trace)))
  let observed := { ctx with observer := some observer }
  let obsCalls ← IO.mkRef []
  let obsTamper ← IO.mkRef false
  let obsExists ← IO.mkRef false
  let result ← expectOk (← run (fixtureRuntime obsCalls "correct" caps truth duplicateRows obsTamper obsExists) observed { req with command := ["python3", "/candidate/correct.py"] })
  let obsRecords := Kalari.Evidence.byRun (← Kalari.Evidence.load store) result.run_id
  verify (result.passed && (← stopped.get) && obsRecords.any (fun r => r.kind == "page-observation" && (r.payload.getObjValAs? (List String) "behaviors").toOption == some ["boundary_overlap_one", "final_page_token"])) "verified observation not linked to run"
  stopped.set false
  let failedRun ← expectOk (← run (fixtureRuntime obsCalls "no_dedupe" caps truth duplicateRows obsTamper obsExists) observed { req with command := ["python3", "/candidate/no_dedupe.py"] })
  let failedRecords := Kalari.Evidence.byRun (← Kalari.Evidence.load store) failedRun.run_id
  verify (!failedRun.passed && (← stopped.get) && !(failedRecords.any (fun r => r.kind == "page-observation"))) "failed run emitted observations or observer leaked"
  let invalid : Observer := fun _ => pure (.ok (pure (.ok "bad")))
  let rejectedTrace ← run (fixtureRuntime obsCalls "correct" caps truth duplicateRows obsTamper obsExists) { ctx with observer := some invalid } { req with command := ["python3", "/candidate/correct.py"] }
  verify (rejectedTrace.isOk == false) "invalid observed run accepted"
  IO.println "run observer: complete linked trace accepted; malformed trace rejected"

#guard (compareRecords
  "{\"id\":\"A\",\"amount\":2}\n{\"id\":\"B\",\"amount\":4}\n"
  "{\"id\":\"A\",\"amount\":1}\n{\"id\":\"C\",\"amount\":5}\n").toOption ==
  some ⟨1, 1, 0, 1⟩

#guard (compareRecords "{\"id\":\"A\",\"amount\":2}\n" "{\"amount\":2,\"id\":\"A\"}\n").toOption ==
  some ⟨0, 0, 0, 0⟩

#eval exercise

end Kalari.Tools.Run

