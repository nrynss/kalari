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
    throw s!"Lambo error: {result.compress}"
  return { result, structured := (field result "structuredContent").toOption.getD Json.null }

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
  let s ← start c.config
  c.state.set (some s)
  return s

/-- No automatic replay after an ambiguous failure: a write might already be accepted. -/
private def call (c : Client) (name : String) (args : List (String × Json)) : IO Reply := do
  let s ← session c
  try
    let (s, r) ← send s "tools/call" (obj [("name", Json.str name),
      ("arguments", obj (("agent_id", Json.str agent) :: args))])
    c.state.set (some s)
    return r
  catch e =>
    c.state.set none
    try s.child.kill catch _ => pure ()
    try discard s.child.wait catch _ => pure ()
    throw e

/-- Derive a typed concept and return its asynchronous receipt. -/
def derive (c : Client) (kind content : String) (dependsOn against : List String := []) : IO String := do
  let concept := obj [("concept_type", Json.str kind), ("content", Json.str content),
    ("depends_on", toJson dependsOn), ("against", toJson against)]
  let r ← call c "lambo_derive" [("concepts", Json.arr #[concept])]
  IO.ofExcept (str r.structured "receipt")

/-- Wait for a specific write to settle; fail rather than treating a pending or failed write as applied. -/
def awaitReceipt (c : Client) (receipt : String) (waitMs : Nat := 10000) : IO Json := do
  let r ← call c "lambo_stats" [("receipt", Json.str receipt), ("wait_ms", toJson waitMs)]
  let result ← IO.ofExcept (field r.structured "receipt")
  let state ← IO.ofExcept (str result "state")
  unless state == "applied" do throw <| .userError s!"write receipt {receipt}: {state}"
  return result

/-- Write and wait before a dependent write or read. -/
def write (c : Client) (kind content : String) (dependsOn against : List String := []) : IO Json := do
  let receipt ← derive c kind content dependsOn against
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

private def hasContradiction (j : Json) : Except String Bool := do
  let focus ← field j "focus"
  let levels ← arr focus "levels"
  for level in levels do
    for edge in (← arr level "neighbours") do
      if (← str edge "edge_type") == "Contradicts" && (← str edge "direction") == "<-" then
        return true
  return false

/-- Traverse change-kind dependencies and inspect each constraint for incoming contradictions. -/
def lessons (c : Client) (changeKind : String) : IO (List Lesson) := do
  let graph ← inspect c changeKind
  let focus ← IO.ofExcept (field graph "focus")
  if (field focus "dependents_truncated").toOption == some (Json.bool true) then
    throw <| .userError "Lambo truncated change-kind dependents"
  let deps ← IO.ofExcept (arr focus "dependents")
  let mut found : List Lesson := []
  for dep in deps do
    let edge ← IO.ofExcept (str dep "edge_type")
    let label ← IO.ofExcept (str dep "label")
    if edge == "Dependency" && label.contains "[Constraint" then
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
        ((str d "label").toOption.getD "").contains "[Constraint]"
      | none => false
    | none => false
  let contradicted := (structuredResponses (include_str "../testdata/lambo/against.jsonl")).any fun j =>
    (hasContradiction j).toOption == some true
  unless ack && applied && change && contradicted do
    throw <| .userError "Lambo recorded response checks failed"

#eval fixtureChecks

end Kalari.Lambo
