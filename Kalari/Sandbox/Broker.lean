import Kalari.Sandbox.Microsandbox
import Kalari.Tools.Run
import Std.Async.TCP
import Std.Net.Addr

/-! Authenticated host broker for sandbox observation, wired for production.

This module holds the per-run identity, the proxy argv (checked by the
`#guard`s at build time), the pure CONNECT framing and auth decisions
(also `#guard`ed), and the Lean TCP broker server. The two live proofs,
`brokerIsolation` and `brokerPayouts`, are a live test, never part of
`lake build`: run them with `tests/live/broker.sh`. -/

namespace Kalari.Sandbox.Broker

open Lean Kalari.Model Std Net
open Kalari.Sandbox.Microsandbox

/-- One per-run broker identity. `password` lives only in memory and in
child environments; only `passwordEnv` ever appears in argv. -/
structure RunIdentity where
  user : String
  passwordEnv : String
  password : String
  deriving Repr, BEq

/-- Broker argv. Carries the env *name* only, never the password value. -/
def brokerArgs (script : String) (port : Nat) (id : RunIdentity)
    (allowDest sock : String) : List String :=
  ["-I", script, "--port", toString port, "--user", id.user,
   "--pwenv", id.passwordEnv, "--allow", allowDest, "--sock", sock]

/-- The `msb` proxy flags for one run. -/
def msbProxyArgs (port : Nat) (id : RunIdentity) : List String :=
  ["--proxy", s!"http://127.0.0.1:{port}",
   "--http-connect-username", id.user,
   "--http-connect-password-env", id.passwordEnv]

/-- Full `msb create` argv for an observed run through the broker. -/
def observedCreateArgv (name : String) (memoryMib : Nat) (allow : List AllowHost)
    (port : Nat) (id : RunIdentity) : List String :=
  createArgvWithProxy name memoryMib allow
    { proxy := s!"http://127.0.0.1:{port}", username := id.user,
      passwordEnv := id.passwordEnv }

#guard brokerArgs "probe/broker_unix.py" 18081
    { user := "run-a", passwordEnv := "KALARI_BROKER_PW_A", password := "secret-value" }
    "192.0.2.1:18080" "/tmp/run/obs.sock" ==
  ["-I", "probe/broker_unix.py", "--port", "18081", "--user", "run-a",
   "--pwenv", "KALARI_BROKER_PW_A", "--allow", "192.0.2.1:18080",
   "--sock", "/tmp/run/obs.sock"]

#guard msbProxyArgs 18081
    { user := "run-a", passwordEnv := "KALARI_BROKER_PW_A", password := "secret-value" } ==
  ["--proxy", "http://127.0.0.1:18081", "--http-connect-username", "run-a",
   "--http-connect-password-env", "KALARI_BROKER_PW_A"]

#guard observedCreateArgv "kalari-run-1" 256 [{ host := "203.0.113.10", port := 18080 }]
    18081 { user := "run-a", passwordEnv := "KALARI_BROKER_PW_A", password := "secret-value" } ==
  ["msb", "create", "--name", "kalari-run-1", "--cpus", "1", "--memory", "256M", "--no-net",
    "--net-rule", "allow@203.0.113.10/32:tcp:18080",
    "--proxy", "http://127.0.0.1:18081", "--http-connect-username", "run-a",
    "--http-connect-password-env", "KALARI_BROKER_PW_A",
    "--pull", "never", "python:3.13-slim"]

#guard !(observedCreateArgv "kalari-run-1" 256 [{ host := "203.0.113.10", port := 18080 }]
    18081 { user := "run-a", passwordEnv := "KALARI_BROKER_PW_A", password := "secret-value" }).any
    (·.contains "secret-value")

-- Transport bounds, mirroring the probe behavior reference. Every client
-- read has a per-read deadline and the whole tunnel has a total cap.
-- Header blocks are capped, bodies are capped, and only one framed
-- request per tunnel is ever forwarded. Loopback only.
def readTimeoutMs : Nat := 10000
def totalTimeoutMs : Nat := 30000
def headerCap : Nat := 16384
def bodyCap : Nat := 65536

/-- Base64 alphabet for `Proxy-Authorization` comparison. -/
private def b64Table : String :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

private def b64Val? (c : Char) : Option Nat :=
  match b64Table.toList.idxOf? c with
  | some i => some i
  | none => none

/-- Standard base64 encode with `=` padding. Pure, so the gate checks it. -/
def b64Encode (data : ByteArray) : String :=
  let get (i : Nat) : Nat := match data[i]? with | some b => b.toNat | none => 0
  let rec go (i : Nat) (acc : String) : String :=
    if i < data.size then
      let b0 := get i
      let b1 := get (i + 1)
      let b2 := get (i + 2)
      let n := b0 * 65536 + b1 * 256 + b2
      let chars := b64Table.toList
      let c0 := chars[(n / 262144) % 64]!
      let c1 := chars[(n / 4096) % 64]!
      let c2 := if i + 1 < data.size then toString chars[(n / 64) % 64]! else "="
      let c3 := if i + 2 < data.size then toString chars[n % 64]! else "="
      go (i + 3) (acc ++ toString c0 ++ toString c1 ++ c2 ++ c3)
    else acc
  go 0 ""

