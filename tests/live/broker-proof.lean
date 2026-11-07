import Kalari.Sandbox.Broker
import Kalari.Sandbox.Microsandbox
import Kalari.Tools.Run

/-! Live-test entry point for the Lean broker proofs. No `probe/*.py` runs
here: two Lean brokers isolate two fake origins, and one Lean broker
tunnels a real payouts traversal to the bench API. The bench payouts
server is the API under test, not wiring. Run from the repository root:
`lake env lean --run tests/live/broker-proof.lean`. -/

open Kalari.Sandbox.Broker Kalari.Model

private def verify (cond : Bool) (msg : String) : IO Unit :=
  unless cond do throw (.userError msg)

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

/-- Run `action`, failing after `ms`. `none` is a timeout. -/
private def withTimeout (ms : Nat) (action : IO α) : IO (Option α) := do
  let task ← IO.asTask action Task.Priority.dedicated
  let start ← IO.monoMsNow
  repeat
    if ← IO.hasFinished task then
      match task.get with
      | .ok v => return some v
      | .error _ => return none
    if (← IO.monoMsNow) - start >= ms then return none
    IO.sleep 20
  return none

private def failClosed (label : String) (action : IO Unit) : IO Unit := do
  match ← withTimeout 20000 action with
  | some () => pure ()
  | none => throw (.userError s!"{label}: timed out")

private def findDelim (buf : ByteArray) : Option Nat :=
  (List.range buf.size).find? fun i =>
    i + 4 <= buf.size && buf[i]! == 13 && buf[i + 1]! == 10 && buf[i + 2]! == 13 && buf[i + 3]! == 10

/-- Read until end-of-headers, EOF, or the cap. -/
private def readHead (c : Std.Async.TCP.Socket.Client) : Std.Async.Async (Option ByteArray) := do
  let mut buf := ByteArray.empty
  repeat
    match ← c.recv? 4096 with
    | none => return if buf.isEmpty then none else some buf
    | some chunk =>
      if chunk.isEmpty then return if buf.isEmpty then none else some buf
      buf := buf ++ chunk
      if buf.size > 65536 then return some buf
      match findDelim buf with
      | some i => return some (buf.extract 0 (i + 4))
      | none => pure ()
  return none

private def firstLine (head : ByteArray) : String :=
  match String.fromUTF8? head with
  | none => "<binary>"
  | some text => (text.splitOn "\r\n").headD "<empty>"

private def sendConnect (port : Nat) (dest mode user pw : String) : IO String := do
  let out ← withTimeout 15000 (Std.Async.Async.block (do
    let c ← Std.Async.TCP.Socket.Client.mk
    c.connect (.v4 ⟨.ofParts 127 0 0 1, port.toUInt16⟩)
    let auth := "Basic " ++ Kalari.Sandbox.Broker.b64Encode s!"{user}:{pw}".toUTF8
    let mut req := s!"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\n"
    if mode == "correct" then req := req ++ s!"Proxy-Authorization: {auth}\r\n"
    if mode == "wrong" then req := req ++ "Proxy-Authorization: Basic d3JvbmdjcmVkZW50aWFscw==\r\n"
    req := req ++ "\r\n"
    c.send req.toUTF8
    match ← readHead c with
    | none => pure "<closed>"
    | some head => pure (firstLine head)))
  match out with
  | some line => pure line
  | none => pure "<timeout>"

private def tunnelGet (port : Nat) (dest path user pw : String) : IO String := do
  let out ← withTimeout 15000 (Std.Async.Async.block (do
    let c ← Std.Async.TCP.Socket.Client.mk
    c.connect (.v4 ⟨.ofParts 127 0 0 1, port.toUInt16⟩)
    let auth := "Basic " ++ Kalari.Sandbox.Broker.b64Encode s!"{user}:{pw}".toUTF8
    c.send s!"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\nProxy-Authorization: {auth}\r\n\r\n".toUTF8
    match ← readHead c with
    | none => pure "CONNECT-REFUSED <closed>"
    | some head =>
      let line := firstLine head
      if !line.contains "200" then pure s!"CONNECT-REFUSED {line}"
      else
        c.send s!"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".toUTF8
        let mut resp := ByteArray.empty
        repeat
          match ← c.recv? 4096 with
          | none => break
          | some chunk =>
            if chunk.isEmpty then break
            resp := resp ++ chunk
            if resp.size > 131072 then break
        let inner := match String.fromUTF8? resp with
          | none => "<binary>"
          | some text => (text.splitOn "\r\n").headD "<closed>"
        pure s!"INNER {inner} len={resp.size}"))
  match out with
  | some line => pure line
  | none => pure "<timeout>"

