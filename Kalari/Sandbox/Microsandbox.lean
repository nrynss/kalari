import Lean.Data.Json
import Kalari.Backend
import Kalari.Model
import Kalari.Proc

/-! SandboxBackend over the `msb` CLI.

The gate has already allowed the run. This module does not call it and does
not resolve DNS: `AllowHost.host` is already an IP, and every rule is that IP.

Create always passes `--no-net`, then one `allow@<host>/32:tcp:<port>` per
allowlist entry, then `debian`. An empty allowlist still passes `--no-net`
and passes no rule. Cleanup is `msb remove`. `exec` on a stopped sandbox
starts it again, so stop is not the end of a run. A failed create is not
removed: the name may already have belonged to another sandbox.

`Proc.run` cannot set a umask. The process that starts Kalari uses umask
0022, because msb refuses group-writable storage. This module does not. -/

namespace Kalari.Sandbox.Microsandbox

open Kalari.Model
open Kalari.Backend
open Kalari.Proc (Result Cap)
open Lean

/-- `(argv, timeoutMs, outputCap)`. `live` binds this to `Proc.run`. -/
abbrev Runner :=
  (argv : List String) → (timeoutMs : Nat) → (outputCap : Nat) → IO Result

/-- Create, copy, list, and remove. Exec uses the request timeout instead. -/
def controlTimeoutMs : Nat := 30000

def imageName : String := "debian"

/-- `sh -c` with the write the guest needs before the aashaan can start threads. -/
def overcommitCommand : List String :=
  ["sh", "-c", "echo 1 > /proc/sys/vm/overcommit_memory"]

def netRule (host : AllowHost) : String :=
  s!"allow@{host.host}/32:tcp:{host.port}"

def netRules (allow : List AllowHost) : List String :=
  allow.flatMap fun host => ["--net-rule", netRule host]

def createArgv (name : String) (memoryMib : Nat) (allow : List AllowHost) : List String :=
  ["msb", "create", "--name", name, "--cpus", "1", "--memory", s!"{memoryMib}M", "--no-net"]
    ++ netRules allow
    ++ [imageName]

def copyInArgv (name hostPath guestPath : String) : List String :=
  ["msb", "copy", "-q", hostPath, s!"{name}:{guestPath}"]

def copyOutArgv (name guestPath hostPath : String) : List String :=
  ["msb", "copy", "-q", s!"{name}:{guestPath}", hostPath]

def execArgv (name : String) (command : List String) : List String :=
  ["msb", "exec", name, "--"] ++ command

def removeArgv (name : String) : List String :=
  ["msb", "remove", name]

/-- Only `list` has machine output. -/
def listArgv : List String :=
  ["msb", "list", "--format", "json"]

/-- One row of `msb list --format json`. -/
structure Listed where
  name : String
  image : String
  status : String
  created_at : String
  deriving Repr, BEq, FromJson

def parseListed (text : String) : Except String (List Listed) :=
  Json.parse text >>= fromJson?

/-- Names from a list that belong to Kalari. Anything else is left alone. -/
def kalariNames (entries : List Listed) : List String :=
  entries.filterMap fun entry =>
    if entry.name.startsWith "kalari-" then some entry.name else none

private def argvLine (argv : List String) : String :=
  String.intercalate " " argv

private def noNetDefault (argv : List String) : Bool :=
  !(argvLine argv).contains "--net-default"

private def showsCreate (argv : List String) : Bool :=
  argv.contains "--no-net"
    && argv.contains "--cpus"
    && argv.contains "1"
    && argv.contains "--memory"
    && argv.contains "256M"
    && argv.contains "debian"
    && argv.contains "--name"
    && argv.contains "kalari-run-1"
    && argv.any (fun arg => arg.contains "allow@" && arg.contains "/32:tcp:")
    && noNetDefault argv

#guard createArgv "kalari-run-1" 256 [] ==
  ["msb", "create", "--name", "kalari-run-1", "--cpus", "1", "--memory", "256M", "--no-net", "debian"]

