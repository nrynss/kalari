import Std.Http
import Lean.Data.Json
import Examples.Gate
/-! Example: an HTTP server on `Std.Http` with JSON in and out, a body cap, and status codes.

Usage: example-http <port>. Binds 127.0.0.1 only; Caddy terminates TLS in front of the real one.

  GET  /health   → 200 {"ok":true}
  POST /check    → the gate's decision for a JSON action; 400 on bad JSON, 413 over 4 KiB
  GET  /auth     → whether an Authorization header arrived (never its value) -/

open Std Async
open Std Http Server
open Lean (Json FromJson ToJson toJson fromJson?)

namespace Examples.HttpServer

structure ActionIn where
  path : String
  host : Option String := none
  timeoutMs : Nat
  deriving FromJson

def maxBody : UInt64 := 4096

def json (j : Json) := Response.ok |>.json j.compress

structure App

instance : Handler App where
  onRequest _ req := do
    -- The request line is `req.line` (the module docs wrongly say `req.head`).
    let target := toString req.line.uri
    let path := (target.splitOn "?").headD target
    match req.line.method, path with
    | .get, "/health" => json (Json.mkObj [("ok", true)])
    | .get, "/auth" =>
      let present := req.line.headers.contains (.mk "authorization")
      json (Json.mkObj [("authorization_present", present)])
    | .post, "/check" =>
      -- readAll throws IO.userError past the cap; catch it to answer 413, not a dropped connection.
      let body? ← try pure (some (← req.body.readAll (maximumSize := some maxBody) : String))
                  catch _ => pure none
      match body? with
      | none => Response.withStatus .payloadTooLarge |>.json "{\"error\":\"body over 4096 bytes\"}"
      | some body =>
        match Lean.Json.parse body >>= fromJson? (α := ActionIn) with
        | .error e => Response.badRequest |>.json (Json.mkObj [("error", e)]).compress
        | .ok a =>
          let allowed := Examples.Gate.allowed { path := a.path, host := a.host, timeoutMs := a.timeoutMs }
          json (Json.mkObj [("allowed", allowed)])
    | _, _ => Response.notFound |>.json "{\"error\":\"not found\"}"

  onFailure _ err := do
    IO.eprintln s!"example-http: {err}"

end Examples.HttpServer

def main (argv : List String) : IO UInt32 := do
  let port := (argv.headD "8080").toNat!.toUInt16
  Async.block do
    let addr : Net.SocketAddress := .v4 ⟨.ofParts 127 0 0 1, port⟩
    let server ← Server.serve addr Examples.HttpServer.App.mk
    IO.println s!"listening on 127.0.0.1:{port}"
    (← IO.getStdout).flush
    server.waitShutdown
  return 0
