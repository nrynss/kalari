import Std.Http
import Lean.Data.Json
import Kalari.Evidence

/-! Read-only JSON API over a shared evidence store. All lists preserve append
order. A run or session detail contains every associated evidence record, so
clients can present the original verdict, checks, logs, timings and tokens.
`benchmark` records are supplied by the benchmark producer; no totals are
inferred here. The server is bound only to loopback for Caddy. -/

open Std Async
open Std Http Server
open Lean

namespace Kalari.Http

def maxBody : UInt64 := 4096

private def recordsJson (rs : List Evidence.Record) : Json := toJson rs
private def ids (rs : List Evidence.Record) (key : Evidence.Record → String) : List String :=
  rs.foldl (fun acc r => let id := key r; if id == "" || acc.contains id then acc else acc ++ [id]) []

/-- Route a read request against a snapshot. Unknown resources return 404;
malformed paths and any nonempty body return 400. -/
def route (loaded : Evidence.Loaded) (method target body : String) : Nat × Json := Id.run do
  let err := fun s => Json.mkObj [("error", Json.str s)]
  if body != "" then return (400, err "request body is not accepted")
  if target.contains '?' || target.contains '#' || !target.startsWith "/" then
    return (400, err "invalid request target")
  if method != "GET" then return (404, err "not found")
  let rs := loaded.records
  let validId := fun (s : String) => !s.isEmpty && s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')
  match target.splitOn "/" with
  | ["", "api", "sessions"] => return (200, toJson (ids rs (·.session_id)))
  | ["", "api", "runs"] => return (200, toJson (ids rs (·.run_id)))
  | ["", "api", "lessons"] => return (200, recordsJson (rs.filter (·.kind == "lesson")))
  | ["", "api", "benchmark"] => return (200, recordsJson (rs.filter (·.kind == "benchmark")))
  | ["", "api", "sessions", id] =>
    if !validId id then return (400, err "invalid session id")
    let found := Evidence.bySession loaded id
    if found.isEmpty then return (404, err "not found")
    return (200, recordsJson found)
  | ["", "api", "runs", id] =>
    if !validId id then return (400, err "invalid run id")
    let found := Evidence.byRun loaded id
    if found.isEmpty then return (404, err "not found")
    return (200, recordsJson found)
  | _ => return (404, err "not found")

structure App where
  store : Evidence.Store

instance : Handler App where
  onRequest app req := do
    let body? ← try pure (some (← req.body.readAll (maximumSize := some maxBody) : String))
                catch _ => pure none
    match body? with
    | none => Response.withStatus .payloadTooLarge |>.json "{\"error\":\"body over 4096 bytes\"}"
    | some body =>
      let loaded ← Evidence.load app.store
      let (status, result) := route loaded (toString req.line.method) (toString req.line.uri) body
      match status with
      | 200 => Response.ok |>.json result.compress
      | 400 => Response.badRequest |>.json result.compress
      | _ => Response.notFound |>.json result.compress
  onFailure _ err := IO.eprintln s!"kalari http: {err}"

/-- Serve the shared store on IPv4 loopback. -/
def serve (store : Evidence.Store) (port : UInt16) : Async Unit := do
  let addr : Net.SocketAddress := .v4 ⟨.ofParts 127 0 0 1, port⟩
  let server ← Server.serve addr { store : App }
  server.waitShutdown

private def verify (b : Bool) (s : String) : IO Unit :=
  unless b do throw <| IO.userError s

private def checks : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Evidence.openStore dir
  let sample := fun kind session run payload =>
    ({ kind, session_id := session, run_id := run, change_kinds := ["pagination_changed"], payload } : Evidence.Record)
  let run := sample "run" "s1" "r1" (Json.mkObj [("verdict", "passed"), ("logs", "log"), ("wall_ms", toJson (12 : Nat)), ("tokens", toJson (20 : Nat))])
  let check := sample "check" "s1" "r1" (Json.str "check")
  let lesson := sample "lesson" "s1" "r1" (Json.str "lesson")
  let bench := sample "benchmark" "s2" "r2" (Json.str "result")
  for r in [run, check, lesson, bench] do Evidence.append store r
  let loaded ← Evidence.load store
  for (path, expected) in [("/api/sessions", toJson (["s1", "s2"] : List String)),
      ("/api/runs", toJson (["r1", "r2"] : List String)),
      ("/api/sessions/s1", recordsJson [run, check, lesson]),
      ("/api/runs/r1", recordsJson [run, check, lesson]),
      ("/api/lessons", recordsJson [lesson]), ("/api/benchmark", recordsJson [bench])] do
    let (status, result) := route loaded "GET" path ""
    verify (status == 200 && result == expected) s!"fixture route {path}"
  verify ((route loaded "GET" "/api/runs/missing" "").1 == 404) "missing run"
  verify ((route loaded "POST" "/api/runs" "").1 == 404) "write route"
  verify ((route loaded "GET" "/api/runs/" "").1 == 400) "malformed id"
  verify ((route loaded "GET" "/api/runs" "body").1 == 400) "unexpected body"

#eval checks
end Kalari.Http
