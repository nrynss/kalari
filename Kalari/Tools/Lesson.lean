import Kalari.Evidence
import Kalari.Lambo
import Kalari.Clef
import Kalari.Tools.Recall
import Kalari.Tools.Run
import Std.Sync.Mutex

/-! Record only service-produced, sandbox-verified observations. The MCP caller
supplies a run ID, never a lesson, check, observation, or failure diagnosis. -/

open Lean Kalari.Model
namespace Kalari.Tools.Lesson


/-- Producer contract: a trusted instrumented run emits this typed payload in
an Evidence record of kind `verified-behavior`, indexed by the passing run.
`behaviors` is a list of observed page-level facts; it is not inferred from the
final output. `failed_run_id` links an earlier sandbox run to the passing fix.
The check must already belong to and pass on the run. -/
structure VerifiedBehavior where
  change_kind : String
  check : Check
  behaviors : List String
  failed_run_id : Option String
  deriving FromJson, ToJson

/-- T4.6a page observer payload: raw facts only, with no policy or check claim. -/
structure PageObservation where
  source : String
  behaviors : List String
  deriving FromJson, ToJson

private def amendedCheckAssertion :=
  "The controlled amended-record fixture distinguishes first from last delivery by ID; keep-last matches final truth."
private def amendedCheckProgram := "kalari_amended_policy_check.py"
private def amendedCheckFixture := "kalari_amended_policy_fixture.json"
private def candidateTruthCheckId := "candidate-v1-truth-v1"
private def candidateTruthCheckAssertion :=
  "Rule: last delivery wins by ID; candidate output must match trusted v1 final truth by exact JSONL comparison."
private def candidateTruthCheckProgram := "kalari_candidate_truth_check.py"
def trustedTruthArtifactName : String := Kalari.Tools.Run.trustedTruthArtifactName

structure PolicyProvenance where
  version : String
  assertion : String
  passed : Bool
  deriving FromJson, ToJson, BEq

private def amendedFixture : String :=
  "{\"stream\":[{\"id\":\"amended-a\",\"amount\":1200,\"status\":\"PENDING\"},{\"id\":\"stable\",\"amount\":500,\"status\":\"SETTLED\"},{\"id\":\"amended-b\",\"amount\":2000,\"status\":\"SETTLED\"},{\"id\":\"amended-a\",\"amount\":1100,\"status\":\"ADJUSTED\"},{\"id\":\"amended-b\",\"amount\":1500,\"status\":\"ADJUSTED\"}],\"truth\":[{\"id\":\"amended-a\",\"amount\":1100,\"status\":\"ADJUSTED\"},{\"id\":\"stable\",\"amount\":500,\"status\":\"SETTLED\"},{\"id\":\"amended-b\",\"amount\":1500,\"status\":\"ADJUSTED\"}]}"

private def amendedCheckProgramText : String := String.intercalate "\n" [
  "import json", "import sys", "from pathlib import Path", "",
  "fixture = json.loads(Path(sys.argv[1]).read_text())",
  "stream = fixture['stream']", "truth = {row['id']: row for row in fixture['truth']}",
  "first = {}", "last = {}", "for row in stream:",
  "    first.setdefault(row['id'], row)", "    last[row['id']] = row", "",
  "if len(stream) != 5 or len(truth) != 3:",
  "    raise SystemExit('controlled fixture shape changed')",
  "if first == truth:",
  "    raise SystemExit('fixture does not distinguish keep-first from final truth')",
  "if last != truth:",
  "    raise SystemExit('keep-last does not match the fixture final truth')",
  "if sum(first[key] != truth[key] for key in truth) != 2:",
  "    raise SystemExit('fixture must expose both amended first-delivery values')",
  "print('amended fixture: first selection loses 2 amendments; last selection preserves final truth')"
]

/-- Provision a trusted policy check in the service-owned check workspace.
It tests a controlled amended-record fixture, independently of payouts' identical
boundary duplicates; it does not claim the candidate run demonstrated last-wins. -/
private def provisionAmendedPolicyFixture (checkWorkspace : String) : IO Unit := do
  if checkWorkspace.isEmpty then throw <| .userError "empty trusted check workspace"
  let root : System.FilePath := checkWorkspace
  IO.FS.createDirAll root
  IO.FS.writeFile (root / amendedCheckFixture) amendedFixture
  IO.FS.writeFile (root / amendedCheckProgram) amendedCheckProgramText

private def candidateTruthCheckText : String := String.intercalate "\n" [
  "import json", "import sys", "from pathlib import Path", "",
  "def read_records(path):", "    rows = {}", "    with Path(path).open() as stream:",
  "        for line_number, line in enumerate(stream, 1):", "            if not line.strip():",
  "                continue", "            row = json.loads(line)", "            key = row.get('id')",
  "            if not isinstance(key, str) or not key:",
  "                raise SystemExit(f'{path}:{line_number}: missing string ID')",
  "            if key in rows:", "                raise SystemExit(f'{path}:{line_number}: duplicate ID {key}')",
  "            rows[key] = row", "    return rows", "",
  "candidate = read_records(sys.argv[1])", "truth = read_records(sys.argv[2])",
  "if candidate != truth:",
  "    missing = sorted(set(truth) - set(candidate))",
  "    extra = sorted(set(candidate) - set(truth))",
  "    changed = sorted(key for key in set(candidate) & set(truth) if candidate[key] != truth[key])",
  "    raise SystemExit(f'candidate differs from trusted v1: missing={len(missing)} extra={len(extra)} changed={len(changed)}')",
  "print(f'candidate exactly matches trusted v1 final truth: {len(truth)} IDs')"
]

