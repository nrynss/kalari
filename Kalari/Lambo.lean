import Lean.Data.Json
import Kalari.Backend
import Kalari.Config

/-! Lambo MCP client. All writes use one stable agent identity. -/

open Lean
namespace Kalari.Lambo

private def agent : String := "kalari"
private def obj := Json.mkObj
private def field (j : Json) (k : String) : Except String Json := j.getObjVal? k
private def str (j : Json) (k : String) : Except String String := (field j k) >>= Json.getStr?
private def arr (j : Json) (k : String) : Except String (Array Json) := (field j k) >>= Json.getArr?

/-- The actual response is retained so receipts piggybacked on later replies are visible. -/
structure Reply where
  result : Json
  structured : Json

private def decode (msg : Json) (id : Nat) : Except String Reply := do
  let got ← field msg "id"
  unless got == toJson id do throw "unexpected JSON-RPC response id"
  if (field msg "error").isOk then throw s!"JSON-RPC error: {(← field msg "error").compress}"
  let result ← field msg "result"
  if (field result "isError").toOption == some (Json.bool true) then
    throw s!"Lambo tool error: {result.compress}"
  return { result, structured := (field result "structuredContent").toOption.getD Json.null }

/-- Tool failures arrive as a result with `isError: true`. They answered with
the matching id, so the child stays alive. Transport and protocol failures
kill it. -/
private def isToolError (e : IO.Error) : Bool :=
  (e.toString.toSlice.dropPrefix? "Lambo tool error: ".toSlice).isSome

/-- The text of a tool failure's single content item, when it has exactly one. -/
private def toolText (e : IO.Error) : Option String := do
  let rest ← (e.toString.toSlice.dropPrefix? "Lambo tool error: ".toSlice).map (·.toString)
  let j ← (Json.parse rest).toOption
  let content ← (field j "content").toOption
  let items ← (Json.getArr? content).toOption
  let first ← items[0]?
  let text ← (field first "text").toOption
  (Json.getStr? text).toOption

/-- Exact Lambo reply when a focus has no concept (measured on 0.8.0 and
0.9.0: `lambo_inspect: no concept matching '<focus>' in session '<name>'`).
Once similar concepts exist Lambo appends a `suggestions` block naming them;
that is still the not-found reply, not another error. The session name varies
by deployment, so it is matched structurally; the focus must equal the
requested change kind. Anything else rethrows. -/
def isNoConcept (focus text : String) : Bool :=
  match text.toSlice.dropPrefix? s!"lambo_inspect: no concept matching '{focus}' in session '".toSlice with
  | none => false
  | some rest =>
    match rest.toString.splitOn "'" with
    | [holder, tail] =>
      if holder.isEmpty || holder.contains '\'' then false
      else tail == "" || (tail.toSlice.dropPrefix? "\nsuggestions".toSlice).isSome
    | _ => false

private abbrev Child := IO.Process.Child { stdin := .piped, stdout := .piped, stderr := .inherit }
structure Session where
  child : Child
  nextId : Nat

/-- A single client serializes its operations; callers must not invoke it concurrently. -/
structure Client where
  config : Kalari.Config.Lambo
  state : IO.Ref (Option Session)

private def message (method : String) (params : Json) (id : Option Nat) : Json :=
  obj <| [("jsonrpc", Json.str "2.0"), ("method", Json.str method), ("params", params)] ++
    match id with | none => [] | some n => [("id", toJson n)]

private def send (s : Session) (method : String) (params : Json) : IO (Session × Reply) := do
  let id := s.nextId
  s.child.stdin.putStrLn (message method params (some id)).compress
  s.child.stdin.flush
  let line ← s.child.stdout.getLine
  if line.isEmpty then throw <| .userError "Lambo exited while awaiting a response"
  let j ← IO.ofExcept (Json.parse line)
  let reply ← IO.ofExcept (decode j id)
  return ({ s with nextId := id + 1 }, reply)