private def directGet (port : Nat) : IO String := do
  let out ← withTimeout 15000 (Std.Async.Async.block (do
    let c ← Std.Async.TCP.Socket.Client.mk
    c.connect (.v4 ⟨.ofParts 127 0 0 1, port.toUInt16⟩)
    c.send "GET /direct HTTP/1.0\r\n\r\n".toUTF8
    match ← readHead c with
    | none => pure "<closed>"
    | some head => pure (firstLine head)))
  match out with
  | some line => pure line
  | none => pure "<timeout>"

/-- Minimal fake origin: counts requests, answers every request with its
tag. No Python. -/
private def startFakeOrigin (tag : String) (count : IO.Ref Nat) : IO (Nat × IO Unit × Task (Except IO.Error Unit)) := do
  let srv ← Std.Async.Async.block (do
    let s ← Std.Async.TCP.Socket.Server.mk
    s.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    s.listen 20
    pure s)
  let addr ← srv.getSockName
  let port ← match addr with
    | .v4 a => pure a.port.toNat
    | .v6 _ => throw (.userError "fake origin: no port")
  let stopped ← IO.mkRef false
  -- Sequential, same thread: one request at a time is enough (overlap in
  -- the proof is across origins, not within one). No per-connection tasks,
  -- so no handle ever crosses threads.
  let loop : IO Unit := do
    repeat
      if ← stopped.get then break
      match ← srv.tryAccept with
      | some client => do
        let req ← Std.Async.Async.block (client.recv? 16384)
        match req with
        | none => pure ()
        | some _ =>
          count.modify (· + 1)
          let body := "{\"ok\":true,\"via\":\"" ++ tag ++ "\"}"
          try
            let _ ← Std.Async.Async.block (client.send
              s!"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}".toUTF8)
            pure ()
          catch _ => pure ()
      | none => IO.sleep 20
    pure ()
  let task ← IO.asTask loop Task.Priority.dedicated
  -- `task` is stored, never a prebuilt `task.get`: `Task.get` blocks, so
  -- building the wait action eagerly would deadlock the still-running loop.
  return (port, stopped.set true, task)

private def awaitLine (h : IO.FS.Handle) (label want : String) : IO Unit := do
  let task ← IO.asTask h.getLine Task.Priority.dedicated
  let rec wait : Nat → IO Unit
    | 0 => throw (.userError s!"{label} startup timeout")
    | n + 1 => do
      if ← IO.hasFinished task then pure () else do
        IO.sleep 10
        wait n
  wait 500
  match task.get with
  | .error _ => throw (.userError s!"{label} startup failed")
  | .ok line =>
    unless line.startsWith want do
      throw (.userError s!"{label} startup failed: {line.trimAscii.toString}")

