import Lean.Data.Json
/-! Example: a JSON-RPC 2.0 loop over stdio, the shape of an MCP server.

One JSON message per line on stdin, one per line on stdout. Requests (with an `id`) get a
response; notifications (no `id`) get none. Logs go to stderr only: stdout is the protocol.
No Lean MCP library exists, and the protocol is small enough not to need one.

Usage: example-jsonrpc (reads stdin until EOF) -/

open Lean (Json toJson)

namespace Examples.JsonRpc

def result (id : Json) (r : Json) : Json :=
  Json.mkObj [("jsonrpc", "2.0"), ("id", id), ("result", r)]

def error (id : Json) (code : Int) (msg : String) : Json :=
  Json.mkObj [("jsonrpc", "2.0"), ("id", id),
              ("error", Json.mkObj [("code", toJson code), ("message", msg)])]

def tools : Json := Json.arr #[Json.mkObj [
  ("name", "echo"),
  ("description", "Return the text it is given."),
  ("inputSchema", Json.mkObj [("type", "object"),
     ("properties", Json.mkObj [("text", Json.mkObj [("type", "string")])]),
     ("required", Json.arr #["text"])])]]

/-- Handle one message. `none` means no reply (a notification). -/
def handle (msg : Json) : Option Json :=
  let id? := (msg.getObjVal? "id").toOption
  let method := (msg.getObjValAs? String "method").toOption.getD ""
  let params := (msg.getObjVal? "params").toOption.getD (Json.mkObj [])
  match id? with
  | none => none
  | some id => some <| match method with
    | "initialize" => result id <| Json.mkObj [
        ("protocolVersion", "2025-06-18"),
        ("capabilities", Json.mkObj [("tools", Json.mkObj [])]),
        ("serverInfo", Json.mkObj [("name", "example-jsonrpc"), ("version", "0.1.0")])]
    | "tools/list" => result id <| Json.mkObj [("tools", tools)]
    | "tools/call" =>
      match (params.getObjValAs? String "name").toOption,
            ((params.getObjVal? "arguments") >>= (·.getObjValAs? String "text")).toOption with
      | some "echo", some text => result id <| Json.mkObj [
          ("content", Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]),
          ("isError", false)]
      | some "echo", none => error id (-32602) "echo needs arguments.text"
      | _, _ => error id (-32602) "unknown tool"
    | m => error id (-32601) s!"method not found: {m}"

end Examples.JsonRpc

partial def loop (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then return            -- EOF: the client closed stdin
  let line := line.trimAscii.toString    -- `String.trim` is now `trimAscii` (a Slice)
  unless line.isEmpty do
    match Lean.Json.parse line with
    | .error e =>
      stdout.putStrLn (Examples.JsonRpc.error Json.null (-32700) s!"parse error: {e}").compress
    | .ok msg =>
      if let some reply := Examples.JsonRpc.handle msg then
        stdout.putStrLn reply.compress
    stdout.flush                         -- the client waits for each line
  loop stdin stdout

def main : IO Unit := do
  IO.eprintln "example-jsonrpc: ready"
  loop (← IO.getStdin) (← IO.getStdout)