private def start (cfg : Kalari.Config.Lambo) : IO Session := do
  let cmd :: args := cfg.command | throw <| .userError "empty Lambo command"
  let argv := (args ++ ["--config", cfg.config_path, "--agent", agent]).toArray
  let child ← IO.Process.spawn {
    cmd := cmd
    args := argv
    stdin := .piped
    stdout := .piped
    stderr := .inherit
  }
  let initial : Session := { child, nextId := 1 }
  try
    let (s, _) ← send initial "initialize" (obj [("protocolVersion", "2025-06-18"),
      ("capabilities", obj []), ("clientInfo", obj [("name", "kalari"), ("version", "0.1.0")])])
    child.stdin.putStrLn (message "notifications/initialized" (obj []) none).compress
    child.stdin.flush
    return s
  catch e =>
    child.kill
    discard child.wait
    throw e

/-- Create a client. The child starts lazily on the first call. -/
def create (config : Kalari.Config.Lambo) : IO Client := do
  return { config, state := ← IO.mkRef none }

private def closeInput (child : Child) : IO (IO.Process.Child { stdin := .null, stdout := .piped, stderr := .inherit }) := do
  let (_, child) ← child.takeStdin
  return child

/-- Stop and reap the child. A later call starts a fresh child. -/
def shutdown (c : Client) : IO Unit := do
  if let some s ← c.state.get then
    c.state.set none
    -- Lambo exits on EOF; extract stdin so that it can be dropped before wait.
    let child ← closeInput s.child
    discard child.wait

private def session (c : Client) : IO Session := do
  if let some s ← c.state.get then
    if (← s.child.tryWait).isNone then return s
    c.state.set none
  -- A killed child orphans Lambo's single-writer lease for about 45 s: the
  -- next serve exits at once with no reply. Wait it out instead of failing.
  -- Only start failures that look like a dead child retry; anything else
  -- (bad command, bad config) fails at once.
  let startMs ← IO.monoMsNow
  let mut last : IO.Error := .userError "Lambo did not start"
  while (← IO.monoMsNow) - startMs < 60000 do
    let attempt : Except IO.Error Session ← try pure (.ok (← start c.config)) catch e => pure (.error e)
    match attempt with
    | .ok s =>
      c.state.set (some s)
      return s
    | .error e =>
      last := e
      let msg := e.toString
      if msg.contains "Lambo exited while awaiting a response" ||
          msg.contains "held by another writer" || msg.contains "single-writer lease" then
        IO.sleep 1000
      else throw e
  throw last

/-- A tool failure keeps the child: it answered with the matching id, so the
next id is consumed but the session survives. Anything else (the child is
gone, the reply is unparseable, the id mismatches, a JSON-RPC error) kills
the child; the next `session` waits out Lambo's orphaned single-writer lease
(~45 s) instead of failing. No automatic replay after an ambiguous failure:
a write might already be accepted. -/
private def call (c : Client) (name : String) (args : List (String × Json)) : IO Reply := do
  let s ← session c
  try
    let (s, r) ← send s "tools/call" (obj [("name", Json.str name),
      ("arguments", obj (("agent_id", Json.str agent) :: args))])
    c.state.set (some s)
    return r
  catch e =>
    if isToolError e then
      c.state.set (some { s with nextId := s.nextId + 1 })
      throw e
    c.state.set none
    try s.child.kill catch _ => pure ()
    try discard s.child.wait catch _ => pure ()
    throw e