def brokerIsolation : IO Unit := IO.FS.withTempDir fun _ => do
  let countA ← IO.mkRef 0
  let countB ← IO.mkRef 0
  let (originA, stopOriginA, waitOriginA) ← startFakeOrigin "a" countA
  let (originB, stopOriginB, waitOriginB) ← startFakeOrigin "b" countB
  let idA ← Kalari.Sandbox.Broker.freshIdentity "a"
  let idB ← Kalari.Sandbox.Broker.freshIdentity "b"
  verify (idA.password != idB.password) "per-run passwords must differ"
  verify (idA.user != idB.user) "per-run users must differ"
  let cfgA : Kalari.Sandbox.Broker.BrokerConfig := {
    user := idA.user, password := idA.password, passwordEnv := idA.passwordEnv,
    allowedDest := s!"127.0.0.1:{originA}", upstreamHost := "127.0.0.1", upstreamPort := originA }
  let cfgB : Kalari.Sandbox.Broker.BrokerConfig := {
    user := idB.user, password := idB.password, passwordEnv := idB.passwordEnv,
    allowedDest := s!"127.0.0.1:{originB}", upstreamHost := "127.0.0.1", upstreamPort := originB }
  let brokerA ← Kalari.Sandbox.Broker.start cfgA
  let brokerB ← Kalari.Sandbox.Broker.start cfgB
  try
    -- Loopback-only proxy argv, --no-net, explicit rules, --pull never, no values.
    let allow : List AllowHost := [{ host := "127.0.0.1", port := originA }]
    for (port, id) in [(brokerA.port, idA), (brokerB.port, idB)] do
      let argv := Kalari.Sandbox.Broker.observedCreateArgv "kalari-run-1" 256 allow port id
      verify (argv.contains "--proxy") "msb proxy missing"
      verify (argv.contains "--http-connect-username") "msb proxy user missing"
      verify (argv.contains "--http-connect-password-env") "msb proxy password-env missing"
      verify (argv.contains "--no-net") "msb no-net missing"
      verify (argv.contains "--pull" && argv.contains "never") "msb pull never missing"
      verify (!(argv.any (·.contains "--net-default"))) "msb net-default present"
      verify (Kalari.Sandbox.Microsandbox.isLoopbackProxy s!"http://127.0.0.1:{port}") "proxy not loopback"
      verify (!(argv.any (fun a => a.contains id.password))) "password value in msb argv"
      verify (argv.contains id.passwordEnv) "password env name missing in msb argv"
    -- Guest reaches only its own origin through host auth.
    failClosed "reach-a" do
      let rA ← tunnelGet brokerA.port cfgA.allowedDest "/a1" idA.user idA.password
      verify (rA.contains "INNER" && rA.contains "200") s!"guest-a did not reach own origin: {rA}"
    failClosed "reach-b" do
      let rB ← tunnelGet brokerB.port cfgB.allowedDest "/b1" idB.user idB.password
      verify (rB.contains "INNER" && rB.contains "200") s!"guest-b did not reach own origin: {rB}"
    verify ((← countA.get) == 1) "origin-a count after first reach"
    verify ((← countB.get) == 1) "origin-b count after first reach"
    -- Overlap: both at once.
    failClosed "overlap" do
      let taskA ← IO.asTask (tunnelGet brokerA.port cfgA.allowedDest "/a2" idA.user idA.password) Task.Priority.dedicated
      let taskB ← IO.asTask (tunnelGet brokerB.port cfgB.allowedDest "/b2" idB.user idB.password) Task.Priority.dedicated
      let rA2 ← IO.ofExcept taskA.get
      let rB2 ← IO.ofExcept taskB.get
      verify (rA2.contains "INNER" && rB2.contains "INNER") "overlap did not serve both"
    verify ((← countA.get) == 2) "origin-a count after overlap"
    verify ((← countB.get) == 2) "origin-b count after overlap"
    -- Fail closed: B creds on A, missing auth, wrong auth, wrong dest,
    -- direct non-CONNECT. No origin sees them.
    failClosed "fail-closed" do
      let sWrong ← sendConnect brokerA.port cfgA.allowedDest "correct" idB.user idB.passwordEnv
      let sMissing ← sendConnect brokerA.port cfgA.allowedDest "missing" idA.user idA.password
      let sBad ← sendConnect brokerA.port cfgA.allowedDest "wrong" idA.user idA.password
      let sDest ← sendConnect brokerA.port "127.0.0.1:19999" "correct" idA.user idA.password
      let sDirect ← directGet brokerA.port
      let rWrongDest ← tunnelGet brokerA.port "127.0.0.1:19999" "/x4" idA.user idA.password
      verify (sWrong.contains "407") s!"B creds on A not refused: {sWrong}"
      verify (sMissing.contains "407") s!"missing auth not refused: {sMissing}"
      verify (sBad.contains "407") s!"wrong auth not refused: {sBad}"
      verify (sDest.contains "403") s!"wrong dest not refused: {sDest}"
      verify (sDirect.contains "405") s!"direct non-CONNECT not refused: {sDirect}"
      verify (rWrongDest.contains "CONNECT-REFUSED") s!"guest wrong-dest reached inner: {rWrongDest}"
    verify ((← countA.get) == 2) "fail-closed grew origin-a"
    verify ((← countB.get) == 2) "fail-closed grew origin-b"
    -- No credential values in guest-visible output.
    failClosed "hygiene" do
      let rA ← tunnelGet brokerA.port cfgA.allowedDest "/a9" idA.user idA.password
      verify (!rA.contains idA.password && !rA.contains idB.password) "password in guest output"
    -- Owner cleanup closes the path: stop A, port refused, B keeps serving.
    brokerA.stop
    brokerA.wait
    IO.sleep 300
    let refused ← sendConnect brokerA.port cfgA.allowedDest "correct" idA.user idA.password
    verify (refused == "<closed>" || refused == "<timeout>") s!"broker-a port still open: {refused}"
    failClosed "b-after-a-death" do
      let rB3 ← tunnelGet brokerB.port cfgB.allowedDest "/b3" idB.user idB.password
      verify (rB3.contains "INNER") "owner death stopped run-b"
    verify ((← countB.get) == 3) "run-b origin did not grow alone"
    verify ((← countA.get) == 3) "run-a origin grew after death"
    say "broker isolation: Lean broker, guest reaches only own origin, fail-closed, separate counts, cleanup closes path"
  finally
    brokerA.stop
    brokerB.stop
    stopOriginA
    stopOriginB
    try brokerA.wait catch _ => pure ()
    try brokerB.wait catch _ => pure ()
    (try IO.ofExcept waitOriginA.get catch _ => pure ())
    (try IO.ofExcept waitOriginB.get catch _ => pure ())

