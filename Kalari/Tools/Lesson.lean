import Kalari.Evidence
import Kalari.Lambo
import Kalari.Clef
import Kalari.Tools.Recall
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
    | _ => .error s!"unknown verified behavior: {v}"

private def reference (lesson : Lesson) : String :=
  s!"{lesson.observation} | kalari-lesson/v1 run_id={lesson.run_id} check_id={lesson.check.id}"

/-- The only input from the MCP caller is `runId`. A trusted page observer must
append verified-behavior evidence. Missing observations produce no lesson.
Failure-only lessons additionally require Clef's api_change answer and a
subsequent passing fix identified in that evidence. -/
private def recordUnlocked (store : Kalari.Evidence.Store) (session runId : String)
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
        let indexedKinds := loaded.records.filterMap fun r =>
          if r.kind == "run" && r.session_id == session && r.run_id == runId then
            r.change_kinds.find? entry.change_kinds.contains
          else none
        let some changeKind := indexedKinds.head? | return .error "page observation has no shared run change kind"
        if indexedKinds.length != 1 then return .error "page observation has ambiguous run change kinds"
        let check := run.checks.find? fun candidate =>
          candidate.assertion.contains "last delivery wins" && candidate.assertion.contains "ID" &&
          run.check_results.any fun result => result.check_id == candidate.id && result.passed
        let some check := check | return .error "no passing runnable last-delivery-wins check is available to bootstrap the lesson"
        pure (changeKind, check, observed.behaviors, none)
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
def record (store : Kalari.Evidence.Store) (session runId : String)
    (classify : Classify) (write : Write) : IO (Except String (List Lesson)) :=
  write.lane.atomically do
    recordUnlocked store session runId classify write

private def tests : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let writes ← IO.mkRef ([] : List (String × String × List String))
  let write ← makeWriter fun kind content deps => do
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

  -- The differential result is provenance for the passing run, while the
  -- bootstrap check must be a real runnable check already recorded on it.
  let pageRun : RunRecord := { run with request := { request with command := ["run-page-observer"] } }
  appendRun "page-pass" pageRun
  let pageSignal : PageObservation := { source := "payouts-api", behaviors := ["boundary_overlap_one", "final_page_token"] }
  let pageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "page-pass", change_kinds := ["pagination_changed"], payload := toJson pageSignal }
  Kalari.Evidence.append store pageRecord
  let pageResult ← IO.ofExcept (← record store "s" "page-pass" classify write)
  unless pageResult.any (fun l => l.check == check && l.observation.contains "one payout") do
    throw <| .userError "page observation did not bootstrap from the passing runnable check"

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
  let firstAttempt ← record retryStore "s" "retry-pass" classify retryWriter
  unless (match firstAttempt with | .error _ => true | .ok _ => false) do
    throw <| .userError "simulated first graph failure was not returned"
  let afterFailure ← Kalari.Evidence.load retryStore
  unless (afterFailure.records.filter (·.kind == "lesson")).length == 1 do
    throw <| .userError "first attempt did not preserve one recovery record"
  let retried ← IO.ofExcept (← record retryStore "s" "retry-pass" classify retryWriter)
  unless retried.length == 1 && (← retryWrites.get) ==
      ["resource", "constraint", "resource", "constraint", "observation"] do
    throw <| .userError "retry did not resume idempotently from typed evidence"
  let afterRetry ← Kalari.Evidence.load retryStore
  unless (afterRetry.records.filter (·.kind == "lesson")).length == 1 do
    throw <| .userError "retry duplicated typed lesson evidence"

  -- Two handler calls share one writer object and therefore one transaction lane.
  let concurrentStore ← Kalari.Evidence.openStore (dir / "concurrent")
  let concurrentRun : Kalari.Evidence.Record := { kind := "run", session_id := "s", run_id := "parallel-pass", change_kinds := ["pagination_changed"], payload := toJson run }
  Kalari.Evidence.append concurrentStore concurrentRun
  let concurrentSignal : PageObservation := { source := "payouts-api", behaviors := ["boundary_overlap_one"] }
  let concurrentRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := "s", run_id := "parallel-pass", change_kinds := ["pagination_changed"], payload := toJson concurrentSignal }
  Kalari.Evidence.append concurrentStore concurrentRecord
  let concurrentWrites ← IO.mkRef ([] : List String)
  let concurrentWriter ← makeWriter fun kind _ _ => do
    IO.sleep 2
    concurrentWrites.modify fun xs => xs ++ [kind]
    return .ok (if kind == "resource" then "parallel-anchor" else if kind == "constraint" then "parallel-lesson" else "parallel-run")
  let firstTask ← IO.asTask (record concurrentStore "s" "parallel-pass" classify concurrentWriter)
  let secondTask ← IO.asTask (record concurrentStore "s" "parallel-pass" classify concurrentWriter)
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
  let orderResult ← record orderStore "s" "ordered-pass" api orderWriter
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
  let kindResult ← record kindStore "s" "same-kind-fix" api orderWriter
  unless (match kindResult with | .error e => e.contains "share a change kind" | .ok _ => false) do
    throw <| .userError "failure-to-fix link accepted different change kinds"

#eval tests
end Kalari.Tools.Lesson