#guard createArgv "kalari-run-1" 256 [{ host := "203.0.113.10", port := 18090 }] ==
  ["msb", "create", "--name", "kalari-run-1", "--cpus", "1", "--memory", "256M", "--no-net",
    "--net-rule", "allow@203.0.113.10/32:tcp:18090", "debian"]

#guard showsCreate (createArgv "kalari-run-1" 256 [{ host := "203.0.113.10", port := 18090 }])

#guard createArgv "n" 128 [
    { host := "203.0.113.10", port := 80 },
    { host := "203.0.113.10", port := 443 }] ==
  ["msb", "create", "--name", "n", "--cpus", "1", "--memory", "128M", "--no-net",
    "--net-rule", "allow@203.0.113.10/32:tcp:80",
    "--net-rule", "allow@203.0.113.10/32:tcp:443", "debian"]

#guard copyInArgv "kalari-run-1" "in.txt" "/tmp/in.txt" ==
  ["msb", "copy", "-q", "in.txt", "kalari-run-1:/tmp/in.txt"]

#guard copyOutArgv "kalari-run-1" "/tmp/in.txt" "./out.txt" ==
  ["msb", "copy", "-q", "kalari-run-1:/tmp/in.txt", "./out.txt"]

#guard execArgv "kalari-run-1" overcommitCommand ==
  ["msb", "exec", "kalari-run-1", "--", "sh", "-c", "echo 1 > /proc/sys/vm/overcommit_memory"]

#guard removeArgv "kalari-run-1" == ["msb", "remove", "kalari-run-1"]

#guard listArgv == ["msb", "list", "--format", "json"]

#guard noNetDefault (createArgv "kalari-run-1" 256 [])
  && noNetDefault (createArgv "kalari-run-1" 256 [{ host := "203.0.113.10", port := 18090 }])
  && noNetDefault (copyInArgv "kalari-run-1" "in.txt" "/tmp/in.txt")
  && noNetDefault (copyOutArgv "kalari-run-1" "/tmp/in.txt" "./out.txt")
  && noNetDefault (execArgv "kalari-run-1" overcommitCommand)
  && noNetDefault (removeArgv "kalari-run-1")
  && noNetDefault listArgv

#guard kalariNames [
    { name := "api-payouts-live", image := "python", status := "Running", created_at := "a" },
    { name := "kalari-run-1", image := "debian", status := "Running", created_at := "b" },
    { name := "not-kalari-run", image := "debian", status := "Stopped", created_at := "c" },
  ] == ["kalari-run-1"]

private def bytesText (b : ByteArray) : String :=
  match String.fromUTF8? b with
  | some s => s
  | none => ""

private def describe (what : String) (r : Result) : String :=
  match r.cap with
  | .timeout => s!"{what}: timeout"
  | .output => s!"{what}: output cap"
  | .none =>
    match r.exitCode with
    | none => s!"{what}: no exit"
    | some code =>
      let err := (bytesText r.stderr).trimAscii.toString
      if err.isEmpty then s!"{what}: exit {code}" else s!"{what}: exit {code}: {err}"

/-- A non-zero exit is an `msb` failure for create, copy, list, and remove. -/
private def requireExit0 (what : String) (r : Result) : Except String Result :=
  if r.cap != .none then .error (describe what r)
  else
    match r.exitCode with
    | some code => if code == 0 then .ok r else .error (describe what r)
    | none => .error (describe what r)

private def invoke (runner : Runner) (what : String) (argv : List String)
    (timeoutMs outputCap : Nat) : IO (Except String Result) := do
  return requireExit0 what (← runner argv timeoutMs outputCap)

private def succeeded (r : Result) : Bool :=
  r.cap == .none && r.exitCode == some 0

