import Kalari.Vimanam
import Kalari.Search
import Kalari.Lambo

/-! Agent-facing changes and caller search. The session retains the full diff
so change IDs resolve to operations without extending the MCP input schema. -/

open Lean
namespace Kalari.Tools.Changes

/-- A conservative byte budget: UTF-8 output is limited to 16,000 bytes. -/
def outputBudget : Nat := 16000

def contextBudget : Nat := 2000

structure Change where
  fact : Kalari.Model.ChangeFact
  operation : Option Kalari.Search.Operation

structure Session where
  changes : List Change
  context : String

/-- The scope is passed to Lambo's write operation, not prepended to content.
The writer must wait for the receipt and return the applied resource ID. -/
abbrev ScopedWrite := String → String → List String → IO (Except String String)

/-- Production resource writer, with a settled receipt and top-level repo scope. -/
def resourceWriter (client : Kalari.Lambo.Client) : ScopedWrite :=
  fun scope content deps => do
    try
      let receipt ← Kalari.Lambo.derive client "resource" content deps [] (some scope)
      return .ok (← Kalari.Lambo.awaitConceptId client receipt)
    catch e => return .error e.toString

private def str? (j : Json) (key : String) : Option String :=
  (j.getObjVal? key >>= Json.getStr?).toOption

private def native? (j : Json) : Option Json := (j.getObjVal? "native").toOption

private def path? (j : Json) : Option String := do
  let native ← native? j
  str? native "path"

private def oldPath? (changes : List Json) (newPath : String) : Option String := do
  let moved ← changes.find? fun j => str? j "kind" == some "operation_moved" && path? j == some newPath
  let details ← (moved.getObjVal? "details").toOption
  str? details "old_path"

private def operation? (changes : List Json) (j : Json) : Option Kalari.Search.Operation := do
  let native ← native? j
  let format ← str? native "format"
  if format == "openapi" then
    let path ← str? native "path"
    return { format := .rest, name := (oldPath? changes path).getD path }
  else if format == "graphql" then
    let coordinate ← str? native "coordinate"
    let parts := coordinate.splitOn "."
    let field ← parts[1]?
    let name := (field.splitOn "(").headD ""
    if name.isEmpty then none else some { format := .graphql, name }
  else if format == "protobuf" then
    let name ← str? native "rpc"
    some { format := .grpc, name }
  else none

private def processText (r : Kalari.Proc.Result) : Except String String := do
  if r.cap != .none then throw "vimanam: output or time cap"
  if r.exitCode != some 0 then
    throw s!"vimanam failed: {(String.fromUTF8? r.stderr).getD "invalid UTF-8"}"
  match String.fromUTF8? r.stdout with
  | none => throw "vimanam: invalid UTF-8"
  | some text => return text

private def bounded (j : Json) : Except String Json :=
  if j.compress.utf8ByteSize > outputBudget then .error s!"output exceeds {outputBudget} byte budget"
  else .ok j

/-- Run the JSON diff, retaining native operation metadata, then obtain GraphQL
focused context. OpenAPI has no focused context flag; its facts are the context. -/
def whatChanged (runner : Kalari.Vimanam.Runner) (oldSpec newSpec : String) :
    IO (Except String (Session × Json)) := do
  let result ← runner (Kalari.Vimanam.diffArgv oldSpec newSpec)
    Kalari.Vimanam.diffTimeoutMs Kalari.Vimanam.diffOutputCap
  let parsed : Except String (List Change) := do
    let text ← processText result
    let raw ← (← (← Json.parse text).getObjVal? "changes").getArr?
    raw.toList.mapM fun j => do
      let fact ← fromJson? j
      return { fact, operation := operation? raw.toList j }
  match parsed with
  | .error e => return .error e
  | .ok changes =>
    let contextResult ← if Kalari.Vimanam.isGraphQL oldSpec && Kalari.Vimanam.isGraphQL newSpec then
      Kalari.Vimanam.focusedContext runner oldSpec newSpec contextBudget
      else pure (.ok "")
    match contextResult with
    | .error e => return .error e
    | .ok context =>
      let out := Json.mkObj [("changes", toJson (changes.map (·.fact))), ("context", Json.str context)]
      match bounded out with
      | .error e => return .error e
      | .ok out => return .ok ({ changes, context }, out)

