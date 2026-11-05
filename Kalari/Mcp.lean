import Lean.Data.Json

/-! MCP over newline-delimited JSON-RPC. Tool implementations are injected by
`serve`'s caller; this module does not grant them access to any backend. -/

open Lean
namespace Kalari.Mcp

private def obj := Json.mkObj
private def scalar (t : String) : Json := obj [("type", Json.str t)]
private def array (items : Json) : Json := obj [("type", "array"), ("items", items)]
private def object (fields : List (String × Json)) : Json := obj [
  ("type", "object"), ("properties", obj fields),
  ("required", toJson (fields.map Prod.fst)), ("additionalProperties", Json.bool false)]
private def string := scalar "string"
private def strings := array string
private def integer := obj [("type", "integer"), ("minimum", toJson (0 : Nat))]
private def caps := object [("timeout_ms", integer), ("output_cap_bytes", integer), ("memory_mib", integer)]
private def host := object [("host", string), ("port", integer)]

/-- The arguments accepted by each of the five tools. -/
def schema (name : String) : Option Json :=
  match name with
  | "what_changed" => some <| object [("old_spec", string), ("new_spec", string)]
  | "blast_radius" => some <| object [("change_ids", strings)]
  | "recall_lessons" => some <| object [("change_kinds", strings)]
  | "run_in_sandbox" => some <| object [("workspace", string), ("command", strings),
      ("caps", caps), ("allowlist", array host)]
  | "record_lesson" => some <| object [("run_id", string)]
  | _ => none

private def descriptions : List (String × String) := [
  ("what_changed", "List changes between two API specs."),
  ("blast_radius", "Find callers touched by change IDs. You may pass every ID from what_changed. Each requested ID returns a status: searched, not_searchable, or unknown_change_id. Confirmed and uncertain callers remain separate. Truncated site lists are marked."),
  ("recall_lessons", "Find checks for change kinds."),
  ("run_in_sandbox", "Run and check a migration in a contained sandbox. Checks require the configured consumer artifact at the workspace root. Exploratory commands are allowed but report no artifact and passed=false if they produce none; they are not verified runs."),
  ("record_lesson", "Propose lessons from a verified run.")]

/-- MCP tool definitions, generated from the same schemas used for validation. -/
def tools : Json := Json.arr <| descriptions.toArray.map fun (name, description) => obj [
  ("name", Json.str name), ("description", Json.str description),
  ("inputSchema", (schema name).getD Json.null)]

private def result (id value : Json) : Json :=
  obj [("jsonrpc", "2.0"), ("id", id), ("result", value)]
private def error (id : Json) (code : Int) (message : String) : Json :=
  obj [("jsonrpc", "2.0"), ("id", id),
    ("error", obj [("code", toJson code), ("message", Json.str message)])]
