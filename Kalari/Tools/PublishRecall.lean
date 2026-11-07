import Kalari.Evidence
import Kalari.Model
import Kalari.Tools.Lesson
import Kalari.Tools.Recall
import Kalari.Tools.Run

/-! Production publish -> recall -> enforce, from one real loopback broker trace.

No inference (the classifier fails if it is ever called), loopback only
(127.0.0.1), no keys in files or the environment. A real payouts observer
serves the real `correct.py` consumer; its trace parses through the production
`pageObservations`; the passing run publishes one typed lesson through
`Lesson.record`; `Recall.resolveEvidence` returns it; the recalled
candidate-truth check passes the corrected output and fails the violating
`partial_output.py` output. Runs with no observation or no eligible behavior
publish nothing, with an explicit reason. Each lesson links to its verified
run, and the recall site is shown. -/

open Lean Kalari.Model
namespace Kalari.Tools.PublishRecall

private def verify (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (.userError message)

private def expectOk (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error e => throw (.userError e)

private def freePort : IO Nat := do
  let result ← IO.Process.output { cmd := "python3", args := #["-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"] }
  let some port := result.stdout.trimAscii.toString.toNat? | throw <| .userError "no test port"
  return port

/-- Run one real reference consumer against a real loopback observer.
Returns (artifact text, trace text). Loopback only; no keys involved. -/
private def runConsumer (dir : System.FilePath) (tag consumer : String) :
    IO (String × String) := do
  let sub := dir / tag
  IO.FS.createDirAll sub
  let port ← freePort
  let observer := Kalari.Tools.Run.payoutsObserver "bench/apis/payouts/server.py"
    { host := "127.0.0.1", port } "127.0.0.1" "127.0.0.1"
  let stop ← expectOk (← observer.start tag sub)
  let outPath := (sub / "out.jsonl").toString
  let run ← IO.Process.output { cmd := "python3", args := #["-I", s!"bench/apis/payouts/reference/{consumer}.py", "--base-url", s!"http://127.0.0.1:{port}", "--out", outPath] }
  let trace ← expectOk (← stop)
  unless run.exitCode == 0 do
    throw <| .userError s!"real {consumer} consumer exited {run.exitCode}"
  let artifact ← IO.FS.readFile outPath
  return (artifact, trace)

private def emptyReason (store : Kalari.Evidence.Store) (session runId : String) : IO String := do
  let loaded ← Kalari.Evidence.load store
  let observations := loaded.records.filter fun r =>
    (r.kind == "verified-behavior" || r.kind == "page-observation") &&
    r.session_id == session && r.run_id == runId
  if observations.isEmpty then
    return s!"observation unavailable for run {runId}: no verified-behavior or page-observation evidence, no lesson published"
  else
    return s!"no eligible lesson for run {runId}: observation present but no publishable behavior, no lesson published"

private def enforcement : IO Unit := IO.FS.withTempDir fun dir => do
  let session := "publish-recall"
  let store ← Kalari.Evidence.openStore dir
  let caps : Caps :=
    { timeout_ms := 30000, output_cap_bytes := 65536, memory_mib := 512 }
  let request : RunRequest :=
    { workspace := "/workspace", command := ["run"], caps, allowlist := [] }
  let baseContext : Kalari.Tools.Run.Context :=
    { workspace := request.workspace
      baseline := { request with workspace := "/baseline" }
      checkWorkspace := (dir / "trusted-checks").toString
      artifact := "payouts.jsonl"
      checks := []
      maxCaps := caps
      allowedNet := []
      secrets := []
      aashaanHost := "/trusted/aashaan"
      evidence := store
      sessionId := session
      changeKinds := ["pagination_changed"] }
  let checked ← Kalari.Tools.Lesson.attachLessonBootstrapChecks baseContext
  let some truthCheck := checked.checks.find? (·.id == Kalari.Tools.Lesson.candidateTruthCheckId)
    | throw <| .userError "candidate truth check missing from Run Context"
  let policy ← Kalari.Tools.Lesson.verifyAmendedPolicyProvenance store session checked.checkWorkspace
  unless (match policy with | .ok () => true | .error _ => false) do
    throw <| .userError "amended policy provenance failed"
  IO.println "publish-recall: trusted checks provisioned on loopback only, no keys read"

  -- One real broker trace: the corrected consumer against a real observer.
  let (correctText, trace) ← runConsumer dir "real-correct" "correct"
  let facts ← expectOk (Kalari.Tools.Run.pageObservations trace)
  verify (facts.contains "boundary_overlap_one" && facts.contains "final_page_token" &&
    facts.contains "rate_limit_retry") "real broker trace did not parse to the retry facts"
  IO.println s!"publish-recall: real broker trace parsed to {facts}"
  let grade ← IO.Process.output { cmd := "python3", args := #["-I", "bench/graders/grade.py", "payouts", (dir / "real-correct" / "out.jsonl").toString] }
  verify (grade.exitCode == 0 && grade.stdout.contains "\"verdict\": \"PASS\"") "corrected consumer did not grade PASS"
  IO.println "publish-recall: corrected consumer graded PASS (verified run)"

  -- A real violating consumer: it treats the 429 as the end and exits short.
  let (partialText, _) ← runConsumer dir "real-partial" "partial_output"
  let partialGrade ← IO.Process.output { cmd := "python3", args := #["-I", "bench/graders/grade.py", "payouts", (dir / "real-partial" / "out.jsonl").toString] }
  verify (partialGrade.exitCode != 0 && partialGrade.stdout.contains "\"verdict\": \"FAIL\"") "violating consumer did not grade FAIL"
  IO.println "publish-recall: violating consumer graded FAIL (short output)"

  -- The verified run record the lesson links to.
  let runId := "real-broker-pass"
  let verdict : Verdict :=
    { verdict := "exited", exit_code := some 0, wall_ms := 1,
      stdout := "", stdout_truncated := false, stderr := "",
      pipe_held_open := false,
      supervisor_peak_rss_kb := 0, cgroup_memory_limit := 0 }
  let runBody : RunRecord :=
    { request, verdict, checks := [truthCheck],
      check_results := [{ check_id := truthCheck.id, passed := true }, { check_id := "differential-v1", passed := true }],
      timings := { wall_ms := 1 } }
  Kalari.Evidence.append store
    { kind := "run", session_id := session, run_id := runId,
      change_kinds := ["pagination_changed"], payload := toJson runBody }
  Kalari.Evidence.append store
    { kind := "page-observation", session_id := session, run_id := runId,
      change_kinds := ["pagination_changed"],
      payload := toJson ({ source := "payouts-api", behaviors := facts } : Kalari.Tools.Lesson.PageObservation) }

  -- No inference: the classifier counts calls and fails if it ever runs.
  let clefCalls ← IO.mkRef 0
  let classify : Kalari.Tools.Lesson.Classify := fun _ _ => do
    clefCalls.modify (· + 1)
    pure (.error "inference blocked: publish-recall uses no model calls")
  let writes ← IO.mkRef ([] : List String)
  let write ← Kalari.Tools.Lesson.makeWriter fun kind _ _ => do
    writes.modify (· ++ [kind])
    return .ok (if kind == "resource" then "anchor" else if kind == "constraint" then "lesson-concept" else "observation-concept")
  let lessons ← expectOk (← Kalari.Tools.Lesson.record store session runId checked.artifact classify write)
  let [lesson] := lessons | throw <| .userError "real broker trace published no lesson"
  verify (lesson.run_id == runId && lesson.check == truthCheck) "lesson does not link its verified run and recalled check"
  verify (lesson.observation.contains "429" && lesson.observation.contains "identical request") "lesson observation is not the retry fact"
  let some concept := lesson.memory_concept_id | throw <| .userError "lesson has no memory concept"
  verify ((← writes.get) == ["resource", "constraint", "observation"]) "lesson graph writes out of order"
  IO.println s!"publish-recall: published run_id={lesson.run_id} check_id={lesson.check.id} memory_concept_id={concept}"
  IO.println s!"publish-recall: observation={lesson.observation}"

  -- The recall site: the versioned reference resolves through typed evidence.
  let label := s!"{lesson.observation} | kalari-lesson/v1 run_id={lesson.run_id} check_id={lesson.check.id}"
  let some reference := Kalari.Tools.Recall.parseReference label | throw <| .userError "published lesson reference did not parse"
  let resolved ← expectOk (← Kalari.Tools.Recall.resolveEvidence store reference)
  verify (resolved.run_id == runId && resolved.check == truthCheck &&
    resolved.observation == lesson.observation) "recall did not return the published lesson"
  IO.println s!"publish-recall: recall site resolveEvidence run_id={resolved.run_id} check_id={resolved.check.id} (recall_lessons change_kinds=[pagination_changed])"

  -- Enforcement with the recalled check: corrected passes, violating fails.
  let checkRoot : System.FilePath := checked.checkWorkspace
  IO.FS.writeFile (checkRoot / Kalari.Tools.Lesson.trustedTruthArtifactName) correctText
  IO.FS.writeFile (dir / "candidate-correct.jsonl") correctText
  IO.FS.writeFile (dir / "candidate-partial.jsonl") partialText
  let program := (checkRoot / Kalari.Tools.Lesson.candidateTruthCheckProgram).toString
  let truth := (checkRoot / Kalari.Tools.Lesson.trustedTruthArtifactName).toString
  let good ← IO.Process.output { cmd := "python3", args := #[program, (dir / "candidate-correct.jsonl").toString, truth] }
  let bad ← IO.Process.output { cmd := "python3", args := #[program, (dir / "candidate-partial.jsonl").toString, truth] }
  verify (good.exitCode == 0 && bad.exitCode != 0) "recalled check did not accept the corrected output and reject the violating output"
  IO.println s!"publish-recall: recalled check {truthCheck.id}: corrected=PASS violating=FAIL"

  -- Clear reasons when no lesson publishes.
  let noObsId := "no-observation-pass"
  Kalari.Evidence.append store
    { kind := "run", session_id := session, run_id := noObsId,
      change_kinds := ["pagination_changed"], payload := toJson ({ runBody with request }) }
  let writesBefore ← writes.get
  let noObs ← expectOk (← Kalari.Tools.Lesson.record store session noObsId checked.artifact classify write)
  verify (noObs.isEmpty && (← writes.get) == writesBefore) "run without observation published a lesson"
  IO.println (← emptyReason store session noObsId)
  let emptyId := "empty-behavior-pass"
  Kalari.Evidence.append store
    { kind := "run", session_id := session, run_id := emptyId,
      change_kinds := ["pagination_changed"], payload := toJson ({ runBody with request }) }
  Kalari.Evidence.append store
    { kind := "page-observation", session_id := session, run_id := emptyId,
      change_kinds := ["pagination_changed"],
      payload := toJson ({ source := "payouts-api", behaviors := [] } : Kalari.Tools.Lesson.PageObservation) }
  let empty ← expectOk (← Kalari.Tools.Lesson.record store session emptyId checked.artifact classify write)
  verify (empty.isEmpty && (← writes.get) == writesBefore) "run with empty behavior published a lesson"
  IO.println (← emptyReason store session emptyId)
  let stored ← Kalari.Evidence.load store
  verify (!(stored.records.any fun r => r.kind == "lesson" && (r.run_id == noObsId || r.run_id == emptyId))) "empty case wrote lesson evidence"

  verify ((← clefCalls.get) == 0) "a model call was made"
  IO.println "publish-recall: clef_calls=0 no inference; loopback only (127.0.0.1); no keys in files"
  IO.println "publish-recall enforcement: real trace -> publish -> recall -> enforce PASS"

#eval enforcement

end Kalari.Tools.PublishRecall
