import Kalari.Backend
import Kalari.Model
import Kalari.Proc

/-! SandboxBackend on Docker, for a host without KVM.

This is the laptop fallback. The demo path stays Microsandbox.

Docker has no per-IP allow rule. A run always passes `--network none`.
There is no other network mode in the argv, no egress proxy, and no nftables.
A non-empty allowlist is an error and does not start a container.

A run is one `docker run --rm`. That flag removes the container. `destroy`
is `docker rm -f` for a name left behind. `--pids-limit` is 256. The root
is `--read-only`. The workspace is a writable mount at `/workspace`. The
image is `debian:stable-slim`. The job's exit code stays in the `Result`. -/

namespace Kalari.Sandbox.Docker

open Kalari.Model
open Kalari.Backend
open Kalari.Proc (Result Cap)

/-- `(argv, timeoutMs, outputCap)`. `live` binds this to `Proc.run`. -/
abbrev Runner :=
  (argv : List String) → (timeoutMs : Nat) → (outputCap : Nat) → IO Result

/-- Destroy. Exec uses the request timeout instead. -/
def controlTimeoutMs : Nat := 30000

def imageName : String := "debian:stable-slim"

/-- Fixed. Not a field of `Caps`. -/
def pidsLimit : Nat := 256

def workspaceGuest : String := "/workspace"

/-- Returned for a non-empty allowlist. No container is started. -/
def noPerIpRule : String := "this backend has no per-IP rule"

def mountArg (hostPath : String) : String :=
  s!"{hostPath}:{workspaceGuest}:rw"

def runArgv (name : String) (memoryMib : Nat) (workspaceHost : String)
    (command : List String) : List String :=
  ["docker", "run", "--name", name, "--rm", "--network", "none", "--read-only",
    "--memory", s!"{memoryMib}m", "--pids-limit", toString pidsLimit,
    "-v", mountArg workspaceHost, imageName] ++ command

def destroyArgv (name : String) : List String :=
  ["docker", "rm", "-f", name]

private def argvLine (argv : List String) : String :=
  String.intercalate " " argv

private def hasPair (argv : List String) (a b : String) : Bool :=
  (argv.zip argv.tail).any fun (x, y) => x == a && y == b

private def hasRunFlags (argv : List String) : Bool :=
  hasPair argv "--network" "none"
    && argv.contains "--rm"
    && argv.contains "--read-only"
    && argv.contains "--memory"
    && hasPair argv "--pids-limit" "256"
    && argv.contains "256"
    && argv.contains imageName
    && argv.any (fun arg => arg.contains "/workspace")
    && !hasPair argv "--network" "host"
    && !argv.contains "--privileged"
    && !(argvLine argv).contains "--network host"
    && !(argvLine argv).contains "--privileged"

#guard pidsLimit == 256

#guard imageName == "debian:stable-slim"

#guard runArgv "kalari-docker-record" 256 "/tmp/kalari-workspace" ["echo", "kalari-docker"] ==
  ["docker", "run", "--name", "kalari-docker-record", "--rm", "--network", "none", "--read-only",
    "--memory", "256m", "--pids-limit", "256", "-v", "/tmp/kalari-workspace:/workspace:rw",
    "debian:stable-slim", "echo", "kalari-docker"]

#guard hasRunFlags (runArgv "kalari-docker-record" 256 "/tmp/kalari-workspace" ["echo", "kalari-docker"])

#guard hasRunFlags (runArgv "n" 128 "/tmp/kalari-workspace" ["true"])

#guard (runArgv "n" 128 "/tmp/kalari-workspace" ["true"]).contains "128m"

#guard (runArgv "n" 128 "/tmp/kalari-workspace" ["true"]).contains "256"

#guard !(runArgv "n" 128 "/tmp/kalari-workspace" ["true"]).contains "--privileged"

#guard hasPair (runArgv "n" 64 "/ws" ["echo", "kalari-docker"]) "--network" "none"

#guard !hasPair (runArgv "n" 64 "/ws" ["echo", "kalari-docker"]) "--network" "host"