/-- Derive a typed concept and return its asynchronous receipt. -/
def derive (c : Client) (kind content : String) (dependsOn against : List String := [])
    (repoScope : Option String := none) : IO String := do
  let concept := obj [("concept_type", Json.str kind), ("content", Json.str content),
    ("depends_on", toJson dependsOn), ("against", toJson against)]
  let args := [("concepts", Json.arr #[concept])] ++
    (match repoScope with | none => [] | some scope => [("repo_scope", Json.str scope)])
  let r ← call c "lambo_derive" args
  IO.ofExcept (str r.structured "receipt")

/-- Wait for a specific write to settle; fail rather than treating a pending or failed write as applied. -/
def awaitReceipt (c : Client) (receipt : String) (waitMs : Nat := 10000) : IO Json := do
  let r ← call c "lambo_stats" [("receipt", Json.str receipt), ("wait_ms", toJson waitMs)]
  let result ← IO.ofExcept (field r.structured "receipt")
  let returnedReceipt ← IO.ofExcept (str result "id")
  unless returnedReceipt == receipt do
    throw <| .userError s!"Lambo receipt mismatch: requested {receipt}, received {returnedReceipt}"
  let state ← IO.ofExcept (str result "state")
  unless state == "applied" do throw <| .userError s!"write receipt {receipt}: {state}"
  return result

/-- A settled write's first created concept ID; refuses writes that matched nothing. -/
def awaitConceptId (c : Client) (receipt : String) (waitMs : Nat := 10000) : IO String := do
  let outcome ← awaitReceipt c receipt waitMs
  let created ← IO.ofExcept (arr outcome "created")
  let matched ← IO.ofExcept (arr outcome "matched")
  let id := (created ++ matched)[0]?.getD Json.null
  let id ← IO.ofExcept (Json.getStr? id)
  if id.isEmpty then throw <| .userError "Lambo applied write returned an empty concept ID"
  return id

/-- Write and wait before a dependent write or read. -/
def write (c : Client) (kind content : String) (dependsOn against : List String := [])
    (repoScope : Option String := none) : IO Json := do
  let receipt ← derive c kind content dependsOn against repoScope
  awaitReceipt c receipt

/-- Inspect the graph by concept ID or content. -/
def inspect (c : Client) (focus : String) : IO Json := do
  return (← call c "lambo_inspect" [("focus", Json.str focus), ("depth", toJson (1 : Nat))]).structured

/-- Semantic recall is supplementary to graph traversal. -/
def «recall» (c : Client) (query : String) : IO Json := do
  return (← call c "lambo_recall" [("query", Json.str query)]).structured

structure Lesson where
  id : String
  label : String
  stale : Bool
  deriving Repr, BEq

private def isConstraintLabel (label : String) : Bool :=
  label.endsWith " [Constraint]" || label.endsWith " [Constraint, candidate]"

private def hasContradiction (j : Json) : Except String Bool := do
  let focus ← field j "focus"
  let levels ← arr focus "levels"
  for level in levels do
    for edge in (← arr level "neighbours") do
      if (← str edge "edge_type") == "Contradicts" && (← str edge "direction") == "<-" then
        return true
  return false

/-- Traverse change-kind dependencies and inspect each constraint for incoming contradictions.
An unknown change kind is zero lessons, not an error: a fresh store has no
concept for any kind yet, so the first session must still run. Only the exact
Lambo not-found reply is mapped; every other failure rethrows. -/
def lessons (c : Client) (changeKind : String) : IO (List Lesson) := do
  let graph ← try inspect c changeKind catch e =>
    match toolText e with
    | some text => if isNoConcept changeKind text then return [] else throw e
    | none => throw e
  let focus ← IO.ofExcept (field graph "focus")
  if (field focus "dependents_truncated").toOption == some (Json.bool true) then
    throw <| .userError "Lambo truncated change-kind dependents"
  let deps ← IO.ofExcept (arr focus "dependents")
  let mut found : List Lesson := []
  for dep in deps do
    let edge ← IO.ofExcept (str dep "edge_type")
    let label ← IO.ofExcept (str dep "label")
    if edge == "Dependency" && isConstraintLabel label then
      let id ← IO.ofExcept (str dep "node_id")
      let stale ← IO.ofExcept (hasContradiction (← inspect c id))
      found := found ++ [{ id := id, label := label, stale := stale }]
  return found

private def recordedResponses (text : String) : List Json :=
  text.splitOn "\n" |>.filterMap fun line => do
    let row ← (Json.parse line).toOption
    if (str row "dir").toOption != some "in" then none else
      (field row "msg").toOption

private def structuredResponses (text : String) : List Json :=
  (recordedResponses text).filterMap fun msg => do
    let result ← (field msg "result").toOption
    (field result "structuredContent").toOption

private def fixtureChecks : IO Unit := do
  let rows := structuredResponses (include_str "../testdata/lambo/receipt.jsonl")
  let ack := rows.any fun j => (str j "receipt").isOk
  let applied := rows.any fun j =>
    match (field j "receipt").toOption with
    | some r => (str r "state").toOption == some "applied"
    | none => false
  let change := rows.any fun j =>
    match (field j "focus").toOption with
    | some focus =>
      (str focus "label").toOption == some "pagination_changed [Resource]" &&
      match (arr focus "dependents").toOption with
      | some deps => deps.any fun d =>
        (str d "edge_type").toOption == some "Dependency" &&
        isConstraintLabel ((str d "label").toOption.getD "")
      | none => false
    | none => false
  let contradicted := (structuredResponses (include_str "../testdata/lambo/against.jsonl")).any fun j =>
    (hasContradiction j).toOption == some true
  unless ack && applied && change && contradicted do
    throw <| .userError "Lambo recorded response checks failed"

  unless isConstraintLabel "lesson [Constraint]" &&
      isConstraintLabel "lesson [Constraint, candidate]" &&
      !isConstraintLabel "free text [Constraint] in the middle [Observation]" &&
      !isConstraintLabel "lesson [Constraint-ish]" do
    throw <| .userError "Lambo lesson type suffix checks failed"

/-! The frozen `Backend.MemoryClient` is intentionally lossy. Its adapter treats
`derive` and `against` as observation writes, `inspect` as direct dependent IDs,
and `recall` as IDs found among recall hits. Product flows that need typed
resources, constraints, citations, or stale status use `Client` directly. -/

private def validNodeId (id : String) : Bool :=
  let chunks := id.splitOn "-"
  chunks.length == 5 &&
    (chunks.map String.length) == [8, 4, 4, 4, 12] &&
    id.toList.all fun c => c == '-' || c.isDigit || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

private def dependentIds (g : Json) : IO (List String) := do
  let focus ← IO.ofExcept (field g "focus")
  if (field focus "dependents_truncated").toOption == some (Json.bool true) then
    throw <| .userError "Lambo truncated dependent IDs"
  let deps ← IO.ofExcept (arr focus "dependents")
  let mut ids := []
  for d in deps do
    let id ← IO.ofExcept (str d "node_id")
    unless validNodeId id do throw <| .userError s!"malformed Lambo dependent node ID: {id}"
    ids := ids ++ [id]
  return ids

private def recallIds (g : Json) : IO (List String) := do
  let hits ← IO.ofExcept (arr g "hits")
  let mut ids := []
  for hit in hits do
    let id ← IO.ofExcept (str hit "node_id")
    unless validNodeId id do throw <| .userError s!"malformed Lambo recall hit ID: {id}"
    ids := ids ++ [id]
  return ids

/-- The frozen backend plus its owning typed client and lifecycle operation. -/
structure MemoryAdapter where
  client : Client
  backend : Kalari.Backend.MemoryClient
  shutdown : IO Unit

/-- Lossy frozen-interface adapter. String writes become observations and
return the applied concept ID. Each adapter owns one child lifecycle. -/
def memoryClient (config : Kalari.Config.Lambo) : IO MemoryAdapter := do
  let c ← create config
  let backend : Kalari.Backend.MemoryClient := {
    derive := fun content => do
      try
        let receipt ← derive c "observation" content
        return .ok (← awaitConceptId c receipt)
      catch e => return .error e.toString
    inspect := fun focus => do
      try return .ok (← dependentIds (← inspect c focus))
      catch e => return .error e.toString
    «recall» := fun query => do
      try return .ok (← recallIds (← «recall» c query))
      catch e => return .error e.toString
    against := fun focus => do
      try
        let receipt ← derive c "observation" s!"against: {focus}" [] [focus]
        return .ok (← awaitConceptId c receipt)
      catch e => return .error e.toString
  }
  return { client := c, backend, shutdown := shutdown c }

private def transcriptServer : String := String.intercalate "\n" [
  "import json, sys",
  "rows = [json.loads(x) for x in open(sys.argv[1]) if x.strip()]",
  "responses = {}; pending = None",
  "for row in rows:",
  "    if row['dir'] == 'out': pending = row['msg']",
  "    elif pending is not None:",
  "        method = pending.get('method')",
  "        if method == 'initialize': responses.setdefault('initialize', []).append(row['msg'])",
  "        elif method == 'tools/call': responses.setdefault(pending.get('params', {}).get('name'), []).append(row['msg'])",
  "        pending = None",
  "positions = {}",
  "last_receipt = None",
  "last_concept_id = None; last_content = None",
  "death_marker = sys.argv[2] if len(sys.argv) > 2 else None",
  "for line in sys.stdin:",
  "    request = json.loads(line); method = request.get('method')",
  "    if method == 'notifications/initialized': continue",
  "    key = 'initialize' if method == 'initialize' else request.get('params', {}).get('name') if method == 'tools/call' else None",
  "    choices = responses.get(key, [])",
  "    if not choices: continue",
  "    args = request.get('params', {}).get('arguments', {})",
  "    assert args.get('agent_id') == 'kalari' if method == 'tools/call' else True",
  "    if key == 'lambo_derive':",
  "        if death_marker == 'scoped': assert args.get('repo_scope') == 'kalari/test'",
  "        else: assert 'repo_scope' not in args",
  "        c = args['concepts'][0]; assert set(c) >= {'concept_type','content','depends_on','against'}",
  "        expected = [('resource','pagination_changed'), ('constraint','When a list endpoint starts paging, follow next_page_token until absent; every record imported exactly once. check: chk-paging-001'), ('observation','run after clean child restart')]",
  "        if 'against.jsonl' in sys.argv[1]: expected = [('observation','run r-004: contradictory outcome')]",
  "        if len(sys.argv) > 2 and sys.argv[2] == 'adapter': expected = [('observation','simple observation'), ('observation','against: 36b116fe')]",
  "        i = positions.get(key, 0); assert (c['concept_type'], c['content']) == expected[min(i, len(expected)-1)]",
  "        if 'against.jsonl' in sys.argv[1]: assert c.get('against') == ['36b116fe']",
  "        elif len(sys.argv) > 2 and sys.argv[2] == 'adapter' and c['content'].startswith('against:'): assert c.get('against') == ['36b116fe']",
  "        elif len(sys.argv) > 2 and sys.argv[2] == 'adapter': assert c.get('against') == [] and c.get('depends_on') == []",
  "        elif c['concept_type'] == 'constraint': assert c.get('depends_on') == ['pagination_changed'] and c.get('against') == []",
  "        elif c['concept_type'] == 'resource': assert c.get('depends_on') == [] and c.get('against') == []",
  "    elif key == 'lambo_stats': assert args.get('receipt') == last_receipt and args.get('wait_ms') == 10000",
  "    elif key == 'lambo_inspect':",
  "        assert args.get('depth') == 1",
  "        if 'against.jsonl' in sys.argv[1]: assert args.get('focus') == '36b116fe'",
  "        elif args.get('focus') == 'pagination_changed': pass",
  "        else: assert len(args.get('focus', '')) == 36",
  "    i = 0 if key == 'lambo_stats' else positions.get(key, 0); source = json.loads(json.dumps(choices[min(i, len(choices)-1)]))",
  "    if key == 'lambo_stats':",
  "        outcome = source['result']['structuredContent']['receipt']; outcome['id'] = 'wrong-receipt' if death_marker == 'bad-receipt' else last_receipt",
  "        outcome['created'] = [] if death_marker == 'adapter' and (last_content or '').startswith('against:') else [last_concept_id]",
  "        outcome['matched'] = [last_concept_id] if death_marker == 'adapter' and (last_content or '').startswith('against:') else []",
  "    positions[key] = i + 1; source['id'] = request.get('id')",
  "    print(json.dumps(source, separators=(',', ':')), flush=True)",
  "    if key == 'lambo_derive':",
  "        if death_marker == 'scoped': assert args.get('repo_scope') == 'kalari/test'",
  "        else: assert 'repo_scope' not in args",
  "        last_receipt = source.get('result', {}).get('structuredContent', {}).get('receipt')",
  "        last_content = args['concepts'][0]['content']",
  "        if last_content == 'pagination_changed': last_concept_id = '4f15dceb-e99c-480a-95e6-d941a1b62339'",
  "        elif last_content.startswith('When a list endpoint'): last_concept_id = '36b116fe-cfc4-4e01-a51d-f12b440107ce'",
  "        elif last_content.startswith('against:'): last_concept_id = '58954999-38fc-4f5e-96d6-d0308e3919be'",
  "        else: last_concept_id = '48ad60d3-2d17-4bcf-b2c6-ae2af2ce7717'",
  "    if death_marker and death_marker.endswith('.death') and not __import__('os').path.exists(death_marker) and key == 'lambo_derive': open(death_marker, 'w').close(); __import__('os')._exit(0)" ]

private def replayConfig (transcript : String) (mode : Option String := none) : Kalari.Config.Lambo :=
  { command := ["python3", "-c", transcriptServer, transcript] ++ mode.toList,
    config_path := "testdata/lambo/lambo.toml" }

private def childReplayChecks : IO Unit := do
  let deathMarker := "/tmp/kalari-lambo-child-death-once.death"
  try IO.FS.removeFile deathMarker catch _ => pure ()
  let c ← create (replayConfig "testdata/lambo/receipt.jsonl")
  let receipt ← derive c "resource" "pagination_changed"
  let _ ← awaitReceipt c receipt
  let _ ← write c "constraint"
      "When a list endpoint starts paging, follow next_page_token until absent; every record imported exactly once. check: chk-paging-001"
      ["pagination_changed"]
  let found ← lessons c "pagination_changed"
  unless found.any (·.label.contains "chk-paging-001") do
    throw <| .userError "Lambo child transcript did not return the written lesson"
  shutdown c
  let restartedReceipt ← derive c "resource" "pagination_changed"
  let _ ← awaitReceipt c restartedReceipt
  shutdown c
  let c2 ← create (replayConfig "testdata/lambo/against.jsonl")
  let changed ← write c2 "observation" "run r-004: contradictory outcome" [] ["36b116fe"]
  let receiptState ← IO.ofExcept (str changed "state")
  unless receiptState == "applied" do throw <| .userError "Lambo contradiction transcript receipt missing"
  let stale ← IO.ofExcept (hasContradiction (← inspect c2 "36b116fe"))
  unless stale do throw <| .userError "Lambo child transcript omitted contradiction edge"
  shutdown c2
  let adapter ← memoryClient (replayConfig "testdata/lambo/receipt.jsonl" (some "adapter"))
  let derived ← adapter.backend.derive "simple observation"
  let derivedId ← match derived with
    | .ok id => pure id
    | .error e => throw <| .userError e
  unless derivedId == "48ad60d3-2d17-4bcf-b2c6-ae2af2ce7717" do
    throw <| .userError s!"MemoryClient derive returned unexpected concept ID {derivedId}"
  let recalled ← adapter.backend.«recall» "reworded paging query"
  let recalledIds ← match recalled with
    | .ok ids => pure ids
    | .error e => throw <| .userError e
  unless recalledIds.contains "73b56b66-3b07-4ed9-a7c4-9da0abfbb212" do
    throw <| .userError "MemoryClient recall omitted its recorded hit ID"
  let contradicted ← adapter.backend.against "36b116fe"
  match contradicted with
  | .ok id => unless id == "58954999-38fc-4f5e-96d6-d0308e3919be" do
      throw <| .userError s!"MemoryClient against returned unexpected concept ID {id}"
  | .error e => throw <| .userError e
  adapter.shutdown
  let scopedClient ← create (replayConfig "testdata/lambo/receipt.jsonl" (some "scoped"))
  let scopedReceipt ← derive scopedClient "resource" "pagination_changed" [] [] (some "kalari/test")
  let _ ← awaitReceipt scopedClient scopedReceipt
  shutdown scopedClient
  let c3 ← create (replayConfig "testdata/lambo/receipt.jsonl" (some deathMarker))
  let first ← derive c3 "resource" "pagination_changed"
  IO.sleep 50
  let second ← derive c3 "resource" "pagination_changed"
  let _ ← awaitReceipt c3 second
  if first.isEmpty then throw <| .userError "Lambo child-death fixture did not acknowledge first write"
  shutdown c3
  try IO.FS.removeFile deathMarker catch _ => pure ()
  let badReceiptClient ← create (replayConfig "testdata/lambo/receipt.jsonl" (some "bad-receipt"))
  let badReceipt ← derive badReceiptClient "resource" "pagination_changed"
  let mismatchRejected ← try let _ ← awaitReceipt badReceiptClient badReceipt; pure false catch _ => pure true
  shutdown badReceiptClient
  let malformedHit := obj [("hits", Json.arr #[obj [("node_id", "not-a-uuid")]])]
  let missingHit := obj [("hits", Json.arr #[obj [("content", "without an id")]])]
  let malformedHitRejected ← try let _ ← recallIds malformedHit; pure false catch _ => pure true
  let missingHitRejected ← try let _ ← recallIds missingHit; pure false catch _ => pure true
  let malformed := obj [("focus", obj [("dependents", Json.arr #[obj [("node_id", "bad")]])])]
  let truncated := obj [("focus", obj [("dependents_truncated", Json.bool true), ("dependents", Json.arr #[])])]
  let malformedRejected ← try let _ ← dependentIds malformed; pure false catch _ => pure true
  let truncatedRejected ← try let _ ← dependentIds truncated; pure false catch _ => pure true
  unless mismatchRejected && malformedHitRejected && missingHitRejected && malformedRejected && truncatedRejected do
    throw <| .userError "Lambo accepted a mismatched receipt or malformed/missing/truncated ID"

private def noConceptServer : String := String.intercalate "\n" [
  "import json, sys",
  "n = 0",
  "for line in sys.stdin:",
  "    req = json.loads(line)",
  "    m = req.get('method')",
  "    if m == 'notifications/initialized': continue",
  "    if m == 'initialize':",
  "        print(json.dumps({'jsonrpc': '2.0', 'id': req.get('id'), 'result': {'protocolVersion': '2025-06-18', 'capabilities': {}}}), flush=True)",
  "        continue",
  "    assert m == 'tools/call'",
  "    name = req.get('params', {}).get('name')",
  "    args = req.get('params', {}).get('arguments', {})",
  "    assert args.get('agent_id') == 'kalari'",
  "    n += 1",
  "    if n == 1:",
  "        assert name == 'lambo_inspect' and req.get('id') == 2",
  "        assert args.get('focus') == 'pagination_changed' and args.get('depth') == 1",
  "        print(json.dumps({'jsonrpc': '2.0', 'id': req.get('id'), 'result': {'content': [{'type': 'text', 'text': \"lambo_inspect: no concept matching 'pagination_changed' in session 'kalari-test'\"}], 'isError': True}}), flush=True)",
  "    elif n == 2:",
  "        assert name == 'lambo_derive' and req.get('id') == 3",
  "        print(json.dumps({'jsonrpc': '2.0', 'id': req.get('id'), 'result': {'content': [{'type': 'text', 'text': 'accepted'}], 'structuredContent': {'receipt': 'r1'}}}), flush=True)",
  "    else:",
  "        print(json.dumps({'jsonrpc': '2.0', 'id': req.get('id'), 'result': {'content': [{'type': 'text', 'text': 'unexpected call'}], 'isError': True}}), flush=True)" ]

/-- Fresh store: the exact Lambo not-found reply means zero lessons, not an
error, and a tool failure must not kill the child. -/
private def noConceptChecks : IO Unit := do
  let recorded := "lambo_inspect: no concept matching 'pagination_changed' in session 'kalari-live'"
  unless isNoConcept "pagination_changed" recorded do
    throw <| .userError "Lambo not-found matcher missed the recorded reply"
  unless !isNoConcept "pagination_changed"
      "lambo_inspect: no concept matching 'other_kind' in session 'kalari-live'" do
    throw <| .userError "Lambo not-found matcher accepted another focus"
  unless !isNoConcept "pagination_changed"
      "lambo_recall: no concept matching 'pagination_changed' in session 'kalari-live'" do
    throw <| .userError "Lambo not-found matcher accepted another tool"
  unless !isNoConcept "pagination_changed" "lambo_inspect: unexpected" do
    throw <| .userError "Lambo not-found matcher accepted another error"
  unless isNoConcept "field_required_changed"
      "lambo_inspect: no concept matching 'field_required_changed' in session 'kalari-live'\nsuggestions (not matches; pass a node_id or name one exactly):\n  pagination_changed [df9e6629-2476-4965-b6ad-f29c43b34c8a]" do
    throw <| .userError "Lambo not-found matcher missed the suggestions reply"
  unless isToolError (.userError "Lambo tool error: {\"content\":[]}") &&
      !isToolError (.userError "Lambo exited while awaiting a response") &&
      !isToolError (.userError "JSON-RPC error: {}") do
    throw <| .userError "Lambo tool/transport classifier wrong"
  let c ← create (replayConfig "testdata/lambo/no-concept.jsonl")
  let found ← lessons c "pagination_changed"
  unless found.isEmpty do throw <| .userError "Lambo fresh store did not return zero lessons"
  shutdown c
  -- A different focus against the same recorded text must rethrow, not map to [].
  let cNeg ← create (replayConfig "testdata/lambo/no-concept.jsonl")
  let rejectedRef ← IO.mkRef false
  try
    let _ ← lessons cNeg "12345678-1234-1234-1234-123456789abc"
    pure ()
  catch _ =>
    rejectedRef.set true
  shutdown cNeg
  unless ← rejectedRef.get do throw <| .userError "Lambo swallowed a non-matching tool error"
  -- The child survives the tool failure: the next derive answers on the same
  -- child with the next id. A kill would restart the fake and break its order.
  let fakeConfig : Kalari.Config.Lambo := { command := ["python3", "-c", noConceptServer], config_path := "testdata/lambo/lambo.toml" }
  let c2 ← create fakeConfig
  let kept ← lessons c2 "pagination_changed"
  unless kept.isEmpty do throw <| .userError "Lambo inline fresh store did not return zero lessons"
  let receipt ← derive c2 "resource" "pagination_changed"
  unless receipt == "r1" do throw <| .userError "Lambo child did not survive the tool failure"
  shutdown c2

#eval noConceptChecks

#eval childReplayChecks

#eval fixtureChecks

end Kalari.Lambo
