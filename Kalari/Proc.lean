import Std.Async.System

/-! One subprocess runner.

`inheritEnv` defaults to false: the child gets `env` and nothing else.
No stdin uses `setsid`, so a kill reaches grandchildren. Stdin does not.
`takeStdin` drops `setsid` (lean4#15674), and `Child.pid` is not called
(lean4#15681). Pipes are read on tasks. The wait after a kill is bounded. -/

namespace Kalari.Proc

/-- Which cap ended the run. `none` means the process exited on its own. -/
inductive Cap where
  | none
  | timeout
  | output
  deriving Repr, BEq

/-- `exitCode` is `none` when a cap killed the process before it exited.
`stdout` and `stderr` are never longer than the output cap. -/
structure Result where
  exitCode : Option UInt32
  stdout : ByteArray
  stderr : ByteArray
  wallMs : Nat
  cap : Cap
  deriving BEq

/-- Read until EOF or `cap` is passed. The bytes returned are at most `cap`. -/
private def readCapped (h : IO.FS.Handle) (cap : Nat) : IO (ByteArray × Bool) := do
  let mut acc : ByteArray := .empty
  repeat
    let chunk ← h.read 4096
    if chunk.isEmpty then return (acc, false)
    acc := acc ++ chunk
    if acc.size > cap then return (acc.extract 0 cap, true)
  return (acc, false)

/-- Own the handle. It closes when this returns, so the child reads EOF. -/
private def writeStdin (h : IO.FS.Handle) (bytes : ByteArray) : IO Unit := do
  h.write bytes
  h.flush

private def clip (b : ByteArray) (cap : Nat) : ByteArray :=
  if b.size > cap then b.extract 0 cap else b

/-- `dedicated` so a full pipe cannot wait on the polling thread. -/
private def readers (outH errH : IO.FS.Handle) (outputCap : Nat) :
    IO (Task (Except IO.Error (ByteArray × Bool)) ×
        Task (Except IO.Error (ByteArray × Bool))) := do
  let outTask ← IO.asTask (readCapped outH outputCap) Task.Priority.dedicated
  let errTask ← IO.asTask (readCapped errH outputCap) Task.Priority.dedicated
  return (outTask, errTask)

private def exceeded (t : Task (Except IO.Error (ByteArray × Bool))) : IO Bool := do
  if !(← IO.hasFinished t) then return false
  match t.get with
  | .ok (_, hit) => return hit
  | .error e => throw e

private def killChild {cfg : IO.Process.StdioConfig} (child : IO.Process.Child cfg) : IO Unit := do
  try
    child.kill
  catch _ =>
    pure ()

/-- Reap within `ms`. An unbounded `wait` would hang if a pipe stayed open. -/
private def reap {cfg : IO.Process.StdioConfig} (child : IO.Process.Child cfg) (ms : Nat) : IO Unit := do
  let start ← IO.monoMsNow
  repeat
    if let some _ ← child.tryWait then return
    if (← IO.monoMsNow) - start >= ms then return
    IO.sleep 10

/-- Give up if a reader is still blocked. The bytes are empty, which is within the cap. -/
private def awaitBounded (t : Task (Except IO.Error (ByteArray × Bool))) (ms : Nat) :
    IO (ByteArray × Bool) := do
  let start ← IO.monoMsNow
  repeat
    if ← IO.hasFinished t then
      match t.get with
      | .ok v => return v
      | .error e => throw e
    if (← IO.monoMsNow) - start >= ms then
      return (.empty, false)
    IO.sleep 10
  return (.empty, false)

private def finish {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (outTask errTask : Task (Except IO.Error (ByteArray × Bool)))
    (start timeoutMs outputCap : Nat) : IO Result := do
  let mut fired : Cap := Cap.none
  let mut code : Option UInt32 := .none
  repeat
    if ← exceeded outTask <||> exceeded errTask then
      killChild child
      fired := Cap.output
      code := .none
      break
    if let some c ← child.tryWait then
      fired := Cap.none
      code := some c
      break
    if (← IO.monoMsNow) - start >= timeoutMs then
      killChild child
      fired := Cap.timeout
      code := .none
      break
    IO.sleep 10
  if fired != Cap.none then reap child 500
  let wallMs := (← IO.monoMsNow) - start
  let (stdout, _) ← awaitBounded outTask 500
  let (stderr, _) ← awaitBounded errTask 500
  return {
    exitCode := code
    stdout := clip stdout outputCap
    stderr := clip stderr outputCap
    wallMs
    cap := fired
  }

/-- Run `argv`. `env` is the whole environment unless `inheritEnv` is true.
`stdin := none` starts a new session. `some` bytes are written and closed. -/
def run (argv : List String)
    (env : Array (String × Option String) := #[])
    (inheritEnv : Bool := false)
    (stdin : Option ByteArray := none)
    (timeoutMs : Nat)
    (outputCap : Nat) : IO Result := do
  let (cmd, args) ← match argv with
    | cmd :: rest => pure (cmd, rest.toArray)
    | [] => throw <| .userError "argv is empty"
  let start ← IO.monoMsNow
  match stdin with
  | .none =>
    let child ← IO.Process.spawn {
      cmd, args
      stdin := .null, stdout := .piped, stderr := .piped
      setsid := true
      inheritEnv, env
    }
    let (outTask, errTask) ← readers child.stdout child.stderr outputCap
    finish child outTask errTask start timeoutMs outputCap
  | .some bytes =>
    -- `takeStdin` drops `setsid`. Group kill does not apply on this path.
    let child ← IO.Process.spawn {
      cmd, args
      stdin := .piped, stdout := .piped, stderr := .piped
      setsid := false
      inheritEnv, env
    }
    let (hin, child) ← child.takeStdin
    let (outTask, errTask) ← readers child.stdout child.stderr outputCap
    writeStdin hin bytes
    finish child outTask errTask start timeoutMs outputCap

/-! The six runs below execute during `lake build`. A kill that does not land
fails the build once the wait expires; it does not spin. -/

private def fail (msg : String) : IO Unit :=
  throw <| .userError msg

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def withinCap (r : Result) (cap : Nat) : Bool :=
  r.stdout.size ≤ cap && r.stderr.size ≤ cap

private def markerGone (pat : String) : IO Bool := do
  let out ← IO.Process.output { cmd := "/usr/bin/pgrep", args := #["-f", pat] }
  if out.exitCode == 1 then return true
  if out.exitCode == 0 then return false
  fail s!"pgrep exited {out.exitCode}"
  return false

private def waitGone (name pat : String) : IO Unit := do
  let start ← IO.monoMsNow
  repeat
    if ← markerGone pat then return
    if (← IO.monoMsNow) - start >= 1500 then
      discard <| IO.Process.output { cmd := "/usr/bin/pkill", args := #["-KILL", "-f", pat] }
      fail s!"{name}: process still running"
    IO.sleep 20

private def runChecks : IO Unit := do
  let normal ← run ["/bin/sh", "-c", "printf hi"] #[] false none 2000 4096
  unless normal.exitCode == some 0 && normal.cap == Cap.none &&
      normal.stdout == "hi".toUTF8 && withinCap normal 4096 do
    fail "normal: expected exit 0, cap none, stdout hi"
  say "proc normal exit=0 cap=none stdout=hi"

  let exit3 ← run ["/bin/sh", "-c", "exit 3"] #[] false none 2000 4096
  unless exit3.exitCode == some 3 && exit3.cap == Cap.none && withinCap exit3 4096 do
    fail "exit3: expected exit 3 and cap none"
  say "proc exit3 exit=3 cap=none"

  -- `& wait` keeps the shell. A simple command is exec'd, so the kill would not
  -- have to reach a child. argv0 is the marker, so this is not `pgrep sleep`.
  let pid ← IO.Process.getPID
  let toMark := s!"kalari-proc-to-{pid}x"
  let toPat := s!"kalari-proc-to-{pid}[x]"
  let timed ← run ["/bin/sh", "-c", s!"/usr/bin/env -a {toMark} /bin/sleep 30 & wait"]
    #[] false none 400 4096
  unless timed.cap == Cap.timeout && timed.exitCode.isNone && withinCap timed 4096 &&
      timed.wallMs < 5000 do
    fail "timeout: expected cap timeout, no exit code"
  waitGone "timeout" toPat
  say s!"proc timeout cap=timeout exit=none wallMs={timed.wallMs} gone=true"

  -- stderr is closed so its reader reaches EOF even if the kill misses.
  let ocMark := s!"kalari-proc-oc-{pid}x"
  let ocPat := s!"kalari-proc-oc-{pid}[x]"
  let flood := s!"exec 2>/dev/null; while :; do printf xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done # {ocMark}"
  let capped ← run ["/bin/sh", "-c", flood] #[] false none 3000 64
  unless capped.cap == Cap.output && capped.exitCode.isNone &&
      capped.stdout.size > 0 && capped.stdout.size ≤ 64 && capped.stderr.size ≤ 64 do
    fail s!"output: cap={reprStr capped.cap} stdoutLen={capped.stdout.size}"
  waitGone "output" ocPat
  say s!"proc output cap=output exit=none stdoutLen={capped.stdout.size} gone=true"

  let payload := "kalari-proc-stdin".toUTF8
  let copied ← run ["/bin/cat"] #[] false (some payload) 2000 4096
  unless copied.exitCode == some 0 && copied.cap == Cap.none &&
      copied.stdout == payload && withinCap copied 4096 do
    fail "stdin: payload was not copied"
  say "proc stdin exit=0 cap=none stdout=kalari-proc-stdin"

  let sentinel := "KALARI_PROC_SENTINEL"
  let saved ← IO.getEnv sentinel
  try
    Std.Async.System.setEnvVar sentinel "present"
    let empty ← run ["/bin/sh", "-c", "printf %s \"$KALARI_PROC_SENTINEL\""]
      #[] false none 2000 4096
    unless empty.exitCode == some 0 && empty.cap == Cap.none &&
        empty.stdout.size == 0 && withinCap empty 4096 do
      fail "empty-env: parent environment was visible"
    say "proc empty-env exit=0 cap=none stdoutEmpty=true"
  finally
    match saved with
    | some v => Std.Async.System.setEnvVar sentinel v
    | none => Std.Async.System.unsetEnvVar sentinel

#eval runChecks

end Kalari.Proc
