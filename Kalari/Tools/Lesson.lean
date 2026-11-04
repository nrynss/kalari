import Kalari.Evidence
import Kalari.Lambo
import Kalari.Clef
import Kalari.Tools.Recall

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

/-- Clef receives the actual failing run and trusted service-supplied context. -/
abbrev Classify := String → RunRecord → IO (Except String Kalari.Backend.DecisionAnswer)

/-- Bind service-owned change and code context to Clef’s typed failure question. -/
def clefClassifier (runner : Kalari.Clef.Runner) (delay : Kalari.Clef.Delay) (keyEnv : String)
    (context : String → IO (Except String (String × String))) : Classify :=
  fun id run => do
    match ← context id with
    | .error e => return .error e
    | .ok (change, code) => Kalari.Clef.failureCause runner delay keyEnv change (toJson run) code
/-- Typed resource/constraint/observation writer; returns an applied concept ID. -/
abbrev Write := String → String → List String → IO (Except String String)

/-- Production writer waits for each applied receipt. -/
def writer (client : Kalari.Lambo.Client) : Write := fun kind content deps => do
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

private def descriptions (values : List String) : Except String (List String) :=
  values.mapM fun v => match v with
    | "boundary_overlap_one" => .ok "Adjacent pages repeated one payout at their boundary."
    | "final_page_token" => .ok "The final page carried a continuation token."
    | "short_page_midstream" => .ok "A short page occurred before the end of the stream."
    | _ => .error s!"unknown verified behavior: {v}"

private def reference (lesson : Lesson) : String :=
  s!"{lesson.observation} | kalari-lesson/v1 run_id={lesson.run_id} check_id={lesson.check.id}"

/-- The only input from the MCP caller is `runId`. A trusted page observer must
append verified-behavior evidence. Missing observations produce no lesson.
Failure-only lessons additionally require Clef's api_change answer and a
subsequent passing fix identified in that evidence. -/
def record (store : Kalari.Evidence.Store) (session runId : String)
    (classify : Classify) (write : Write) : IO (Except String (List Lesson)) := do
  if !validId runId then return .error "invalid run ID"
  let loaded ← Kalari.Evidence.load store
  if !loaded.warnings.isEmpty then return .error "incomplete evidence store"
  let run ← match runFor loaded.records session runId with
    | .error e => return .error e
    | .ok r => pure r
  if !passed run then return .ok []
  let observations := loaded.records.filter fun r =>
    r.kind == "verified-behavior" && r.session_id == session && r.run_id == runId
  let mut lessons := []
  for entry in observations do
    let signal : VerifiedBehavior ← match fromJson? entry.payload with
      | .error e => return .error e
      | .ok s => pure s
    if !(loaded.records.any fun r => r.kind == "run" && r.session_id == session && r.run_id == runId && r.change_kinds.contains signal.change_kind) then
      return .error "run does not identify the behavior change kind"
    if !entry.change_kinds.contains signal.change_kind || signal.change_kind.isEmpty ||
        !validId signal.check.id || signal.check.assertion.isEmpty || signal.check.command.isEmpty ||
        signal.check.command.headD "" == "" then return .error "invalid verified behavior evidence"
    if !run.checks.contains signal.check ||
        !(run.check_results.any fun c => c.check_id == signal.check.id && c.passed) then
      return .error "behavior check was not verified by the passing run"
    let facts ← match descriptions signal.behaviors with
      | .error e => return .error e
      | .ok facts => pure facts
    let mut cause := false
    if let some failedId := signal.failed_run_id then
      let failed ← match runFor loaded.records session failedId with
        | .error e => return .error e
        | .ok r => pure r
      if passed failed then return .error "failure reference names a passing run"
      match ← classify failedId failed with
      | .ok (.label label _ _) => cause := label == "api_change"
      | .ok (.error status message) => return .error s!"Clef {status}: {message}"
      | .ok _ => return .error "Clef returned no failure label"
      | .error e => return .error e
      -- A non-API diagnosis never teaches a lesson from this failure.
      if !cause then continue
    if facts.isEmpty && !cause then continue
    if signal.behaviors.contains "boundary_overlap_one" &&
        !(signal.check.assertion.contains "last delivery wins" && signal.check.assertion.contains "ID") then
      return .error "overlap check must assert last delivery wins by ID"
    let text := String.intercalate " " (facts ++
      if cause then [s!"A prior failure in run {signal.failed_run_id.getD ""} was attributed to the API change; this fix passed."] else [])
    let lesson : Lesson := { change_kind := signal.change_kind, observation := text, run_id := runId, check := signal.check }
    if (Kalari.Tools.Recall.parseReference (reference lesson)).isNone then return .error "invalid lesson reference"
    if loaded.records.any (fun r => r.kind == "lesson" && r.run_id == runId &&
        match (fromJson? r.payload : Except String Lesson) with
        | .ok old => old.check.id == signal.check.id
        | .error _ => false) || lessons.any (fun old => old.check.id == signal.check.id) then
      return .error "lesson evidence already exists for run and check"
    let anchor ← match ← write "resource" signal.change_kind [] with
      | .error e => return .error e
      | .ok id => pure id
    -- Persist before publishing the reference, so a visible constraint resolves.
    Kalari.Evidence.append store { kind := "lesson", session_id := session, run_id := runId, change_kinds := [signal.change_kind], payload := toJson lesson }
    let concept ← match ← write "constraint" (reference lesson) [anchor] with
      | .error e => return .error e
      | .ok id => pure id
    match ← write "observation" s!"run {runId}: {text}" [concept] with
    | .error e => return .error e
    | .ok _ => pure ()
    lessons := lessons ++ [{ lesson with memory_concept_id := some concept }]
  return .ok lessons

private def tests : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let writes ← IO.mkRef ([] : List (String × String × List String))
  let write : Write := fun kind content deps => do
    writes.modify fun xs => xs ++ [(kind, content, deps)]
    return .ok (if kind == "resource" then "anchor" else "lesson-id")
  let check : Check := { id := "check-paging", assertion := "Key records by ID; last delivery wins", command := ["check-paging"] }
  let verdict : Verdict := { verdict := "exited", exit_code := some 0, wall_ms := 1, stdout := "", stdout_truncated := false, stderr := "", pipe_held_open := false, supervisor_peak_rss_kb := 0, cgroup_memory_limit := 0 }
  let request : RunRequest := { workspace := "/workspace", command := ["run"], caps := { timeout_ms := 1000, output_cap_bytes := 1000, memory_mib := 128 }, allowlist := [] }
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
  let noneResult ← IO.ofExcept (← record store "s" "empty-pass" classify write)
  let flakyResult ← IO.ofExcept (← record store "s" "flaky-fix" classify write)
  unless noneResult.isEmpty && flakyResult.isEmpty && (← writes.get).isEmpty do
    throw <| .userError "flaky or empty pass wrote a lesson"
  let lessons ← IO.ofExcept (← record store "s" "payouts-pass" classify write)
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
  let apiResult ← IO.ofExcept (← record store "s" "api-fix" api write)
  unless apiResult.any (fun l => l.observation.contains "flaky-fail") do throw <| .userError "API failure fix was not recorded"

#eval tests
end Kalari.Tools.Lesson