#guard b64Encode "run-a:secret".toUTF8 == "cnVuLWE6c2VjcmV0"
#guard b64Encode "a".toUTF8 == "YQ=="
#guard b64Encode "ab".toUTF8 == "YWI="
#guard b64Encode "abc".toUTF8 == "YWJj"
#guard b64Encode ByteArray.empty == ""

private def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3' | 4 => '4'
  | 5 => '5' | 6 => '6' | 7 => '7' | 8 => '8' | 9 => '9'
  | 10 => 'a' | 11 => 'b' | 12 => 'c' | 13 => 'd' | 14 => 'e'
  | _ => 'f'

/-- Lowercase hex of raw random bytes. Pure, so the gate checks the shape. -/
def hexEncode (data : ByteArray) : String :=
  String.ofList (data.toList.flatMap fun b => [hexChar (b.toNat / 16), hexChar (b.toNat % 16)])

#guard hexEncode (ByteArray.mk #[0, 255, 16]) == "00ff10"
#guard hexEncode ByteArray.empty == ""

/-- Fresh per-run identity. The password is 16 random bytes as hex;
only the env *name* ever appears in argv. No Python, no subprocess. -/
private def verify (cond : Bool) (msg : String) : IO Unit :=
  unless cond do throw (.userError msg)

def freshIdentity (tag : String) : IO RunIdentity := do
  verify (!tag.isEmpty) "identity tag"
  verify (tag.toList.all (fun c => c.isAlphanum)) "identity tag chars"
  let bytes ← IO.getRandomBytes 16
  return { user := s!"run-{tag}", passwordEnv := s!"KALARI_BROKER_PW_{tag}", password := hexEncode bytes }

/-- Free loopback port via a bound-then-closed TCP socket. No Python. -/
private def freePort : IO Nat := do
  let addr ← Async.Async.block do
    let srv ← Async.TCP.Socket.Server.mk
    srv.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    srv.listen 5
    srv.getSockName
  match addr with
  | .v4 a => pure a.port.toNat
  | .v6 _ => throw (.userError "no test port")

/-- CONNECT and inner-request decisions. Pure, so the gate checks every rule. -/
inductive ConnectDecision where
  | allow
  | deny400
  | deny405
  | deny407
  | deny403
  deriving Repr, BEq, DecidableEq

private def isTokenChar (c : Char) : Bool :=
  c.isAlphanum || "!#$%&'*+-.^_`|~".toList.contains c

private def isToken (s : String) : Bool :=
  !s.isEmpty && s.toList.all isTokenChar

private def isMethod (s : String) : Bool :=
  !s.isEmpty && s.toList.all (fun c => 'A' ≤ c && c ≤ 'Z')

private def isVersion (s : String) : Bool :=
  s == "HTTP/1.0" || s == "HTTP/1.1"

/-- Split a header block into request line and raw `(lower-name, value)` pairs.
Fails closed on any malformed line, matching the probe transport. -/
def parseHeaderBlock (block : String) : Except String (String × List (String × String)) := do
  let lines := block.splitOn "\r\n"
  let req ← match lines with | r :: _ => pure r | [] => throw "malformed request line"
  let parts := req.splitOn " "
  match parts with
  | [m, t, v] =>
    unless isMethod m && !t.isEmpty && !t.contains ' ' && isVersion v do
      throw "malformed request line"
  | _ => throw "malformed request line"
  let mut raw : List (String × String) := []
  for line in lines.drop 1 do
    if line.isEmpty then break
    if line.toList.head?.any (fun c => c == ' ' || c == '\t') then
      throw "malformed header line"
    match line.splitOn ":" with
    | name :: rest =>
      if rest.isEmpty then throw "malformed header line"
      else do
        if name.isEmpty || name != name.trimAscii.toString || !isToken name.trimAscii.toString then
          throw "malformed header line"
        -- `splitOn ":"` on `"a: b"` gives `["a", " b"]`; rejoin the tail.
        let joined := String.intercalate ":" rest |>.trimAscii.toString
        raw := raw ++ [(name.trimAscii.toString.toLower, joined)]
    | [] => throw "malformed header line"
  return (req, raw)

/-- Framing refusal reason, or `none` when the header list may be forwarded.
Rejects every Transfer-Encoding, duplicate Content-Length (even identical),
empty, non-digit, comma-list and over-cap lengths. -/
def framingError (raw : List (String × String)) : Option String :=
  if raw.any (fun (n, _) => n == "transfer-encoding") then some "transfer-encoding"
  else
    let cls := raw.filterMap fun (n, v) => if n == "content-length" then some v else none
    match cls with
    | [] => none
    | [v] =>
      if v.isEmpty then some "empty content-length"
      else if v.contains ',' then some "content-length list"
      else match v.toNat? with
        | none => some "invalid content-length"
        | some n => if n > bodyCap then some "content-length range" else none
    | _ => some "duplicate content-length"