/-- Provision generic candidate-versus-truth enforcement in the trusted check
workspace. Run must copy the candidate artifact and the same run's already
collected v1 artifact to the two command arguments. -/
def provisionCandidateTruthCheck (checkWorkspace artifactName : String) : IO Check := do
  if checkWorkspace.isEmpty || artifactName.isEmpty || artifactName.contains '/' || artifactName.contains '\\' then
    throw <| .userError "invalid trusted check workspace or artifact name"
  let root : System.FilePath := checkWorkspace
  IO.FS.createDirAll root
  IO.FS.writeFile (root / candidateTruthCheckProgram) candidateTruthCheckText
  return {
    id := candidateTruthCheckId
    assertion := candidateTruthCheckAssertion
    command := ["python3", candidateTruthCheckProgram, artifactName, trustedTruthArtifactName]
  }

/-- Attach the fixture policy check to a trusted Run Context. Call once while
assembling the service context, before candidate runs begin. -/
def attachLessonBootstrapChecks (ctx : Kalari.Tools.Run.Context) : IO Kalari.Tools.Run.Context := do
  if ctx.artifact == trustedTruthArtifactName then
    throw <| .userError "candidate artifact name collides with the reserved v1 truth artifact"
  let truth ← provisionCandidateTruthCheck ctx.checkWorkspace ctx.artifact
  let checks := ctx.checks.filter (·.id != candidateTruthCheckId)
  return { ctx with checks := checks ++ [truth] }

private def isCandidateTruthCheck (artifact : String) (check : Check) : Bool :=
  check.id == candidateTruthCheckId && check.assertion == candidateTruthCheckAssertion &&
  check.command.length == 4 && check.command[0]? == some "python3" &&
  check.command[1]? == some candidateTruthCheckProgram &&
  check.command[2]? == some artifact &&
  check.command[3]? == some trustedTruthArtifactName

/-- Run the independent policy fixture once per session and record its result.
This is provenance for the last-wins rule, not a candidate-output check. -/
def verifyAmendedPolicyProvenance (store : Kalari.Evidence.Store) (session checkWorkspace : String) :
    IO (Except String Unit) := do
  provisionAmendedPolicyFixture checkWorkspace
  let root : System.FilePath := checkWorkspace
  let args := #[(root / amendedCheckProgram).toString, (root / amendedCheckFixture).toString]
  let process ← IO.Process.output { cmd := "python3", args }
  if process.exitCode != 0 then return .error "amended policy fixture did not distinguish first from last"
  let loaded ← Kalari.Evidence.load store
  if !loaded.warnings.isEmpty then return .error "incomplete policy provenance evidence store"
  let policy : PolicyProvenance := {
    version := "amended-policy-fixture/v1", assertion := amendedCheckAssertion, passed := true }
  let existing := loaded.records.filter fun r =>
    r.kind == "lesson-policy" && r.session_id == session && r.run_id == "amended-policy-fixture-v1"
  if existing.isEmpty then
    let record : Kalari.Evidence.Record := { kind := "lesson-policy", session_id := session, run_id := "amended-policy-fixture-v1", change_kinds := ["pagination_changed"], payload := toJson policy }
    Kalari.Evidence.append store record
    return .ok ()
  if existing.length != 1 then return .error "ambiguous amended policy provenance records"
  let some item := existing.head? | return .error "policy provenance disappeared"
  match fromJson? item.payload with
  | .error _ => return .error "corrupt amended policy provenance"
  | .ok prior => return if prior == policy then .ok () else .error "amended policy provenance conflicts"

/-- Clef receives the actual failing run and trusted service-supplied context. -/
abbrev Classify := String → RunRecord → IO (Except String Kalari.Backend.DecisionAnswer)

/-- Bind service-owned change and code context to Clef’s typed failure question. -/
def clefClassifier (runner : Kalari.Clef.Runner) (delay : Kalari.Clef.Delay) (keyEnv : String)
    (context : String → IO (Except String (String × String))) : Classify :=
  fun id run => do
    match ← context id with
    | .error e => return .error e
    | .ok (change, code) => Kalari.Clef.failureCause runner delay keyEnv change (toJson run) code
/-- One writer instance is allocated per Kalari service and shared by all its
record_lesson handlers. Its lock owns the full record transaction. -/
structure Write where
  perform : String → String → List String → IO (Except String String)
  lane : Std.Mutex Unit

def makeWriter (perform : String → String → List String → IO (Except String String)) : IO Write := do
  return { perform, lane := ← Std.Mutex.new () }

