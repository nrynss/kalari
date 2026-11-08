import Kalari.Lambo
import Kalari.Clef
import Kalari.Model
import Kalari.Evidence

/-! Recall linked lessons first, then classify semantic candidates.

Lambo constraints use the interoperable text reference
`<observation> | kalari-lesson/v1 run_id=<id> check_id=<id>`. The runnable
`Model.Lesson` (including its command) lives in `Evidence.Record(kind="lesson")`.
The legacy `check: <id>` suffix is accepted only when exactly one typed lesson
record resolves it. Other constraints are ordinary prose and are ignored. -/

open Lean
namespace Kalari.Tools.Recall

structure Entry where
  lesson : Kalari.Model.Lesson
  status : String
  stale : Bool
  concepts : List String := []
  confirming_runs : List String := []
  deriving Repr, BEq, ToJson, FromJson

/-- Lesson identity: what the lesson teaches, not the run that showed it.
Change kind, the check's id, assertion and command before session rebinding
(the candidate-truth artifact argument varies per session), and the sorted
set of observed behaviours. The hardcoded candidate-truth constants must
match `Kalari.Tools.Run` (`Lesson.lean` guards this); the single identity
function lives here so both `Lesson` (deduplicating writes) and `Recall`
(collapsing old duplicates) share it. -/
def candidateTruthCheckId : String := "candidate-v1-truth-v1"
def candidateTruthCheckProgram : String := "kalari_candidate_truth_check.py"
def candidateTruthArtifact : String := "kalari-v1-truth.jsonl"

def behaviorSentences : List (String × String) :=
  [("boundary_overlap_one", "Adjacent pages repeated one payout at their boundary."),
   ("final_page_token", "The final page carried a continuation token."),
   ("short_page_midstream", "A short page occurred before the end of the stream."),
   ("rate_limit_retry", "The API answered one request with HTTP 429 and a retry delay, and the identical request then succeeded."),
   ("amended_policy_fixture", "A controlled amended-record fixture shows that keeping the first value loses final truth; the last value by ID preserves it.")]

def sortedBehaviors (behaviors : List String) : List String :=
  (behaviors.eraseDups.toArray.qsort (· < ·)).toList

def behaviorsOfObservation (observation : String) : List String :=
  sortedBehaviors (behaviorSentences.filterMap fun (id, sentence) =>
    if observation.contains sentence then some id else none)

def normalizeCommand (checkId : String) (command : List String) : List String :=
  if checkId == candidateTruthCheckId && command.length == 4 &&
      command[0]? == some "python3" &&
      command[1]? == some candidateTruthCheckProgram &&
      command[3]? == some candidateTruthArtifact then
    ["python3", candidateTruthCheckProgram, "<artifact>", candidateTruthArtifact]
  else command

def lessonIdentityKey (changeKind : String) (check : Kalari.Model.Check)
    (behaviors : List String) : String :=
  changeKind ++ "|" ++ check.id ++ "|" ++ check.assertion ++ "|" ++
    String.intercalate "\u0001" (normalizeCommand check.id check.command) ++ "|" ++
    String.intercalate "," (sortedBehaviors behaviors)

#guard lessonIdentityKey "pagination_changed"
  { id := candidateTruthCheckId, assertion := "A",
    command := ["python3", candidateTruthCheckProgram, "payouts.jsonl", candidateTruthArtifact] }
  ["final_page_token", "boundary_overlap_one"] ==
  lessonIdentityKey "pagination_changed"
  { id := candidateTruthCheckId, assertion := "A",
    command := ["python3", candidateTruthCheckProgram, "other-session.jsonl", candidateTruthArtifact] }
  ["boundary_overlap_one", "final_page_token"]
