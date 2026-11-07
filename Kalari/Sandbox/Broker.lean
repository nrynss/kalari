import Kalari.Sandbox.Microsandbox
import Std.Async.TCP
import Std.Async.Timer
import Std.Net.Addr
import Std.Time

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

/-- Strict parse of one upstream response header block. Status line shape
is `HTTP/x NNN Reason` (the reason may contain spaces); header rules
match client requests. -/
def parseResponseBlock (block : String) : Except String (Nat × List (String × String)) := do
  let lines := block.splitOn "\r\n"
  let status ← match lines with | s :: _ => pure s | [] => throw "malformed status line"
  -- Split into at most 3: version, 3-digit code, reason (which may hold spaces).
  let (v, rest) ← match status.splitOn " " with
    | v :: rest => pure (v, rest)
    | [] => throw "malformed status line"
  let (c, reason) ← match rest with
    | c :: r :: rs =>
      let reason := String.intercalate " " (r :: rs)
      pure (c, reason)
    | _ => throw "malformed status line"
  unless isVersion v && c.length == 3 && c.toList.all (·.isDigit) && !reason.isEmpty do
    throw "malformed status line"
  let code := c.toNat!
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
        let joined := String.intercalate ":" rest |>.trimAscii.toString
        raw := raw ++ [(name.trimAscii.toString.toLower, joined)]
    | [] => throw "malformed header line"
  return (code, raw)

private def isRespErr : Except String (Nat × List (String × String)) → Bool
  | .error _ => true
  | .ok _ => false

#guard (parseResponseBlock "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n").toOption ==
  some (200, [("content-length", "3")])
#guard (parseResponseBlock "HTTP/1.0 429 Too Many Requests\r\nContent-Length: 79\r\nRetry-After: 1\r\n\r\n").toOption ==
  some (429, [("content-length", "79"), ("retry-after", "1")])
#guard isRespErr (parseResponseBlock "HTTP/1.1 20 OK\r\n\r\n")
#guard isRespErr (parseResponseBlock "HTTP/1.1 200 OK\r\nNoColon\r\n\r\n")

/-- Single validated Content-Length, or `0` when absent. Call only after
`framingError` returned `none`. -/
def contentLengthOf (raw : List (String × String)) : Nat :=
  match raw.filterMap fun (n, v) => if n == "content-length" then some v else none with
  | [v] => v.toNat?.getD 0
  | _ => 0

#guard contentLengthOf [] == 0
#guard contentLengthOf [("content-length", "12")] == 12
#guard contentLengthOf [("content-length", "x")] == 0

/-- Live broker configuration. `password` lives only in memory; only
`passwordEnv` ever appears in argv. `allowedDest` is the exact CONNECT
target (guest-visible `host:port`); the tunnel goes to
`upstreamHost:upstreamPort` over plain TCP. -/
structure BrokerConfig where
  user : String
  password : String
  passwordEnv : String
  allowedDest : String
  upstreamHost : String
  upstreamPort : Nat
  deriving Repr

/-- A running broker: loopback `port`, plus `stop` and `wait`.
`task` is stored, not a prebuilt wait action: `Task.get` blocks, so
building `wait` from it eagerly would deadlock construction while the
server still runs. Call `BrokerHandle.wait` after `stop`. -/
structure BrokerHandle where
  port : Nat
  stop : IO Unit
  task : Task (Except IO.Error Unit)

/-- Reap the server task. Call after `stop`; blocks until the accept loop
exits (prompt when idle, after the in-flight tunnel otherwise). -/
def BrokerHandle.wait (h : BrokerHandle) : IO Unit := do
  IO.ofExcept h.task.get

/-- Index of the first `\r\n\r\n` in `buf`, if any. -/
private def findDelim (buf : ByteArray) : Option Nat :=
  (List.range buf.size).find? fun i =>
    i + 4 <= buf.size && buf[i]! == 13 && buf[i + 1]! == 10 && buf[i + 2]! == 13 && buf[i + 3]! == 10

#guard findDelim ("a\r\n\r\nb".toUTF8) == some 1
#guard findDelim ("abc".toUTF8) == none
#guard findDelim (ByteArray.empty) == none

private def toMs (ms : Nat) : Std.Time.Millisecond.Offset :=
  Std.Time.Internal.UnitVal.ofNat ms

/-- One `recv?` bounded by `ms`. Outer `none` is a timeout, inner `none`
is EOF. -/
private def recvTimeout (c : Async.TCP.Socket.Client) (ms : Nat)
    : Async.Async (Option (Option ByteArray)) := do
  let sel ← Async.Selector.sleep (toMs ms)
  let recvSel : Async.Selectable (Option (Option ByteArray)) :=
    { β := Option ByteArray, selector := c.recvSelector 4096, cont := fun r => pure (some r) }
  let sleepSel : Async.Selectable (Option (Option ByteArray)) :=
    { β := Unit, selector := sel, cont := fun _ => pure none }
  Async.Selectable.one #[recvSel, sleepSel]