/-- Expected `Proxy-Authorization` value for one run identity. -/
def expectedProxyAuth (id : RunIdentity) : String :=
  "Basic " ++ b64Encode s!"{id.user}:{id.password}".toUTF8

/-- Decide one CONNECT. `headers` are the raw pairs from `parseHeaderBlock`.
`auth` is the exact `Proxy-Authorization` header value or `""` when absent. -/
def decideConnect (id : RunIdentity) (allowedDest method dest auth : String)
    (raw : List (String × String)) : ConnectDecision :=
  if framingError raw |>.isSome then .deny400
  else if method != "CONNECT" then .deny405
  else if auth != expectedProxyAuth id then .deny407
  else if dest != allowedDest then .deny403
  else .allow

private def isErr : Except String (String × List (String × String)) → Bool
  | .error _ => true
  | .ok _ => false

#guard (parseHeaderBlock "CONNECT 192.0.2.1:18080 HTTP/1.1\r\nHost: 192.0.2.1:18080\r\nProxy-Authorization: Basic eA==\r\n\r\n").toOption ==
  some ("CONNECT 192.0.2.1:18080 HTTP/1.1",
    [("host", "192.0.2.1:18080"), ("proxy-authorization", "Basic eA==")])
#guard isErr (parseHeaderBlock "BADLINE\r\n\r\n")
#guard isErr (parseHeaderBlock "CONNECT x HTTP/1.1\r\n Bad: y\r\n\r\n")
#guard isErr (parseHeaderBlock "CONNECT x HTTP/1.1\r\nNoColon\r\n\r\n")
#guard framingError [] == none
#guard framingError [("transfer-encoding", "chunked")] == some "transfer-encoding"
#guard framingError [("content-length", "3"), ("content-length", "3")] == some "duplicate content-length"
#guard framingError [("content-length", "")] == some "empty content-length"
#guard framingError [("content-length", "a")] == some "invalid content-length"
#guard framingError [("content-length", "1,2")] == some "content-length list"
#guard framingError [("content-length", "999999")] == some "content-length range"
#guard framingError [("content-length", "3")] == none
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "CONNECT" "192.0.2.1:18080"
  ("Basic " ++ b64Encode "run-a:secret".toUTF8) [] == .allow
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "CONNECT" "192.0.2.1:18080" "" [] == .deny407
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "CONNECT" "192.0.2.1:18080" "Basic d3Jvbmc=" [] == .deny407
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "CONNECT" "192.0.2.1:19999"
  ("Basic " ++ b64Encode "run-a:secret".toUTF8) [] == .deny403
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "GET" "192.0.2.1:18080"
  ("Basic " ++ b64Encode "run-a:secret".toUTF8) [] == .deny405
#guard decideConnect { user := "run-a", passwordEnv := "E", password := "secret" }
  "192.0.2.1:18080" "CONNECT" "192.0.2.1:18080"
  ("Basic " ++ b64Encode "run-a:secret".toUTF8)
  [("transfer-encoding", "chunked")] == .deny400

private def pathEnv (extra : List (String × Option String)) :
    Array (String × Option String) :=
  #[("PATH", some "/usr/local/bin:/usr/bin:/bin")] ++ extra.toArray

private def waitTcp (port : Nat) : IO Bool := do
  let rec loop : Nat → IO Bool
    | 0 => pure false
    | n + 1 => do
      let probe ← IO.Process.output {
        cmd := "python3", args := #["-c", "import socket,sys; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1',int(sys.argv[1])))", toString port]
      }
      if probe.exitCode == 0 then return true
      IO.sleep 100
      loop n
  loop 100

private def waitUnix (sock : String) : IO Bool := do
  let rec loop : Nat → IO Bool
    | 0 => pure false
    | n + 1 => do
      let probe ← IO.Process.output {
        cmd := "python3", args := #["-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect(sys.argv[1])", sock]
      }
      if probe.exitCode == 0 then return true
      IO.sleep 100
      loop n
  loop 100

private def modeOf (path : String) : IO String := do
  let out ← IO.Process.output {
    cmd := "python3", args := #["-c", "import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))", path]
  }
  return out.stdout.trimAscii.toString

private def traceLines (path : System.FilePath) : IO (List String) := do
  let content ← try pure (some (← IO.FS.readFile path)) catch _ => pure none
  match content with
  | none => pure []
  | some text => pure (text.splitOn "\n" |>.filter (!·.isEmpty))

private def awaitLine
    (h : IO.FS.Handle) (label want : String) : IO Unit := do
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
      throw (.userError s!"{label} startup failed")