private def siteJson (site : Kalari.Model.CallSite) : Json := toJson site

/-- Each known change is searched and linked to its confirmed and uncertain
sites. Unknown IDs or changes without an operation fail explicitly. -/
def blastRadius (session : Session) (runner : Kalari.Search.Runner)
    (confirm : Kalari.Search.Confirmer) (write : ScopedWrite)
    (repoScope workspace : String) (ids : List String) : IO (Except String Json) := do
  if repoScope.isEmpty then return .error "empty repo_scope"
  let mut reports : List Json := []
  for id in ids do
    let some change := session.changes.find? (fun c => c.fact.id == id)
      | return .error s!"unknown change ID: {id}"
    let some op := change.operation
      | return .error s!"change has no searchable operation: {id}"
    let report ← match ← Kalari.Search.search runner confirm change.fact op workspace with
      | .error e => return .error e
      | .ok r => pure r
    let uncertain := report.uncertain.map fun u => Json.mkObj [
      ("site", siteJson u.site), ("probability", toJson u.probability)]
    reports := reports ++ [Json.mkObj [("change_id", Json.str id),
      ("confirmed", toJson report.radius.call_sites), ("uncertain", toJson uncertain)]]
    let changeId ← match ← write repoScope s!"change {id}" [] with
      | .error e => return .error e
      | .ok v => pure v
    for site in report.radius.call_sites do
      match ← write repoScope s!"confirmed call site {(siteJson site).compress}" [changeId] with
      | .error e => return .error e
      | .ok _ => pure ()
    for u in report.uncertain do
      match ← write repoScope s!"uncertain call site {(siteJson u.site).compress}" [changeId] with
      | .error e => return .error e
      | .ok _ => pure ()
  return bounded (Json.mkObj [("reports", toJson reports)])

private def replay : Kalari.Vimanam.Runner := fun argv _ _ => do
  let path := if argv.contains "bench/workspaces/payout-sync/specs/openapi-v1.yaml" then
    "testdata/vimanam/2.1.0/payouts.json"
  else if argv.contains "--context" then "testdata/vimanam/2.1.0/settlements.context.md"
  else "testdata/vimanam/2.1.0/settlements.json"
  return { exitCode := some 0, stdout := ← IO.FS.readBinFile path, stderr := .empty, wallMs := 0, cap := .none }

private def test : IO Unit := do
  let writes ← IO.mkRef ([] : List (String × String × List String))
  let writer : ScopedWrite := fun scope content deps => do
    writes.modify fun xs => xs ++ [(scope, content, deps)]
    return .ok "change-concept"
  let confirm : Kalari.Search.Confirmer := fun _ hits => pure <| .ok (hits.map fun h => (h.1, 0.25))
  for (oldSpec, newSpec, workspace, file) in [
      ("bench/workspaces/payout-sync/specs/openapi-v1.yaml", "bench/workspaces/payout-sync/specs/openapi-v2.yaml", "bench/workspaces/payout-sync", "payout_sync.py"),
      ("bench/workspaces/settlement-reconcile/specs/schema-v1.graphql", "bench/workspaces/settlement-reconcile/specs/schema-v2.graphql", "bench/workspaces/settlement-reconcile", "settlement_reconcile.py")] do
    let (session, changes) ← IO.ofExcept (← whatChanged replay oldSpec newSpec)
    unless changes.compress.contains "pagination_changed" && changes.compress.utf8ByteSize ≤ outputBudget do throw <| .userError "changes output"
    let some page := session.changes.find? (fun c => c.fact.kind == "pagination_changed") | throw <| .userError "no pagination change"
    let radius ← IO.ofExcept (← blastRadius session (Kalari.Search.live "/usr/bin:/bin") confirm writer "kalari/test" workspace [page.fact.id])
    unless radius.compress.contains file && radius.compress.utf8ByteSize ≤ outputBudget do throw <| .userError "blast radius output"
  let log ← writes.get
  unless log.all (fun (scope, _, _) => scope == "kalari/test") && log.any (fun (_, _, deps) => deps == ["change-concept"]) do
    throw <| .userError "scoped graph links"

#eval test
end Kalari.Tools.Changes
