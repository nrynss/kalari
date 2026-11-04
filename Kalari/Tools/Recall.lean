import Kalari.Lambo
import Kalari.Clef
import Kalari.Model

/-! Recall linked lessons first, then classify semantic candidates. Constraints
store a JSON-encoded `Model.Lesson`; this preserves the executable check and
run citation, rather than reconstructing them from free text. -/

open Lean
namespace Kalari.Tools.Recall

structure Entry where
  lesson : Kalari.Model.Lesson
  status : String
  stale : Bool
  deriving Repr, BEq, ToJson

/-- Operations exposed for fixture replay; the production implementation uses
Lambo's typed client and Clef's typed lesson question. -/
structure Sources where
  linked : String → IO (List Kalari.Lambo.Lesson)
  semantic : String → IO (List Kalari.Lambo.Lesson)
  applies : String → List (String × String) → IO (Except String Kalari.Backend.DecisionAnswer)

def threshold : Float := 0.9

private def decodeLesson (id label : String) : Except String Kalari.Model.Lesson := do
  let text := if label.endsWith " [Constraint, candidate]" then
    (label.toSlice.dropEnd " [Constraint, candidate]".length).toString
  else if label.endsWith " [Constraint]" then
    (label.toSlice.dropEnd " [Constraint]".length).toString
  else label
  let lesson : Kalari.Model.Lesson ← Json.parse text >>= fromJson?
  if lesson.check.id.isEmpty || lesson.check.assertion.isEmpty || lesson.run_id.isEmpty then
    throw "lesson lacks check ID, assertion or run ID"
  return { lesson with memory_concept_id := some id }

private def isConfident (answer : Kalari.Backend.DecisionAnswer) (kinds : List String) : Bool :=
  match answer with
  | .probabilities ps => kinds.any fun kind =>
      match ps.find? (fun p => p.1 == kind) with
      | some (_, p) => p >= threshold && p <= 1.0
      | none => false
  | _ => false

/-- Stale lessons remain visible, explicitly labelled, and never become checks. -/
def call (source : Sources) (kinds : List String) : IO (List Entry) := do
  let mut out : List Entry := []
  let mut seen : List String := []
  for kind in kinds do
    for item in (← source.linked kind) do
      if !seen.contains item.id then
        let lesson ← IO.ofExcept (decodeLesson item.id item.label)
        out := out ++ [{ lesson := lesson, stale := item.stale, status := if item.stale then "stale" else "required" }]
        seen := item.id :: seen
  for kind in kinds do
    for item in (← source.semantic kind) do
      if !seen.contains item.id then
        let lesson ← IO.ofExcept (decodeLesson item.id item.label)
        let status ← if item.stale then pure "stale" else do
          let answer ← source.applies item.label (kinds.map fun k => (k, k))
          pure <| match answer with
            | .ok answer => if isConfident answer kinds then "required" else "advice"
            | .error _ => "advice"
        out := out ++ [{ lesson, stale := item.stale, status }]
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

/-- Construct the production source. Semantic hits are inspected for incoming
contradictions just like graph-linked constraints. -/
def sources (client : Kalari.Lambo.Client) (runner : Kalari.Clef.Runner)
    (delay : Kalari.Clef.Delay) (keyEnv : String) : Sources := {
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
  applies := Kalari.Clef.lessonApplies runner delay keyEnv
}

private def test : IO Unit := do
  let check : Kalari.Model.Check := { id := "exactly-once", assertion := "last delivery wins", command := ["check"] }
  let lesson : Kalari.Model.Lesson := { change_kind := "pagination_changed", observation := "boundary repeats", run_id := "payouts-run", check }
  let other : Kalari.Model.Lesson := { lesson with change_kind := "rename", run_id := "other-run" }
  let linked : Kalari.Lambo.Lesson := { id := "a", label := (toJson lesson).compress ++ " [Constraint]", stale := false }
  let semantic : Kalari.Lambo.Lesson := { id := "b", label := (toJson other).compress, stale := false }
  let src : Sources := {
    linked := fun _ => pure [linked]
    semantic := fun _ => pure [linked, semantic]
    applies := fun _ _ => pure (.ok (.probabilities [("pagination_changed", 0.025)]))
  }
  let result ← call src ["pagination_changed"]
  unless result.length == 2 && result.any (fun x => x.status == "required" && x.lesson.run_id == "payouts-run" && x.lesson.check == check) && result.any (fun x => x.status == "advice" && x.lesson.run_id == "other-run") do
    throw <| .userError "recall classification failed"
  let staleSrc := { src with linked := fun _ => pure [{ linked with stale := true }] }
  let stale ← call staleSrc ["pagination_changed"]
  unless stale.any (fun x => x.status == "stale" && x.stale) do throw <| .userError "stale lesson promoted"

#eval test
end Kalari.Tools.Recall