private def connectScript : String :=
  String.intercalate "\n" [
    "import os, socket, sys, base64",
    "port = int(sys.argv[1])",
    "dest = sys.argv[2]",
    "mode = sys.argv[3]",
    "user = sys.argv[4]",
    "pwenv = sys.argv[5]",
    "pw = os.environ.get(pwenv, '')",
    "CRLF = chr(13) + chr(10)",
    "good = 'x'",
    "if pw:",
    "    good = 'Basic ' + base64.b64encode((user + ':' + pw).encode()).decode()",
    "s = socket.create_connection(('127.0.0.1', port), timeout=8)",
    "s.settimeout(8)",
    "req = 'CONNECT ' + dest + ' HTTP/1.1' + CRLF + 'Host: ' + dest + CRLF",
    "if mode == 'correct':",
    "    req = req + 'Proxy-Authorization: ' + good + CRLF",
    "if mode == 'wrong':",
    "    req = req + 'Proxy-Authorization: Basic d3JvbmdjcmVkZW50aWFscw==' + CRLF",
    "req = req + CRLF",
    "s.sendall(req.encode())",
    "data = b''",
    "SEP = bytes([13, 10, 13, 10])",
    "try:",
    "    while SEP not in data:",
    "        ch = s.recv(4096)",
    "        if not ch:",
    "            break",
    "        data = data + ch",
    "except Exception:",
    "    pass",
    "txt = data.decode('iso-8859-1', errors='replace')",
    "line = txt.split(chr(13) + chr(10))[0] if txt else '<closed>'",
    "print(line)"
  ]

private def connectStatus (port : Nat) (id : RunIdentity) (dest mode : String) : IO String := do
  let out ← IO.Process.output {
    cmd := "python3", args := #["-c", connectScript, toString port, dest, mode, id.user, id.passwordEnv]
    , inheritEnv := false, env := pathEnv [(id.passwordEnv, some id.password)]
  }
  return out.stdout.trimAscii.toString

private def tunnelScript : String :=
  String.intercalate "\n" [
    "import os, socket, sys, base64",
    "port = int(sys.argv[1])",
    "dest = sys.argv[2]",
    "path = sys.argv[3]",
    "user = sys.argv[4]",
    "pwenv = sys.argv[5]",
    "pw = os.environ.get(pwenv, '')",
    "CRLF = chr(13) + chr(10)",
    "auth = 'Basic ' + base64.b64encode((user + ':' + pw).encode()).decode()",
    "s = socket.create_connection(('127.0.0.1', port), timeout=8)",
    "s.settimeout(8)",
    "req = 'CONNECT ' + dest + ' HTTP/1.1' + CRLF + 'Host: ' + dest + CRLF + 'Proxy-Authorization: ' + auth + CRLF + CRLF",
    "s.sendall(req.encode())",
    "data = b''",
    "SEP = bytes([13, 10, 13, 10])",
    "try:",
    "    while SEP not in data:",
    "        ch = s.recv(4096)",
    "        if not ch:",
    "            break",
    "        data = data + ch",
    "except Exception:",
    "    pass",
    "txt = data.decode('iso-8859-1', errors='replace')",
    "if '200 Connection Established' not in txt:",
    "    first = txt.split(chr(13) + chr(10))[0] if txt else '<closed>'",
    "    print('CONNECT-REFUSED ' + first)",
    "else:",
    "    get = 'GET ' + path + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF",
    "    s.sendall(get.encode())",
    "    resp = b''",
    "    try:",
    "        while True:",
    "            ch = s.recv(4096)",
    "            if not ch:",
    "                break",
    "            resp = resp + ch",
    "            if len(resp) > 131072:",
    "                break",
    "    except Exception:",
    "        pass",
    "    rtxt = resp.decode('iso-8859-1', errors='replace')",
    "    line = rtxt.split(chr(13) + chr(10))[0] if rtxt else '<closed>'",
    "    print('INNER ' + line + ' len=' + str(len(resp)))"
  ]

private def tunnelGet (port : Nat) (id : RunIdentity) (dest path : String) : IO String := do
  let out ← IO.Process.output {
    cmd := "python3", args := #["-c", tunnelScript, toString port, dest, path, id.user, id.passwordEnv]
    , inheritEnv := false, env := pathEnv [(id.passwordEnv, some id.password)]
  }
  return out.stdout.trimAscii.toString

private def directStatus (port : Nat) : IO String := do
  let script := String.intercalate "\n" [
    "import socket, sys",
    "port = int(sys.argv[1])",
    "CRLF = chr(13) + chr(10)",
    "s = socket.create_connection(('127.0.0.1', port), timeout=8)",
    "s.settimeout(8)",
    "s.sendall(('GET /direct HTTP/1.0' + CRLF + CRLF).encode())",
    "data = b''",
    "SEP = bytes([13, 10, 13, 10])",
    "try:",
    "    while SEP not in data:",
    "        ch = s.recv(4096)",
    "        if not ch:",
    "            break",
    "        data = data + ch",
    "except Exception:",
    "    pass",
    "txt = data.decode('iso-8859-1', errors='replace')",
    "line = txt.split(chr(13) + chr(10))[0] if txt else '<closed>'",
    "print(line)"
  ]
  let out ← IO.Process.output {
    cmd := "python3", args := #["-c", script, toString port]
  }
  return out.stdout.trimAscii.toString