/-- One header block read. `total` is total-deadline expiry (answer 408),
`silent` is empty, incomplete or per-read expiry (close, no reply),
`oversize` is past the header cap (answer 400). -/
inductive HeadResult where
  | total
  | silent
  | oversize
  | ok (head rest : ByteArray)

private def recvHeaders (c : Async.TCP.Socket.Client) (initial : ByteArray)
    (deadline : Nat) : Async.Async HeadResult := do
  if initial.size > headerCap then return .oversize
  let mut buf := initial
  match findDelim buf with
  | some i => return .ok (buf.extract 0 (i + 4)) (buf.extract (i + 4) buf.size)
  | none => pure ()
  repeat
    let now ← liftM IO.monoMsNow
    if now >= deadline then return .total
    let waitMs := Nat.min readTimeoutMs (deadline - now)
    match ← recvTimeout c waitMs with
    | none =>
      let late ← liftM IO.monoMsNow
      if late >= deadline then return .total else return .silent
    | some none => return .silent
    | some (some chunk) =>
      if chunk.isEmpty then return .silent
      buf := buf ++ chunk
      if buf.size > headerCap then return .oversize
      match findDelim buf with
      | some i => return .ok (buf.extract 0 (i + 4)) (buf.extract (i + 4) buf.size)
      | none => pure ()
  return .silent

/-- Exactly `need` body bytes. `total` is total-deadline expiry (answer
408); `silent` is truncation, per-read expiry or over-cap (close). -/
inductive BodyResult where
  | total
  | silent
  | ok (body : ByteArray)

private def recvBody (c : Async.TCP.Socket.Client) (initial : ByteArray) (need : Nat)
    (deadline : Nat) : Async.Async BodyResult := do
  if need > bodyCap then return .silent
  if initial.size > bodyCap then return .silent
  let mut buf := initial.extract 0 (Nat.min initial.size need)
  repeat
    if buf.size >= need then return .ok (buf.extract 0 need)
    let now ← liftM IO.monoMsNow
    if now >= deadline then return .total
    let waitMs := Nat.min readTimeoutMs (deadline - now)
    match ← recvTimeout c waitMs with
    | none =>
      let late ← liftM IO.monoMsNow
      if late >= deadline then return .total else return .silent
    | some none => return .silent
    | some (some chunk) =>
      if chunk.isEmpty then return .silent
      buf := buf ++ chunk
      if buf.size > bodyCap then return .silent
  return .ok (buf.extract 0 need)

private def sendStr (c : Async.TCP.Socket.Client) (s : String) : Async.Async Unit := do
  try
    c.send s.toUTF8
  catch _ =>
    pure ()

private def sendBytes (c : Async.TCP.Socket.Client) (b : ByteArray) : Async.Async Unit := do
  try
    c.send b
  catch _ =>
    pure ()

private def reply400 : String :=
  "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply403 : String :=
  "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply405 : String :=
  "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply407 : String :=
  "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"broker\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply408 : String :=
  "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply502 : String :=
  "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private def reply200 : String :=
  "HTTP/1.1 200 Connection Established\r\n\r\n"

/-- Read one complete upstream response within the deadline, or `none`
on any oversize, timeout, early close, malformed or bad framing.
Never returns a partial: the caller answers 502 instead. -/
private def recvUpstream (u : Async.TCP.Socket.Client) (deadline : Nat)
    : Async.Async (Option ByteArray) := do
  match ← recvHeaders u ByteArray.empty deadline with
  | .total => return none
  | .silent => return none
  | .oversize => return none
  | .ok head rest =>
    match String.fromUTF8? head with
    | none => return none
    | some text =>
      match parseResponseBlock text with
      | .error _ => return none
      | .ok (_, raw) =>
        if (framingError raw).isSome then return none
        let need := contentLengthOf raw
        let hasCl := raw.any (fun (n, _) => n == "content-length")
        if hasCl then
          if head.size + need > headerCap + bodyCap then return none
          match ← recvBody u rest need deadline with
          | .total => return none
          | .silent => return none
          | .ok body => return some (head ++ body)
        else
          let mut buf := head ++ rest
          if buf.size > headerCap + bodyCap then return none
          repeat
            let now ← liftM IO.monoMsNow
            if now >= deadline then return none
            let waitMs := Nat.min readTimeoutMs (deadline - now)
            match ← recvTimeout u waitMs with
            | none => return none
            | some none => return some buf
            | some (some chunk) =>
              if chunk.isEmpty then return some buf
              buf := buf ++ chunk
              if buf.size > headerCap + bodyCap then return none
          return some buf