#guard (runArgv "n" 64 "/ws" ["echo", "kalari-docker"]).dropWhile (fun arg => arg != imageName) ==
  ["debian:stable-slim", "echo", "kalari-docker"]

#guard !(argvLine (runArgv "n" 64 "/ws" ["true"])).contains "--network host"

#guard !(argvLine (runArgv "n" 64 "/ws" ["true"])).contains "--privileged"

#guard destroyArgv "kalari-docker-record" == ["docker", "rm", "-f", "kalari-docker-record"]

#guard noPerIpRule.contains "per-IP"

private structure Slot where
  name : String
  memoryMib : Nat
  workspaceHost : Option String
  deriving Repr, BEq

private def putSlot (slots : List Slot) (slot : Slot) : List Slot :=
  slots.filter (fun s => s.name != slot.name) ++ [slot]

private def findSlot (slots : List Slot) (name : String) : Option Slot :=
  slots.find? (fun s => s.name == name)

/-- Create accepted the allowlist. It is not a docker result: no container was started. -/
private def localOk : Result :=
  { exitCode := some 0, stdout := .empty, stderr := .empty, wallMs := 0, cap := .none }

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

private def requireExit0 (what : String) (r : Result) : Except String Result :=
  if r.cap != .none then .error (describe what r)
  else
    match r.exitCode with
    | some code => if code == 0 then .ok r else .error (describe what r)
    | none => .error (describe what r)

/-- One `docker run`. A non-empty allowlist returns `noPerIpRule` and does not call `runner`. -/
structure Run where
  name : String
  caps : Caps
  allow : List AllowHost
  workspaceHost : String
  command : List String
  deriving Repr

def run (runner : Runner) (spec : Run) : IO (Except String Result) := do
  if !spec.allow.isEmpty then
    return .error noPerIpRule
  return .ok (← runner
    (runArgv spec.name spec.caps.memory_mib spec.workspaceHost spec.command)
    spec.caps.timeout_ms spec.caps.output_cap_bytes)

/-- `copyIn` stores the workspace mount. `exec` is the `docker run` from `run`.
`create` does not start a container. A non-empty allowlist does not call `runner`. -/
def make (runner : Runner) (execTimeoutMs outputCap : Nat) : IO SandboxBackend := do
  let held ← IO.mkRef ([] : List Slot)
  return {
    create := fun name caps allow => do
      if !allow.isEmpty then
        return .error noPerIpRule
      held.modify fun slots =>
        putSlot slots { name, memoryMib := caps.memory_mib, workspaceHost := none }
      return .ok localOk
    copyIn := fun name hostPath guestPath => do
      if guestPath != workspaceGuest then
        return .error s!"docker workspace mount is {workspaceGuest}"
      let some slot := findSlot (← held.get) name
        | return .error s!"copy-in: {name} was not created"
      held.modify fun slots =>
        putSlot slots { slot with workspaceHost := some hostPath }
      return .ok localOk
    exec := fun name command => do
      let some slot := findSlot (← held.get) name
        | return .error s!"exec: {name} was not created"
      let some hostPath := slot.workspaceHost
        | return .error s!"exec: {name} has no workspace mount"
      run runner {
        name
        caps := {
          timeout_ms := execTimeoutMs
          output_cap_bytes := outputCap
          memory_mib := slot.memoryMib
        }
        allow := []
        workspaceHost := hostPath
        command
      }
    copyOut := fun name guestPath _hostPath => do
      let some slot := findSlot (← held.get) name
        | return .error s!"copy-out: {name} was not created"
      if slot.workspaceHost.isNone then
        return .error s!"copy-out: {name} has no workspace mount"
      if guestPath != workspaceGuest && !guestPath.startsWith s!"{workspaceGuest}/" then
        return .error "docker copy-out is the workspace mount"
      return .ok localOk
    destroy := fun name => do
      let outcome := requireExit0 "destroy" (← runner (destroyArgv name) controlTimeoutMs outputCap)
      match outcome with
      | .ok v =>
        held.modify fun slots => slots.filter (fun s => s.name != name)
        return .ok v
      | .error e => return .error e
  }

