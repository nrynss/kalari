import Kalari.Evidence
import Kalari.RunId
import Kalari.Gate
import Kalari.Sandbox.Broker
import Kalari.Sandbox.Microsandbox
import Std.Async.System
import Std.Net.Addr
import Std.Data.HashMap

/-! Contained consumer runs and mandatory migration checks. -/

namespace Kalari.Tools.Run

open Lean Kalari.Model Kalari.Proc
open Kalari.Sandbox

private def guestWorkspace := "/workspace"
private def supervisor := "/usr/local/bin/kalari-aashaan"
private def artifactCap := 4 * 1024 * 1024
/-- Reserved check-guest filename for the exact v1 output collected by the
same run's differential comparison. -/
def trustedTruthArtifactName : String := "kalari-v1-truth.jsonl"

/-- The candidate truth check identity. The lesson writer uses the same ID,
program and artifact. -/
def candidateTruthCheckId : String := "candidate-v1-truth-v1"
def candidateTruthCheckProgram : String := "kalari_candidate_truth_check.py"

/-- The guest-visible name of the msb host gateway. Every observed endpoint
uses this name so the trusted service, not the caller, fixes the destination. -/
def guestAlias : String := "host.microsandbox.internal"

/-- The private range msb allocates a dedicated /30 from for one sandbox. -/
def guestCidr : String := "172.16.0.0/12"

/-- What the runtime reports from inside one running sandbox. The guest and
gateway must be the two usable addresses of one dedicated /30. -/
structure GuestNetwork where
  guest : String
  gateway : String
  deriving Repr, BEq

/-- The endpoint is the candidate's sole permitted destination. The runtime
must report the guest network before the observer starts. -/
structure Observer where
  endpoint : AllowHost
  start : String → System.FilePath → IO (Except String (IO (Except String String)))

