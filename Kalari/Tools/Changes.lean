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

private def emptyReport (id status : String) (extra : List (String × Json) := []) : Json :=
  Json.mkObj ([("change_id", Json.str id), ("status", Json.str status),
    ("confirmed", toJson ([] : List Json)), ("uncertain", toJson ([] : List Json))] ++ extra)

private def skippedReport (session : Session) (id : String) : Json :=
  match session.changes.find? (fun c => c.fact.id == id) with
  | none => emptyReport id "unknown_change_id" [
      ("note", Json.str "not an ID from what_changed in this session")]
  | some change =>
    if change.operation.isSome then emptyReport id "searched"
    else emptyReport id "not_searchable" [
      ("kind", Json.str change.fact.kind),
      ("note", Json.str "this change has no operation to search for in code; review it by hand")]

/-- Search each operation and link its sites. Return one status per requested ID,
including unknown and non-searchable changes. Reject an oversized minimum response
before side effects; shorten site lists with an explicit marker when needed. -/
def blastRadius (session : Session) (runner : Kalari.Search.Runner)
    (confirm : Kalari.Search.Confirmer) (write : ScopedWrite)
    (repoScope workspace : String) (ids : List String) : IO (Except String Json) := do
  if repoScope.isEmpty then return .error "empty repo_scope"
  if ids.isEmpty then return .error "empty change_ids"
  let minimum := ids.map (skippedReport session)
  -- Reserve space for truncation markers before any search or graph write.
  let reserved := minimum.map fun j =>
    match j.getObjValAs? String "status" with
    | .ok "searched" => emptyReport ((j.getObjValAs? String "change_id").toOption.getD "")
        "searched" [("truncated", Json.bool true)]
    | _ => j
  if (Json.mkObj [("reports", toJson reserved)]).compress.utf8ByteSize > outputBudget then
    return .error "change_ids response exceeds byte budget; request fewer or shorter IDs"
  let mut reports := minimum.toArray
  for index in [:ids.length] do
    let id := ids[index]!
    let some change := session.changes.find? (fun c => c.fact.id == id) | continue
    let some op := change.operation | continue
    let report ← match ← Kalari.Search.search runner confirm change.fact op workspace with
      | .error e => return .error e
      | .ok r => pure r
    let uncertain := report.uncertain.map fun u => Json.mkObj [
      ("site", siteJson u.site), ("probability", toJson u.probability)]
    let mut confirmed := report.radius.call_sites.map siteJson
    let mut remaining := uncertain
    let mut truncated := false
    -- Future reports retain their reserved minimum space.
    let tail := reserved.drop (index + 1)
    for _ in [:confirmed.length + remaining.length + 1] do
      let current := Json.mkObj ([("change_id", Json.str id), ("status", Json.str "searched"),
        ("confirmed", toJson confirmed), ("uncertain", toJson remaining)] ++
        if truncated then [("truncated", Json.bool true)] else [])
      let trial := reports.toList.take index ++ [current] ++ tail
      if (Json.mkObj [("reports", toJson trial)]).compress.utf8ByteSize ≤ outputBudget then
        reports := reports.set! index current
        break
      truncated := true
      if !remaining.isEmpty then remaining := remaining.take (remaining.length - 1)
      else confirmed := confirmed.take (confirmed.length - 1)
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
    let some skipped := session.changes.find? (fun c => c.operation.isNone)
      | throw <| .userError "no non-searchable change"
    writes.set []
    let radius ← IO.ofExcept (← blastRadius session (Kalari.Search.live "/usr/bin:/bin") confirm writer "kalari/test" workspace [page.fact.id, skipped.fact.id, "made-up-id"])
    let reports ← IO.ofExcept (radius.getObjValAs? (List Json) "reports")
    unless reports.length == 3 do throw <| .userError "report count"
    for (item, id, status) in reports.zip [page.fact.id, skipped.fact.id, "made-up-id"] |>.zip ["searched", "not_searchable", "unknown_change_id"] |>.map (fun ((item, id), status) => (item, id, status)) do
      unless (item.getObjValAs? String "change_id").toOption == some id &&
          (item.getObjValAs? String "status").toOption == some status do
        throw <| .userError "report order or status"
    let log ← writes.get
    unless log.filter (fun (_, _, deps) => deps.isEmpty) == [("kalari/test", s!"change {page.fact.id}", [])] do
      throw <| .userError "skipped change wrote graph links"
    IO.println s!"mixed blast_radius: {radius.compress}"
    for ids in [[], [String.ofList (List.replicate outputBudget 'x')]] do
      writes.set []
      match ← blastRadius session (Kalari.Search.live "/usr/bin:/bin") confirm writer "kalari/test" workspace ids with
      | .ok _ => throw <| .userError "invalid request succeeded"
      | .error _ => pure ()
      unless (← writes.get).isEmpty do throw <| .userError "invalid request wrote links"
    writes.set []
    let skippedOnly ← IO.ofExcept (← blastRadius session (Kalari.Search.live "/usr/bin:/bin") confirm writer "kalari/test" workspace ["made-up-id", skipped.fact.id, "made-up-id"])
    unless (← IO.ofExcept (skippedOnly.getObjValAs? (List Json) "reports")).length == 3 &&
        (← writes.get).isEmpty do throw <| .userError "skipped-only request"
    -- Restore a searched write for the shared scoped-link assertion below.
    discard <| IO.ofExcept (← blastRadius session (Kalari.Search.live "/usr/bin:/bin") confirm writer "kalari/test" workspace [page.fact.id])

    unless radius.compress.contains file && radius.compress.utf8ByteSize ≤ outputBudget do throw <| .userError "blast radius output"
  let log ← writes.get
  unless log.all (fun (scope, _, _) => scope == "kalari/test") && log.any (fun (_, _, deps) => deps == ["change-concept"]) do
    throw <| .userError "scoped graph links"

#eval test
end Kalari.Tools.Changes