/-- `execTimeoutMs` and `outputCap` are the request's. Exec uses both.
Create, copy, and remove use `controlTimeoutMs` and that same output cap.
`msb exec` forwards the command's exit code, so a non-zero code stays in
the `Result` instead of becoming an error. -/
def make (runner : Runner) (execTimeoutMs outputCap : Nat) : SandboxBackend where
  create := fun name caps allow =>
    invoke runner "create" (createArgv name caps.memory_mib allow) controlTimeoutMs outputCap
  copyIn := fun name hostPath guestPath =>
    invoke runner "copy-in" (copyInArgv name hostPath guestPath) controlTimeoutMs outputCap
  exec := fun name command => do
    return .ok (← runner (execArgv name command) execTimeoutMs outputCap)
  copyOut := fun name guestPath hostPath =>
    invoke runner "copy-out" (copyOutArgv name guestPath hostPath) controlTimeoutMs outputCap
  destroy := fun name =>
    invoke runner "remove" (removeArgv name) controlTimeoutMs outputCap

/-- `path` is the child's whole `PATH`. The parent environment is not inherited,
so without it the child cannot find `msb`. The checks do not call this. -/
def live (path : String) : Runner := fun argv timeoutMs outputCap =>
  Proc.run argv (env := #[("PATH", some path)]) (inheritEnv := false) (stdin := none)
    (timeoutMs := timeoutMs) (outputCap := outputCap)

/-- Paths are the caller's. `command` is the job argv, not wrapped again. -/
structure Run where
  name : String
  caps : Caps
  allow : List AllowHost
  workspaceHost : String
  workspaceGuest : String
  aashaanHost : String
  aashaanGuest : String
  command : List String
  resultsGuest : String
  resultsHost : String
  deriving Repr

private def cleanup (b : SandboxBackend) (name : String) (outcome : Except String Result) :
    IO (Except String Result) := do
  match ← b.destroy name with
  | .ok _ => return outcome
  | .error removeError =>
    match outcome with
    | .error _ => return outcome
    | .ok _ => return .error removeError

private def steps (b : SandboxBackend) (spec : Run) : IO (Except String Result) := do
  match ← b.copyIn spec.name spec.workspaceHost spec.workspaceGuest with
  | .error e => return .error e
  | .ok _ => pure ()
  match ← b.copyIn spec.name spec.aashaanHost spec.aashaanGuest with
  | .error e => return .error e
  | .ok _ => pure ()
  match ← b.exec spec.name overcommitCommand with
  | .error e => return .error e
  | .ok r =>
    if !succeeded r then
      return .error (describe "overcommit" r)
  match ← b.exec spec.name spec.command with
  | .error e => return .error e
  | .ok job =>
    match ← b.copyOut spec.name spec.resultsGuest spec.resultsHost with
    | .error e => return .error e
    | .ok _ => return .ok job

/-- Create, copy the workspace and the aashaan in, set overcommit, exec the
job, copy results out, and remove. A failed create returns the error and
does not remove. Any create that succeeded is removed, including when the
job's exit code is not 0. -/
def run (runner : Runner) (spec : Run) : IO (Except String Result) := do
  let b := make runner spec.caps.timeout_ms spec.caps.output_cap_bytes
  match ← b.create spec.name spec.caps spec.allow with
  | .error e => return .error e
  | .ok _ => pure ()
  try
    let outcome ← steps b spec
    cleanup b spec.name outcome
  catch
    | e =>
      discard <| b.destroy spec.name
      throw e

/-- Sandboxes left behind by a crash. Removes only names from `kalariNames`. -/
def reap (runner : Runner) (outputCap : Nat) : IO (Except String (List String)) := do
  match requireExit0 "list" (← runner listArgv controlTimeoutMs outputCap) with
  | .error e => return .error e
  | .ok listed =>
    match parseListed (bytesText listed.stdout) with
    | .error e => return .error s!"list: {e}"
    | .ok entries =>
      let names := kalariNames entries
      for name in names do
        match requireExit0 "remove" (← runner (removeArgv name) controlTimeoutMs outputCap) with
        | .error e => return .error e
        | .ok _ => pure ()
      return .ok names

/-! The checks below run during `lake build`. The runner replays `testdata/msb`.
A step with no recording fails the build. `live` is not applied: the gate has
no `msb` binary. -/

private def fail {α : Type} (msg : String) : IO α :=
  throw <| .userError msg

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def check (cond : Bool) (msg : String) : IO Unit := do
  unless cond do
    fail msg

private def ofExcept {α : Type} (e : Except String α) : IO α := do
  match e with
  | .ok a => return a
  | .error err => fail err

private def findRootFrom (dir : System.FilePath) (left : Nat) : IO System.FilePath := do
  if ← (dir / "lakefile.toml").pathExists then
    return dir
  if left = 0 then
    return dir
  match dir.parent with
  | none => return dir
  | some parent => findRootFrom parent (left - 1)

private def repoRoot : IO System.FilePath := do
  let dir ← findRootFrom (← IO.currentDir) 8
  unless ← (dir / "lakefile.toml").pathExists do
    fail "no lakefile.toml"
  return dir

private structure Rec where
  name : String
  code : Nat
  ms : Nat

private def parseRec (j : Json) : Except String Rec := do
  let name ← (← j.getObjVal? "case").getStr?
  let code ← (← j.getObjVal? "exit").getNat?
  let ms ← (← j.getObjVal? "ms").getNat?
  return { name, code, ms }

private def replay (root : System.FilePath) (case : String) : IO Result := do
  let text ← IO.FS.readFile (root / "testdata" / "msb" / "index.json")
  let arr ← ofExcept ((← ofExcept (Json.parse text)).getArr?)
  let recs ← arr.toList.mapM fun item => ofExcept (parseRec item)
  let some r := recs.find? (·.name == case)
    | fail s!"no recording for {case}"
  let stdout ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{case}.stdout")
  let stderr ← IO.FS.readBinFile (root / "testdata" / "msb" / s!"{case}.stderr")
  return {
    exitCode := some (UInt32.ofNat r.code)
    stdout
    stderr
    wallMs := r.ms
    cap := .none
  }

private structure Call where
  argv : List String
  timeoutMs : Nat
  outputCap : Nat
  deriving Repr, BEq

/-- A case the runner was not given is a miss, not an empty success. -/
private def accepts (case : String) (argv : List String) : Bool :=
  let noDefault := noNetDefault argv
  match case with
  | "create-ok" =>
    noDefault && argv.contains "--no-net" && argv.contains "--net-rule"
      && argv.contains "--cpus" && argv.getLast? == some "debian"
  | "create-duplicate" =>
    noDefault && argv.contains "--no-net" && !argv.contains "--net-rule"
      && argv.getLast? == some "debian"
  | "copy-in-ok" =>
    match argv with
    | ["msb", "copy", "-q", host, dest] => !host.contains ":" && dest.contains ":"
    | _ => false
  | "copy-out-ok" | "copy-out-missing" =>
    match argv with
    | ["msb", "copy", "-q", src, host] => src.contains ":" && !host.contains ":"
    | _ => false
  | "exec-sysctl" =>
    match argv with
    | "msb" :: "exec" :: _ :: "--" :: "sh" :: "-c" :: script :: [] =>
      script.contains "overcommit_memory" && script.contains "echo 1 >"
    | _ => false
  | "exec-exit3" =>
    match argv with
    | "msb" :: "exec" :: _ :: "--" :: cmd =>
      let line := argvLine cmd
      line.contains "exit 3" && !line.contains "overcommit_memory"
    | _ => false
  | "remove-ok" =>
    match argv with
    | ["msb", "remove", name] => name.startsWith "kalari-"
    | _ => false
  | "list-json" => argv == listArgv
  | _ => false

private def replayRunner (root : System.FilePath) (calls : IO.Ref (List Call))
    (left : IO.Ref (List String)) : Runner :=
  fun argv timeoutMs outputCap => do
    calls.modify fun xs => xs ++ [Call.mk argv timeoutMs outputCap]
    let rest ← left.get
    match rest with
    | [] => fail s!"no recording for extra call"
    | case :: more =>
      unless accepts case argv do
        fail s!"no recording for {case}"
      left.set more
      replay root case

private def fresh (cases : List String) : IO (IO.Ref (List Call) × IO.Ref (List String)) := do
  let calls ← IO.mkRef ([] : List Call)
  let left ← IO.mkRef cases
  return (calls, left)

private def expectOk (what : String) (e : Except String Result) : IO Result := do
  match e with
  | .ok r => return r
  | .error err => fail s!"{what}: {err}"

private def expectRecording (what : String) (root : System.FilePath) (case : String)
    (got : Result) : IO Unit := do
  let want ← replay root case
  check (got == want) s!"{what}: result is not {case}"

private def unconsumed (left : IO.Ref (List String)) : IO Unit := do
  let rest ← left.get
  unless rest.isEmpty do
    fail s!"unconsumed recording {String.intercalate "," rest}"

private def exitText (code : Option UInt32) : String :=
  match code with
  | some n => toString n
  | none => "none"

private def guardCalls (calls : List Call) : IO Unit := do
  for c in calls do
    check (noNetDefault c.argv) s!"argv contains --net-default: {argvLine c.argv}"
    if c.argv.contains "create" then
      check (c.argv.contains "--no-net") s!"create omits --no-net: {argvLine c.argv}"

private def runChecks : IO Unit := do
  let root ← repoRoot
  let host : AllowHost := { host := "203.0.113.10", port := 18090 }
  let caps : Caps := { timeout_ms := 800, output_cap_bytes := 4096, memory_mib := 256 }
  let name := "kalari-run-1"
  let job := ["sh", "-c", "echo out; echo err >&2; exit 3"]
  let wsHost := "in.txt"
  let wsGuest := "/tmp/ws"
  let aashaanHost := "kalari-aashaan"
  let aashaanGuest := "/usr/local/bin/kalari-aashaan"
  let resultsGuest := "/tmp/in.txt"
  let resultsHost := "./out.txt"

  -- Each step, a failed create, against the recordings.
  let (stepCalls, stepLeft) ← fresh
    ["create-ok", "copy-in-ok", "exec-sysctl", "exec-exit3", "copy-out-ok", "remove-ok",
      "create-duplicate"]
  let b := make (replayRunner root stepCalls stepLeft) caps.timeout_ms caps.output_cap_bytes
  let created ← expectOk "create" (← b.create name caps [host])
  expectRecording "create" root "create-ok" created
  let copied ← expectOk "copy-in" (← b.copyIn name wsHost wsGuest)
  expectRecording "copy-in" root "copy-in-ok" copied
  let sys ← expectOk "exec-sysctl" (← b.exec name overcommitCommand)
  expectRecording "exec-sysctl" root "exec-sysctl" sys
  check (succeeded sys) "exec-sysctl: not a success"
  let exit3 ← expectOk "exec-exit3" (← b.exec name job)
  expectRecording "exec-exit3" root "exec-exit3" exit3
  check (exit3.exitCode == some 3) "exec-exit3: exit code"
  let copiedOut ← expectOk "copy-out" (← b.copyOut name resultsGuest resultsHost)
  expectRecording "copy-out" root "copy-out-ok" copiedOut
  let removed ← expectOk "remove" (← b.destroy name)
  expectRecording "remove" root "remove-ok" removed
  match ← b.create name caps [] with
  | .ok _ => fail "create-duplicate: expected an error"
  | .error msg =>
    let errFile ← IO.FS.readFile (root / "testdata" / "msb" / "create-duplicate.stderr")
    check (msg.contains errFile.trimAscii.toString) s!"create-duplicate: {msg}"
    check (msg.contains "exit 1") "create-duplicate: exit"
  unconsumed stepLeft
  let steps ← stepCalls.get
  guardCalls steps
  match steps with
  | [c0, c1, c2, c3, c4, c5, c6] =>
    check (c0.argv == createArgv name caps.memory_mib [host]) "create argv"
    check (c0.timeoutMs == controlTimeoutMs && c0.outputCap == caps.output_cap_bytes) "create budget"
    check (c1.argv == copyInArgv name wsHost wsGuest) "copy-in argv"
    check (c1.timeoutMs == controlTimeoutMs && c1.outputCap == caps.output_cap_bytes) "copy-in budget"
    check (c2.argv == execArgv name overcommitCommand) "sysctl argv"
    check (c2.timeoutMs == caps.timeout_ms && c2.outputCap == caps.output_cap_bytes) "sysctl budget"
    check (c3.argv == execArgv name job) "job argv"
    check (c3.timeoutMs == caps.timeout_ms && c3.outputCap == caps.output_cap_bytes) "job budget"
    check (c4.argv == copyOutArgv name resultsGuest resultsHost) "copy-out argv"
    check (c4.timeoutMs == controlTimeoutMs && c4.outputCap == caps.output_cap_bytes) "copy-out budget"
    check (c5.argv == removeArgv name) "remove argv"
    check (c5.timeoutMs == controlTimeoutMs && c5.outputCap == caps.output_cap_bytes) "remove budget"
    check (c6.argv == createArgv name caps.memory_mib []) "duplicate argv"
    check (c6.timeoutMs == controlTimeoutMs && c6.outputCap == caps.output_cap_bytes) "duplicate budget"
    check (c6.argv.contains "--no-net" && !c6.argv.contains "--net-rule") "duplicate shape"
    say s!"msb argv {argvLine c0.argv}"
  | _ => fail s!"step count {steps.length}"
  say s!"msb create-ok exit={exitText created.exitCode} wallMs={created.wallMs}"
  say s!"msb copy-in-ok exit={exitText copied.exitCode}"
  say s!"msb exec-sysctl exit={exitText sys.exitCode}"
  say s!"msb exec-exit3 exit={exitText exit3.exitCode}"
  say s!"msb copy-out-ok exit={exitText copiedOut.exitCode}"
  say s!"msb remove-ok exit={exitText removed.exitCode}"
  say "msb create-duplicate exit=1 removed=false"

  -- The run removes after an exec that returns exit 3, and returns that result.
  let (runCalls, runLeft) ← fresh
    ["create-ok", "copy-in-ok", "copy-in-ok", "exec-sysctl", "exec-exit3", "copy-out-ok", "remove-ok"]
  let ran ← expectOk "run" (← run (replayRunner root runCalls runLeft) {
    name
    caps
    allow := [host]
    workspaceHost := wsHost
    workspaceGuest := wsGuest
    aashaanHost
    aashaanGuest
    command := job
    resultsGuest
    resultsHost
  })
  expectRecording "run" root "exec-exit3" ran
  check (ran.exitCode == some 3) "run: job exit was not returned"
  unconsumed runLeft
  let ranCalls ← runCalls.get
  guardCalls ranCalls
  match ranCalls with
  | [r0, r1, r2, r3, r4, r5, r6] =>
    check (r0.argv == createArgv name caps.memory_mib [host]) "run create"
    check (r1.argv == copyInArgv name wsHost wsGuest) "run workspace"
    check (r2.argv == copyInArgv name aashaanHost aashaanGuest) "run aashaan"
    check (r3.argv == execArgv name overcommitCommand) "run sysctl"
    check (r4.argv == execArgv name job) "run job"
    check (r5.argv == copyOutArgv name resultsGuest resultsHost) "run copy-out"
    check (r6.argv == removeArgv name) "run remove"
    check (r0.timeoutMs == controlTimeoutMs && r3.timeoutMs == caps.timeout_ms) "run budgets"
    check (r4.timeoutMs == caps.timeout_ms && r6.timeoutMs == controlTimeoutMs) "run budgets 2"
    check (r6.outputCap == caps.output_cap_bytes && r4.outputCap == caps.output_cap_bytes) "run cap"
  | _ => fail s!"run count {ranCalls.length}"
  say "msb run exit=3 remove-after-exit3=true steps=7"

  -- A failed create does not exec and does not remove.
  let (dupCalls, dupLeft) ← fresh ["create-duplicate"]
  match ← run (replayRunner root dupCalls dupLeft) {
    name
    caps
    allow := []
    workspaceHost := wsHost
    workspaceGuest := wsGuest
    aashaanHost
    aashaanGuest
    command := job
    resultsGuest
    resultsHost
  } with
  | .ok _ => fail "failed create: expected an error"
  | .error msg =>
    let errFile ← IO.FS.readFile (root / "testdata" / "msb" / "create-duplicate.stderr")
    check (msg.contains errFile.trimAscii.toString) s!"failed create: {msg}"
  unconsumed dupLeft
  let dupLog ← dupCalls.get
  guardCalls dupLog
  match dupLog with
  | [only] =>
    check (only.argv == createArgv name caps.memory_mib []) "failed create argv"
    check (only.argv.contains "--no-net" && !only.argv.contains "--net-rule") "failed create shape"
    check (!(argvLine only.argv).contains "--net-default") "failed create net-default"
  | _ => fail s!"failed create calls {dupLog.length}"
  say "msb run failed-create calls=1 remove=false exec=false"

  -- A failed copy-out still removes. The error is the copy, not a missing remove.
  let (missCalls, missLeft) ← fresh
    ["create-ok", "copy-in-ok", "copy-in-ok", "exec-sysctl", "exec-exit3", "copy-out-missing", "remove-ok"]
  match ← run (replayRunner root missCalls missLeft) {
    name
    caps
    allow := [host]
    workspaceHost := wsHost
    workspaceGuest := wsGuest
    aashaanHost
    aashaanGuest
    command := job
    resultsGuest
    resultsHost
  } with
  | .ok _ => fail "copy-out-missing: expected an error"
  | .error msg =>
    let errFile ← IO.FS.readFile (root / "testdata" / "msb" / "copy-out-missing.stderr")
    check (msg.contains errFile.trimAscii.toString) s!"copy-out-missing: {msg}"
  unconsumed missLeft
  let missLog ← missCalls.get
  guardCalls missLog
  match missLog with
  | [_, _, _, _, jobCall, _, removedCall] =>
    check (jobCall.argv == execArgv name job) "copy-out-missing: job"
    check (removedCall.argv == removeArgv name) "copy-out-missing: remove"
  | _ => fail s!"copy-out-missing calls {missLog.length}"
  say "msb run copy-out-missing remove-after=true"

  -- Next start: the recorded list has no kalari- name, so reap removes nothing.
  let listedText ← IO.FS.readFile (root / "testdata" / "msb" / "list-json.stdout")
  let entries ← ofExcept (parseListed listedText)
  check (entries.any (·.name == "rec-msb")) "list-json: name"
  check (entries.all (·.image != "")) "list-json: image"
  check (entries.all (·.status != "")) "list-json: status"
  check (kalariNames entries == []) "list-json: unexpected kalari name"
  let (listCalls, listLeft) ← fresh ["list-json"]
  match ← reap (replayRunner root listCalls listLeft) caps.output_cap_bytes with
  | .error e => fail s!"reap: {e}"
  | .ok names => check (names == []) "reap removed a sandbox"
  unconsumed listLeft
  let listLog ← listCalls.get
  match listLog with
  | [only] =>
    check (only.argv == listArgv) "list argv"
    check (only.timeoutMs == controlTimeoutMs && only.outputCap == caps.output_cap_bytes) "list budget"
  | _ => fail s!"reap calls {listLog.length}"
  say s!"msb list-json parsed={entries.length} kalari=0"

#eval runChecks

end Kalari.Sandbox.Microsandbox