/-- Forward one framed request to the upstream over plain TCP and relay
the complete response, or answer 502 with no partial. -/
private def forwardUpstream (c : Async.TCP.Socket.Client) (cfg : BrokerConfig)
    (framed : ByteArray) (deadline : Nat) : Async.Async Unit := do
  match Std.Net.IPv4Addr.ofString cfg.upstreamHost with
  | none => sendStr c reply502
  | some ip =>
    let outcome ← liftM (try
      Async.Async.block (do
        let u ← Async.TCP.Socket.Client.mk
        u.connect (.v4 ⟨ip, cfg.upstreamPort.toUInt16⟩)
        u.send framed
        recvUpstream u deadline)
      catch _ => pure none)
    match outcome with
    | some resp => sendBytes c resp
    | none => sendStr c reply502

private def textOf (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s
  | none => .error "malformed request line"

/-- One tunnel: CONNECT auth, then exactly one framed inner request
tunneled upstream. Every refusal and every total-deadline expiry is an
explicit reply; empty or incomplete tunnels close silently. -/
private def handleOne (c : Async.TCP.Socket.Client) (cfg : BrokerConfig) : Async.Async Unit := do
  try
    let start ← liftM IO.monoMsNow
    let deadline := start + totalTimeoutMs
    let id : RunIdentity := { user := cfg.user, passwordEnv := cfg.passwordEnv, password := cfg.password }
    match ← recvHeaders c ByteArray.empty deadline with
    | .total => sendStr c reply408
    | .silent => pure ()
    | .oversize => sendStr c reply400
    | .ok head rest =>
      match textOf head >>= parseHeaderBlock with
      | .error _ => sendStr c reply400
      | .ok (reqLine, raw) =>
        let parts := reqLine.splitOn " "
        let method := parts.headD ""
        let dest := parts.getD 1 ""
        let auth := raw.lookup "proxy-authorization" |>.getD ""
        match decideConnect id cfg.allowedDest method dest auth raw with
        | .deny400 => sendStr c reply400
        | .deny405 => sendStr c reply405
        | .deny407 => sendStr c reply407
        | .deny403 => sendStr c reply403
        | .allow =>
          sendStr c reply200
          match ← recvHeaders c rest deadline with
          | .total => sendStr c reply408
          | .silent => pure ()
          | .oversize => sendStr c reply400
          | .ok ihead irest =>
            match textOf ihead >>= parseHeaderBlock with
            | .error _ => sendStr c reply400
            | .ok (_, iraw) =>
              if (framingError iraw).isSome then sendStr c reply400
              else
                let need := contentLengthOf iraw
                match ← recvBody c irest need deadline with
                | .total => sendStr c reply408
                | .silent => pure ()
                | .ok body =>
                  let now ← liftM IO.monoMsNow
                  if now >= deadline then sendStr c reply408
                  else forwardUpstream c cfg (ihead ++ body) deadline
  catch _ =>
    liftM (IO.eprintln "broker: transport error")

/-- Serve loop. Binds 127.0.0.1 on an ephemeral port, reports the port,
then serves one connection at a time on this thread: exactly one framed
request per tunnel, then the next connection. Polls `tryAccept` so `stop`
shuts the listener down with no extra close call. Sequential handling is
deliberate: one broker serves one run's sequential guest requests, and
isolation is between brokers, not between threads. Plain `IO` with one
`Async.block` per step on this thread (the `serveBoth` shape): handles
never cross threads. -/
private def serverMain (cfg : BrokerConfig) (stopped : IO.Ref Bool)
    (ready : IO.Ref (Option Nat)) : IO Unit := do
  let srv ← Async.Async.block (do
    let s ← Async.TCP.Socket.Server.mk
    s.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    s.listen 20
    pure s)
  let addr ← srv.getSockName
  match addr with
  | .v4 a => ready.set (some a.port.toNat)
  | .v6 _ => ready.set none
  repeat
    if ← stopped.get then break
    match ← srv.tryAccept with
    | some client => Async.Async.block (handleOne client cfg)
    | none => IO.sleep 20
  pure ()

/-- Start a Lean broker on 127.0.0.1 with a fresh ephemeral port.
The password lives only in memory; the proxy URL is always loopback.
The whole server runs in one task (the `serveBoth` shape); `stop` ends
the loop and `wait` reaps it. -/
def start (cfg : BrokerConfig) : IO BrokerHandle := do
  let stopped ← IO.mkRef false
  let ready ← IO.mkRef (none : Option Nat)
  let task ← IO.asTask (serverMain cfg stopped ready) Task.Priority.dedicated
  let rec awaitPort : Nat → IO Nat
    | 0 => throw (IO.userError "broker: startup timeout")
    | n + 1 => do
      let r ← ready.get
      match r with
      | some port => pure port
      | none =>
        if ← IO.hasFinished task then
          IO.ofExcept task.get
          throw (IO.userError "broker: startup failed")
        IO.sleep 50
        awaitPort n
  let port ← awaitPort 100
  return { port, stop := stopped.set true, task }

end Kalari.Sandbox.Broker