#guard lessonIdentityKey "pagination_changed"
  { id := candidateTruthCheckId, assertion := "A",
    command := ["python3", candidateTruthCheckProgram, "payouts.jsonl", candidateTruthArtifact] }
  ["boundary_overlap_one"] !=
  lessonIdentityKey "pagination_changed"
  { id := candidateTruthCheckId, assertion := "A",
    command := ["python3", candidateTruthCheckProgram, "payouts.jsonl", candidateTruthArtifact] }
  ["boundary_overlap_one", "final_page_token"]
#guard lessonIdentityKey "pagination_changed"
  { id := "other-check", assertion := "A", command := ["check-once"] } ["boundary_overlap_one"] !=
  lessonIdentityKey "pagination_changed"
  { id := candidateTruthCheckId, assertion := "A",
    command := ["python3", candidateTruthCheckProgram, "payouts.jsonl", candidateTruthArtifact] }
  ["boundary_overlap_one"]
#guard behaviorsOfObservation "Adjacent pages repeated one payout at their boundary. The final page carried a continuation token." ==
  ["boundary_overlap_one", "final_page_token"]
#guard behaviorsOfObservation "nothing observed" == []
#guard sortedBehaviors ["c", "a", "b", "a"] == ["a", "b", "c"]

structure CheckReference where
  observation : String
  runId : Option String
  checkId : String
  deriving Repr, BEq

/-- Operations exposed for fixture replay; production resolves lesson IDs from
Kalari's typed evidence store rather than trying to reconstruct commands from
Lambo prose. -/
structure Sources where
  linked : String → IO (List Kalari.Lambo.Lesson)
  semantic : String → IO (List Kalari.Lambo.Lesson)
  resolve : CheckReference → IO (Except String Kalari.Model.Lesson)
  applies : String → List (String × String) → IO (Except String Kalari.Backend.DecisionAnswer)

def threshold : Float := 0.9

private def contentLabel (label : String) : String :=
  if label.endsWith " [Constraint, candidate]" then
    (label.toSlice.dropEnd " [Constraint, candidate]".length).toString
  else if label.endsWith " [Constraint]" then
    (label.toSlice.dropEnd " [Constraint]".length).toString
  else label

private def validReferenceId (value : String) : Bool :=
  !value.isEmpty && value.toList.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

private def fieldValue (marker : String) (fields : List String) : Option String :=
  (fields.filterMap fun field => (field.dropPrefix? marker).map String.Slice.toString).head?

private def hasOnlyFields (fields : List String) : Bool :=
  fields.all fun field => field.startsWith "run_id=" || field.startsWith "check_id="

/-- Parse the versioned T4.6 format, or the recorded legacy check-ID suffix.
Both forms resolve through typed evidence; free-text constraints never fail
recall merely because they are not executable lessons. -/
def parseReference (label : String) : Option CheckReference := Id.run do
  let body := contentLabel label
  let versioned := body.splitOn " | kalari-lesson/v1 "
  if versioned.length == 2 then
    let fields := versioned[1]!.splitOn " "
    if fields.length != 2 || !hasOnlyFields fields then return none
    let some runId := fieldValue "run_id=" fields | return none
    let some checkId := fieldValue "check_id=" fields | return none
    if !validReferenceId runId || !validReferenceId checkId then return none
    return some { observation := versioned[0]!, runId := some runId, checkId }
  let legacy := body.splitOn " check: "
  if legacy.length == 2 then
    let checkId := legacy[1]!
    if !validReferenceId checkId then return none
    return some { observation := legacy[0]!, runId := none, checkId }
  return none

private def validLesson (lesson : Kalari.Model.Lesson) : Bool :=
  !lesson.change_kind.isEmpty && !lesson.observation.isEmpty && !lesson.run_id.isEmpty &&
  !lesson.check.id.isEmpty && !lesson.check.assertion.isEmpty &&
  !lesson.check.command.isEmpty && lesson.check.command.headD "" != ""