/-- Production writer waits for each applied receipt. -/
def writer (client : Kalari.Lambo.Client) : IO Write := makeWriter fun kind content deps => do
  try
    let receipt ← Kalari.Lambo.derive client kind content deps
    return .ok (← Kalari.Lambo.awaitConceptId client receipt)
  catch e => return .error e.toString

private def validId (s : String) : Bool :=
  !s.isEmpty && s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

private def passed (run : RunRecord) : Bool :=
  run.verdict.verdict == "exited" && run.verdict.exit_code == some 0 &&
  !run.check_results.isEmpty && run.check_results.all (·.passed) &&
  run.check_results.any (fun r => r.check_id == "differential-v1" && r.passed)

private def runFor (records : List Kalari.Evidence.Record) (session id : String) : Except String RunRecord := do
  let runs := records.filter fun r => r.kind == "run" && r.session_id == session && r.run_id == id
  let [entry] := runs | throw s!"expected one run record for {id}"
  fromJson? entry.payload

private def runPosition (records : List Kalari.Evidence.Record) (session id : String) : Option Nat := Id.run do
  for (record, index) in records.zipIdx do
    if record.kind == "run" && record.session_id == session && record.run_id == id then
      return some index
  return none

private def descriptions (values : List String) : Except String (List String) :=
  values.mapM fun v => match v with
    | "boundary_overlap_one" => .ok "Adjacent pages repeated one payout at their boundary."
    | "final_page_token" => .ok "The final page carried a continuation token."
    | "short_page_midstream" => .ok "A short page occurred before the end of the stream."
    | "rate_limit_retry" => .ok "The API answered one request with HTTP 429 and a retry delay, and the identical request then succeeded."
    | "amended_policy_fixture" => .ok "A controlled amended-record fixture shows that keeping the first value loses final truth; the last value by ID preserves it."
    | _ => .error s!"unknown verified behavior: {v}"

private def reference (lesson : Lesson) : String :=
  s!"{lesson.observation} | kalari-lesson/v1 run_id={lesson.run_id} check_id={lesson.check.id}"

