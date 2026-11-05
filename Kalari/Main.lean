import Kalari.Service
import Kalari.Model
import Kalari.Config
import Kalari.Proc
import Kalari.Backend
import Kalari.Fake
import Kalari
/-! kalari: the main service. A stub until P1; see product.md and docs/architecture.md. -/

def version : String := "0.1.2"

def usage : String :=
  "usage: kalari <command>\n\n" ++
  "  serve <config.json> <session.json>  MCP endpoint over stdio\n" ++
  "  check      load and validate the config, reach each backend (planned)\n" ++
  "  --version  print the version\n"

/-- Exercise the actual executable and its fixture dispatcher over stdio. -/
def offlineSelfTest : IO Unit := do
  let obj := Lean.Json.mkObj
  let request (id : Nat) (name : String) (args : Lean.Json) :=
    (obj [("jsonrpc", "2.0"), ("id", Lean.toJson id), ("method", "tools/call"),
      ("params", obj [("name", Lean.Json.str name), ("arguments", args)])]).compress
  let caps := obj [("timeout_ms", Lean.toJson (1000 : Nat)), ("output_cap_bytes", Lean.toJson (4096 : Nat)), ("memory_mib", Lean.toJson (128 : Nat))]
  let requests := [request 1 "what_changed" (obj [("old_spec", "old"), ("new_spec", "new")]),
    request 2 "blast_radius" (obj [("change_ids", Lean.toJson (["unknown-fixture-id"] : List String))]),
    request 3 "recall_lessons" (obj [("change_kinds", Lean.toJson (["pagination_changed"] : List String))]),
    request 4 "run_in_sandbox" (obj [("workspace", "/candidate"), ("command", Lean.toJson (["python3", "/candidate/correct.py"] : List String)), ("caps", caps), ("allowlist", Lean.toJson ([obj [("host", "api.example.test"), ("port", Lean.toJson (18080 : Nat))]] : List Lean.Json))]),
    request 5 "record_lesson" (obj [("run_id", "latest")])]
  let path ← IO.appPath
  let result ← Kalari.Proc.run [path.toString, "--offline-fixture"] (stdin := some (String.intercalate "\n" requests ++ "\n").toUTF8) (timeoutMs := 10000) (outputCap := 65536)
  unless result.exitCode == some 0 && result.cap == .none do throw <| .userError "fixture process failed"
  let text := (String.fromUTF8? result.stdout).getD ""
  let lines := (text.splitOn "\n").filter (!·.isEmpty)
  unless lines.length == 5 do throw <| .userError "fixture response count"
  for (line, expected) in lines.zip [false, false, false, false, false] do
    let json ← IO.ofExcept (Lean.Json.parse line)
    let value ← IO.ofExcept (json.getObjVal? "result")
    unless (value.getObjValAs? Bool "isError").toOption == some expected do
      throw <| .userError "fixture response status"
  unless text.contains "pagination_changed" && text.contains "passed" && text.contains "last value by ID" do
    throw <| .userError "fixture response content"
  IO.println "offline executable dispatcher: five handlers passed"

def main (argv : List String) : IO UInt32 := do
  match argv with
  | ["--version"] => IO.println s!"kalari {version}"; return 0
  | ["--help"] => IO.print usage; return 0
  | ["--offline-self-test"] =>
    try offlineSelfTest; return 0 catch e => IO.eprintln s!"{e}"; return 1
  | ["--offline-fixture"] => Kalari.Service.fixture; return 0
  | ["serve", config, session] =>
    try
      Kalari.Service.serve config session
      return 0
    catch e => IO.eprintln s!"kalari serve: {e}"; return 1
  | "check" :: _ => IO.eprintln "kalari check: not implemented yet"; return 2
  | _ => IO.eprint usage; return 2