/-- Start a dedicated observed payouts server on a loopback bind. The guest
reaches it through the msb host gateway. `guestIp` is the address the observer
sees: the gateway proxy uses loopback, so it is the loopback address, not a
caller claim about the guest. An optional behaviour list lets the gate replay
a B5-off trace.
Observer/Python boundary: `serverPath` names the observed API implementation
(the bench payouts `server.py`, i.e. the API under test), not proxy wiring.
The broker mechanism — per-run identity, CONNECT auth, tunneling, and the msb
`--proxy` argv — is pure Lean in `Kalari.Sandbox.Broker` (gate `#guard`s);
`python3` here only runs the observed API, as `tests/live/broker-proof.lean`
states. -/
def payoutsObserver (serverPath : String) (endpoint : AllowHost) (bindHost guestIp : String)
    (behaviours : Option String := none) : Observer := {
  endpoint
  start := fun _ dir => do
    if (Std.Net.IPv4Addr.ofString bindHost).isNone ||
        (Std.Net.IPv4Addr.ofString guestIp).isNone || endpoint.port == 0 || endpoint.port > 65535 then
      return .error "observer requires IPv4 addresses and a valid port"
    let trace := dir / "payouts-pages.jsonl"
    let args := #["-I", serverPath, "--bind", bindHost, "--port", toString endpoint.port, "--v1", "off", "--trace", trace.toString, "--trace-client", guestIp]
    let args := match behaviours with | some value => args ++ #["--behaviours", value] | none => args
    try
      -- The observer is trusted host code. It needs no service secret, so it
      -- starts with an explicit PATH and no inherited environment.
      let child ← IO.Process.spawn {
        cmd := "python3", args := args, stdin := .null, stdout := .piped, stderr := .inherit
        inheritEnv := false, env := #[("PATH", some "/usr/local/bin:/usr/bin:/bin")] }
      let ready ← IO.asTask child.stdout.getLine Task.Priority.dedicated
      let started ← IO.monoMsNow
      repeat
        if ← IO.hasFinished ready then break
        if (← IO.monoMsNow) - started >= 5000 then
          child.kill
          discard child.wait
          return .error "observer startup timeout"
        IO.sleep 10
      match ready.get with
      | .error _ =>
        child.kill
        discard child.wait
        return .error "observer startup failed"
      | .ok line =>
        unless line.startsWith "payouts listening on " do
          child.kill
          discard child.wait
          return .error "observer startup failed"
      return .ok (do
        try
          child.kill
          discard child.wait
          let data ← IO.FS.readBinFile trace
          if data.size > 262144 then return .error "oversized page trace"
          match String.fromUTF8? data with
          | none => return .error "invalid page trace encoding"
          | some text => return .ok text
        catch _ => return .error "observer cleanup or trace read failed")
    catch _ => return .error "observer launch failed"
}

/-- One event from the trusted payouts trace. A page carries what the API sent.
A 429 carries the retry delay and no page. Neither carries a raw cursor, a raw
request or a token. -/
private inductive TraceEvent where
  | page (request response first last : String) (count : Nat) (ids : List String) (drained : Bool)
      (fingerprint : Option String) (retry : Bool)
  | throttled (request fingerprint retryAfter : String)

private def optional (json : Json) (key : String) : Option Json :=
  (json.getObjVal? key).toOption

private def optionalString (json : Json) (key : String) : Except String (Option String) :=
  match optional json key with
  | none => pure none
  | some value => value.getStr?.map some

/-- A page event recorded before the retry events carried no status and meant 200. -/
private def traceStatus (json : Json) : Except String Nat :=
  match optional json "status" with
  | none => pure 200
  | some value => value.getNat?.mapError fun _ => "invalid trace status"

private def traceRetry (json : Json) : Except String Bool :=
  match optional json "retry" with
  | none => pure false
  | some value => value.getBool?.mapError fun _ => "invalid trace retry flag"

/-- A trace digest is 32 lowercase hex characters. -/
private def isDigest (value : String) : Bool :=
  value.length == 32 && value.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

/-- A 429 must name the full-request fingerprint. `parseTraceEvent` has already
validated the shape of every present fingerprint. -/
private def traceFingerprint (fingerprint : Option String) : Except String String := do
  let some fingerprint := fingerprint | throw "trace event has no request fingerprint"
  return fingerprint

/-- The request field is a cursor digest. The first request of a traversal has no cursor. -/
private def traceRequest (json : Json) : Except String String := do
  let request ← (json.getObjVal? "request" >>= Json.getStr?).mapError
    fun _ => "trace event has no request digest"
  unless request.isEmpty || isDigest request do throw "trace request is not a digest"
  return request

private def parseTraceEvent (line : String) : Except String TraceEvent := do
  let json ← Json.parse line
  let status ← traceStatus json
  let request ← traceRequest json
  let fingerprint ← optionalString json "fingerprint"
  if let some value := fingerprint then
    unless isDigest value do throw "trace request fingerprint is not a digest"
  let retry ← traceRetry json
  let api ← optionalString json "api"
  match api with
  | none => pure ()
  | some "v1" => throw "traced v1 response is not a v2 page"
  | some _ => throw "unexpected trace api marker"
  if status == 429 then do
    if ["response", "first", "last", "count", "ids", "drained"].any (fun key => (optional json key).isSome) then
      throw "throttled event carries a page"
    if retry then throw "throttled event is marked as a retry"
    let fingerprint ← traceFingerprint fingerprint
    let some retryAfter := (optional json "retry_after").bind (fun value => value.getStr?.toOption) |
      throw "throttled event has no retry delay"
    return .throttled request fingerprint retryAfter
  unless status == 200 do throw "unexpected trace status"
  let response ← (json.getObjVal? "response" >>= Json.getStr?).mapError
    fun _ => "page event has no response digest"
  unless isDigest response do throw "trace response is not a digest"
  let first ← (json.getObjVal? "first" >>= Json.getStr?).mapError
    fun _ => "page event has no first record"
  let last ← (json.getObjVal? "last" >>= Json.getStr?).mapError
    fun _ => "page event has no last record"
  let count ← (json.getObjVal? "count" >>= Json.getNat?).mapError
    fun _ => "page event has no record count"
  let ids ← (json.getObjVal? "ids" >>= Json.getArr?).mapError
    fun _ => "page event has no record IDs"
  let ids ← ids.toList.mapM fun id => id.getStr?.mapError fun _ => "page event has a non-string record ID"
  let drained ← (json.getObjVal? "drained" >>= Json.getBool?).mapError
    fun _ => "page event has no drained flag"
  return .page request response first last count ids drained fingerprint retry

/-- Validate one complete, unbranched cursor chain. A 429 has no page, and only
the identical retry may follow it. A response is evidence of what the API sent,
not of how the consumer used it. -/
def pageObservations (trace : String) : Except String (List String) := do
  if trace.utf8ByteSize > 262144 || !trace.endsWith "\n" then throw "missing, truncated or oversized page trace"
  let lines := (trace.splitOn "\n").dropLast
  if lines.isEmpty || lines.length > 256 then throw "empty or oversized page trace"
  let events ← lines.mapM parseTraceEvent
  let mut previous := ""
  let mut previousIds : List String := []
  let mut overlap := false
  let mut terminal := false
  let mut retries := 0
  let mut seen : List String := []
  let mut pending : Option (String × String) := none
  for event in events do
    match event with
    | .throttled request fingerprint retryAfter =>
      if terminal then throw "throttled request after the drained response"
      if retries != 0 then throw "more than one throttled request"
      if retryAfter.isEmpty || !retryAfter.toList.all (fun c => c.isDigit) then
        throw "invalid retry delay"
      if request != previous then throw "orphaned throttled request"
      retries := retries + 1
      pending := some (request, fingerprint)
    | .page request response first last count ids drained fingerprint retry =>
      if terminal then throw "page after the drained response"
      if ids.length > 100 then throw "page exceeds the trusted page cap"
      if seen.contains response || count == 0 || first.isEmpty || last.isEmpty ||
          ids.length != count || ids.eraseDups.length != ids.length ||
          ids.head? != some first || ids.getLast? != some last then
        throw "invalid page IDs"
      match pending with
      | some (throttledRequest, throttledFingerprint) =>
        unless retry && request == throttledRequest && fingerprint == some throttledFingerprint do
          throw "throttled request was not followed by the identical retry"
        pending := none
      | none =>
        if retry then throw "retry page without a throttled request"
        if request != previous then throw "ambiguous or incomplete page trace"
      if !previous.isEmpty then
        let repeated := ids.filter previousIds.contains
        if repeated.length == 1 && repeated.head? == previousIds.getLast? && repeated.head? == some first then overlap := true
      seen := response :: seen
      previous := response
      previousIds := ids
      terminal := drained
  if pending.isSome then throw "trace ends with an unanswered throttled request"
  unless terminal do throw "page trace has no drained response"
  return (if overlap then ["boundary_overlap_one"] else []) ++ ["final_page_token"] ++
    (if retries > 0 then ["rate_limit_retry"] else [])

/-- Session-owned inputs. The candidate and baseline workspace paths point to
separate prepared consumer trees; `checkWorkspace` points to a host-owned tree
of trusted lesson-check programs. The baseline is pristine and targets v1 of
the same dataset. Each consumer writes `artifact`, a JSONL file at the root of
its guest workspace. None of these settings or the recalled checks come from
the tool arguments. -/
structure Context where
  workspace : String
  baseline : RunRequest
  /-- Host-owned directory containing trusted lesson-check programs. -/
  checkWorkspace : String
  artifact : String
  checks : List Check
  maxCaps : Caps
  allowedNet : List AllowHost
  secrets : List String
  image : String := Microsandbox.imageName
  aashaanHost : String
  evidence : Kalari.Evidence.Store
  sessionId : String
  changeKinds : List String
  observer : Option Observer := none

/-- Reads the gateway from the guest's hosts file and the guest's own /30
address from the kernel table. It makes no network request. -/
private def networkProbe : List String :=
  ["sh", "-c",
    "gw=$(grep 'host.microsandbox' /etc/hosts | head -1 | cut -f1); " ++
    "guest=$(grep -B1 '/32 host LOCAL' /proc/net/fib_trie | " ++
    "grep -oE '([0-9]{1,3}[.]){3}[0-9]{1,3}' | grep -v '^127[.]' | head -1); " ++
    "printf '%s\\n%s\\n' \"$gw\" \"$guest\""]

/-- External operations can replay through the same orchestration as live runs.
A runtime that cannot report its guest network, or cannot show the sandbox
policy, fails the observer closed. -/
structure Runtime where
  runner : Microsandbox.Runner
  resolve : String → IO (List String)
  wait : Nat → IO Unit := fun ms => IO.sleep ms.toUInt32
  network : String → IO (Except String GuestNetwork) := fun _ =>
    pure (.error "runtime cannot report the guest network")
  inspect : String → IO (Except String String) := fun _ =>
    pure (.error "runtime cannot inspect the sandbox")
  /-- Start one Lean broker for an observed run. The default fails closed
  (no broker), so replay fixtures must opt in explicitly. -/
  startBroker : Kalari.Sandbox.Broker.BrokerConfig → IO (Except String Kalari.Sandbox.Broker.BrokerHandle) :=
    fun _ => pure (.error "runtime has no broker")

/-- Run commands with the storage permissions msb expects and no inherited keys. -/
def live (path : String) : Runtime :=
  let run := Microsandbox.live path
  { runner := fun argv =>
      let argv := match argv with
        | "msb" :: "exec" :: rest => ["msb", "exec", "--quiet", "--no-tty", "--no-stdin"] ++ rest
        | _ => argv
      run (["/bin/sh", "-c", "umask 022; exec \"$@\"", "sh"] ++ argv)
    resolve := fun host => do
      let result ← run ["getent", "ahostsv4", host] 5000 16384
      if result.cap != .none || result.exitCode != some 0 then return []
      let lines := ((String.fromUTF8? result.stdout).getD "").splitOn "\n"
      return lines.map fun line => (line.splitOn " ").headD ""
    network := fun name => do
      let result ← run (["msb", "exec", name, "--"] ++ networkProbe) 5000 16384
      if result.cap != .none || result.exitCode != some 0 then
        return .error "sandbox network unavailable"
      let lines := (String.fromUTF8? result.stdout).getD "" |>.splitOn "\n" |>.map (·.trimAscii.toString)
      match lines.filter (fun line => !line.isEmpty) with
      | gateway :: guest :: _ => pure (.ok { guest, gateway })
      | _ => pure (.error "sandbox network unavailable")
    inspect := fun name => do
      let result ← run ["msb", "inspect", name, "--format", "json"] 5000 65536
      if result.cap != .none || result.exitCode != some 0 then
        return .error "sandbox inspect unavailable"
      pure (.ok ((String.fromUTF8? result.stdout).getD ""))
    startBroker := fun cfg => do
      try
        pure (.ok (← Kalari.Sandbox.Broker.start cfg))
      catch _ => pure (.error "broker start failed") }

structure Difference where
  missing : Nat
  extra : Nat
  duplicates : Nat
  changed : Nat
  deriving BEq, Repr

private abbrev Records := Std.HashMap String (Json × Nat)

private def readRecords (data : String) : Except String Records := do
  let mut records : Records := {}
  for line in data.splitOn "\n" do
    if !line.trimAscii.isEmpty then
      let row ← (Json.parse line).mapError fun _ => "invalid JSONL record"
      let id ← (row.getObjValAs? String "id").mapError fun _ => "record has no string ID"
      if id.isEmpty then throw "record has an empty ID"
      records := records.insert id (row, (records[id]?.map Prod.snd).getD 0 + 1)
  return records

/-- Compare full records by ID, counting duplicate deliveries beyond the first. -/
def compareRecords (baseline candidate : String) : Except String Difference := do
  let expected ← readRecords baseline
  let actual ← readRecords candidate
  unless expected.toList.all (fun (_, _, count) => count == 1) do
    throw "v1 returned duplicate IDs"
  let missing := expected.toList.countP fun (id, _) => !actual.contains id
  let extra := actual.toList.countP fun (id, _) => !expected.contains id
  let duplicates := actual.fold (fun n _ (_, count) => n + (count - 1)) 0
  let changed := actual.toList.countP fun (id, record, _) =>
    (expected[id]?.map fun (old, _) => old != record).getD false
  return { missing, extra, duplicates, changed }

private def Difference.passed (d : Difference) : Bool :=
  d == ⟨0, 0, 0, 0⟩

private def Difference.summary (d : Difference) : String :=
  s!"{d.missing} missing, {d.extra} extra, {d.duplicates} duplicates, {d.changed} changed"

private def differentialId := "differential-v1"

private def permit (ctx : Context) (request : RunRequest) : Except String Unit := do
  let (allowed, reason) := Gate.decide request ctx.maxCaps ctx.allowedNet ctx.secrets
  unless allowed do throw s!"refused: {reason.getD "gate"}"
  if request.command.isEmpty || request.command.headD "" == "" then throw "refused: empty command"
  if request.caps.timeout_ms == 0 || request.caps.memory_mib == 0 then throw "refused: caps"
  if (request.workspace :: request.command).any (·.contains '\x00') then throw "refused: invalid argument"

private def admit (ctx : Context) (request : RunRequest) : Except String Unit := do
  unless request.workspace == ctx.workspace do throw "refused: workspace"
  permit ctx request
  permit ctx ctx.baseline
  if ctx.baseline.workspace == ctx.workspace then throw "setup: v1 requires a separate workspace"
  if ctx.checkWorkspace.isEmpty || ctx.checkWorkspace == ctx.workspace ||
      ctx.checkWorkspace == ctx.baseline.workspace then
    throw "setup: checks require a separate trusted workspace"
  unless Gate.segmentOk ctx.artifact && ctx.artifact.toList.all
      (fun c => c.isAlphanum || c == '.' || c == '-' || c == '_') do
    throw "setup: invalid JSONL artifact name"
  if ctx.artifact == trustedTruthArtifactName then
    throw "setup: candidate artifact name is reserved for trusted v1 truth"
  if let some observer := ctx.observer then
    unless request.allowlist == [observer.endpoint] do throw "setup: observer endpoint must be the sole candidate allowlist entry"
  for check in ctx.checks do
    permit ctx { request with workspace := ctx.checkWorkspace, command := check.command }

/-- A lesson may publish from a run only when every candidate truth check in
that run names the session's trusted artifact. The check program and the truth
artifact are fixed, so the artifact argument is the remaining binding. -/
def verifyCandidateTruthArtifact (record : RunRecord) (artifact : String) : Except String Unit := do
  let checks := record.checks.filter fun check =>
    check.id == candidateTruthCheckId &&
    check.command.length == 4 && check.command[0]? == some "python3" &&
    check.command[1]? == some candidateTruthCheckProgram &&
    check.command[3]? == some trustedTruthArtifactName
  if checks.isEmpty then throw "run has no candidate truth check"
  for check in checks do
    unless check.command[2]? == some artifact do
      throw "candidate truth check does not name the trusted artifact"

private def resolveAllowlist (runtime : Runtime) (hosts : List AllowHost) :
    ExceptT String IO (List AllowHost) := do
  let mut rules := []
  for entry in hosts do
    unless entry.port > 0 && entry.port <= 65535 && !entry.host.isEmpty &&
        entry.host.toList.all (fun c => c.isAlphanum || c == '.' || c == '-' || c == '/') &&
        !entry.host.startsWith "-" do
      throw "setup: invalid API host or port"
    if entry.host == guestAlias then
      rules := rules ++ [{ entry with host := guestCidr }]
    else
      let answers ← match Std.Net.IPv4Addr.ofString entry.host with
        | some ip => pure [toString ip]
        | none => runtime.resolve entry.host
      let ips := answers.filterMap Std.Net.IPv4Addr.ofString
      if ips.isEmpty then throw "setup: API host has no IPv4 address"
      rules := rules ++ ips.map fun ip => { entry with host := toString ip }
  return rules.eraseDups

/-- One net rule token. A guest CIDR is already a network, so it does not get
the `/32` suffix a single address needs. -/
private def netRule (host : AllowHost) : String :=
  if host.host.contains "/" then s!"allow@{host.host}:tcp:{host.port}"
  else s!"allow@{host.host}/32:tcp:{host.port}"

/-- The msb create argv, with the same shape as `Microsandbox.createArgv`, so a
guest-alias endpoint becomes one private CIDR rule instead of a /32. -/
private def createArgv (ctx : Context) (name : String) (request : RunRequest)
    (allow : List AllowHost) : List String :=
  ["msb", "create", "--name", name, "--cpus", "1", "--memory", s!"{request.caps.memory_mib}M", "--no-net"]
    ++ allow.flatMap (fun host => ["--net-rule", netRule host])
    ++ ["--pull", "never", ctx.image]

/-- Parse a dotted IPv4 literal into one number. -/
private def ipv4Nat? (value : String) : Option Nat :=
  let part (text : String) : Option Nat :=
    match text.toNat? with
    | some n => if n ≤ 255 then some n else none
    | none => none
  match value.splitOn "." with
  | [a, b, c, d] =>
    match part a, part b, part c, part d with
    | some a, some b, some c, some d => some (a * 16777216 + b * 65536 + c * 256 + d)
    | _, _, _, _ => none
  | _ => none

/-- The production refusal. The service and the harness share this message. -/
def isolationMessage : String :=
  "observer requires verified exclusive guest source isolation"

/-- A guest address is exclusive when the runtime reports a private /30 with
the gateway at network+1 and the guest at network+2. The alias rule is the
pool that contains that /30. The sandbox holds no other network path. -/
private def verifyGuestNetwork (net : GuestNetwork) : Except String Unit := do
  let some gateway := ipv4Nat? net.gateway | throw isolationMessage
  let some guest := ipv4Nat? net.guest | throw isolationMessage
  -- The create rule is the default msb pool. Any other pool leaves the guest
  -- unable to reach the observer, so it is not a configuration to enable.
  unless (gateway &&& 0xFFF00000) == 0xAC100000 &&
      (guest &&& 0xFFF00000) == 0xAC100000 do
    throw isolationMessage
  unless (gateway &&& 3) == 1 && (guest &&& 3) == 2 && gateway + 1 == guest do
    throw isolationMessage
  let canonical (n : Nat) : String :=
    s!"{n / 16777216}.{n / 65536 % 256}.{n / 256 % 256}.{n % 256}"
  unless net.gateway == canonical gateway && net.guest == canonical guest do
    throw isolationMessage

/-- The sandbox must be the one just created: running, no published port, and
one egress allow rule for this observer's port on the expected guest network. -/
private def verifySandboxPolicy (name expectedCidr : String) (port : Nat) (raw : String) :
    Except String Unit := do
  let json ← Json.parse raw
  let actual ← (json.getObjVal? "name" >>= Json.getStr?).mapError fun _ => isolationMessage
  unless actual == name do throw isolationMessage
  let status ← (json.getObjVal? "status" >>= Json.getStr?).mapError fun _ => isolationMessage
  unless status == "Running" do throw isolationMessage
  let config ← (json.getObjVal? "active_config").mapError fun _ => isolationMessage
  let network ← (config.getObjVal? "network").mapError fun _ => isolationMessage
  let enabled ← (network.getObjVal? "enabled" >>= Json.getBool?).mapError fun _ => isolationMessage
  unless enabled do throw isolationMessage
  let published ← (network.getObjVal? "ports" >>= Json.getArr?).mapError fun _ => isolationMessage
  unless published.isEmpty do throw isolationMessage
  let policy ← (network.getObjVal? "policy").mapError fun _ => isolationMessage
  let egress ← (policy.getObjVal? "default_egress" >>= Json.getStr?).mapError fun _ => isolationMessage
  let ingress ← (policy.getObjVal? "default_ingress" >>= Json.getStr?).mapError fun _ => isolationMessage
  unless egress == "deny" && ingress == "deny" do throw isolationMessage
  let rules ← (policy.getObjVal? "rules" >>= Json.getArr?).mapError fun _ => isolationMessage
  let [rule] := rules.toList | throw isolationMessage
  let action ← (rule.getObjVal? "action" >>= Json.getStr?).mapError fun _ => isolationMessage
  let direction ← (rule.getObjVal? "direction" >>= Json.getStr?).mapError fun _ => isolationMessage
  let destination ← (rule.getObjVal? "destination").mapError fun _ => isolationMessage
  let cidr ← (destination.getObjVal? "cidr" >>= Json.getStr?).mapError fun _ => isolationMessage
  let protocols ← (rule.getObjVal? "protocols" >>= Json.getArr?).mapError fun _ => isolationMessage
  let ports ← (rule.getObjVal? "ports" >>= Json.getArr?).mapError fun _ => isolationMessage
  let [range] := ports.toList | throw isolationMessage
  let start ← (range.getObjVal? "start" >>= Json.getNat?).mapError fun _ => isolationMessage
  let stop ← (range.getObjVal? "end" >>= Json.getNat?).mapError fun _ => isolationMessage
  let protocolOk := !protocols.toList.isEmpty && protocols.toList.all fun protocol =>
    match protocol.getStr? with
    | .ok "tcp" => true
    | _ => false
  unless action == "allow" && direction == "egress" && cidr == expectedCidr &&
      start == port && stop == port && protocolOk do
    throw isolationMessage

private def successful (v : Verdict) : Bool :=
  v.verdict == "exited" && v.exit_code == some 0 && !v.pipe_held_open && !v.stdout_truncated

private def summary (v : Verdict) : String :=
  match v.verdict with
  | "killed_timeout" => "The aashaan killed the run when it reached the time cap."
  | "killed_output_cap" => "The aashaan killed the run when it reached the output cap."
  | _ => s!"Exited with code {v.exit_code.getD 1}."

private def scrub (secrets : List String) (s : String) : String :=
  secrets.foldl (fun acc key => if key.isEmpty then acc else acc.replace key "[redacted]") s

private def clip (bytes : Nat) (s : String) : String :=
  let raw := s.toUTF8
  if raw.size <= bytes then s
  else ((List.range 4).findSome? fun n => String.fromUTF8? (raw.extract 0 (bytes - n))).getD ""

private def failureDetail (result : Except String Result) : String :=
  match result with
  | .error e => "backend error: " ++ e
  | .ok r =>
    let cap := match r.cap with
      | .none => "none"
      | .timeout => "timeout"
      | .output => "output"
    s!"exit_code={r.exitCode}, cap={cap}; " ++ (String.fromUTF8? r.stderr).getD "invalid UTF-8 diagnostics"

private def execOk (backend : Kalari.Backend.SandboxBackend) (name stage : String)
    (command : List String) (secrets : List String := []) : ExceptT String IO Result := do
  let result : Except String Result ← liftM (backend.exec name command)
  match result with
  | .ok r =>
    if r.cap == .none && r.exitCode == some 0 then return r
    throw s!"sandbox {stage}: msb exec failed: {clip 1024 (scrub secrets (failureDetail result))}"
  | .error _ =>
    throw s!"sandbox {stage}: msb exec failed: {clip 1024 (scrub secrets (failureDetail result))}"

private def requireStep (stage : String) (result : Except String Result)
    (secrets : List String := []) : ExceptT String IO Unit :=
  match result with
  | .ok r =>
    if r.cap == .none && r.exitCode == some 0 then pure ()
    else throw s!"sandbox {stage} failed: {clip 1024 (scrub secrets (failureDetail result))}"
  | .error _ =>
    throw s!"sandbox {stage} failed: {clip 1024 (scrub secrets (failureDetail result))}"

private def cleanupFailure : Result :=
  { cap := .none, exitCode := some 1, stdout := ByteArray.empty,
    stderr := ByteArray.empty, wallMs := 0 }

private def duplicateCreate (r : Result) : Bool := Id.run do
  let message := (String.fromUTF8? r.stderr).getD "" ++
    (String.fromUTF8? r.stdout).getD ""
  return message.contains "already exists"

/-- An msb create timeout or transport failure may have created the sandbox.
Remove that unique run name unless msb explicitly says it belongs to an existing
sandbox; that name is not ours to delete. -/
private def sanitizeTag (s : String) : String :=
  let t := String.ofList (s.toList.filter (·.isAlphanum))
  if t.isEmpty then "run" else t

/-- True when a live sandbox already uses this name. Best-effort: a runner
that cannot list (fixtures, offline paths) reports no collision, and the
evidence-store check plus the create-time duplicate guard still hold. -/
private def sandboxTaken (runtime : Runtime) (sandboxName : String) : IO Bool := do
  try
    let result ← runtime.runner ["msb", "list", "--format", "json"]
      Microsandbox.controlTimeoutMs 65536
    match result.exitCode with
    | some 0 =>
      match String.fromUTF8? result.stdout with
      | some text =>
        match Microsandbox.parseListed text with
        | .ok entries => pure (entries.any (·.name == sandboxName))
        | .error _ => pure false
      | none => pure false
    | _ => pure false
  catch _ => pure false

/-- Draw a purposeful run ID, skipping any ID already in the evidence store
or live as a `kalari-run-…` sandbox. The temp directory stays a temp
directory: nothing reads its name. Fails closed after a few collisions. -/
private def freshRunIdWith (store : Kalari.Evidence.Store) (runtime : Runtime)
    (draw : IO String) : ExceptT String IO String := do
  let loaded ← liftM (Kalari.Evidence.load store)
  let taken := fun (candidate : String) =>
    loaded.records.any (·.run_id == candidate)
  let mut attempt := 0
  while attempt < Kalari.RunId.maxAttempts do
    let candidate ← liftM <| try pure (← draw)
      catch _ => pure ""
    if candidate.isEmpty || !Kalari.RunId.isRunId candidate then
      attempt := attempt + 1
      continue
    if taken candidate then
      attempt := attempt + 1
      continue
    if ← liftM (sandboxTaken runtime (Kalari.RunId.sandboxName candidate)) then
      attempt := attempt + 1
      continue
    return candidate
  throw s!"run ID collision: no fresh run ID after {Kalari.RunId.maxAttempts} attempts"

private def freshRunId (store : Kalari.Evidence.Store) (runtime : Runtime) :
    ExceptT String IO String :=
  freshRunIdWith store runtime Kalari.RunId.generate

/-- Start one Lean broker for this exact run. Fresh per-run identity, a
loopback bind, the run's single allowed dest as the CONNECT allow list,
and a plain-TCP tunnel to the local observer. The password is placed in
the parent env under its per-run name so the msb child inherits it via
`--http-connect-password-env`; it lives only in memory, never in argv,
files, logs or evidence. Fail closed when the runtime has no broker. -/
private def startRunBroker (runtime : Runtime) (observer : Observer) (runId : String)
    : IO (Except String (Kalari.Sandbox.Broker.RunIdentity × Kalari.Sandbox.Broker.BrokerHandle)) := do
  try
    let id ← Kalari.Sandbox.Broker.freshIdentity (sanitizeTag runId)
    Std.Async.System.setEnvVar id.passwordEnv id.password
    let endpoint := observer.endpoint
    let cfg : Kalari.Sandbox.Broker.BrokerConfig := {
      user := id.user, password := id.password, passwordEnv := id.passwordEnv,
      allowedDest := s!"{endpoint.host}:{endpoint.port}",
      upstreamHost := "127.0.0.1", upstreamPort := endpoint.port }
    match ← runtime.startBroker cfg with
    | .error _ =>
      Std.Async.System.unsetEnvVar id.passwordEnv
      pure (.error isolationMessage)
    | .ok handle => pure (.ok (id, handle))
  catch _ =>
    pure (.error isolationMessage)

/-- Stop the run broker and clear its password from the parent env. Runs
on every path after `startRunBroker` succeeded, including failures:
sockets close, the port frees, and nothing secret remains. -/
private def stopRunBroker
    : Option (Kalari.Sandbox.Broker.RunIdentity × Kalari.Sandbox.Broker.BrokerHandle) → IO Unit
  | none => pure ()
  | some (id, handle) => do
    try handle.stop catch _ => pure ()
    try handle.wait catch _ => pure ()
    try Std.Async.System.unsetEnvVar id.passwordEnv catch _ => pure ()

private def createSandbox (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost)
    (proxy : Option Microsandbox.ProxyAuth := none) : ExceptT String IO Unit := do
  let argv := match proxy with
    | none => createArgv ctx name request allow
    | some auth => Microsandbox.createArgvWithProxy name request.caps.memory_mib allow auth ctx.image
  let attempted : Except String Result ← try
    pure (.ok (← runtime.runner argv
      Microsandbox.controlTimeoutMs (4096 + 12 * request.caps.output_cap_bytes)))
  catch _ => pure (.error "create runner failed")
  let created := attempted.toOption
  if let some result := created then
    if result.cap == .none && result.exitCode == some 0 then return
    if duplicateCreate result then throw "sandbox create: name already exists; left untouched"
  let removed ← liftM <| try
    runtime.runner ["msb", "remove", "-f", name] Microsandbox.controlTimeoutMs 4096
  catch _ => pure cleanupFailure
  requireStep "create cleanup" (.ok removed)
  throw "sandbox create failed"

private def guestArg (workspace arg : String) : String :=
  if arg == workspace then guestWorkspace
  else match arg.dropPrefix? (workspace ++ "/") with
    | some suffix => guestWorkspace ++ "/" ++ suffix.toString
    | none => arg

private def supervise (backend : Kalari.Backend.SandboxBackend) (name : String)
    (request : RunRequest) (secrets : List String) : ExceptT String IO Verdict := do
  let args := request.command.map (guestArg request.workspace)
  -- The Python image installs Python in /usr/local/bin, outside aashaan's PATH.
  let args := if args.head? == some "python3" then "/usr/local/bin/python3" :: args.drop 1 else args
  let r ← execOk backend name "supervisor" <|
    [supervisor, toString request.caps.timeout_ms, toString request.caps.output_cap_bytes,
     "/bin/sh", "-c", "cd /workspace && exec \"$@\"", "sh"] ++ args
  let decoded : Except String Verdict := do
    let some text := String.fromUTF8? r.stdout | throw "invalid UTF-8"
    let v : Verdict ← Json.parse text >>= fromJson?
    unless (v.verdict == "exited" && v.exit_code.isSome) ||
      (["killed_timeout", "killed_output_cap"].contains v.verdict && v.exit_code.isNone) do
      throw "invalid supervisor verdict"
    return v
  match decoded with
  | .error _ => throw "sandbox supervisor: invalid verdict"
  | .ok v =>
    let capped := clip request.caps.output_cap_bytes ∘ scrub secrets
    return { v with stdout := capped v.stdout, stderr := capped v.stderr }

private structure Execution where
  verdict : Verdict
  artifact : Except String String
  trace : Option (Except String String) := none

/-- The host-owned observer to start for this exact sandbox run. -/
private structure Observation where
  observer : Observer
  runId : String
  dir : System.FilePath

private def readArtifact (backend : Kalari.Backend.SandboxBackend) (name artifact : String)
    (secrets : List String := []) : ExceptT String IO String := do
  let path := guestWorkspace ++ "/" ++ artifact
  -- Test symlinks first, including dangling links. Transfer only bounded bytes.
  let command := ["/bin/sh", "-c",
    "if test -L \"$1\"; then exit 4; fi; if ! test -e \"$1\"; then exit 3; fi; if ! test -f \"$1\"; then exit 5; fi; exec head -c \"$2\" -- \"$1\"",
    "sh", path, toString (artifactCap + 1)]
  let result ← liftM (backend.exec name command)
  let r ← match result with
    | .error _ => throw s!"sandbox artifact: msb exec failed: {clip 1024 (scrub secrets (failureDetail result))}"
    | .ok r => pure r
  if r.cap == .timeout then
    throw s!"sandbox artifact: msb exec failed: {clip 1024 (scrub secrets (failureDetail result))}"
  if r.cap == .none then
    if r.exitCode == some 3 then
      throw s!"no artifact: the run wrote no {artifact} at the workspace root; the checks compare that file, so run the consumer with its output there"
    if r.exitCode == some 4 then
      throw s!"invalid artifact: {artifact} is a symlink; write a regular file at the workspace root"
    if r.exitCode == some 5 then
      throw s!"invalid artifact: {artifact} is not a regular file; write a regular file at the workspace root"
  if r.stdout.size > artifactCap then
    throw s!"invalid artifact: {artifact} exceeds the {artifactCap} byte size limit; reduce the artifact size"
  if r.cap != .none || r.exitCode != some 0 then
    throw s!"sandbox artifact: msb exec failed: {clip 1024 (scrub secrets (failureDetail result))}"
  match String.fromUTF8? r.stdout with
  | none => throw s!"invalid artifact: {artifact} is not UTF-8; write UTF-8 records"
  | some text => return text

private def execute (runtime : Runtime) (ctx : Context) (name : String) (request : RunRequest)
    (allow : List AllowHost) (artifactHost : Option String := none)
    (truthArtifactHost : Option String := none)
    (collectArtifact : Bool := true)
    (observation : Option Observation := none) : ExceptT String IO Execution := do
  -- The host deadline lets aashaan kill, collect pipes, and emit its verdict.
  -- JSON can escape each byte of both logs as six bytes.
  let backend := Microsandbox.make runtime.runner (request.caps.timeout_ms + 5000)
    (4096 + 12 * request.caps.output_cap_bytes) ctx.image
  let artifactBackend := Microsandbox.make runtime.runner 5000 (artifactCap + 1) ctx.image
  -- An observed run reaches the observer only through one fresh Lean
  -- broker. The CONNECT allow list is the run's single allowed dest; the
  -- sandbox is created with host proxy auth, keeping --no-net, explicit
  -- rules and --pull never. The password travels only by env var name.
  let broker : Option (Kalari.Sandbox.Broker.RunIdentity × Kalari.Sandbox.Broker.BrokerHandle) ←
    match observation with
    | none => pure none
    | some obs => liftM (startRunBroker runtime obs.observer obs.runId) >>= fun
      | .error e => throw e
      | .ok pair => pure (some pair)
  let proxy : Option Microsandbox.ProxyAuth := broker.map fun (id, handle) =>
    { proxy := s!"http://127.0.0.1:{handle.port}", username := id.user, passwordEnv := id.passwordEnv }
  try
    createSandbox runtime ctx name request allow proxy
  catch e =>
    liftM (stopRunBroker broker)
    throw e
  -- The observer starts only after the runtime reports a private /30 and the
  -- sandbox shows one egress rule. Any missing proof keeps it off.
  let started : Except String (Option (IO (Except String String))) ← liftM <| (try
    match observation with
    | none => pure (.ok none)
    | some obs =>
      match ← runtime.network name with
      | .error _ => pure (.error isolationMessage)
      | .ok net =>
        match verifyGuestNetwork net with
        | .error e => pure (.error e)
        | .ok () =>
          let expected := allow.find? fun host => host.port == obs.observer.endpoint.port
          match expected with
          | none => pure (.error isolationMessage)
          | some host =>
            let cidr := if host.host.contains "/" then host.host else host.host ++ "/32"
            match ← runtime.inspect name with
            | .error _ => pure (.error isolationMessage)
            | .ok raw =>
              match verifySandboxPolicy name cidr obs.observer.endpoint.port raw with
              | .error e => pure (.error e)
              | .ok () =>
                match ← obs.observer.start obs.runId obs.dir with
                | .error e => pure (.error s!"observer start: {e}")
                | .ok stop => pure (.ok (some stop))
    catch _ => pure (.error isolationMessage) :
      IO (Except String (Option (IO (Except String String)))))
  let finish ← match started with
    | .error e =>
      let removed ← runtime.runner ["msb", "remove", "-f", name] Microsandbox.controlTimeoutMs 4096
      liftM (stopRunBroker broker)
      requireStep "cleanup" (.ok removed)
      throw e
    | .ok finish => pure finish
  let outcome : Except String Execution ← liftM <| try
    let steps : ExceptT String IO Execution := do
      requireStep "workspace copy" (← liftM (backend.copyIn name request.workspace guestWorkspace))
      requireStep "supervisor copy" (← liftM (backend.copyIn name ctx.aashaanHost supervisor))
      discard <| execOk backend name "overcommit" Microsandbox.overcommitCommand
      discard <| execOk backend name "supervisor permissions" ["chmod", "755", supervisor]
      let path := guestWorkspace ++ "/" ++ ctx.artifact
      discard <| execOk backend name "clear stale artifact" ["rm", "-f", "--", path]
      if let some source := artifactHost then
        requireStep "check artifact copy" (← liftM (backend.copyIn name source path))
      if let some source := truthArtifactHost then
        requireStep "trusted truth copy" (← liftM (backend.copyIn name source
          (guestWorkspace ++ "/" ++ trustedTruthArtifactName)))
      let verdict ← supervise backend name request ctx.secrets
      let artifact : Except String String ← if !collectArtifact then pure (.error "artifact collection disabled")
        else if successful verdict then liftM (readArtifact artifactBackend name ctx.artifact ctx.secrets).run
        else pure (.error "consumer did not complete successfully")
      return { verdict, artifact }
    steps.run
  catch _ =>
    pure (.error "sandbox execution failed")
  -- Always stop the host observer, including when sandbox execution failed.
  let trace : Option (Except String String) ← match finish with
    | none => pure none
    | some stop =>
      let result ← liftM <| try stop catch _ => pure (.error "observer stop failed")
      pure (some result)
  -- A successful exec leaves the microVM running. Plain remove refuses it.
  -- The broker stays up through the run, then always stops before the
  -- sandbox is removed: sockets and dirs stay 0600/0700, and the per-run
  -- password leaves the parent env even when cleanup below fails.
  liftM (stopRunBroker broker)
  let removed ← runtime.runner ["msb", "remove", "-f", name] Microsandbox.controlTimeoutMs 4096
  requireStep "cleanup" (.ok removed)
  match outcome with
  | .ok result => return { result with trace }
  | .error e => throw e

structure Report where
  run_id : String
  verdict : Verdict
  checks : List CheckResult
  passed : Bool
  summary : String
  deriving ToJson

private def evidence (ctx : Context) (id kind : String) (payload : Json) : IO Unit :=
  Kalari.Evidence.append ctx.evidence {
    kind, session_id := ctx.sessionId, run_id := id, change_kinds := ctx.changeKinds, payload
  }

private def checkResult (id : String) (passed : Bool) (detail : Option String) : CheckResult :=
  { check_id := id, passed := passed, detail := detail }

/-- Run one trusted lesson check in a fresh guest populated only from the
host-owned check workspace and the candidate's bounded output artifact. -/
private def runOneCheck (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost) (source : System.FilePath)
    (truthSource : Option System.FilePath)
    (check : Check) : IO CheckResult := do
  let checkRequest : RunRequest := { request with
    workspace := ctx.checkWorkspace, command := check.command }
  let execution ← try
    (execute runtime ctx name checkRequest allow (some source.toString)
      (truthSource.map System.FilePath.toString) false).run
  catch _ => pure (.error "sandbox check failed")
  return match execution with
    | .error reason => checkResult check.id false (some reason)
    | .ok checked => checkResult check.id (successful checked.verdict)
        (some (summary checked.verdict))

private def runChecks (runtime : Runtime) (ctx : Context) (name : String)
    (request : RunRequest) (allow : List AllowHost) (dir : System.FilePath)
    (artifact : Except String String) (truth : Option String) : IO (List CheckResult) := do
  let mut results := []
  for (check, index) in ctx.checks.zipIdx do
    let result ← match artifact with
      | .error reason => pure (checkResult check.id false
          (some ("Not run: " ++ scrub ctx.secrets reason)))
      | .ok contents => do
        let source := dir / s!"check-{index}-artifact.jsonl"
        IO.FS.writeFile source contents
        let truthSource ← match truth with
          | none => pure none
          | some data => do
            let path := dir / "trusted-v1-truth.jsonl"
            IO.FS.writeFile path data
            pure (some path)
        runOneCheck runtime ctx (name ++ s!"-check-{index}") request allow source truthSource check
    results := results ++ [result]
  return results

private def compareRun (runtime : Runtime) (ctx : Context) (name : String)
    (allow : List AllowHost) (candidate : Execution) : IO (CheckResult × Option String) := do
  let (diff, baselineArtifact) ← match candidate.artifact with
    | .error e => pure (.error e, none)
    | .ok actual => do
      match ← (execute runtime ctx (name ++ "-v1") ctx.baseline allow).run with
      | .error e => pure (.error e, none)
      | .ok baseline =>
        let diff := do
          let old ← baseline.artifact.mapError fun e => "v1: " ++ e
          compareRecords old actual
        pure (diff, some baseline.artifact)
  let truth := match candidate.artifact with
    | .error _ => none
    | .ok _ => match baselineArtifact with
      | some (.ok data) => some data
      | _ => none
  let check := match diff with
    | .ok d => { check_id := differentialId, passed := d.passed, detail := some d.summary }
    | .error e => { check_id := differentialId, passed := false, detail := some ("Not run: " ++ scrub ctx.secrets e) }
  return (check, truth)

/-- The exact MCP argument shape is `RunRequest`. Refusals happen before any
runner, resolver, evidence append, or sandbox action. -/
def run (runtime : Runtime) (ctx : Context) (request : RunRequest) : IO (Except String Report) :=
  match admit ctx request with
  | .error e => pure (.error e)
  | .ok () => IO.FS.withTempDir fun dir => (do
    let allow ← resolveAllowlist runtime request.allowlist
    let baselineAllow ← resolveAllowlist runtime ctx.baseline.allowlist
    let runId ← freshRunId ctx.evidence runtime
    let name := Kalari.RunId.sandboxName runId
    requireStep "image pull" (← liftM (Microsandbox.ensureImage runtime.runner ctx.image 4096 runtime.wait))
    let observation : Option Observation := ctx.observer.map fun item =>
      { observer := item, runId := runId, dir := dir }
    let candidateResult ← liftM <| try
        (execute runtime ctx name request allow (observation := observation)).run
      catch _ => pure (.error "sandbox execution failed")
    let candidate ← match candidateResult with
      | .error e => throw e
      | .ok c => pure c
    let traceResult := candidate.trace
    let (diff, truth) ← compareRun runtime ctx name baselineAllow candidate
    let lessonResults ← runChecks runtime ctx name request allow dir candidate.artifact truth
    let checks := (lessonResults ++ [diff]).map fun check =>
      { check with detail := check.detail.map (clip 2048 ∘ scrub ctx.secrets) }
    let observations ← if successful candidate.verdict && checks.all (·.passed) then
      match traceResult with
      | none => pure none
      | some (.error e) => throw s!"observer: {e}"
      | some (.ok trace) =>
        match pageObservations trace with
        | .error e => throw s!"observer: {e}"
        | .ok facts => pure (some facts)
      else pure none
    let record : RunRecord := {
      request, verdict := candidate.verdict, checks := ctx.checks, check_results := checks
      timings := { wall_ms := candidate.verdict.wall_ms }
    }
    evidence ctx runId "run" (toJson record)
    for check in checks do
      evidence ctx runId "check" (toJson check)
    if let some facts := observations then
      evidence ctx runId "page-observation" (Json.mkObj [("source", Json.str "payouts-api"), ("behaviors", toJson facts)])
    return {
      run_id := runId, verdict := candidate.verdict, checks
      passed := successful candidate.verdict && checks.all (·.passed)
      summary := match candidate.artifact with
        | .ok _ => summary candidate.verdict
        | .error reason => summary candidate.verdict ++ " Verification unavailable: " ++ scrub ctx.secrets reason
    } : ExceptT String IO Report).run

/-- Adapter for the service's MCP handler once session state is wired. -/
def call (runtime : Runtime) (ctx : Context) (args : Json) : IO (Except String String) :=
  match fromJson? args with
  | .error _ => pure (.error "invalid sandbox request")
  | .ok request => return (← run runtime ctx request).mapError (fun e => clip 2048 (scrub ctx.secrets e)) |>.map (fun r => (toJson r).compress)


private def verify (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (.userError message)

private def expectOk (value : Except String α) : IO α :=
  match value with
  | .ok result => pure result
  | .error e => throw (.userError e)

/-- True when a parse failed with exactly the intended message. -/
private def expectError (value : Except String α) (message : String) : Bool :=
  match value with
  | .error actual => actual == message
  | .ok _ => false

private def row (i : Nat) : String :=
  (Json.mkObj [("id", toJson s!"P{i}"), ("amount", toJson (100 + i))]).compress ++ "\n"

/-- One trace line. Omit `status` for the pre-retry shape the parser still takes. -/
private def tracePage (request response : String) (ids : List String) (drained : Bool)
    (fingerprint : Option String := none) (retry : Option Bool := none)
    (status : Option Nat := none) : String :=
  let fields : List (String × Json) := [
    ("request", toJson request), ("response", toJson response),
    ("first", toJson (ids.headD "")), ("last", toJson (ids.getLast?.getD "")),
    ("count", toJson ids.length), ("ids", toJson ids), ("drained", toJson drained)]
  let fields := match fingerprint with | some value => ("fingerprint", toJson value) :: fields | none => fields
  let fields := match retry with | some value => ("retry", toJson value) :: fields | none => fields
  let fields := match status with | some value => ("status", toJson value) :: fields | none => fields
  (Json.mkObj fields).compress ++ "\n"

private def traceThrottle (request fingerprint : String) (retryAfter : String := "1") : String :=
  (Json.mkObj [("status", toJson (429 : Nat)), ("request", toJson request),
    ("fingerprint", toJson fingerprint), ("retry_after", toJson retryAfter)]).compress ++ "\n"

/-- One non-page event. A request that is not a served v2 page carries its status
and its incoming cursor digest, and no page. A v1 reply carries `api: "v1"`. -/
private def traceOther (status : Nat) (request : String) (api : Option String := none) : String :=
  let fields : List (String × Json) := [("status", toJson status), ("request", toJson request)]
  let fields := match api with | some value => ("api", toJson value) :: fields | none => fields
  (Json.mkObj fields).compress ++ "\n"

private def fixtureVerdict (kind : String) (code : Option Nat) (out : String := "") : Verdict :=
  { verdict := kind, exit_code := code, stdout := out, stderr := "", wall_ms := 800
    stdout_truncated := false, pipe_held_open := false, supervisor_peak_rss_kb := 5500
    cgroup_memory_limit := 0 }

private def fixtureResult (stdout : String := "") : Result :=
  { cap := .none, exitCode := some 0, stdout := stdout.toUTF8, stderr := ByteArray.empty, wallMs := 1 }

private def fixtureFailure (stderr : String) : Result :=
  { (fixtureResult "") with exitCode := some 1, stderr := stderr.toUTF8 }

private def fixtureRule (cidr : String := "203.0.113.10/32") (port : Nat := 18080)
    (protocols : List String := ["tcp"]) : Json :=
  Json.mkObj [
    ("action", toJson "allow"),
    ("direction", toJson "egress"),
    ("destination", Json.mkObj [("cidr", toJson cidr)]),
    ("protocols", toJson protocols),
    ("ports", toJson [Json.mkObj [
      ("start", toJson port),
      ("end", toJson port)]])]

private def fixtureInspect (name : String) (status : String := "Running")
    (rules : List Json := [fixtureRule]) (published : List Json := []) : String :=
  let policy : Json := Json.mkObj [
    ("default_egress", toJson "deny"),
    ("default_ingress", toJson "deny"),
    ("rules", toJson rules)]
  let network : Json := Json.mkObj [
    ("enabled", toJson true),
    ("ports", toJson published),
    ("policy", policy)]
  (Json.mkObj [
    ("name", toJson name),
    ("status", toJson status),
    ("active_config", Json.mkObj [("network", network)])]).compress

def fixtureRuntime (calls : IO.Ref (List String)) (variant : String)
    (caps : Caps) (truth duplicates : String) (tampered existsRef : IO.Ref Bool) : Runtime where
  resolve := fun host => do
    verify (host == "api.example.test") "unexpected DNS query"
    calls.modify (· ++ ["resolve"])
    return ["203.0.113.10", "203.0.113.10"]
  wait := fun _ => throw (.userError "unexpected image retry")
  network := fun _ => pure (.ok { guest := "172.16.0.6", gateway := "172.16.0.5" })
  inspect := fun name => pure (.ok (fixtureInspect name))
  startBroker := fun _ => do
    calls.modify (· ++ ["broker-start"])
    let done ← IO.asTask (pure () : IO Unit) Task.Priority.dedicated
    pure (.ok ({ port := 18081, stop := pure (), task := done } : Kalari.Sandbox.Broker.BrokerHandle))
  runner := fun argv timeout output => do
    let (stage, reply) ← match argv with
      | ["msb", "pull", image] =>
        verify (image == Microsandbox.imageName) "wrong image pull"
        pure ("pull", fixtureResult "")
      | "msb" :: "create" :: "--name" :: name :: _ => do
        verify (name.startsWith "kalari-") "sandbox name missing prefix"
        if argv.contains "--proxy" then do
          -- Observed create: loopback proxy, per-run identity by env name,
          -- --no-net, explicit rules, --pull never. The password lives in
          -- the parent env under that name and never appears in argv.
          verify (argv.contains "--no-net") "observed create omits --no-net"
          verify (argv.contains "--pull" && argv.contains "never") "observed create omits --pull never"
          verify (!(argv.any (·.contains "--net-default"))) "observed create has --net-default"
          verify (argv.any (·.contains "allow@203.0.113.10/32:tcp:18080")) "observed create allow rule missing"
          let proxy := match argv.dropWhile (· != "--proxy") with
            | _ :: url :: _ => some url
            | _ => none
          let some proxy := proxy
            | throw (.userError "observed create proxy missing")
          verify (Microsandbox.isLoopbackProxy proxy) "observed proxy not loopback"
          verify (argv.contains "--http-connect-username") "observed create proxy user missing"
          let some pwenv := Microsandbox.passwordEnvOfArgv argv
            | throw (.userError "observed create password-env missing")
          verify (pwenv.startsWith "KALARI_BROKER_PW_") "observed password env name shape"
          let pw ← IO.getEnv pwenv
          match pw with
          | none => throw (.userError "observed password not in parent env for msb child")
          | some value =>
            verify (!value.isEmpty) "observed password empty"
            verify (!(argv.any (·.contains value))) "password value in msb argv"
          verify (!(argv.any (·.contains "test-secret"))) "secret in msb argv"
          verify (argv.getLast? == some Microsandbox.imageName) "observed create image"
        else do
          verify (argv == Microsandbox.createArgv name caps.memory_mib
            [{ host := "203.0.113.10", port := 18080 }]) "create lacks restricted network, image, or memory"
        let stage := if name.contains "-check-" then "create-check"
          else if name.endsWith "-v1" then "create-v1" else "create-v2"
        if variant == "create-timeout" && stage == "create-v2" then do
          existsRef.set true
          pure (stage, { (fixtureResult "") with cap := .timeout, exitCode := none })
        else if variant == "create-duplicate" && stage == "create-v2" then do
          existsRef.set true
          pure (stage, fixtureFailure "sandbox already exists")
        else do
          existsRef.set true
          pure (stage, fixtureResult "")
      | ["msb", "copy", "-q", host, guest] => do
        let baseline := guest.contains "-v1:"
        let checking := guest.contains "-check-"
        if host == "/trusted/aashaan" then do
          verify (guest.endsWith (":" ++ supervisor)) "supervisor copy target"
          if checking && variant == "tamper" then
            verify (← tampered.get) "tampered candidate was not isolated before check"
          pure ("copy-supervisor", fixtureResult "")
        else if checking && guest.endsWith ":/workspace/payouts.jsonl" then do
          verify (host.startsWith "/tmp/") "check artifact was not staged as controlled material"
          pure ("copy-artifact", fixtureResult "")
        else if checking && guest.endsWith (":/workspace/" ++ trustedTruthArtifactName) then do
          verify (host.startsWith "/tmp/") "trusted truth was not staged as controlled material"
          verify ((← IO.FS.readFile host) == truth) "trusted check did not receive the exact v1 artifact"
          pure ("copy-truth", fixtureResult "")
        else do
          let expected := if checking then "/checks" else if baseline then "/baseline" else "/candidate"
          verify (host == expected && guest.endsWith ":/workspace") "wrong workspace copy"
          pure (if checking then "copy-check-workspace" else if baseline then "copy-baseline" else "copy-candidate",
            fixtureResult "")
      | "msb" :: "exec" :: name :: "--" :: cmd => do
        if cmd == Microsandbox.overcommitCommand then pure ("overcommit", fixtureResult "")
        else if cmd == ["chmod", "755", supervisor] then pure ("chmod", fixtureResult "")
        else if cmd == ["rm", "-f", "--", "/workspace/payouts.jsonl"] then
          pure ("clear", fixtureResult "")
        else if cmd.head? == some supervisor then do
          verify (timeout > caps.timeout_ms && output > caps.output_cap_bytes) "no supervisor transport headroom"
          verify (cmd.take 7 == [supervisor, toString caps.timeout_ms, toString caps.output_cap_bytes,
            "/bin/sh", "-c", "cd /workspace && exec \"$@\"", "sh"]) "missing supervisor invocation"
          let script ← match cmd.drop 7 with
            | ["/usr/local/bin/python3", script] => pure script
            | _ => throw (.userError "unexpected consumer argv")
          let verdict ←
            if name.contains "-check-" then do
              verify (script == "lesson.py") "check did not use the trusted check command"
              pure (fixtureVerdict "exited" (some (if ["correct", "tamper", "lesson_only"].contains variant then 0 else 1)))
            else if name.endsWith "-v1" then do
              verify (script == "/workspace/v1_unchanged.py") "wrong baseline consumer"
              pure (fixtureVerdict "exited" (some 0))
            else do
              verify (script == s!"/workspace/{variant}.py") "wrong candidate consumer"
              if variant == "tamper" then tampered.set true
              pure <| if variant == "cursor_loop" then fixtureVerdict "killed_timeout" none
                else if variant == "v1_unchanged" then fixtureVerdict "exited" (some 1)
                else fixtureVerdict "exited" (some 0) "synced payouts"
          pure (if name.contains "-check-" then "lesson" else if name.endsWith "-v1" then "baseline-consumer" else "consumer",
            fixtureResult (toJson verdict).compress)
        else if cmd.take 2 == ["/bin/sh", "-c"] &&
            cmd.drop 3 == ["sh", "/workspace/payouts.jsonl", toString (artifactCap + 1)] then do
          verify (output == artifactCap + 1) "artifact transfer is unbounded"
          let data := if name.endsWith "-v1" then truth
            else if variant == "no_dedupe" then truth ++ duplicates
            else if ["single_page", "short_page_stop", "lesson_only"].contains variant then
              String.join ((List.range 100).map row)
            else truth
          let result := match variant with
            | "missing_artifact" => { fixtureResult "" with exitCode := some 3 }
            | "symlink_artifact" => { fixtureResult "" with exitCode := some 4 }
            | "backend_artifact" => { fixtureResult "" with exitCode := some 17, stderr := "test-secret".toUTF8 }
            | _ => fixtureResult data
          pure ("artifact", result)
        else throw (.userError "unexpected exec")
      | ["msb", "remove", "-f", name] => do
        let cleanup := variant == "create-timeout" && !name.contains "-check-" && !name.endsWith "-v1"
        if cleanup then verify (← existsRef.get) "ambiguous create did not leave a sandbox to clean"
        else verify (← existsRef.get) "removed sandbox was not created"
        existsRef.set false
        pure (if cleanup then "create-cleanup" else if name.contains "-check-" then "remove-check"
          else if name.endsWith "-v1" then "remove-v1" else "remove-v2", fixtureResult "")
      | _ => throw (.userError "unexpected msb command")
    calls.modify (· ++ [stage])
    return reply

private def exercise : IO Unit := IO.FS.withTempDir fun dir => do
  let store ← Kalari.Evidence.openStore dir
  let caps : Caps := { timeout_ms := 800, output_cap_bytes := 64, memory_mib := 256 }
  let allow : List AllowHost := [{ host := "api.example.test", port := 18080 }]
  let req : RunRequest := { workspace := "/candidate", command := [], caps, allowlist := allow }
  let ctx : Context := {
    workspace := req.workspace
    baseline := { req with workspace := "/baseline", command := ["python3", "/baseline/v1_unchanged.py"] }
    checkWorkspace := "/checks"
    artifact := "payouts.jsonl"
    checks := [{ id := "exactly-once", assertion := "Each ID appears once", command := ["python3", "lesson.py"] }]
    maxCaps := caps, allowedNet := allow, secrets := ["test-secret"], aashaanHost := "/trusted/aashaan"
    evidence := store, sessionId := "test-session", changeKinds := ["pagination_changed"]
  }
  let truth := String.join ((List.range 2431).map row)
  let duplicateRows := String.join ((List.range 24).map fun i => row ((i + 1) * 99))
  for variant in ["cursor_loop", "no_dedupe", "correct", "single_page", "short_page_stop", "v1_unchanged", "tamper", "missing_artifact", "symlink_artifact", "backend_artifact"] do
    let calls ← IO.mkRef []
    let tampered ← IO.mkRef false
    let existsRef ← IO.mkRef false
    let runtime := fixtureRuntime calls variant caps truth duplicateRows tampered existsRef
    let request := { req with command := ["python3", s!"/candidate/{variant}.py"] }
    let text ← expectOk (← call runtime ctx (toJson request))
    verify (!text.contains "test-secret") "secret in report"
    let payload ← expectOk (Json.parse text)
    let id ← expectOk (payload.getObjValAs? String "run_id")
    verify (Kalari.RunId.isRunId id) "run ID is not a purposeful run- ID"
    verify ((Kalari.RunId.sandboxName id).startsWith "kalari-run-" &&
      (Kalari.RunId.sandboxName id).length <= 64) "sandbox name out of msb shape"
    let verdict ← expectOk (payload.getObjValAs? Verdict "verdict")
    let checks ← expectOk (payload.getObjValAs? (List CheckResult) "checks")
    let passed ← expectOk (payload.getObjValAs? Bool "passed")
    let current ← calls.get
    let setup := ["copy-candidate", "copy-supervisor", "overcommit", "chmod", "clear", "consumer"]
    let checkSetup := ["create-check", "copy-check-workspace", "copy-supervisor", "overcommit", "chmod", "clear", "copy-artifact", "copy-truth", "lesson", "remove-check"]
    let first := ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["artifact", "remove-v2"]
    let [lesson, diff] := checks | throw (.userError "expected both checks")
    verify (lesson.check_id == "exactly-once" && diff.check_id == differentialId) "wrong check IDs"
    if variant == "cursor_loop" then
      verify (verdict.verdict == "killed_timeout" && !passed && !lesson.passed && !diff.passed) "cursor_loop outcome"
      verify (current == ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["remove-v2"])
        "timeout ran checks, retrieved artifact, or leaked sandbox"
      let message ← expectOk (payload.getObjValAs? String "summary")
      verify (message.startsWith "The aashaan killed the run when it reached the time cap.") "timeout message"
    else if ["missing_artifact", "symlink_artifact", "backend_artifact"].contains variant then do
      verify (verdict.exit_code == some 0 && !passed && !lesson.passed && !diff.passed) "artifact failure verdict"
      verify (current == first) "artifact failure ran checks or leaked sandbox"
      let message ← expectOk (payload.getObjValAs? String "summary")
      let expected := if variant == "missing_artifact" then "no artifact:" else if variant == "symlink_artifact" then "is a symlink" else "msb exec failed"
      verify (message.contains expected && message.contains "payouts.jsonl" == (variant != "backend_artifact")) "artifact summary"
    else if variant == "v1_unchanged" then do
      verify (verdict.verdict == "exited" && verdict.exit_code == some 1 && !passed &&
        !lesson.passed && !diff.passed) "unchanged v1 consumer outcome"
      verify (current == ["resolve", "resolve", "pull", "create-v2"] ++ setup ++ ["remove-v2"])
        "failed v1 consumer ran checks or leaked sandbox"
    else do
      let expected := variant == "correct" || variant == "tamper"
      verify (verdict.verdict == "exited" && verdict.exit_code == some 0) "consumer did not exit successfully"
      verify (passed == expected && lesson.passed == expected && diff.passed == expected) "wrong checks verdict"
      let missingCount := if ["single_page", "short_page_stop"].contains variant then 2331 else 0
      let duplicateCount := if variant == "no_dedupe" then 24 else 0
      verify (diff.detail == some s!"{missingCount} missing, 0 extra, {duplicateCount} duplicates, 0 changed")
        s!"wrong differential counts for {variant}: {diff.detail.getD "none"}"
      verify (current == first ++ ["create-v1", "copy-baseline", "copy-supervisor",
        "overcommit", "chmod", "clear", "baseline-consumer", "artifact", "remove-v1"] ++ checkSetup)
        "incorrect isolated-check/baseline lifecycle"
      if variant == "tamper" then do
        verify (← tampered.get) "tamper candidate did not run"

    let records := Kalari.Evidence.byRun (← Kalari.Evidence.load store) id
    verify (records.map (·.kind) == ["run", "check", "check"]) "run/check evidence missing"
    IO.println s!"run {variant}: {verdict.verdict}, passed={passed}, {diff.detail.getD ""}"
  let calls ← IO.mkRef []
  let tampered ← IO.mkRef false
  let existsRef ← IO.mkRef false
  let aliasedChecks := { ctx with checkWorkspace := ctx.workspace }
  let badCheckRoot ← run (fixtureRuntime calls "correct" caps truth truth tampered existsRef) aliasedChecks
    { req with command := ["python3", "correct.py"] }
  verify ((badCheckRoot matches .error "setup: checks require a separate trusted workspace") &&
    (← calls.get).isEmpty) "check workspace alias reached runtime"
  let badTruthName := { ctx with artifact := trustedTruthArtifactName }
  let collision ← run (fixtureRuntime calls "correct" caps truth truth tampered existsRef) badTruthName
    { req with command := ["python3", "correct.py"] }
  verify ((collision matches .error "setup: candidate artifact name is reserved for trusted v1 truth") &&
    (← calls.get).isEmpty) "reserved truth artifact collision reached runtime"
  let denied := { req with command := ["python3", "correct.py"], allowlist := [{ host := "other.test", port := 18080 }] }
  let beforeRefusal := (← Kalari.Evidence.load store).records.length
  let rejected ← run (fixtureRuntime calls "correct" caps truth truth tampered existsRef) ctx denied
  verify ((rejected matches .error "refused: allowlist") && (← calls.get).isEmpty) "refusal reached runtime"
  verify ((← Kalari.Evidence.load store).records.length == beforeRefusal) "refusal wrote evidence"
  IO.println "run refused: allowlist, runner and resolver calls=0, no evidence appended"
  for variant in ["create-timeout", "create-duplicate"] do
    let createCalls ← IO.mkRef []
    let changed ← IO.mkRef false
    let existingRef ← IO.mkRef false
    let failed ← run (fixtureRuntime createCalls variant caps truth truth changed existingRef) ctx
      { req with command := ["python3", "correct.py"] }
    let actualCalls ← createCalls.get
    if variant == "create-timeout" then do
      verify ((failed matches .error "sandbox create failed") && !(← existingRef.get))
        "timed-out create was not force-cleaned"
      verify (actualCalls == ["resolve", "resolve", "pull", "create-v2", "create-cleanup"])
        "ambiguous create cleanup sequence"
    else do
      verify ((failed matches .error "sandbox create: name already exists; left untouched") && (← existingRef.get))
        "known duplicate sandbox was removed or misreported"
      verify (actualCalls == ["resolve", "resolve", "pull", "create-v2"])
        "duplicate-name failure attempted cleanup"
  IO.println "run create-timeout: force cleanup; duplicate name: preserved"
  let fingerprint := "00000000000000000000000000000001"
  let otherFingerprint := "00000000000000000000000000000002"
  let cursor1 := "11111111111111111111111111111111"
  let cursor2 := "22222222222222222222222222222222"
  let cursor3 := "33333333333333333333333333333333"
  let head := tracePage "" cursor1 ["1", "2"] false
  let tail := tracePage cursor1 cursor2 ["2", "3"] true
  let retryTail := tracePage cursor1 cursor2 ["2", "3"] true (some fingerprint) (some true) (some 200)
  let throttle := traceThrottle cursor1 fingerprint
  -- Old-shape lines, as a B5-off trace wrote them before the page fields were added.
  let oldShape := head ++ tail
  verify ((pageObservations oldShape).toOption == some ["boundary_overlap_one", "final_page_token"])
    "old-shape trace rejected"
  -- The B5-off trace now carries the page fields. It parses to the old facts.
  let b5Off := tracePage "" cursor1 ["1", "2"] false (some fingerprint) (some false) (some 200) ++
    tracePage cursor1 cursor2 ["2", "3"] true (some fingerprint) (some false) (some 200)
  verify ((pageObservations b5Off).toOption == some ["boundary_overlap_one", "final_page_token"])
    "B5-off trace did not keep the old facts"
  -- The page cap is the server's 100. A longer page is not a trusted shape.
  let overCapIds := (List.range 101).map fun i => s!"P{i}"
  verify (expectError (pageObservations (head ++ tracePage cursor1 cursor2 overCapIds true))
    "page exceeds the trusted page cap") "page over the trusted cap accepted"
  -- Request and response fields are digests, never raw cursors.
  verify (expectError (pageObservations (head ++ tracePage "a" cursor2 ["2", "3"] true))
    "trace request is not a digest") "raw cursor request accepted"
  verify (expectError (pageObservations (head ++ tracePage cursor1 "b" ["2", "3"] true))
    "trace response is not a digest") "raw cursor response accepted"
  let retryTrace := head ++ throttle ++ retryTail
  verify ((pageObservations retryTrace).toOption ==
    some ["boundary_overlap_one", "final_page_token", "rate_limit_retry"]) "valid retry trace rejected"
  verify ((pageObservations "").isOk == false) "missing trace accepted"
  verify ((pageObservations (oldShape.replace "\"drained\":true" "\"drained\":false")).isOk == false) "unterminated chain accepted"
  verify ((pageObservations (oldShape.toSlice.dropEnd 1).toString).isOk == false) "truncated trace accepted"
  verify ((pageObservations (oldShape.replace s!"\"request\":\"{cursor1}\"" s!"\"request\":\"{cursor3}\"")).isOk == false) "ambiguous trace accepted"
  -- A 400 between the 429 and the retry must fail closed, not vanish from the trace.
  verify (expectError (pageObservations (head ++ throttle ++ traceOther 400 "" ++ retryTail))
    "unexpected trace status") "a 400 between the 429 and the retry was accepted"
  -- A reset reply still leaves its event, and every other status fails closed.
  verify (expectError (pageObservations (head ++ throttle ++ traceOther 501 "" ++ retryTail))
    "unexpected trace status") "a 501 between the 429 and the retry was accepted"
  -- A v1 response is marked and rejected, not read as a v2 page.
  verify (expectError (pageObservations (head ++ traceOther 200 "" (some "v1")))
    "traced v1 response is not a v2 page") "traced v1 200 read as a page"
  verify (expectError (pageObservations (head ++ traceOther 200 "" (some "other")))
    "unexpected trace api marker") "unknown trace api marker accepted"
  -- A present fingerprint is a digest on every event, not only on the 429.
  verify (expectError (pageObservations (head ++
    tracePage cursor1 cursor2 ["2", "3"] true (some "garbage") (some false) (some 200)))
    "trace request fingerprint is not a digest") "garbage page fingerprint accepted"
  let mismatched := head ++ throttle ++ tracePage cursor1 cursor2 ["2", "3"] true (some otherFingerprint) (some true) (some 200)
  verify ((pageObservations mismatched).isOk == false) "mismatched retry fingerprint accepted"
  verify ((pageObservations (head ++ throttle ++ tail)).isOk == false) "throttled request without a retry accepted"
  verify ((pageObservations (head ++ throttle ++
    tracePage cursor1 cursor2 ["2", "3"] true (some fingerprint) (some false) (some 200))).isOk == false)
    "retry without the retry flag accepted"
  verify ((pageObservations (head ++ tracePage cursor1 cursor2 ["2", "3"] true (some fingerprint) (some true) (some 200))).isOk == false)
    "retry flag without a throttled request accepted"
  let throttledWithPage := head ++ tracePage cursor1 cursor2 ["2", "3"] true (some fingerprint) (some false) (some 429) ++ retryTail
  verify ((pageObservations throttledWithPage).isOk == false) "throttled event with a page accepted"
  let midRetry := head ++ throttle ++ tracePage cursor1 cursor2 ["2", "3"] false (some fingerprint) (some true) (some 200)
  let twoThrottles := midRetry ++ traceThrottle cursor2 fingerprint ++
    tracePage cursor2 cursor3 ["3", "4"] true (some fingerprint) (some true) (some 200)
  verify ((pageObservations twoThrottles).isOk == false) "two throttled requests accepted"
  verify ((pageObservations (head ++ traceThrottle cursor3 fingerprint ++ retryTail)).isOk == false)
    "orphaned throttled request accepted"
  -- The retry must repeat the throttled request digest. The 429 must repeat the
  -- previous page's response digest.
  verify (expectError (pageObservations (head ++ throttle ++
    tracePage cursor3 cursor2 ["2", "3"] true (some fingerprint) (some true) (some 200)))
    "throttled request was not followed by the identical retry")
    "retry cursor differs from the throttled request"
  verify (expectError (pageObservations (head ++ traceThrottle cursor3 fingerprint ++
    tracePage cursor3 cursor2 ["2", "3"] true (some fingerprint) (some true) (some 200)))
    "orphaned throttled request") "throttled cursor differs from the previous response"
  verify (expectError (pageObservations (head ++ throttle))
    "trace ends with an unanswered throttled request") "429 at the end accepted"
  verify (expectError (pageObservations (head ++ tracePage cursor1 cursor1 ["2", "3"] true))
    "invalid page IDs") "repeated response cursor accepted"
  let drainedBranch := head ++ tracePage cursor1 cursor2 ["2", "3"] true ++ tracePage cursor1 cursor3 ["2", "4"] true
  verify ((pageObservations drainedBranch).isOk == false) "branched chain accepted"
  let liveBranch := head ++ tracePage cursor1 cursor2 ["2", "3"] false ++ tracePage cursor1 cursor3 ["2", "4"] false
  verify (expectError (pageObservations liveBranch) "ambiguous or incomplete page trace")
    "non-drained branch accepted"
  verify ((pageObservations midRetry).isOk == false) "unterminated retry chain accepted"
  IO.println "run trace: old-shape and B5-off traces keep the old facts; the parser rejects raw cursors, over-cap pages, the intervening 400 and every broken chain"
  let stopped ← IO.mkRef false
  let observer : Observer := { endpoint := allow.headD {host := "", port := 0}, start := fun _ _ => pure (.ok (do stopped.set true; pure (.ok retryTrace))) }
  let observed := { ctx with observer := some observer }
  let mismatch ← run (fixtureRuntime calls "correct" caps truth duplicateRows tampered existsRef) observed { req with command := ["python3", "/candidate/correct.py"], allowlist := [] }
  verify (mismatch matches .error "setup: observer endpoint must be the sole candidate allowlist entry") "unrelated endpoint was accepted"
  let obsCalls ← IO.mkRef []
  let obsTamper ← IO.mkRef false
  let obsExists ← IO.mkRef false
  let result ← expectOk (← run (fixtureRuntime obsCalls "correct" caps truth duplicateRows obsTamper obsExists) observed { req with command := ["python3", "/candidate/correct.py"] })
  let obsRecords := Kalari.Evidence.byRun (← Kalari.Evidence.load store) result.run_id
  verify (result.passed && (← stopped.get) && obsRecords.any (fun r => r.kind == "page-observation" && (r.payload.getObjValAs? (List String) "behaviors").toOption == some ["boundary_overlap_one", "final_page_token", "rate_limit_retry"])) "verified retry observation not linked to run"
  -- The observed create went through the broker: proxy argv, per-run
  -- identity by env name, password in the msb child env but never argv.
  verify ((← obsCalls.get).contains "broker-start") "observed run did not start a broker"
  let tag := String.ofList (result.run_id.toList.filter (·.isAlphanum))
  let tag := if tag.isEmpty then "run" else tag
  verify ((← IO.getEnv s!"KALARI_BROKER_PW_{tag}") == none) "broker password left in parent env"
  stopped.set false
  let failedRun ← expectOk (← run (fixtureRuntime obsCalls "no_dedupe" caps truth duplicateRows obsTamper obsExists) observed { req with command := ["python3", "/candidate/no_dedupe.py"] })
  let failedRecords := Kalari.Evidence.byRun (← Kalari.Evidence.load store) failedRun.run_id
  verify (!failedRun.passed && (← stopped.get) && !(failedRecords.any (fun r => r.kind == "page-observation"))) "failed differential emitted a retry observation or observer leaked"
  -- The differential must hold at the emission point even when every lesson
  -- check passes. Only the `checks` list carries the differential.
  stopped.set false
  let lessonRun ← expectOk (← run (fixtureRuntime obsCalls "lesson_only" caps truth duplicateRows obsTamper obsExists) observed { req with command := ["python3", "/candidate/lesson_only.py"] })
  let lessonRecords := Kalari.Evidence.byRun (← Kalari.Evidence.load store) lessonRun.run_id
  let lessonCheck := lessonRun.checks.find? (·.check_id == "exactly-once")
  let lessonDiff := lessonRun.checks.find? (·.check_id == differentialId)
  verify (lessonCheck.map (·.passed) == some true && lessonDiff.map (·.passed) == some false && !lessonRun.passed)
    "lesson_only fixture did not pass its lesson check and fail the differential"
  verify ((← stopped.get) && !(lessonRecords.any (fun r => r.kind == "page-observation")))
    "a run whose lesson check passed but whose differential failed emitted an observation"
  IO.println "run observer: a passing lesson check with a failed differential emitted no observation"
  let badObserver : Observer := { endpoint := allow.headD {host := "", port := 0}, start := fun _ _ => pure (.ok (pure (.ok mismatched))) }
  let beforeBad := (← Kalari.Evidence.load store).records.length
  let badTraceRun ← run (fixtureRuntime obsCalls "correct" caps truth duplicateRows obsTamper obsExists) { ctx with observer := some badObserver } { req with command := ["python3", "/candidate/correct.py"] }
  verify (badTraceRun.isOk == false && (← Kalari.Evidence.load store).records.length == beforeBad) "mismatched retry fingerprint emitted evidence"
  let invalid : Observer := { endpoint := allow.headD {host := "", port := 0}, start := fun _ _ => pure (.ok (pure (.ok "bad"))) }
  let rejectedTrace ← run (fixtureRuntime obsCalls "correct" caps truth duplicateRows obsTamper obsExists) { ctx with observer := some invalid } { req with command := ["python3", "/candidate/correct.py"] }
  verify (rejectedTrace.isOk == false) "invalid observed run accepted"
  -- A runtime that cannot report the guest network, or reports a network that
  -- is not one dedicated /30, must leave the observer off and the run failed.
  let beforeUnknown := (← Kalari.Evidence.load store).records.length
  let noNetworkCalls ← IO.mkRef []
  let noNetwork : Runtime := {
    (fixtureRuntime noNetworkCalls "correct" caps truth duplicateRows obsTamper obsExists) with
    network := fun _ => pure (.error "unavailable") }
  let noNetworkRun ← run noNetwork observed { req with command := ["python3", "/candidate/correct.py"] }
  verify (match noNetworkRun with | .error e => e == isolationMessage | .ok _ => false)
    "runtime without a guest network did not fail closed"
  verify ((← noNetworkCalls.get) == ["resolve", "resolve", "pull", "broker-start", "create-v2", "remove-v2"])
    "unproven observer ran the guest or leaked its sandbox"
  let badNetworkCalls ← IO.mkRef []
  let badNetwork : Runtime := {
    (fixtureRuntime badNetworkCalls "correct" caps truth duplicateRows obsTamper obsExists) with
    network := fun _ => pure (.ok { guest := "172.16.0.10", gateway := "172.16.0.5" }) }
  let badNetworkRun ← run badNetwork observed { req with command := ["python3", "/candidate/correct.py"] }
  verify (match badNetworkRun with | .error e => e == isolationMessage | .ok _ => false)
    "two different /30 addresses were accepted as one guest network"
  let badPolicyCalls ← IO.mkRef []
  let badPolicy : Runtime := {
    (fixtureRuntime badPolicyCalls "correct" caps truth duplicateRows obsTamper obsExists) with
    inspect := fun _ => pure (.ok "{}") }
  let badPolicyRun ← run badPolicy observed { req with command := ["python3", "/candidate/correct.py"] }
  verify (match badPolicyRun with | .error e => e == isolationMessage | .ok _ => false)
    "sandbox without a verifiable policy was accepted"
  let crafted (label : String) (inspect : String → String) : IO Unit := do
    let craftedCalls ← IO.mkRef []
    let craftedRuntime : Runtime := {
      (fixtureRuntime craftedCalls "correct" caps truth duplicateRows obsTamper obsExists) with
      inspect := fun name => pure (.ok (inspect name)) }
    stopped.set false
    let craftedRun ← run craftedRuntime observed { req with command := ["python3", "/candidate/correct.py"] }
    verify (match craftedRun with | .error e => e == isolationMessage | .ok _ => false)
      s!"crafted inspect case {label} was accepted"
    verify ((← craftedCalls.get) == ["resolve", "resolve", "pull", "broker-start", "create-v2", "remove-v2"])
      s!"crafted inspect case {label} ran the guest or leaked its sandbox"
    verify (!(← stopped.get)) s!"crafted inspect case {label} started the observer"
  crafted "second egress rule" fun name => fixtureInspect name (rules := [fixtureRule, fixtureRule])
  crafted "published port" fun name => fixtureInspect name
    (published := [Json.mkObj [("host", toJson (8080 : Nat)), ("guest", toJson (80 : Nat))]])
  crafted "stopped sandbox" fun name => fixtureInspect name (status := "Stopped")
  crafted "empty protocol list" fun name => fixtureInspect name (rules := [fixtureRule (protocols := [])])
  crafted "non-tcp protocol" fun name => fixtureInspect name (rules := [fixtureRule (protocols := ["udp"])])
  verify ((← Kalari.Evidence.load store).records.length == beforeUnknown)
    "an unproven observer appended evidence"
  IO.println "run observer: linked retry trace accepted; mismatched fingerprint, failed differential, passing lesson check with a failed differential, malformed trace, and unproven guest isolation rejected"
  IO.println "run inspect: a second rule, a published port, a stopped sandbox and an empty or non-tcp protocol list all fail closed"
  let goodCheck : Check := { id := "candidate-v1-truth-v1", assertion := "candidate matches trusted v1", command := ["python3", "kalari_candidate_truth_check.py", "payouts.jsonl", trustedTruthArtifactName] }
  let badCheck := { goodCheck with command := ["python3", "kalari_candidate_truth_check.py", "other.jsonl", trustedTruthArtifactName] }
  let wrongId := { goodCheck with id := "other-check" }
  let wrongProgram := { goodCheck with command := ["python3", "other.py", "payouts.jsonl", trustedTruthArtifactName] }
  let baseRecord : RunRecord := { request := req, verdict := fixtureVerdict "exited" (some 0), checks := [goodCheck], check_results := [], timings := { wall_ms := 0 } }
  verify ((verifyCandidateTruthArtifact baseRecord "payouts.jsonl").isOk)
    "the trusted artifact check was rejected"
  verify (!((verifyCandidateTruthArtifact { baseRecord with checks := [badCheck] } "payouts.jsonl").isOk))
    "a candidate truth check for another artifact was accepted"
  verify (!((verifyCandidateTruthArtifact { baseRecord with checks := [wrongId] } "payouts.jsonl").isOk))
    "a check with another ID was accepted as the candidate truth check"
  verify (!((verifyCandidateTruthArtifact { baseRecord with checks := [wrongProgram] } "payouts.jsonl").isOk))
    "a check with another program was accepted as the candidate truth check"
  verify (!((verifyCandidateTruthArtifact { baseRecord with checks := [] } "payouts.jsonl").isOk))
    "a run without a candidate truth check was accepted"
  IO.println "run artifact: the candidate truth check must have its ID, program and trusted artifact"
  -- Purposeful IDs: format, evidence collision retry, sandbox-name collision
  -- retry, and exhaustion failing closed. Old temp-dir IDs still resolve.
  let idStore ← Kalari.Evidence.openStore (dir / "runid")
  Kalari.Evidence.append idStore ({ kind := "run", session_id := "s", run_id := "run-0000000000", change_kinds := ["pagination_changed"], payload := toJson baseRecord } : Kalari.Evidence.Record)
  Kalari.Evidence.append idStore ({ kind := "run", session_id := "s", run_id := "tmp.XXh51tnj", change_kinds := ["pagination_changed"], payload := toJson baseRecord } : Kalari.Evidence.Record)
  let idCalls ← IO.mkRef []
  let idTamper ← IO.mkRef false
  let idExists ← IO.mkRef false
  let idBase := fixtureRuntime idCalls "correct" caps truth truth idTamper idExists
  -- Evidence hit, then a live sandbox name hit, then a free ID.
  let clashRuntime : Runtime := { idBase with
    runner := fun argv timeout output =>
      match argv with
      | ["msb", "list", "--format", "json"] => pure (({ cap := .none, exitCode := some 0, stdout := ("[{\"name\":\"kalari-run-1111111111\",\"image\":\"i\",\"status\":\"Running\",\"created_at\":\"t\"}]").toUTF8, stderr := ByteArray.empty, wallMs := 0 } : Kalari.Proc.Result))
      | _ => idBase.runner argv timeout output }
  let draws ← IO.mkRef (["run-0000000000", "run-1111111111", "run-2222222222"] : List String)
  let draw : IO String := do
    match ← draws.get with
    | [] => return "run-3333333333"
    | head :: tail => draws.set tail; return head
  let retried ← expectOk (← (freshRunIdWith idStore clashRuntime draw).run)
  verify (retried == "run-2222222222") "fresh ID did not skip evidence and sandbox collisions"
  -- Exhaustion fails closed with a clear error.
  match ← (freshRunIdWith idStore clashRuntime (pure "run-0000000000")).run with
  | .error e => verify (e.contains "run ID collision") "exhaustion did not fail closed"
  | .ok _ => throw (.userError "exhaustion produced an ID")
  let oldFound := Kalari.Evidence.byRun (← Kalari.Evidence.load idStore) "tmp.XXh51tnj"
  verify (oldFound.length == 1) "old tmp. run ID no longer resolves"
  IO.println "run runid: format, evidence retry, sandbox-name check, old tmp. resolves"

#guard (compareRecords
  "{\"id\":\"A\",\"amount\":2}\n{\"id\":\"B\",\"amount\":4}\n"
  "{\"id\":\"A\",\"amount\":1}\n{\"id\":\"C\",\"amount\":5}\n").toOption ==
  some ⟨1, 1, 0, 1⟩

#guard (compareRecords "{\"id\":\"A\",\"amount\":2}\n" "{\"amount\":2,\"id\":\"A\"}\n").toOption ==
  some ⟨0, 0, 0, 0⟩

#eval exercise

private def freePort : IO Nat := do
  let result ← IO.Process.output { cmd := "python3", args := #["-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"] }
  let some port := result.stdout.trimAscii.toString.toNat? | throw <| .userError "no test port"
  return port

/-- A driver that resets the connection on a 400 and a 501 between the 429 and
the identical retry. The server sees both requests, and the reply write fails. -/
private def resetDriver : String := String.intercalate "\n" [
  "import http.client, json, socket, struct, sys, time",
  "port = int(sys.argv[1])",
  "conn = http.client.HTTPConnection(\"127.0.0.1\", port, timeout=10)",
  "def get(path):",
  "    conn.request(\"GET\", path)",
  "    r = conn.getresponse()",
  "    return r.status, json.loads(r.read() or b\"{}\")",
  "status, body = get(\"/v2/payouts?limit=1000\")",
  "assert status == 200, status",
  "cursor = body[\"cursor\"]",
  "while True:",
  "    status, body = get(f\"/v2/payouts?limit=1000&cursor={cursor}\")",
  "    if status == 429:",
  "        break",
  "    assert status == 200, status",
  "    cursor = body[\"cursor\"]",
  "def reset(method, path):",
  "    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)",
  "    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack(\"ii\", 1, 0))",
  "    s.settimeout(2)",
  "    s.connect((\"127.0.0.1\", port))",
  "    s.sendall(f\"{method} {path} HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n\".encode())",
  "    s.close()",
  "    time.sleep(0.1)",
  "reset(\"GET\", \"/v2/payouts?limit=0\")",
  "reset(\"POST\", \"/v2/payouts?limit=1000\")",
  "status, body = get(f\"/v2/payouts?limit=1000&cursor={cursor}\")",
  "assert status == 200, status",
  "while not body[\"drained\"]:",
  "    status, body = get(f\"/v2/payouts?limit=1000&cursor={body['cursor']}\")",
  "    assert status == 200, status"
]

/-- A driver that forces `traced_reply` and `send_error` to raise on the reply,
then checks that the trace still holds the 400 and 501 events. -/
private def resetHandlerDriver : String := String.intercalate "\n" [
  "import importlib.util, sys",
  "spec = importlib.util.spec_from_file_location(\"payouts_server\", sys.argv[1])",
  "server = importlib.util.module_from_spec(spec)",
  "spec.loader.exec_module(server)",
  "server.TRACE = open(sys.argv[2], \"w\")",
  "server.Handler.trace_client = \"127.0.0.1\"",
  "handler = object.__new__(server.Handler)",
  "handler.client_address = (\"127.0.0.1\", 1234)",
  "handler.command = \"GET\"",
  "handler.path = \"/v2/payouts?limit=0\"",
  "handler.request_version = \"HTTP/1.1\"",
  "handler.close_connection = False",
  "handler._headers_buffer = []",
  "class Failing:",
  "    def write(self, data):",
  "        raise ConnectionResetError(104, \"reset\")",
  "handler.wfile = Failing()",
  "def failing_reply(status, obj):",
  "    raise ConnectionResetError(104, \"reset\")",
  "handler.reply = failing_reply",
  "try:",
  "    handler.traced_reply(400, {\"error\": \"invalid_limit\"}, \"\")",
  "except ConnectionResetError:",
  "    pass",
  "handler.command = \"POST\"",
  "handler.requestline = \"POST /v2/payouts HTTP/1.1\"",
  "try:",
  "    handler.send_error(501, \"Unsupported method\")",
  "except ConnectionResetError:",
  "    pass",
  "server.TRACE.close()"
]

private def realObserver : IO Unit := IO.FS.withTempDir fun dir => do
  let port ← freePort
  let observer := payoutsObserver "bench/apis/payouts/server.py" { host := "127.0.0.1", port } "127.0.0.1" "127.0.0.1"
  let stop ← expectOk (← observer.start "real-payouts" dir)
  let denied ← IO.Process.output { cmd := "python3", args := #["-c", "import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1])), source_address=('127.0.0.2',0)); s.sendall(b'GET /v2/payouts HTTP/1.0\\r\\n\\r\\n'); assert b' 403 ' in s.recv(128)", toString port] }
  unless denied.exitCode == 0 do
    discard stop
    throw <| .userError "observer accepted another source address"
  let run ← IO.Process.output { cmd := "python3", args := #["-I", "bench/apis/payouts/reference/correct.py", "--base-url", s!"http://127.0.0.1:{port}", "--out", (dir / "payouts.jsonl").toString] }
  let result ← stop
  let trace ← expectOk result
  unless run.exitCode == 0 &&
      (pageObservations trace).toOption == some ["boundary_overlap_one", "final_page_token", "rate_limit_retry"] do
    throw <| .userError "real observer did not capture the reference run and its retry"
  unless trace.contains "\"status\":429" && trace.contains "\"retry\":true" do
    throw <| .userError "real observer trace has no 429 and matching retry"
  let grade ← IO.Process.output { cmd := "python3", args := #["-I", "bench/graders/grade.py", "payouts", (dir / "payouts.jsonl").toString] }
  unless grade.exitCode == 0 && grade.stdout.contains "\"verdict\": \"PASS\"" do throw <| .userError "observed reference did not pass grader"
  IO.println "observer actual B5 server, reference consumer and grader: PASS with a verified retry trace"

  -- A real B5-off server. The page events carry the new fields, and the same
  -- Lean parser must keep the old facts.
  let offPort ← freePort
  let offDir := dir / "b5off"
  IO.FS.createDirAll offDir
  let offObserver := payoutsObserver "bench/apis/payouts/server.py" { host := "127.0.0.1", port := offPort } "127.0.0.1" "127.0.0.1" (some "B1,B2,B4")
  let offStop ← expectOk (← offObserver.start "real-payouts-b5off" offDir)
  let offRun ← IO.Process.output { cmd := "python3", args := #["-I", "bench/apis/payouts/reference/correct.py", "--base-url", s!"http://127.0.0.1:{offPort}", "--out", (dir / "payouts-b5off.jsonl").toString] }
  let offTrace ← expectOk (← offStop)
  unless offRun.exitCode == 0 &&
      (pageObservations offTrace).toOption == some ["boundary_overlap_one", "final_page_token"] do
    throw <| .userError "real B5-off trace did not keep the old facts"
  unless !offTrace.contains "\"status\":429" do
    throw <| .userError "real B5-off trace throttled a request"
  IO.println "observer real B5-off: the parsed trace keeps the old facts"

  -- A client reset on a 400 and a 501 between the 429 and the retry. The events
  -- must survive the failed reply, and the parser must reject the trace.
  let resetPort ← freePort
  let resetDir := dir / "reset"
  IO.FS.createDirAll resetDir
  let resetObserver := payoutsObserver "bench/apis/payouts/server.py" { host := "127.0.0.1", port := resetPort } "127.0.0.1" "127.0.0.1"
  let resetStop ← expectOk (← resetObserver.start "real-payouts-reset" resetDir)
  IO.FS.writeFile (dir / "reset.py") resetDriver
  let resetRun ← IO.Process.output { cmd := "python3", args := #["-I", (dir / "reset.py").toString, toString resetPort] }
  let resetTrace ← expectOk (← resetStop)
  unless resetRun.exitCode == 0 do
    throw <| .userError "reset driver did not finish the traversal"
  unless resetTrace.contains "\"status\":400" && resetTrace.contains "\"status\":501" do
    throw <| .userError "a reset reply hid a traced 400 or 501"
  unless (match pageObservations resetTrace with
      | .error e => e == "unexpected trace status"
      | .ok _ => false) do
    throw <| .userError "reset trace with a 400 and a 501 was accepted"
  IO.println "observer reset: a reset 400 and 501 both leave events, and the parser rejects them"

  -- The same reply-raise path, forced and deterministic: both handlers must
  -- append their event before the reset error leaves the handler.
  let handlerTrace := dir / "reset-handler.jsonl"
  IO.FS.writeFile (dir / "reset_handler.py") resetHandlerDriver
  let handlerRun ← IO.Process.output { cmd := "python3", args := #["-I", (dir / "reset_handler.py").toString,
    "bench/apis/payouts/server.py", handlerTrace.toString] }
  unless handlerRun.exitCode == 0 do
    throw <| .userError "raising-reply handler test did not finish"
  let handlerText ← IO.FS.readFile handlerTrace
  unless handlerText.contains "\"status\":400" && handlerText.contains "\"status\":501" do
    throw <| .userError "a raising reply hid a traced 400 or 501"
  unless (match pageObservations handlerText with
      | .error e => e == "unexpected trace status"
      | .ok _ => false) do
    throw <| .userError "raising-reply trace with a 400 and a 501 was accepted"
  IO.println "observer raising reply: a 400 and 501 both leave events, and the parser rejects them"

#eval realObserver

private def artifactDiagnostics : IO Unit := do
  let base := fixtureResult "valid"
  let cases : List (Except String Result × String) := [
    (.ok base, "valid"),
    (.ok { base with exitCode := some 3 }, "no artifact:"),
    (.ok { base with exitCode := some 4 }, "is a symlink"),
    (.ok { base with exitCode := some 5 }, "not a regular file"),
    (.ok { base with stdout := ByteArray.mk #[255] }, "not UTF-8"),
    (.ok { base with stdout := ByteArray.mk (Array.replicate (artifactCap + 1) 65), cap := .output }, "size limit"),
    (.ok { base with cap := .timeout, exitCode := none }, "cap=timeout"),
    (.ok { base with cap := .output, exitCode := none }, "cap=output"),
    (.ok { base with exitCode := some 17, stderr := "secret-value".toUTF8 }, "exit_code="),
    (.error "backend secret-value", "backend error:")]
  for (result, expected) in cases do
    let backend : Kalari.Backend.SandboxBackend := {
      create := fun _ _ _ => pure result
      copyIn := fun _ _ _ => pure result
      copyOut := fun _ _ _ => pure result
      destroy := fun _ => pure result
      exec := fun _ argv => do
        verify (argv.drop 3 == ["sh", "/workspace/records.jsonl", toString (artifactCap + 1)]) "artifact path or bound"
        verify ((argv[2]!).startsWith "if test -L") "symlink check must precede existence"
        pure result
    }
    let actual ← (readArtifact backend "test" "records.jsonl" ["secret-value"]).run
    match actual with
    | .ok text => verify (expected == "valid" && text == "valid") "artifact success"
    | .error reason =>
      verify (reason.contains expected && !reason.contains "secret-value") "artifact classification or secret leak"
      if expected == "no artifact:" then
        verify (reason.contains "records.jsonl" && !reason.contains "msb exec failed") "missing artifact remedy"
  IO.println "artifact diagnostics: missing, symlink, non-file, size, UTF-8, backend, timeout, output cap, redaction passed"

#eval artifactDiagnostics

end Kalari.Tools.Run