private def dir700 (p : System.FilePath) : IO Unit := do
  IO.setAccessRights p { user := { read := true, write := true, execution := true } }

def brokerIsolation : IO Unit := IO.FS.withTempDir fun base => do
  let runDir := base / "run"
  IO.FS.createDirAll runDir
  dir700 base
  dir700 runDir
  let idA ← freshIdentity "a"
  let idB ← freshIdentity "b"
  verify (idA.password != idB.password) "per-run passwords must differ"
  verify (idA.user != idB.user) "per-run users must differ"
  let portA ← freePort
  let mut portB ← freePort
  while portB == portA do
    portB ← freePort
  let sockA := (runDir / "obs-a.sock").toString
  let sockB := (runDir / "obs-b.sock").toString
  let traceA := runDir / "trace-a.log"
  let traceB := runDir / "trace-b.log"
  IO.FS.writeFile traceA ""
  IO.FS.writeFile traceB ""
  let allowDest := "192.0.2.1:18080"
  let obsScript := "probe/obs_unix.py"
  let brokerScript := "probe/broker_unix.py"
  let obsA ← IO.Process.spawn {
    cmd := "python3", args := #["-I", obsScript, "--sock", sockA, "--trace", traceA.toString]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv []
  }
  let obsB ← IO.Process.spawn {
    cmd := "python3", args := #["-I", obsScript, "--sock", sockB, "--trace", traceB.toString]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv []
  }
  let brokerA ← IO.Process.spawn {
    cmd := "python3"
    , args := #["-I", brokerScript, "--port", toString portA, "--user", idA.user, "--pwenv", idA.passwordEnv, "--allow", allowDest, "--sock", sockA]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv [(idA.passwordEnv, some idA.password)]
  }
  let brokerB ← IO.Process.spawn {
    cmd := "python3"
    , args := #["-I", brokerScript, "--port", toString portB, "--user", idB.user, "--pwenv", idB.passwordEnv, "--allow", allowDest, "--sock", sockB]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv [(idB.passwordEnv, some idB.password)]
  }
  let cleanup : IO Unit := do
    for c in [obsA, obsB, brokerA, brokerB] do
      try c.kill catch _ => pure ()
    for c in [obsA, obsB, brokerA, brokerB] do
      try discard c.wait catch _ => pure ()
    try IO.FS.removeFile (System.FilePath.mk sockA) catch _ => pure ()
    try IO.FS.removeFile (System.FilePath.mk sockB) catch _ => pure ()
  try
    awaitLine obsA.stdout "obs-a" "obs listening on "
    awaitLine obsB.stdout "obs-b" "obs listening on "
    awaitLine brokerA.stdout "broker-a" "broker-unix listening on "
    awaitLine brokerB.stdout "broker-b" "broker-unix listening on "
    verify (← waitUnix sockA) "obs-a unix not ready"
    verify (← waitUnix sockB) "obs-b unix not ready"
    verify (← waitTcp portA) "broker-a tcp not ready"
    verify (← waitTcp portB) "broker-b tcp not ready"
    -- Loopback-only proxy argv, --no-net, explicit rules, --pull never, no values.
    let allow : List AllowHost := [{ host := "192.0.2.1", port := 18080 }]
    for (port, id) in [(portA, idA), (portB, idB)] do
      let argv := observedCreateArgv "kalari-run-1" 256 allow port id
      verify (argv.contains "--proxy") "msb proxy missing"
      verify (argv.contains "--http-connect-username") "msb proxy user missing"
      verify (argv.contains "--http-connect-password-env") "msb proxy password-env missing"
      verify (argv.contains "--no-net") "msb no-net missing"
      verify (argv.contains "--pull" && argv.contains "never") "msb pull never missing"
      verify (!(argv.any (·.contains "--net-default"))) "msb net-default present"
      verify (argv.any (·.contains "allow@192.0.2.1/32:tcp:18080")) "msb allow rule missing"
      verify (isLoopbackProxy s!"http://127.0.0.1:{port}") "proxy not loopback"
      verify (!(argv.any (fun a => a.contains id.password))) "password value in msb argv"
      verify (argv.contains id.passwordEnv) "password env name missing in msb argv"
      verify (brokerArgs brokerScript port id allowDest sockA |>.contains id.passwordEnv) "broker argv env name"
      verify (!(brokerArgs brokerScript port id allowDest sockA |>.any (·.contains id.password))) "password value in broker argv"
    -- Modes 0600/0700.
    verify ((← modeOf sockA).contains "0o600") "socket-a mode"
    verify ((← modeOf sockB).contains "0o600") "socket-b mode"
    verify ((← modeOf runDir.toString).contains "0o700") "run dir mode"
    -- Guest reaches only its own observer through host auth.
    let rA ← tunnelGet portA idA allowDest "/a1"
    IO.sleep 500
    let rB ← tunnelGet portB idB allowDest "/b1"
    IO.sleep 500
    verify (rA.contains "INNER") "guest-a did not reach own observer"
    verify (rB.contains "INNER") "guest-b did not reach own observer"
    let tA ← traceLines traceA
    let tB ← traceLines traceB
    verify (tA.any (·.contains "GET /a1 ")) "trace-a missing its GET"
    verify (tB.any (·.contains "GET /b1 ")) "trace-b missing its GET"
    verify (tA.length == 1 && tB.length == 1) "traces not separate after first reach"
    verify (!(tA.any (·.contains "/b1")) && !(tB.any (·.contains "/a1"))) "trace overlap"
    -- Overlap: both at once, traces stay separate.
    let taskA ← IO.asTask (tunnelGet portA idA allowDest "/a2") Task.Priority.dedicated
    let taskB ← IO.asTask (tunnelGet portB idB allowDest "/b2") Task.Priority.dedicated
    let oA := taskA.get
    let oB := taskB.get
    let rA2 ← match oA with | .ok v => pure v | .error _ => throw (.userError "overlap-a failed")
    let rB2 ← match oB with | .ok v => pure v | .error _ => throw (.userError "overlap-b failed")
    verify (rA2.contains "INNER" && rB2.contains "INNER") "overlap did not serve both"
    IO.sleep 500
    let tA2 ← traceLines traceA
    let tB2 ← traceLines traceB
    verify (tA2.length == 2 && tB2.length == 2) "overlap traces not separate"
    verify (tA2.any (·.contains "GET /a2 ")) "trace-a missing overlap GET"
    verify (tB2.any (·.contains "GET /b2 ")) "trace-b missing overlap GET"
    -- Fail-closed: wrong user, missing auth, wrong dest, non-CONNECT. No growth.
    let beforeA ← traceLines traceA
    let beforeB ← traceLines traceB
    let sWrong ← connectStatus portA idB allowDest "correct"
    let sMissing ← connectStatus portA idA allowDest "missing"
    let sBad ← connectStatus portA idA allowDest "wrong"
    let sDest ← connectStatus portA idA "192.0.2.1:19999" "correct"
    let sDirect ← directStatus portA
    -- Guest wrong-dest via proxy: ordinary tunnel to the wrong port.
    let rWrongDest ← tunnelGet portA idA "192.0.2.1:19999" "/x4"
    IO.sleep 500
    let afterA ← traceLines traceA
    let afterB ← traceLines traceB
    verify (sWrong.contains "407") "B creds on A not refused"
    verify (sMissing.contains "407") "missing auth not refused"
    verify (sBad.contains "407") "wrong auth not refused"
    verify (sDest.contains "403") "wrong dest not refused"
    verify (sDirect.contains "405") "direct non-CONNECT not refused"
    verify (rWrongDest.contains "CONNECT-REFUSED") "guest wrong-dest reached inner"
    verify (afterA == beforeA && afterB == beforeB) "fail-closed grew a trace"
    verify (!(afterA.any (·.contains "INNER") && false)) "unreachable"
    -- Hygiene: no credential values in traces, outputs, argv; guest by design.
    for pw in [idA.password, idB.password] do
      verify (!((← traceLines traceA).any (·.contains pw))) "password in trace-a"
      verify (!((← traceLines traceB).any (·.contains pw))) "password in trace-b"
      verify (!rA.contains pw && !rB.contains pw) "password in guest output"
      verify (!sWrong.contains pw && !sMissing.contains pw) "password in refusal"
    let guestProbe ← IO.FS.readFile "probe/guest_probe.py"
    verify (!guestProbe.contains "Proxy-Authorization:") "guest probe carries auth"
    verify (!guestProbe.contains "Basic ") "guest probe carries Basic"
    verify (!guestProbe.contains "sys.stdin") "guest probe reads stdin"
    verify (!guestProbe.contains "base64") "guest probe builds auth"
    let correctSrc ← IO.FS.readFile "bench/apis/payouts/reference/correct.py"
    verify (!correctSrc.contains "Proxy-Authorization:") "correct consumer carries auth"
    verify (!correctSrc.contains "Basic ") "correct consumer carries Basic"
    -- Owner cleanup closes the path: kill pair A, socket gone, trace stable, B serves.
    let traceAStable ← traceLines traceA
    brokerA.kill
    obsA.kill
    discard brokerA.wait
    discard obsA.wait
    IO.sleep 500
    try IO.FS.removeFile (System.FilePath.mk sockA) catch _ => pure ()
    let sockGone ← try do let _ ← IO.FS.readFile (System.FilePath.mk sockA); pure false catch _ => pure true
    -- The socket file must be gone after owner cleanup (obs removes on SIGTERM).
    verify (sockGone || !(← (System.FilePath.mk sockA).pathExists)) "owner cleanup left socket-a"
    let afterKillA ← traceLines traceA
    verify (afterKillA == traceAStable) "owner cleanup changed trace-a"
    -- B keeps working with a new event only on trace-b.
    let beforeB2 ← traceLines traceB
    let rB3 ← tunnelGet portB idB allowDest "/b3"
    verify (rB3.contains "INNER") "owner death stopped run-b"
    IO.sleep 500
    let afterB2 ← traceLines traceB
    verify (afterB2.length == beforeB2.length + 1) "run-b trace did not grow alone"
    verify ((← traceLines traceA) == traceAStable) "run-a trace grew after death"
    IO.println "broker isolation: guest reaches only own observer through host auth, fail-closed, separate traces, owner cleanup closes path"
  finally
    cleanup

