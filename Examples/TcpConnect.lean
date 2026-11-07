import Std.Async.TCP
import Std.Net.Addr

/-! Example: raw TCP on `Std.Async.TCP` for the CONNECT broker.

The broker is inbound plain TCP only: no HTTP client, no TLS (those stay
in `curl` and Caddy). It binds 127.0.0.1 on an ephemeral port, accepts one
client, reads one header block under a cap, and answers. The live broker in
`Kalari.Sandbox.Broker` adds auth, strict framing, deadlines and tunneling;
this file only shows the socket shape so the pattern cannot rot: `lake
build` type-checks it against this toolchain.

  `Server.mk` → `bind 127.0.0.1:0` → `listen` → `getSockName` (the port)
  `accept` → `recv?` → `send` (both `Async`, run under `Async.block`)
-/

open Std Net Async TCP.Socket

/-- Bind loopback on an ephemeral port and report the bound address. -/
def bindLoopback : IO SocketAddress :=
  Async.block (do
    let srv ← Server.mk
    srv.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    srv.listen 5
    srv.getSockName)

/-- Accept one client and echo the first chunk back with a prefix. -/
def echoOnce (srv : Server) : Async Unit := do
  let client ← srv.accept
  match ← client.recv? 4096 with
  | some data => client.send ("hi:".toUTF8 ++ data)
  | none => pure ()