/-- Resolve only a unique typed lesson evidence record matching the check ID,
and the run ID when the versioned Lambo reference supplies one. -/
def resolveEvidence (store : Kalari.Evidence.Store) (reference : CheckReference) :
    IO (Except String Kalari.Model.Lesson) := do
  let loaded ← Kalari.Evidence.load store
  let mut found : List Kalari.Model.Lesson := []
  let mut malformed := false
  for record in loaded.records do
    if record.kind == "lesson" &&
        (reference.runId.isNone || reference.runId == some record.run_id) then
      match fromJson? record.payload with
      | .ok lesson =>
        if validLesson lesson && lesson.run_id == record.run_id &&
            lesson.check.id == reference.checkId &&
            record.change_kinds.contains lesson.change_kind then
          found := found ++ [lesson]
        else if lesson.check.id == reference.checkId then malformed := true
      | .error _ => malformed := true
  if found.length > 1 then return .error s!"ambiguous lesson evidence for check {reference.checkId}"
  if malformed then return .error s!"corrupt or inconsistent lesson evidence for check {reference.checkId}"
  if let some lesson := found.head? then return .ok lesson
  return .error s!"missing lesson evidence for check {reference.checkId}"

private def isConfident (answer : Kalari.Backend.DecisionAnswer) (kinds : List String) : Bool :=
  match answer with
  | .probabilities ps => kinds.any fun kind =>
      match ps.find? (fun p => p.1 == kind) with
      | some (_, p) => p >= threshold && p <= 1.0
      | none => false
  | _ => false

private def resolveCandidate (source : Sources) (kind : String) (requireKind : Bool)
    (item : Kalari.Lambo.Lesson) :
    IO (Except String (Option Kalari.Model.Lesson)) := do
  let some reference := parseReference item.label | return .ok none
  let resolved ← source.resolve reference
  let lesson ← match resolved with
    | .ok lesson => pure lesson
    | .error error => return .error error
  -- Graph-linked lessons must agree with the change kind anchoring the edge.
  if requireKind && lesson.change_kind != kind then
    return .error s!"linked lesson {reference.checkId} has change kind {lesson.change_kind}, expected {kind}"
  if lesson.check.id != reference.checkId then
    return .error s!"lesson evidence check ID does not match {reference.checkId}"
  return .ok <| some { lesson with memory_concept_id := some item.id }

/-- Stale lessons remain visible, explicitly labelled, and never become checks.
Unrecognized constraints and ambiguous/missing evidence references are skipped.
Old stores may hold one constraint concept per verifying run for the same
identity (the per-run reference used to differ by run ID); those collapse
into one entry listing every concept ID and every confirming run. -/
def call (source : Sources) (kinds : List String) : IO (List Entry) := do
  let mut out : List Entry := []
  let mut seen : List String := []
  for kind in kinds do
    for item in (← source.linked kind) do
      if !seen.contains item.id then
        match ← resolveCandidate source kind true item with
        | .error error => throw <| .userError error
        | .ok none => pure ()
        | .ok (some lesson) =>
          let lesson := { lesson with memory_concept_id := some item.id }
          let entry : Entry := {
            lesson := lesson
            stale := item.stale
            status := if item.stale then "stale" else "required"
            concepts := [item.id]
            confirming_runs := [lesson.run_id]
          }
          out := out ++ [entry]
          seen := item.id :: seen
  for kind in kinds do
    for item in (← source.semantic kind) do
      if !seen.contains item.id then
        match ← resolveCandidate source kind false item with
        | .error _ => pure ()
        | .ok none => pure ()
        | .ok (some lesson) =>
          let status ← if item.stale then pure "stale" else do
            let query := (parseReference item.label).map CheckReference.observation |>.getD item.label
            let answer ← source.applies query (kinds.map fun k => (k, k))
            pure <| match answer with
              | .ok answer => if isConfident answer kinds then "required" else "advice"
              | .error _ => "advice"
          let lesson := { lesson with memory_concept_id := some item.id }
          out := out ++ [{ lesson := lesson, stale := item.stale, status := status, concepts := [item.id], confirming_runs := [lesson.run_id] }]
          seen := item.id :: seen
  -- Collapse same-identity entries: one entry per lesson identity.
  let mut collapsed : List Entry := []
  let mut keys : List String := []
  for entry in out do
    let key := lessonIdentityKey entry.lesson.change_kind entry.lesson.check
      (behaviorsOfObservation entry.lesson.observation)
    match keys.findIdx? (· == key) with
    | none =>
      keys := keys ++ [key]
      collapsed := collapsed ++ [entry]
    | some idx =>
      match collapsed[idx]? with
      | none =>
        keys := keys ++ [key]
        collapsed := collapsed ++ [entry]
      | some prior =>
        let concepts := (prior.concepts ++ entry.concepts).eraseDups
        let runs := (prior.confirming_runs ++ entry.confirming_runs).eraseDups
        let stale := prior.stale && entry.stale
        let status :=
          if stale then "stale"
          else if prior.status == "required" || entry.status == "required" then "required"
          else prior.status
        collapsed := collapsed.set idx
          { prior with concepts := concepts, confirming_runs := runs, stale := stale, status := status }
  return collapsed