/-- The only input from the MCP caller is `runId`. A trusted page observer must
append verified-behavior evidence. Missing observations produce no lesson.
Failure-only lessons additionally require Clef's api_change answer and a
subsequent passing fix identified in that evidence. -/
private def recordUnlocked (store : Kalari.Evidence.Store) (session runId artifact : String)
    (classify : Classify) (write : Write) : IO (Except String (List Lesson)) := do
  if !validId runId then return .error "invalid run ID"
  let loaded ← Kalari.Evidence.load store
  if !loaded.warnings.isEmpty then return .error "incomplete evidence store"
  let run ← match runFor loaded.records session runId with
    | .error e => return .error e
    | .ok r => pure r
  if !passed run then return .ok []
  let observations := loaded.records.filter fun r =>
    (r.kind == "verified-behavior" || r.kind == "page-observation") &&
    r.session_id == session && r.run_id == runId
  let mut lessons := []
  for entry in observations do
    let (signalChange, signalCheck, signalBehaviors, failedRunId) ←
      if entry.kind == "page-observation" then
        let observed : PageObservation ← match fromJson? entry.payload with
          | .error e => return .error e
          | .ok s => pure s
        if observed.source.isEmpty then return .error "page observation has no trusted source"
        -- Policy provenance establishes the lesson's rule, but cannot itself
        -- make an otherwise empty page observation into a lesson.
        if observed.behaviors.isEmpty then continue
        -- These observer IDs describe page traversal, so their explicit graph
        -- anchor is pagination_changed even when the run indexes other changes.
        let changeKind := "pagination_changed"
        let policies := loaded.records.filter fun record =>
          record.kind == "lesson-policy" && record.session_id == session &&
          record.run_id == "amended-policy-fixture-v1" && record.change_kinds.contains changeKind
        let [policyRecord] := policies | return .error "missing or ambiguous amended-record policy provenance"
        let policy : PolicyProvenance ← match fromJson? policyRecord.payload with
          | .error _ => return .error "corrupt amended-record policy provenance"
          | .ok policy => pure policy
        if policy.version != "amended-policy-fixture/v1" ||
            policy.assertion != amendedCheckAssertion || !policy.passed then
          return .error "invalid amended-record policy provenance"
        let truth := run.checks.find? fun candidate =>
          isCandidateTruthCheck artifact candidate &&
          run.check_results.any fun result => result.check_id == candidate.id && result.passed
        let some check := truth | return .error "candidate artifact did not match the trusted final truth artifact"
        pure (changeKind, check, observed.behaviors ++ ["amended_policy_fixture"], none)
      else
        let signal : VerifiedBehavior ← match fromJson? entry.payload with
          | .error e => return .error e
          | .ok s => pure s
        pure (signal.change_kind, signal.check, signal.behaviors, signal.failed_run_id)
    if !(loaded.records.any fun r => r.kind == "run" && r.session_id == session && r.run_id == runId && r.change_kinds.contains signalChange) then
      return .error "run does not identify the behavior change kind"
    if !entry.change_kinds.contains signalChange || signalChange.isEmpty ||
        !validId signalCheck.id || signalCheck.assertion.isEmpty || signalCheck.command.isEmpty ||
        signalCheck.command.headD "" == "" then return .error "invalid verified behavior evidence"
    if !run.checks.contains signalCheck ||
        !(run.check_results.any fun c => c.check_id == signalCheck.id && c.passed) then
      return .error "behavior check was not verified by the passing run"
    let facts ← match descriptions signalBehaviors with
      | .error e => return .error e
      | .ok facts => pure facts
    let mut cause := false
    if let some failedId := failedRunId then
      let failed ← match runFor loaded.records session failedId with
        | .error e => return .error e
        | .ok r => pure r
      let some failedPosition := runPosition loaded.records session failedId
        | return .error "failure reference is not recorded before its passing fix"
      let some passingPosition := runPosition loaded.records session runId
        | return .error "passing run is missing from evidence order"
      if failedPosition >= passingPosition then
        return .error "failure reference must precede its passing fix"
      if !(loaded.records.any fun r => r.kind == "run" && r.session_id == session &&
          r.run_id == failedId && r.change_kinds.contains signalChange) then
        return .error "failure and fix do not share a change kind"
      if passed failed then return .error "failure reference names a passing run"
      match ← classify failedId failed with
      | .ok (.label label _ _) => cause := label == "api_change"
      | .ok (.error status message) => return .error s!"Clef {status}: {message}"
      | .ok _ => return .error "Clef returned no failure label"
      | .error e => return .error e
      -- A non-API diagnosis never teaches a lesson from this failure.
      if !cause then continue
    if facts.isEmpty && !cause then continue
    if signalBehaviors.contains "boundary_overlap_one" &&
        !(signalCheck.assertion.contains "last delivery wins" && signalCheck.assertion.contains "ID") then
      return .error "overlap check must assert last delivery wins by ID"
    let text := String.intercalate " " (facts ++
      if cause then [s!"A prior failure in run {failedRunId.getD ""} was attributed to the API change; this fix passed."] else [])
    let lesson : Lesson := { change_kind := signalChange, observation := text, run_id := runId, check := signalCheck }
    if (Kalari.Tools.Recall.parseReference (reference lesson)).isNone then return .error "invalid lesson reference"
    let prior := loaded.records.filter fun r => r.kind == "lesson" &&
      r.session_id == session && r.run_id == runId
    let mut existing : Option Lesson := none
    for record in prior do
      let old : Lesson ← match fromJson? record.payload with
        | .error _ => return .error "corrupt existing lesson evidence"
        | .ok old => pure old
      if old.check.id == signalCheck.id then
        if existing.isSome then return .error "ambiguous existing lesson evidence"
        existing := some old
    if let some old := existing then
      if old != lesson then return .error "existing lesson evidence conflicts with verified behavior"
    if lessons.any (fun old => old.check.id == signalCheck.id) then
      return .error "duplicate verified behavior check in evidence"
    let anchor ← match ← write.perform "resource" signalChange [] with
      | .error e => return .error e
      | .ok id => pure id
    -- Persist before publishing the reference, so a visible constraint resolves.
    if existing.isNone then
      Kalari.Evidence.append store { kind := "lesson", session_id := session, run_id := runId, change_kinds := [signalChange], payload := toJson lesson }
    let concept ← match ← write.perform "constraint" (reference lesson) [anchor] with
      | .error e => return .error e
      | .ok id => pure id
    match ← write.perform "observation" s!"run {runId}: {text}" [concept] with
    | .error e => return .error e
    | .ok _ => pure ()
    lessons := lessons ++ [{ lesson with memory_concept_id := some concept }]
  return .ok lessons

/-- Serialize lesson recording across all handlers owned by this Kalari service.
Retrying repeats the same content and dependency writes; the Lambo derive API
matches identical concepts, while a previously appended typed evidence record
is reused after validating it against the trusted producer payload. -/
def record (store : Kalari.Evidence.Store) (session runId artifact : String)
    (classify : Classify) (write : Write) : IO (Except String (List Lesson)) :=
  write.lane.atomically do
    recordUnlocked store session runId artifact classify write