private def content (s : String) (failed : Bool) : Json := obj [
  ("content", Json.arr #[obj [("type", "text"), ("text", Json.str s)]]),
  ("isError", Json.bool failed)]

/-- Validate every declared field and reject extra keys; schema and dispatch cannot drift. -/
private partial def valid (s v : Json) : Bool := Id.run do
  let t := (s.getObjValAs? String "type").toOption.getD ""
  match t with
  | "string" => return v.getStr?.isOk
  | "integer" => return (fromJson? (α := Nat) v).isOk
  | "array" =>
    match v.getArr?, s.getObjVal? "items" with
    | .ok vs, .ok item => return vs.all (valid item)
    | _, _ => return false
  | "object" =>
    match v.getObj?, s.getObjVal? "properties" with
    | .ok values, .ok props =>
      match props.getObj? with
      | .error _ => return false
      | .ok properties =>
        if values.size != properties.size then return false
        for (key, spec) in properties.toList do
          match values.get? key with
          | none => return false
          | some value => if !valid spec value then return false
        return true
    | _, _ => return false
  | _ => return false

/-- An implementation returns display text or a tool failure. Exceptions also become tool failures. -/
abbrev Handler := String → Json → IO (Except String String)

/-- Handle one parsed request. Notifications never produce a response. -/
def handle (handler : Handler) (msg : Json) : IO (Option Json) := do
  let invalid := some <| error Json.null (-32600) "invalid request"
  let .ok _ := msg.getObj? | return invalid
  if (msg.getObjValAs? String "jsonrpc").toOption != some "2.0" then return invalid
  let some method := (msg.getObjValAs? String "method").toOption | return invalid
  let idField := msg.getObjVal? "id"
  let id := match idField with
    | .error _ => none
    | .ok (.str value) => some <| Json.str value
    | .ok (.num value) => if value.exponent == 0 then some <| Json.num value else none
    | .ok _ => none
  if idField.isOk && id.isNone then return invalid
  let params := (msg.getObjVal? "params").toOption.getD (obj [])
  if !(params.getObj?.isOk || params.getArr?.isOk) then return invalid
  -- A valid notification has no id and, by JSON-RPC, receives no response.
  let some id := id | return none
  match method with
  | "initialize" =>
    let requested := (params.getObjValAs? String "protocolVersion").toOption.getD "2025-11-25"
    let version := if requested == "2025-11-25" then requested else "2025-11-25"
    return some <| result id <| obj [("protocolVersion", Json.str version),
      ("capabilities", obj [("tools", obj [])]),
      ("serverInfo", obj [("name", "kalari"), ("version", "0.1.0")])]
  | "tools/list" => return some <| result id <| obj [("tools", tools)]
  | "ping" => return some <| result id (obj [])
  | "tools/call" =>
    let some name := (params.getObjValAs? String "name").toOption |
      return some <| error id (-32602) "tool name required"
    let some spec := schema name | return some <| error id (-32602) "unknown tool"
    let some args := (params.getObjVal? "arguments").toOption |
      return some <| error id (-32602) "arguments required"
    unless valid spec args do return some <| error id (-32602) "invalid tool arguments"
    let reply ← try handler name args catch e => pure <| .error (toString e)
    return some <| result id <| match reply with
      | .ok text => content text false
      | .error text => content text true
  | _ => return some <| error id (-32601) s!"method not found: {method}"

/-- Process one wire line, returning no output for notifications or blank lines. -/
def line (handler : Handler) (input : String) : IO (Option String) := do
  let input := input.trimAscii.toString
  if input.isEmpty then return none
  match Json.parse input with
  | .error _ => return some <| (error Json.null (-32700) "parse error").compress
  | .ok msg => return (← handle handler msg).map Json.compress

/-- Serve until stdin closes. All output is protocol; every reply is flushed. -/
partial def serve (handler : Handler) (input output : IO.FS.Stream) : IO Unit := do
  let request ← input.getLine
  if request.isEmpty then return
  if let some reply ← line handler request then
    output.putStrLn reply
    output.flush
  serve handler input output

private def recordedInput (recording : String) : IO String := do
  let mut lines := []
  for row in recording.splitOn "\n" do
    if !row.isEmpty then
      let j ← IO.ofExcept (Json.parse row)
      if (j.getObjValAs? String "dir").toOption == some "in" then
        lines := lines ++ [(← IO.ofExcept (j.getObjVal? "msg")).compress]
  return String.intercalate "\n" lines ++ "\n"

private def testHandler : Handler := fun name args => do
  if name == "what_changed" then
    unless (args.getObjValAs? String "old_spec").toOption == some "specs/openapi-v1.yaml" do
      throw <| .userError "wrong replay argument"
    return .ok "recorded change"
  if name == "blast_radius" then throw <| .userError "test failure"
  return .ok name

private def request (id : Nat) (name : String) (args : Json) : String :=
  (obj [("jsonrpc", "2.0"), ("id", toJson id), ("method", "tools/call"),
    ("params", obj [("name", Json.str name), ("arguments", args)])]).compress

private def verify (condition : Bool) (message : String) : IO Unit := do
  unless condition do throw <| .userError message

private def exercise (recording : String) : IO Unit := do
  let recorded ← recordedInput recording
  let invalid := request 10 "what_changed" (obj [("old_spec", Json.str "v1")])
  let unknown := request 11 "missing" (obj [])
  let throwing := request 12 "blast_radius" (obj [("change_ids", toJson (["x"] : List String))])
  let after := request 13 "recall_lessons" (obj [("change_kinds", toJson (["pagination_changed"] : List String))])
  let input ← IO.mkRef ({ data := (recorded ++ invalid ++ "\n" ++ unknown ++ "\n" ++
    throwing ++ "\n" ++ after ++ "\n").toUTF8 } : IO.FS.Stream.Buffer)
  let output ← IO.mkRef ({} : IO.FS.Stream.Buffer)
  serve testHandler (IO.FS.Stream.ofBuffer input) (IO.FS.Stream.ofBuffer output)
  let bytes := (← output.get).data
  let some text := String.fromUTF8? bytes | throw <| .userError "invalid output UTF-8"
  let lines := (text.splitOn "\n").filter (!·.isEmpty)
  verify (lines.length == 7) "wrong response count or notification reply"
  let replies ← lines.mapM fun l => IO.ofExcept (Json.parse l)
  let a := replies.toArray
  let init ← IO.ofExcept (a[0]!.getObjVal? "result")
  verify ((init.getObjValAs? String "protocolVersion").toOption == some "2025-11-25") "initialize version"
  let listing ← IO.ofExcept ((a[1]!.getObjVal? "result") >>= (·.getObjValAs? (Array Json) "tools"))
  let names := listing.map fun t => (t.getObjValAs? String "name").toOption.getD ""
  verify (names == #["what_changed", "blast_radius", "recall_lessons", "run_in_sandbox", "record_lesson"]) "tool listing"
  let called ← IO.ofExcept (a[2]!.getObjVal? "result")
  verify ((called.getObjValAs? Bool "isError").toOption == some false) "recorded call"
  for index in [3, 4] do
    let err ← IO.ofExcept (a[index]!.getObjVal? "error")
    verify ((err.getObjValAs? Int "code").toOption == some (-32602)) "argument error"
  let failed ← IO.ofExcept (a[5]!.getObjVal? "result")
  verify ((failed.getObjValAs? Bool "isError").toOption == some true) "handler exception"
  let recovered ← IO.ofExcept (a[6]!.getObjVal? "result")
  verify ((recovered.getObjValAs? Bool "isError").toOption == some false) "server recovery"

private def checks : IO Unit := do
  exercise (include_str "../testdata/opencode/direct.mcp.jsonl")
  exercise (include_str "../testdata/opencode/codemode.mcp.jsonl")
  for (name, args) in [
      ("what_changed", obj [("old_spec", Json.str "a"), ("new_spec", Json.str "b")]),
      ("blast_radius", obj [("change_ids", toJson (["x"] : List String))]),
      ("recall_lessons", obj [("change_kinds", toJson (["x"] : List String))]),
      ("run_in_sandbox", obj [("workspace", Json.str "/w"), ("command", toJson (["true"] : List String)),
        ("caps", obj [("timeout_ms", toJson (1 : Nat)), ("output_cap_bytes", toJson (1 : Nat)), ("memory_mib", toJson (1 : Nat))]),
        ("allowlist", Json.arr #[])]),
      ("record_lesson", obj [("run_id", Json.str "r")])] do
    let some spec := schema name | throw <| .userError "missing schema"
    verify (valid spec args && !valid spec (obj []) && !valid spec Json.null) s!"schema {name}"
  let some runSpec := schema "run_in_sandbox" | throw <| .userError "missing run schema"
  let malformedRun := obj [("workspace", Json.str "/w"), ("command", toJson (["true"] : List String)),
    ("caps", obj [("timeout_ms", Json.str "bad"), ("output_cap_bytes", toJson (1 : Nat)), ("memory_mib", toJson (1 : Nat))]),
    ("allowlist", Json.arr #[])]
  verify (!valid runSpec malformedRun) "nested type validation"
  let some changedSpec := schema "what_changed" | throw <| .userError "missing change schema"
  verify (!valid changedSpec (obj [("old_spec", Json.str "a"), ("new_spec", Json.str "b"), ("extra", Json.bool true)])) "extra field accepted"
  let r ← line testHandler "{broken"
  verify (r.isSome && ((r.getD "").contains "-32700")) "parse error"
  let malformed ← line testHandler "{\"jsonrpc\":\"2.0\"}"
  verify (malformed.isSome && ((malformed.getD "").contains "-32600") &&
    ((malformed.getD "").contains "\"id\":null")) "missing-id malformed request was dropped"
  let badId ← line testHandler "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}"
  verify (badId.isSome && ((badId.getD "").contains "-32600") &&
    ((badId.getD "").contains "\"id\":null")) "invalid id type accepted"
  let badVersion ← line testHandler "{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}"
  verify (badVersion.isSome && ((badVersion.getD "").contains "-32600")) "unsupported JSON-RPC version was dropped"
  let notification ← line testHandler "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  verify notification.isNone "notification received a response"
  let initOther ← line testHandler "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"unsupported\"}}"
  let initOtherJson ← IO.ofExcept (Json.parse (initOther.getD "{}"))
  let initOtherResult ← IO.ofExcept (initOtherJson.getObjVal? "result")
  verify ((initOtherResult.getObjValAs? String "protocolVersion").toOption == some "2025-11-25")
    "unsupported MCP version was echoed instead of negotiating the server version"

#eval checks

end Kalari.Mcp