private def contradiction (j : Json) : Except String Bool := do
  let focus ← j.getObjVal? "focus"
  let levels ← (← focus.getObjVal? "levels").getArr?
  for level in levels do
    for edge in (← (← level.getObjVal? "neighbours").getArr?) do
      if (← (← edge.getObjVal? "edge_type").getStr?) == "Contradicts" &&
          (← (← edge.getObjVal? "direction").getStr?) == "<-" then return true
  return false

/-- Build a resolver over the same typed evidence records T4.6 writes. -/
def evidenceResolver (store : Kalari.Evidence.Store) : CheckReference → IO (Except String Kalari.Model.Lesson) :=
  resolveEvidence store

/-- Construct the production source. Semantic ordinary constraints are retained
as candidates but are ignored unless their content carries a supported lesson
reference and unique typed evidence resolves it. -/
def sources (client : Kalari.Lambo.Client) (store : Kalari.Evidence.Store)
    (runner : Kalari.Clef.Runner) (delay : Kalari.Clef.Delay) (keyEnv : String) : Sources := {
  linked := Kalari.Lambo.lessons client
  semantic := fun query => do
    let result ← Kalari.Lambo.«recall» client query
    let hits ← IO.ofExcept ((← IO.ofExcept (result.getObjVal? "hits")).getArr?)
    let mut found := []
    for hit in hits do
      let typ ← IO.ofExcept ((← IO.ofExcept (hit.getObjVal? "concept_type")).getStr?)
      if typ == "Constraint" then
        let id ← IO.ofExcept ((← IO.ofExcept (hit.getObjVal? "node_id")).getStr?)
        let content ← IO.ofExcept ((← IO.ofExcept (hit.getObjVal? "content")).getStr?)
        let stale ← IO.ofExcept (contradiction (← Kalari.Lambo.inspect client id))
        found := found ++ [{ id, label := content, stale }]
    return found
  resolve := evidenceResolver store
  applies := Kalari.Clef.lessonApplies runner delay keyEnv
}

private def recordedLinkedLessons (text : String) : List Kalari.Lambo.Lesson := Id.run do
  let mut lessons := []
  for line in text.splitOn "\n" do
    let some row := (Json.parse line).toOption | continue
    if (row.getObjValAs? String "dir").toOption != some "in" then continue
    let some msg := (row.getObjVal? "msg").toOption | continue
    let some result := (msg.getObjVal? "result").toOption | continue
    let some structured := (result.getObjVal? "structuredContent").toOption | continue
    let some focus := (structured.getObjVal? "focus").toOption | continue
    let some depsValue := (focus.getObjVal? "dependents").toOption | continue
    let some dependents := depsValue.getArr?.toOption | continue
    for dep in dependents do
      if (dep.getObjValAs? String "edge_type").toOption == some "Dependency" then
        let id := (dep.getObjValAs? String "node_id").toOption.getD ""
        let label := (dep.getObjValAs? String "label").toOption.getD ""
        if !id.isEmpty && (label.endsWith " [Constraint]" || label.endsWith " [Constraint, candidate]") then
          lessons := lessons ++ [{ id, label, stale := false }]
  return lessons