/-- One inner GET through the tunnel. Returns status code, headers and body. -/
private def tunnelFetch (port : Nat) (dest path user pw : String)
    : IO (Nat × List (String × String) × String) := do
  let res ← withTimeout 20000 (Std.Async.Async.block (do
    let c ← Std.Async.TCP.Socket.Client.mk
    c.connect (.v4 ⟨.ofParts 127 0 0 1, port.toUInt16⟩)
    let auth := "Basic " ++ Kalari.Sandbox.Broker.b64Encode s!"{user}:{pw}".toUTF8
    c.send s!"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\nProxy-Authorization: {auth}\r\n\r\n".toUTF8
    match ← readHead c with
    | none => pure (0, [], "")
    | some head =>
      let line := firstLine head
      if !line.contains "200" then pure (0, [], line)
      else
        c.send s!"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".toUTF8
        let mut resp := ByteArray.empty
        repeat
          match ← c.recv? 65536 with
          | none => break
          | some chunk =>
            if chunk.isEmpty then break
            resp := resp ++ chunk
            if resp.size > 1048576 then break
        let text := String.fromUTF8? resp |>.getD ""
        let parts := text.splitOn "\r\n\r\n"
        let headPart := parts.headD ""
        let body := if parts.length > 1 then String.intercalate "\r\n\r\n" (parts.drop 1) else ""
        let statusLine := (headPart.splitOn "\r\n").headD ""
        let code := ((statusLine.splitOn " ").getD 1 "").toNat?.getD 0
        let hdrs := (headPart.splitOn "\r\n").drop 1 |>.filterMap fun l =>
          match l.splitOn ":" with
          | n :: rest => if rest.isEmpty then none else some (n.trimAscii.toString.toLower, String.intercalate ":" rest |>.trimAscii.toString)
          | [] => none
        pure (code, hdrs, body)))
  match res with
  | some v => pure v
  | none => pure (0, [], "<timeout>")