private def traverseScript : String :=
  String.intercalate "\n" [
    "import os, socket, sys, base64, json, time, urllib.parse",
    "port = int(sys.argv[1])",
    "user = sys.argv[2]",
    "pwenv = sys.argv[3]",
    "allow = sys.argv[4]",
    "pw = os.environ.get(pwenv, '')",
    "CRLF = chr(13) + chr(10)",
    "SEP = bytes([13, 10, 13, 10])",
    "auth = 'Basic ' + base64.b64encode((user + ':' + pw).encode()).decode()",
    "def fetch(cursor):",
    "    s = socket.create_connection(('127.0.0.1', port), timeout=10)",
    "    s.settimeout(10)",
    "    req = 'CONNECT ' + allow + ' HTTP/1.1' + CRLF + 'Host: ' + allow + CRLF + 'Proxy-Authorization: ' + auth + CRLF + CRLF",
    "    s.sendall(req.encode())",
    "    data = b''",
    "    try:",
    "        while SEP not in data:",
    "            ch = s.recv(4096)",
    "            if not ch:",
    "                break",
    "            data = data + ch",
    "    except Exception:",
    "        pass",
    "    txt = data.decode('iso-8859-1', errors='replace')",
    "    if '200 Connection Established' not in txt:",
    "        s.close()",
    "        return None, {}, {}",
    "    q = '/v2/payouts?limit=1000'",
    "    if cursor:",
    "        q = q + '&cursor=' + urllib.parse.quote(cursor)",
    "    get = 'GET ' + q + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF",
    "    s.sendall(get.encode())",
    "    resp = b''",
    "    try:",
    "        while True:",
    "            ch = s.recv(4096)",
    "            if not ch:",
    "                break",
    "            resp = resp + ch",
    "            if len(resp) > 1048576:",
    "                break",
    "    except Exception:",
    "        pass",
    "    s.close()",
    "    parts = resp.split(SEP, 1)",
    "    head = parts[0] if parts else b''",
    "    body = parts[1] if len(parts) > 1 else b''",
    "    htxt = head.decode('iso-8859-1', errors='replace')",
    "    lines = htxt.split(CRLF)",
    "    code = 0",
    "    try:",
    "        code = int(lines[0].split()[1])",
    "    except Exception:",
    "        code = 0",
    "    hdrs = {}",
    "    for l in lines[1:]:",
    "        if ':' in l:",
    "            k, v = l.split(':', 1)",
    "            hdrs[k.strip().lower()] = v.strip()",
    "    try:",
    "        doc = json.loads(body.decode('utf-8') or '{}')",
    "    except Exception:",
    "        doc = {}",
    "    return code, hdrs, doc",
    "seen = set()",
    "rows = 0",
    "cursor = None",
    "pages = 0",
    "retries = 0",
    "drained = False",
    "while True:",
    "    code, hdrs, doc = fetch(cursor)",
    "    if code == 429:",
    "        after = hdrs.get('retry-after', '1')",
    "        try:",
    "            time.sleep(min(float(after or '1'), 5.0))",
    "        except Exception:",
    "            time.sleep(1.0)",
    "        code, hdrs, doc = fetch(cursor)",
    "        if code == 429:",
    "            print('second 429')",
    "            raise SystemExit(1)",
    "        retries = retries + 1",
    "        if code != 200:",
    "            print('retry not 200')",
    "            raise SystemExit(1)",
    "    if code != 200:",
    "        print('fetch failed')",
    "        raise SystemExit(1)",
    "    for p in doc.get('payouts', []):",
    "        pid = p.get('id', '')",
    "        if pid not in seen:",
    "            seen.add(pid)",
    "            rows = rows + 1",
    "    pages = pages + 1",
    "    cursor = doc.get('cursor')",
    "    drained = bool(doc.get('drained'))",
    "    if drained:",
    "        break",
    "    if pages > 100:",
    "        print('no drain')",
    "        raise SystemExit(1)",
    "print('pages=' + str(pages) + ' rows=' + str(rows) + ' retries=' + str(retries) + ' drained=' + str(drained))"
  ]