/-- `path` is the child's whole `PATH`. The parent environment is not inherited,
so without it the child cannot find `docker`. The checks do not call this. -/
def live (path : String) : Runner := fun argv timeoutMs outputCap =>
  Proc.run argv (env := #[("PATH", some path)]) (inheritEnv := false) (stdin := none)
    (timeoutMs := timeoutMs) (outputCap := outputCap)

/-! The checks below run during `lake build`. The runner replays
`deploy/local/recordings`. It does not call docker. `live` is not applied. -/

private def fail {α : Type} (msg : String) : IO α :=
  throw <| .userError msg

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def check (cond : Bool) (msg : String) : IO Unit := do
  unless cond do
    fail msg

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

private def recording (root : System.FilePath) (ext : String) : System.FilePath :=
  root / "deploy" / "local" / "recordings" / s!"kalari-docker-record.{ext}"

/-- The wall time was not recorded. `wallMs` is 0, not a measured duration. -/
private def replay (root : System.FilePath) : IO Result := do
  let stdout ← IO.FS.readBinFile (recording root "stdout")
  let stderr ← IO.FS.readBinFile (recording root "stderr")
  let exitText ← IO.FS.readFile (recording root "exit")
  let some code := exitText.trimAscii.toString.toNat?
    | fail s!"exit code {exitText.trimAscii.toString}"
  return {
    exitCode := some (UInt32.ofNat code)
    stdout
    stderr
    wallMs := 0
    cap := .none
  }

private structure Call where
  argv : List String
  timeoutMs : Nat
  outputCap : Nat
  deriving Repr, BEq

/-- Only a `docker run` argv has a recording. Anything else fails the build. -/
private def replayRunner (root : System.FilePath) (calls : IO.Ref (List Call)) : Runner :=
  fun argv timeoutMs outputCap => do
    calls.modify fun xs => xs ++ [Call.mk argv timeoutMs outputCap]
    unless hasRunFlags argv do
      fail s!"no recording for {argvLine argv}"
    replay root

private def expectOk (what : String) (e : Except String Result) : IO Result := do
  match e with
  | .ok r => return r
  | .error err => fail s!"{what}: {err}"

private def runChecks : IO Unit := do
  let root ← repoRoot
  let recorded ← replay root
  let stdoutText := (bytesText recorded.stdout).trimAscii.toString
  check (stdoutText == "kalari-docker") "recorded stdout"
  check (recorded.stdout == "kalari-docker\n".toUTF8) "recorded stdout bytes"
  check (recorded.stderr.size == 0) "recorded stderr"
  check (recorded.exitCode == some 0) "recorded exit"
  check (recorded.cap == .none) "recorded cap"

  let calls ← IO.mkRef ([] : List Call)
  let runner := replayRunner root calls
  let caps : Caps := { timeout_ms := 2000, output_cap_bytes := 4096, memory_mib := 256 }
  let spec : Run := {
    name := "kalari-docker-record"
    caps
    allow := []
    workspaceHost := "/tmp/kalari-workspace"
    command := ["echo", "kalari-docker"]
  }
  let ran ← expectOk "run" (← run runner spec)
  check (ran == recorded) "replay"
  check (ran.exitCode == some 0) "replay exit"
  check ((bytesText ran.stdout).trimAscii.toString == "kalari-docker") "replay stdout"
  let logged ← calls.get
  let c0 ← match logged with
    | [c] => pure c
    | _ => fail s!"run calls {logged.length}"
  let line := argvLine c0.argv
  check (c0.argv == runArgv spec.name caps.memory_mib spec.workspaceHost spec.command) "run argv"
  check (line.contains "--network none") "network none"
  check (c0.argv.contains "--rm") "--rm"
  check (c0.argv.contains "--read-only") "--read-only"
  check (c0.argv.contains "--memory") "--memory"
  check (hasPair c0.argv "--memory" "256m") "memory 256m"
  check (c0.argv.contains "--pids-limit") "--pids-limit"
  check (hasPair c0.argv "--pids-limit" "256") "pids 256"
  check (c0.argv.contains "256") "256"
  check (c0.argv.contains "debian:stable-slim") "image"
  check (c0.argv.any (fun arg => arg.contains "/workspace")) "/workspace"
  check (c0.argv.dropWhile (fun arg => arg != imageName) == imageName :: spec.command) "command"
  check (!line.contains "--network host") "no host"
  check (!hasPair c0.argv "--network" "host") "no host pair"
  check (!c0.argv.contains "--privileged") "no privileged"
  check (!line.contains "--privileged") "no privileged text"
  check (c0.timeoutMs == caps.timeout_ms && c0.outputCap == caps.output_cap_bytes) "run budget"
  say "docker record exit=0 stdout=kalari-docker stderrBytes=0"
  say s!"docker argv {line}"
  say "docker argv has --network none --rm --read-only --memory --pids-limit 256 debian:stable-slim /workspace"
  say "docker argv omits --network host and --privileged"

  let refused : AllowHost := { host := "refused.example", port := 9 }
  let beforeAllow ← calls.get
  match ← run runner { spec with allow := [refused] } with
  | .ok _ => fail "allowlist: expected an error"
  | .error msg =>
    check (msg == noPerIpRule) s!"allowlist: {msg}"
    check (msg.contains "per-IP") "allowlist names per-IP"
  let afterAllow ← calls.get
  check (afterAllow == beforeAllow) "allowlist called the runner"
  say s!"docker allowlist error={noPerIpRule} calls=0"

  let b ← make runner caps.timeout_ms caps.output_cap_bytes
  let beforeCreate ← calls.get
  match ← b.create spec.name caps [refused] with
  | .ok _ => fail "create allowlist: expected an error"
  | .error msg =>
    check (msg == noPerIpRule) s!"create allowlist: {msg}"
  match ← b.exec spec.name spec.command with
  | .ok _ => fail "exec after refused create started a container"
  | .error _ => pure ()
  check ((← calls.get) == beforeCreate) "refused create called the runner"

  match ← b.create spec.name caps [] with
  | .error e => fail s!"create: {e}"
  | .ok _ => pure ()
  check ((← calls.get) == beforeCreate) "empty allowlist started a container"
  match ← b.copyIn spec.name spec.workspaceHost "/tmp" with
  | .ok _ => fail "copy-in accepted a guest path other than /workspace"
  | .error _ => pure ()
  match ← b.copyIn spec.name spec.workspaceHost workspaceGuest with
  | .error e => fail s!"copy-in: {e}"
  | .ok _ => pure ()
  match ← b.copyOut spec.name "/workspace/out.txt" "/tmp/out.txt" with
  | .error e => fail s!"copy-out: {e}"
  | .ok _ => pure ()
  check ((← calls.get) == beforeCreate) "copy called the runner"
  let ranExec ← expectOk "exec" (← b.exec spec.name spec.command)
  check (ranExec == recorded) "exec replay"
  let both ← calls.get
  match both with
  | [first, second] =>
    check (first.argv == second.argv) "exec argv"
    check (second.timeoutMs == caps.timeout_ms && second.outputCap == caps.output_cap_bytes) "exec budget"
    check (hasRunFlags second.argv) "exec flags"
  | _ => fail s!"exec calls {both.length}"
  say "docker make exec exit=0 same-argv=true"

  let seen ← IO.mkRef ([] : List (List String))
  let capture : Runner := fun argv _timeoutMs _outputCap => do
    seen.modify fun xs => xs ++ [argv]
    return localOk
  let remover ← make capture caps.timeout_ms caps.output_cap_bytes
  let removed ← expectOk "destroy" (← remover.destroy spec.name)
  check (removed.exitCode == some 0) "destroy exit"
  let destroyCalls ← seen.get
  match destroyCalls with
  | [argv] =>
    check (argv == destroyArgv spec.name) "destroy argv"
    check (argv == ["docker", "rm", "-f", spec.name]) "destroy tokens"
  | _ => fail s!"destroy calls {destroyCalls.length}"
  say "docker destroy argv=docker rm -f kalari-docker-record"

#eval runChecks

end Kalari.Sandbox.Docker