private def test : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let check : Kalari.Model.Check := {
    id := "chk-paging-001", assertion := "follow the cursor to completion; records appear exactly once",
    command := ["python3", "checks/payouts.py"] }
  let lesson : Kalari.Model.Lesson := {
    change_kind := "pagination_changed", observation := "boundary repeats and the final cursor must be followed",
    run_id := "r-001", check }
  let otherCheck : Kalari.Model.Check := {
    id := "chk-rename-002", assertion := "preserve compatibility after the rename",
    command := ["python3", "checks/rename.py"] }
  let other : Kalari.Model.Lesson := {
    change_kind := "rename", observation := "renamed operation retains a legacy alias", run_id := "r-002",
    check := otherCheck }
  for stored in [lesson, other] do
    Kalari.Evidence.append store {
      kind := "lesson", session_id := "s1", run_id := stored.run_id,
      change_kinds := [stored.change_kind], payload := toJson stored }
  let linked := recordedLinkedLessons (include_str "../../testdata/lambo/receipt.jsonl")
  unless linked.any (fun item => item.label.contains "check: chk-paging-001") do
    throw <| .userError "recorded Lambo payout dependency not found"
  let freeText : Kalari.Lambo.Lesson := {
    id := "semantic-free-text", label := "The demo API v1 returns all items in one response [Constraint]", stale := false }
  let typedSemantic : Kalari.Lambo.Lesson := {
    id := "semantic-typed", label := "Keep the previous operation available during migration | kalari-lesson/v1 run_id=r-002 check_id=chk-rename-002",
    stale := false }
  let src : Sources := {
    linked := fun _ => pure linked
    semantic := fun _ => pure (freeText :: typedSemantic :: linked)
    resolve := evidenceResolver store
    applies := fun _ _ => pure (.ok (.probabilities [("pagination_changed", 0.025)]))
  }
  let result ← call src ["pagination_changed"]
  unless result.length == 2 &&
      result.any (fun x => x.status == "required" && x.lesson.run_id == "r-001" && x.lesson.check == check) &&
      result.any (fun x => x.status == "advice" && x.lesson.run_id == "r-002" && x.lesson.check == otherCheck) do
    throw <| .userError "recorded linked/semantic lesson classification failed"
  let some linkedItem := linked.head? | throw <| .userError "recorded dependency disappeared"
  let staleSrc := { src with linked := fun _ => pure [{ linkedItem with stale := true }] }
  let stale ← call staleSrc ["pagination_changed"]
  unless stale.any (fun x => x.status == "stale" && x.stale) do
    throw <| .userError "stale lesson promoted"
  -- A fresh store links nothing: recall is empty, not an error, so the first
  -- run still proceeds. (The Lambo side maps the exact not-found reply to []
  -- in `Kalari.Lambo.noConceptChecks`.)
  let freshSrc := { src with linked := fun _ => pure [], semantic := fun _ => pure [] }
  let fresh ← call freshSrc ["pagination_changed", "other_kind"]
  unless fresh.isEmpty do throw <| .userError "fresh store recall was not empty"
  let ambiguousStore ← Kalari.Evidence.openStore (dir / "ambiguous")
  for _ in [0:2] do
    Kalari.Evidence.append ambiguousStore {
      kind := "lesson", session_id := "s2", run_id := "r-ambiguous", change_kinds := ["pagination_changed"],
      payload := toJson { lesson with run_id := "r-ambiguous" } }
  let ambiguous ← resolveEvidence ambiguousStore {
    observation := "legacy", runId := none, checkId := check.id }
  unless (match ambiguous with | .error _ => true | .ok _ => false) do
    throw <| .userError "ambiguous legacy evidence reference accepted"
  let missingItem : Kalari.Lambo.Lesson := {
    id := "missing-linked", label := "missing | kalari-lesson/v1 run_id=r-missing check_id=chk-missing", stale := false }
  let missingSource := { src with linked := fun _ => pure [missingItem], semantic := fun _ => pure [] }
  let mut missingFailed := false
  try
    let _ ← call missingSource ["pagination_changed"]
    pure ()
  catch _ => missingFailed := true
  unless missingFailed do throw <| .userError "recognized linked lesson with missing evidence did not fail closed"
  let duplicateItem : Kalari.Lambo.Lesson := {
    id := "duplicate-linked", label := "duplicate | kalari-lesson/v1 run_id=r-ambiguous check_id=chk-paging-001", stale := false }
  let duplicateSource : Sources := {
    linked := fun _ => pure [duplicateItem]
    semantic := fun _ => pure []
    resolve := evidenceResolver ambiguousStore
    applies := src.applies
  }
  let mut duplicateError := ""
  try
    let _ ← call duplicateSource ["pagination_changed"]
    pure ()
  catch error => duplicateError := error.toString
  unless duplicateError.contains "ambiguous lesson evidence" do
    throw <| .userError "recognized linked lesson did not report ambiguous evidence"
  -- An old store holding one constraint concept per verifying run for the
  -- same identity collapses into one entry listing every concept and run.
  let dupStore ← Kalari.Evidence.openStore (dir / "dup-collapse")
  let dupCheck : Kalari.Model.Check := {
    id := "chk-paging-001", assertion := "follow the cursor to completion; records appear exactly once",
    command := ["python3", "checks/payouts.py"] }
  for dupRun in ["r-dup-one", "r-dup-two"] do
    let dupLesson : Kalari.Model.Lesson := { change_kind := "pagination_changed", observation := "boundary repeats and the final cursor must be followed", run_id := dupRun, check := dupCheck }
    Kalari.Evidence.append dupStore { kind := "lesson", session_id := "s1", run_id := dupRun, change_kinds := ["pagination_changed"], payload := toJson dupLesson }
  let dupLinked : List Kalari.Lambo.Lesson := [
    { id := "concept-one", label := "boundary repeats and the final cursor must be followed | kalari-lesson/v1 run_id=r-dup-one check_id=chk-paging-001", stale := false },
    { id := "concept-two", label := "boundary repeats and the final cursor must be followed | kalari-lesson/v1 run_id=r-dup-two check_id=chk-paging-001", stale := false }]
  let dupSrc : Sources := {
    linked := fun _ => pure dupLinked
    semantic := fun _ => pure []
    resolve := evidenceResolver dupStore
    applies := src.applies
  }
  let dupResult ← call dupSrc ["pagination_changed"]
  let [collapsed] := dupResult | throw <| .userError "duplicate concepts did not collapse to one entry"
  unless collapsed.concepts.eraseDups.length == 2 &&
      collapsed.concepts.contains "concept-one" &&
      collapsed.concepts.contains "concept-two" &&
      collapsed.confirming_runs.contains "r-dup-one" &&
      collapsed.confirming_runs.contains "r-dup-two" &&
      collapsed.status == "required" do
    throw <| .userError "collapsed entry did not list every concept and confirming run"
  IO.println "recall: duplicate concepts collapse to one entry"
  unless parseReference "ordinary prose [Constraint]" == none do
    throw <| .userError "ordinary Constraint text misidentified as a lesson"
  unless (parseReference "rule text | kalari-lesson/v1 run_id=r-001 check_id=chk-paging-001").isSome do
    throw <| .userError "versioned lesson reference not recognized"

#eval test
end Kalari.Tools.Recall