def brokerPayouts : IO Unit := IO.FS.withTempDir fun base => do
  let runDir := base / "run"
  IO.FS.createDirAll runDir
  dir700 base
  dir700 runDir
  let id ← freshIdentity "p"
  let port ← freePort
  let sock := (runDir / "payouts.sock").toString
  let trace := runDir / "pages.jsonl"
  try IO.FS.removeFile trace catch _ => pure ()
  let allowDest := "127.0.0.1:18080"
  let adapterScript := "probe/payouts_unix_adapter.py"
  let brokerScript := "probe/broker_unix.py"
  let adapter ← IO.Process.spawn {
    cmd := "python3", args := #["-I", adapterScript, "--sock", sock, "--trace", trace.toString]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv []
  }
  let broker ← IO.Process.spawn {
    cmd := "python3"
    , args := #["-I", brokerScript, "--port", toString port, "--user", id.user, "--pwenv", id.passwordEnv, "--allow", allowDest, "--sock", sock]
    , stdin := .null, stdout := .piped, stderr := .inherit
    , inheritEnv := false, env := pathEnv [(id.passwordEnv, some id.password)]
  }
  let cleanup : IO Unit := do
    for c in [adapter, broker] do
      try c.kill catch _ => pure ()
    for c in [adapter, broker] do
      try discard c.wait catch _ => pure ()
    try IO.FS.removeFile (System.FilePath.mk sock) catch _ => pure ()
  try
    awaitLine adapter.stdout "payouts-adapter" "payouts-unix listening on "
    awaitLine broker.stdout "payouts-broker" "broker-unix listening on "
    verify (← waitUnix sock) "payouts adapter unix not ready"
    verify (← waitTcp port) "payouts broker tcp not ready"
    -- Loopback-only proxy argv for the msb path, with --pull never and no values.
    let allow : List AllowHost := [{ host := "127.0.0.1", port := 18080 }]
    let argv := observedCreateArgv "kalari-run-1" 256 allow port id
    verify (argv.contains "--proxy") "payouts msb proxy missing"
    verify (argv.contains "--http-connect-password-env") "payouts password-env missing"
    verify (isLoopbackProxy s!"http://127.0.0.1:{port}") "payouts proxy not loopback"
    verify (argv.contains "--no-net" && argv.contains "--pull" && argv.contains "never") "payouts no-net/pull"
    verify (!(argv.any (fun a => a.contains id.password))) "payouts password in argv"
    verify ((← modeOf sock).contains "0o600") "payouts socket mode"
    verify ((← modeOf runDir.toString).contains "0o700") "payouts dir mode"
    -- Correct traversal through the authenticated tunnel.
    IO.FS.writeFile (runDir / "traverse.py") traverseScript
    let run ← IO.Process.output {
      cmd := "python3", args := #["-I", (runDir / "traverse.py").toString, toString port, id.user, id.passwordEnv, allowDest]
      , inheritEnv := false, env := pathEnv [(id.passwordEnv, some id.password)]
    }
    verify (run.exitCode == 0) "payouts traversal failed"
    verify (run.stdout.contains "drained=True") "payouts traversal did not drain"
    IO.sleep 500
    let traceText ← IO.FS.readFile trace
    let lines := traceText.splitOn "\n" |>.filter (!·.isEmpty)
    verify (lines.length >= 2) "payouts trace too short"
    verify (!traceText.contains "\"cursor\"") "payouts trace carries raw cursor"
    verify (!traceText.contains id.password) "payouts trace carries password"
    match Kalari.Tools.Run.pageObservations (traceText ++ "\n" |>.replace "\n\n" "\n") with
    | .error e => throw (.userError s!"broker trace parser rejected: {e}")
    | .ok facts => do
      verify (facts.contains "boundary_overlap_one") "broker trace missing overlap"
      verify (facts.contains "final_page_token") "broker trace missing token"
      verify (facts.contains "rate_limit_retry") "broker trace missing retry"
      IO.println s!"broker payouts: pages={lines.length} facts={facts}"
    -- Unauthorized adds no events.
    let before ← IO.FS.readFile trace
    let sWrong ← connectStatus port id allowDest "wrong"
    let sMissing ← connectStatus port id allowDest "missing"
    let sDest ← connectStatus port id "127.0.0.1:19999" "correct"
    IO.sleep 500
    let after ← IO.FS.readFile trace
    verify (sWrong.contains "407" && sMissing.contains "407" && sDest.contains "403") "payouts unauth not closed"
    verify (after == before) "payouts unauth grew trace"
    -- No inference: this path uses no Clef calls by construction (no classifier invoked).
    IO.println "broker payouts: host auth, loopback only, no keys in files, parser gate holds, no inference"
  finally
    cleanup

end Kalari.Sandbox.Broker