private def tests : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let writes ← IO.mkRef ([] : List (String × String × List String))
  let write ← makeWriter fun kind content deps => do
    writes.modify fun xs => xs ++ [(kind, content, deps)]
    return .ok (if kind == "resource" then "anchor" else "lesson-id")
  let check : Check := { id := "check-paging", assertion := "Key records by ID; last delivery wins", command := ["check-paging"] }
  let verdict : Verdict := { verdict := "exited", exit_code := some 0, wall_ms := 1, stdout := "", stdout_truncated := false, stderr := "", pipe_held_open := false, supervisor_peak_rss_kb := 0, cgroup_memory_limit := 0 }
  let request : RunRequest := { workspace := "/workspace", command := ["run"], caps := { timeout_ms := 1000, output_cap_bytes := 1000, memory_mib := 128 }, allowlist := [] }
  let runContext : Kalari.Tools.Run.Context := {
    workspace := request.workspace
    baseline := { request with workspace := "/baseline" }
    checkWorkspace := (dir / "trusted-checks").toString
    artifact := "candidate.jsonl"
    checks := []
    maxCaps := request.caps
    allowedNet := []
    secrets := []
    aashaanHost := "/trusted/aashaan"
    evidence := store
    sessionId := "s"
    changeKinds := ["pagination_changed"]
  }
  let checkedContext ← attachLessonBootstrapChecks runContext
  let some truthCheck := checkedContext.checks.find? (·.id == candidateTruthCheckId) | throw <| .userError "candidate truth check missing from Run Context"
  unless isCandidateTruthCheck checkedContext.artifact truthCheck do throw <| .userError "wrong candidate truth check"
  let checkWorkspace : System.FilePath := checkedContext.checkWorkspace
  let policyResult ← verifyAmendedPolicyProvenance store "s" checkedContext.checkWorkspace
  unless (match policyResult with | .ok () => true | .error _ => false) do
    throw <| .userError "amended policy executable did not distinguish first from last"
  let truthText := "{\"id\":\"amended-a\",\"amount\":1100,\"status\":\"ADJUSTED\"}\n{\"id\":\"stable\",\"amount\":500,\"status\":\"SETTLED\"}\n{\"id\":\"amended-b\",\"amount\":1500,\"status\":\"ADJUSTED\"}\n"
  let staleText := "{\"id\":\"amended-a\",\"amount\":1200,\"status\":\"PENDING\"}\n{\"id\":\"stable\",\"amount\":500,\"status\":\"SETTLED\"}\n{\"id\":\"amended-b\",\"amount\":2000,\"status\":\"SETTLED\"}\n"
  let truthPath := checkWorkspace / trustedTruthArtifactName
  let correctPath := checkWorkspace / "candidate-correct.jsonl"
  let stalePath := checkWorkspace / "candidate-stale-first.jsonl"
  IO.FS.writeFile truthPath truthText
  IO.FS.writeFile correctPath truthText
  IO.FS.writeFile stalePath staleText
  let truthProgram := (checkWorkspace / candidateTruthCheckProgram).toString
  let correctRun ← IO.Process.output { cmd := "python3", args := #[truthProgram, correctPath.toString, truthPath.toString] }
  let staleRun ← IO.Process.output { cmd := "python3", args := #[truthProgram, stalePath.toString, truthPath.toString] }
  unless correctRun.exitCode == 0 && staleRun.exitCode != 0 do
    throw <| .userError "candidate truth checker did not accept correct and reject stale-first output"
  let run : RunRecord := { request, verdict, checks := [check], check_results := [{ check_id := "check-paging", passed := true }, { check_id := "differential-v1", passed := true }], timings := { wall_ms := 1 } }
  let failed : RunRecord := { run with verdict := { verdict with exit_code := some 1 }, check_results := [{ check_id := "differential-v1", passed := false }] }
  let appendRun := fun id r => Kalari.Evidence.append store { kind := "run", session_id := "s", run_id := id, change_kinds := ["pagination_changed"], payload := toJson r }
  appendRun "payouts-pass" run
  appendRun "flaky-fail" failed
  appendRun "flaky-fix" run
  appendRun "empty-pass" run
  let addSignal := fun id sig => Kalari.Evidence.append store { kind := "verified-behavior", session_id := "s", run_id := id, change_kinds := ["pagination_changed"], payload := toJson sig }
  let signal : VerifiedBehavior := { change_kind := "pagination_changed", check, behaviors := ["boundary_overlap_one", "final_page_token"], failed_run_id := none }
  addSignal "payouts-pass" signal
  addSignal "flaky-fix" { signal with behaviors := [], failed_run_id := some "flaky-fail" }
  let classify : Classify := fun _ _ => pure (.ok (.label "flaky" [] 0.6))
  let noneResult ← IO.ofExcept (← record store "s" "empty-pass" checkedContext.artifact classify write)
  let flakyResult ← IO.ofExcept (← record store "s" "flaky-fix" checkedContext.artifact classify write)
  unless noneResult.isEmpty && flakyResult.isEmpty && (← writes.get).isEmpty do
    throw <| .userError "flaky or empty pass wrote a lesson"
  let lessons ← IO.ofExcept (← record store "s" "payouts-pass" checkedContext.artifact classify write)
  let [lesson] := lessons | throw <| .userError "expected one payouts lesson"
  unless lesson.observation.contains "one payout" && lesson.observation.contains "final page" && lesson.check.assertion.contains "last delivery wins" do
    throw <| .userError "payouts observation or rule missing"
  let log ← writes.get
  let [(_, _, _), (_, label, deps), (_, _, runDeps)] := log | throw <| .userError "expected resource, constraint and observation"
  unless deps == ["anchor"] && runDeps == ["lesson-id"] do throw <| .userError "lesson links"
  let some ref := Kalari.Tools.Recall.parseReference label | throw <| .userError "reference format"
  let resolved ← IO.ofExcept (← Kalari.Tools.Recall.resolveEvidence store ref)
  unless resolved.run_id == "payouts-pass" && resolved.check == check do throw <| .userError "recall evidence"
  let emptySignal : VerifiedBehavior := { signal with behaviors := [], failed_run_id := some "flaky-fail" }
  appendRun "api-fix" run
  addSignal "api-fix" emptySignal
  let api : Classify := fun _ _ => pure (.ok (.label "api_change" [] 0.8))
  let apiResult ← IO.ofExcept (← record store "s" "api-fix" checkedContext.artifact api write)
  unless apiResult.any (fun l => l.observation.contains "flaky-fail") do throw <| .userError "API failure fix was not recorded"

  -- The differential result is provenance for the passing run, while the
  -- bootstrap check must be a real runnable check already recorded on it.
  let pageRequest : RunRequest := { request with command := ["run-page-observer"] }
  let pageRun : RunRecord := { run with request := pageRequest, checks := [truthCheck], check_results := [{ check_id := truthCheck.id, passed := true }, { check_id := "differential-v1", passed := true }] }
  appendRun "page-pass" pageRun
  let pageSignal : PageObservation := { source := "payouts-api", behaviors := ["boundary_overlap_one", "final_page_token"] }
  let pageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "page-pass", change_kinds := ["pagination_changed"], payload := toJson pageSignal }
  Kalari.Evidence.append store pageRecord
  let pageResult ← IO.ofExcept (← record store "s" "page-pass" checkedContext.artifact classify write)
  unless pageResult.any (fun l => l.check == truthCheck && l.observation.contains "one payout" && l.observation.contains "first value loses final truth") do
    throw <| .userError "page observation did not bootstrap from the passing runnable check"
  let some pageLesson := pageResult.head? | throw <| .userError "page lesson missing"
  let some pageRef := Kalari.Tools.Recall.parseReference (reference pageLesson) | throw <| .userError "page lesson reference malformed"
  let resolvedPage ← IO.ofExcept (← Kalari.Tools.Recall.resolveEvidence store pageRef)
  unless resolvedPage.check == truthCheck && resolvedPage.observation == pageLesson.observation do
    throw <| .userError "recall did not resolve candidate truth check evidence"

  -- A retry observed on a passing run publishes a typed lesson. Its observation
  -- says only that the identical request succeeded after the 429. Its runnable
  -- check is still the candidate-versus-final-truth check.
  let retryRunId := "page-retry-pass"
  appendRun retryRunId pageRun
  let retrySignal : PageObservation := { source := "payouts-api", behaviors := ["boundary_overlap_one", "rate_limit_retry"] }
  Kalari.Evidence.append store { kind := "page-observation", session_id := "s", run_id := retryRunId, change_kinds := ["pagination_changed"], payload := toJson retrySignal }
  let retryResult ← IO.ofExcept (← record store "s" retryRunId checkedContext.artifact classify write)
  let some retryLesson := retryResult.head? | throw <| .userError "retry observation published no lesson"
  unless retryLesson.check == truthCheck && retryLesson.observation.contains "429" &&
      retryLesson.observation.contains "identical request" do
    throw <| .userError "retry lesson sentence or runnable check missing"
  let some retryRef := Kalari.Tools.Recall.parseReference (reference retryLesson) | throw <| .userError "retry lesson reference malformed"
  let resolvedRetry ← IO.ofExcept (← Kalari.Tools.Recall.resolveEvidence store retryRef)
  unless resolvedRetry.check == truthCheck && resolvedRetry.observation == retryLesson.observation do
    throw <| .userError "recall did not resolve the retry lesson to the truth check"

  -- A run may carry several passing checks. The lesson must take the candidate
  -- truth check, not the first passing check. The weaker check carries the same
  -- overlap rule so it would pass the overlap guard if it were selected.
  let weaker : Check := { id := "weaker-paging", assertion := "Key records by ID; last delivery wins", command := ["check-weaker"] }
  let weakRunId := "page-weak-first"
  appendRun weakRunId { pageRun with checks := [weaker, truthCheck], check_results := [
    { check_id := weaker.id, passed := true }, { check_id := truthCheck.id, passed := true },
    { check_id := "differential-v1", passed := true }] }
  Kalari.Evidence.append store { kind := "page-observation", session_id := "s", run_id := weakRunId, change_kinds := ["pagination_changed"], payload := toJson pageSignal }
  let weakResult ← IO.ofExcept (← record store "s" weakRunId checkedContext.artifact classify write)
  let some weakLesson := weakResult.head? | throw <| .userError "a run with a weaker passing check first published no lesson"
  unless weakLesson.check == truthCheck do
    throw <| .userError "lesson took a weaker passing check instead of the candidate truth check"
  IO.println "lesson: a weaker passing check first still publishes the candidate truth check"

  -- A failed run or a missing differential pass publishes no retry lesson.
  let quietWriter ← IO.mkRef ([] : List String)
  let quiet ← makeWriter fun kind _ _ => do quietWriter.modify (· ++ [kind]); return .ok "unexpected"
  let failedRetryId := "page-retry-failed"
  appendRun failedRetryId { pageRun with verdict := { verdict with exit_code := some 1 } }
  Kalari.Evidence.append store { kind := "page-observation", session_id := "s", run_id := failedRetryId, change_kinds := ["pagination_changed"], payload := toJson retrySignal }
  let failedRetry ← IO.ofExcept (← record store "s" failedRetryId checkedContext.artifact classify quiet)
  let noDiffId := "page-retry-nodiff"
  appendRun noDiffId { pageRun with check_results := [{ check_id := truthCheck.id, passed := true }] }
  Kalari.Evidence.append store { kind := "page-observation", session_id := "s", run_id := noDiffId, change_kinds := ["pagination_changed"], payload := toJson retrySignal }
  let noDiff ← IO.ofExcept (← record store "s" noDiffId checkedContext.artifact classify quiet)
  unless failedRetry.isEmpty && noDiff.isEmpty && (← quietWriter.get).isEmpty &&
      !(← Kalari.Evidence.load store).records.any (fun r => r.kind == "lesson" &&
        (r.run_id == failedRetryId || r.run_id == noDiffId)) do
    throw <| .userError "a failed or undifferentiated retry run published a lesson"
  IO.println "lesson: a retry observation publishes the truth check; a failed run and a missing differential pass publish nothing"

  -- An empty page observation remains a no-op even when valid policy
  -- provenance exists; provenance supplies a rule, not observed behavior.
  appendRun "page-empty-pass" pageRun
  let emptyPageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "page-empty-pass", change_kinds := ["pagination_changed"], payload := toJson ({ source := "payouts-api", behaviors := [] } : PageObservation) }
  Kalari.Evidence.append store emptyPageRecord
  let writesBeforeEmptyPage ← writes.get
  let emptyPageResult ← IO.ofExcept (← record store "s" "page-empty-pass" checkedContext.artifact classify write)
  let afterEmptyPage ← Kalari.Evidence.load store
  unless emptyPageResult.isEmpty && (← writes.get) == writesBeforeEmptyPage &&
      !(afterEmptyPage.records.any fun r => r.kind == "lesson" && r.run_id == "page-empty-pass") do
    throw <| .userError "empty page observation produced a lesson from policy provenance"
  let staleStore ← Kalari.Evidence.openStore (dir / "stale-first")
  let staleRunBody : RunRecord := { run with checks := [truthCheck], check_results := [
    { check_id := truthCheck.id, passed := false }, { check_id := "differential-v1", passed := false }] }
  let staleRunRecord : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "stale-first", change_kinds := ["pagination_changed"], payload := toJson staleRunBody }
  Kalari.Evidence.append staleStore staleRunRecord
  let stalePageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "stale-first", change_kinds := ["pagination_changed"], payload := toJson pageSignal }
  Kalari.Evidence.append staleStore stalePageRecord
  let staleWrites ← IO.mkRef ([] : List String)
  let staleWriter ← makeWriter fun kind _ _ => do
    staleWrites.modify fun xs => xs ++ [kind]
    return .ok "unexpected"
  let staleLesson ← IO.ofExcept (← record staleStore "s" "stale-first" checkedContext.artifact classify staleWriter)
  unless staleLesson.isEmpty && (← staleWrites.get).isEmpty &&
      (← Kalari.Evidence.load staleStore).records.all (·.kind != "lesson") do
    throw <| .userError "stale-first output produced a recalled lesson"

  -- Simulate a graph write that fails after the typed lesson is appended.
  -- Retrying must validate and reuse that record, then finish the same writes.
  let retryStore ← Kalari.Evidence.openStore (dir / "retry")
  let retryRun : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "retry-pass", change_kinds := ["pagination_changed"], payload := toJson run }
  let retrySignal : Kalari.Evidence.Record := { kind := "verified-behavior", session_id := "s", run_id := "retry-pass", change_kinds := ["pagination_changed"], payload := toJson signal }
  Kalari.Evidence.append retryStore retryRun
  Kalari.Evidence.append retryStore retrySignal
  let failOnce ← IO.mkRef true
  let retryWrites ← IO.mkRef ([] : List String)
  let retryWriter ← makeWriter fun kind _ _ => do
    retryWrites.modify fun xs => xs ++ [kind]
    if kind == "constraint" && (← failOnce.get) then
      failOnce.set false
      return .error "simulated receipt failure"
    return .ok (if kind == "resource" then "retry-anchor" else if kind == "constraint" then "retry-lesson" else "retry-run")
  let firstAttempt ← record retryStore "s" "retry-pass" checkedContext.artifact classify retryWriter
  unless (match firstAttempt with | .error _ => true | .ok _ => false) do
    throw <| .userError "simulated first graph failure was not returned"
  let afterFailure ← Kalari.Evidence.load retryStore
  unless (afterFailure.records.filter (·.kind == "lesson")).length == 1 do
    throw <| .userError "first attempt did not preserve one recovery record"
  let retried ← IO.ofExcept (← record retryStore "s" "retry-pass" checkedContext.artifact classify retryWriter)
  unless retried.length == 1 && (← retryWrites.get) ==
      ["resource", "constraint", "resource", "constraint", "observation"] do
    throw <| .userError "retry did not resume idempotently from typed evidence"
  let afterRetry ← Kalari.Evidence.load retryStore
  unless (afterRetry.records.filter (·.kind == "lesson")).length == 1 do
    throw <| .userError "retry duplicated typed lesson evidence"

  -- Two handler calls share one writer object and therefore one transaction lane.
  let concurrentStore ← Kalari.Evidence.openStore (dir / "concurrent")
  let concurrentPolicy ← verifyAmendedPolicyProvenance concurrentStore "s" checkedContext.checkWorkspace
  unless (match concurrentPolicy with | .ok () => true | .error _ => false) do
    throw <| .userError "concurrent store policy provenance missing"
  let concurrentRunBody : RunRecord := { run with checks := [truthCheck], check_results := [{ check_id := truthCheck.id, passed := true }, { check_id := "differential-v1", passed := true }] }
  let concurrentRun : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "parallel-pass", change_kinds := ["pagination_changed"], payload := toJson concurrentRunBody }
  Kalari.Evidence.append concurrentStore concurrentRun
  let concurrentSignal : PageObservation := { source := "payouts-api", behaviors := ["boundary_overlap_one"] }
  let concurrentRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "parallel-pass", change_kinds := ["pagination_changed"], payload := toJson concurrentSignal }
  Kalari.Evidence.append concurrentStore concurrentRecord
  let concurrentWrites ← IO.mkRef ([] : List String)
  let concurrentWriter ← makeWriter fun kind _ _ => do
    IO.sleep 2
    concurrentWrites.modify fun xs => xs ++ [kind]
    return .ok (if kind == "resource" then "parallel-anchor" else if kind == "constraint" then "parallel-lesson" else "parallel-run")
  let firstTask ← IO.asTask (record concurrentStore "s" "parallel-pass" checkedContext.artifact classify concurrentWriter)
  let secondTask ← IO.asTask (record concurrentStore "s" "parallel-pass" checkedContext.artifact classify concurrentWriter)
  let firstCall ← IO.ofExcept firstTask.get
  let secondCall ← IO.ofExcept secondTask.get
  unless (match firstCall, secondCall with
      | .ok a, .ok b => a.length == 1 && b.length == 1
      | _, _ => false) do
    throw <| .userError "concurrent lesson calls did not both succeed"
  unless (← concurrentWrites.get) ==
      ["resource", "constraint", "observation", "resource", "constraint", "observation"] do
    throw <| .userError "shared writer lane allowed concurrent transaction interleaving"
  let concurrentEvidence ← Kalari.Evidence.load concurrentStore
  unless (concurrentEvidence.records.filter (·.kind == "lesson")).length == 1 do
    throw <| .userError "concurrent calls duplicated lesson evidence"

  -- A failure link must point backward and share the fix's indexed change kind.
  let orderStore ← Kalari.Evidence.openStore (dir / "bad-order")
  let orderedPass : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "ordered-pass", change_kinds := ["pagination_changed"], payload := toJson run }
  let laterFailure : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "later-failure", change_kinds := ["pagination_changed"], payload := toJson failed }
  let reverseSignal : VerifiedBehavior := { signal with behaviors := [], failed_run_id := some "later-failure" }
  let reverseEvidence : Kalari.Evidence.Record := { kind := "verified-behavior", session_id := "s", run_id := "ordered-pass", change_kinds := ["pagination_changed"], payload := toJson reverseSignal }
  Kalari.Evidence.append orderStore orderedPass
  Kalari.Evidence.append orderStore laterFailure
  Kalari.Evidence.append orderStore reverseEvidence
  let orderWriter ← makeWriter fun _ _ _ => pure (.ok "unexpected")
  let orderResult ← record orderStore "s" "ordered-pass" checkedContext.artifact api orderWriter
  unless (match orderResult with | .error e => e.contains "precede" | .ok _ => false) do
    throw <| .userError "failure-to-fix link accepted reverse evidence order"

  let kindStore ← Kalari.Evidence.openStore (dir / "bad-kind")
  let differentFailure : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "different-failure", change_kinds := ["argument_added"], payload := toJson failed }
  let sameKindFix : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "same-kind-fix", change_kinds := ["pagination_changed"], payload := toJson run }
  let wrongKindSignal : VerifiedBehavior := { signal with behaviors := [], failed_run_id := some "different-failure" }
  let wrongKindEvidence : Kalari.Evidence.Record := { kind := "verified-behavior", session_id := "s", run_id := "same-kind-fix", change_kinds := ["pagination_changed"], payload := toJson wrongKindSignal }
  Kalari.Evidence.append kindStore differentFailure
  Kalari.Evidence.append kindStore sameKindFix
  Kalari.Evidence.append kindStore wrongKindEvidence
  let kindResult ← record kindStore "s" "same-kind-fix" checkedContext.artifact api orderWriter
  unless (match kindResult with | .error e => e.contains "share a change kind" | .ok _ => false) do
    throw <| .userError "failure-to-fix link accepted different change kinds"

#eval tests
end Kalari.Tools.Lesson