def brokerPayouts : IO Unit := IO.FS.withTempDir fun base => do
  let runDir := base / "run"
  IO.FS.createDirAll runDir
  let trace := runDir / "pages.jsonl"
  let id ← Kalari.Sandbox.Broker.freshIdentity "p"
  -- Free loopback port for the bench API, bound the Lean way (no Python).
  let free ← Std.Async.Async.block (do
    let s ← Std.Async.TCP.Socket.Server.mk
    s.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    s.listen 5
    let addr ← s.getSockName
    pure (match addr with | .v4 a => a.port.toNat | .v6 _ => 0))
  -- Bench payouts API: the API under test, not wiring. No probe scripts.
  let adapter ← IO.Process.spawn {
    cmd := "python3", args := #["-I", "bench/apis/payouts/server.py", "--bind", "127.0.0.1",
      "--port", toString free, "--v1", "off", "--trace", trace.toString, "--trace-client", "127.0.0.1"]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := #[("PATH", some "/usr/local/bin:/usr/bin:/bin")] }
  let cleanupServer : IO Unit := do
    try adapter.kill catch _ => pure ()
    try discard adapter.wait catch _ => pure ()
  try
    awaitLine adapter.stdout "payouts-api" "payouts listening on "
    let allowedDest := s!"127.0.0.1:{free}"
    let cfg : Kalari.Sandbox.Broker.BrokerConfig := {
      user := id.user, password := id.password, passwordEnv := id.passwordEnv,
      allowedDest, upstreamHost := "127.0.0.1", upstreamPort := free }
    let broker ← Kalari.Sandbox.Broker.start cfg
    try
      let argv := Kalari.Sandbox.Broker.observedCreateArgv "kalari-run-1" 256
        [{ host := "127.0.0.1", port := free }] broker.port id
      verify (argv.contains "--proxy" && argv.contains "--http-connect-password-env") "payouts msb proxy missing"
      verify (Kalari.Sandbox.Microsandbox.isLoopbackProxy s!"http://127.0.0.1:{broker.port}") "payouts proxy not loopback"
      verify (!(argv.any (fun a => a.contains id.password))) "payouts password in argv"
      -- Correct traversal: limit 1000, follow cursor, dedupe, one 429 retry.
      let mut cursor : Option String := none
      let mut seen : List String := []
      let mut rows := 0
      let mut pages := 0
      let mut retries := 0
      repeat
        if pages > 100 then throw (.userError "payouts traversal did not drain")
        let path := match cursor with
          | none => "/v2/payouts?limit=1000"
          | some c => s!"/v2/payouts?limit=1000&cursor={c}"
        let (code, hdrs, body) ← tunnelFetch broker.port allowedDest path id.user id.password
        if code == 429 then
          let after := hdrs.lookup "retry-after" |>.getD "1"
          let waitMs := (after.toNat?.getD 1).min 5 * 1000
          IO.sleep (waitMs.toUInt32)
          let (code2, _, body2) ← tunnelFetch broker.port allowedDest path id.user id.password
          verify (code2 == 200) "payouts retry not 200"
          retries := retries + 1
          let json ← IO.ofExcept (Lean.Json.parse body2)
          let doc ← IO.ofExcept (json.getObjVal? "payouts" |>.mapError fun _ => IO.userError "no payouts")
          let arr ← IO.ofExcept (doc.getArr? |>.mapError fun _ => IO.userError "no payout array")
          for p in arr.toList do
            let pid := (p.getObjVal? "id").toOption.bind (·.getStr?.toOption) |>.getD ""
            unless seen.contains pid do
              seen := pid :: seen
              rows := rows + 1
          pages := pages + 1
          let cur := ((Lean.Json.parse body2).toOption.bind (·.getObjVal? "cursor" |>.toOption)).bind (·.getStr?.toOption)
          let drained := ((Lean.Json.parse body2).toOption.bind (·.getObjVal? "drained" |>.toOption)).bind (·.getBool?.toOption) |>.getD false
          cursor := cur
          if drained then break
        else
          verify (code == 200) s!"payouts fetch failed: {code} {body.take 80}"
          let json ← IO.ofExcept (Lean.Json.parse body)
          let doc ← IO.ofExcept (json.getObjVal? "payouts" |>.mapError fun _ => IO.userError "no payouts")
          let arr ← IO.ofExcept (doc.getArr? |>.mapError fun _ => IO.userError "no payout array")
          for p in arr.toList do
            let pid := (p.getObjVal? "id").toOption.bind (·.getStr?.toOption) |>.getD ""
            unless seen.contains pid do
              seen := pid :: seen
              rows := rows + 1
          pages := pages + 1
          let cur := (json.getObjVal? "cursor" |>.toOption).bind (·.getStr?.toOption)
          let drained := (json.getObjVal? "drained" |>.toOption).bind (·.getBool?.toOption) |>.getD false
          cursor := cur
          if drained then break
      verify (rows == 2431) s!"payouts rows {rows} != 2431"
      say s!"broker payouts: pages={pages} rows={rows} retries={retries} drained=true"
      IO.sleep 500
      let traceText ← IO.FS.readFile trace
      verify (!traceText.contains "\"cursor\"") "payouts trace carries raw cursor"
      verify (!traceText.contains id.password) "payouts trace carries password"
      match Kalari.Tools.Run.pageObservations (traceText ++ "\n" |>.replace "\n\n" "\n") with
      | .error e => throw (.userError s!"broker trace parser rejected: {e}")
      | .ok facts => do
        verify (facts.contains "boundary_overlap_one") "broker trace missing overlap"
        verify (facts.contains "final_page_token") "broker trace missing token"
        verify (facts.contains "rate_limit_retry") "broker trace missing retry"
        say s!"broker payouts: trace facts={facts}"
      -- Unauthorized adds no events.
      let before ← IO.FS.readFile trace
      let sWrong ← sendConnect broker.port allowedDest "wrong" id.user id.password
      let sMissing ← sendConnect broker.port allowedDest "missing" id.user id.password
      let sDest ← sendConnect broker.port "127.0.0.1:19999" "correct" id.user id.password
      IO.sleep 500
      let after ← IO.FS.readFile trace
      verify (sWrong.contains "407" && sMissing.contains "407" && sDest.contains "403") "payouts unauth not closed"
      verify (after == before) "payouts unauth grew trace"
      say "broker payouts: host auth, loopback only, parser gate holds, no inference"
    finally
      broker.stop
      (try broker.wait catch _ => pure ())
  finally
    cleanupServer

def main : IO UInt32 := do
  try
    brokerIsolation
    brokerPayouts
    say "broker proofs: PASS isolation and payouts through the Lean broker"
    return 0
  catch e =>
    IO.eprintln s!"broker proof: {e}"
    return 1
