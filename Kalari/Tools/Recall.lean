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
  deriving Repr, BEq, ToJson

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
Unrecognized constraints and ambiguous/missing evidence references are skipped. -/
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
          out := out ++ [{ lesson := lesson, stale := item.stale, status }]
          seen := item.id :: seen
  return out

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
  unless parseReference "ordinary prose [Constraint]" == none do
    throw <| .userError "ordinary Constraint text misidentified as a lesson"
  unless (parseReference "rule text | kalari-lesson/v1 run_id=r-001 check_id=chk-paging-001").isSome do
    throw <| .userError "versioned lesson reference not recognized"

#eval test
end Kalari.Tools.Recall
