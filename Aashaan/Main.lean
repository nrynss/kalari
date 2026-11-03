import Std.Async.Process
open Std

/-! kalari-aashaan: the supervisor inside each microVM. Runs one untrusted job with a
wall-clock cap and an output cap, and prints a JSON verdict.
Std only (no Lean.Json), so the executable stays small. Starting point: the day-one
probe (dev-diary/research/sandbox.md). The guest needs vm.overcommit_memory=1, or the
Lean runtime can't start its reader threads.
Usage: kalari-aashaan <timeout-ms> <output-cap-bytes> <cmd> [args...] -/

def jstr (s : String) : String :=
  "\"" ++ s.foldl (fun acc c =>
    acc ++ match c with
      | '"' => "\\\"" | '\\' => "\\\\" | '\n' => "\\n" | '\r' => "\\r" | '\t' => "\\t"
      | c => if c.toNat < 0x20 then "?" else c.toString) "" ++ "\""

inductive Verdict where
  | exited (code : UInt32)
  | timeout
  | outputCap

def Verdict.json : Verdict → String
  | .exited c => s!"\"exited\",\"exit_code\":{c}"
  | .timeout => "\"killed_timeout\",\"exit_code\":null"
  | .outputCap => "\"killed_output_cap\",\"exit_code\":null"

/-- Read a pipe up to `cap` bytes. Returns (bytes, hitCap). -/
partial def readCapped (h : IO.FS.Handle) (cap : Nat) : IO (ByteArray × Bool) := do
  let rec go (acc : ByteArray) : IO (ByteArray × Bool) := do
    let chunk ← h.read 4096
    if chunk.isEmpty then return (acc, false)
    let acc := acc ++ chunk
    if acc.size > cap then return (acc.extract 0 cap, true)
    go acc
  go .empty

/-- Wait for a reader task at most `ms`; a process that escaped the group can keep a pipe open. -/
def awaitBounded (t : Task (Except IO.Error (ByteArray × Bool))) (ms : Nat) :
    IO (ByteArray × Bool × Bool) := do
  let start ← IO.monoMsNow
  while (← IO.monoMsNow) - start < ms do
    if ← IO.hasFinished t then
      return match t.get with
        | .ok (b, c) => (b, c, false)
        | .error _ => (.empty, false, false)
    IO.sleep 10
  return (.empty, false, true)   -- gave up: pipe still held open

def main (argv : List String) : IO UInt32 := do
  let (timeoutMs, cap, cmd, args) ← match argv with
    | t :: c :: cmd :: rest => pure (t.toNat!, c.toNat!, cmd, rest.toArray)
    | _ => throw <| .userError "usage: kalari-aashaan <timeout-ms> <output-cap-bytes> <cmd> [args...]"
  let start ← IO.monoMsNow
  let child ← IO.Process.spawn {
    cmd, args
    stdout := .piped, stderr := .piped, stdin := .null
    setsid := true                         -- own process group: kill reaches its children
    inheritEnv := false                    -- no secrets from our environment
    env := #[("PATH", some "/usr/bin:/bin")]
  }
  let outTask ← IO.asTask (readCapped child.stdout cap)
  let errTask ← IO.asTask (readCapped child.stderr cap)
  let mut verdict : Verdict := .timeout
  repeat
    if let some code ← child.tryWait then
      verdict := .exited code; break
    if (← IO.monoMsNow) - start > timeoutMs then
      child.kill; verdict := .timeout; break       -- SIGKILL to the whole group
    if ← IO.hasFinished outTask then
      if let .ok (_, true) := outTask.get then
        child.kill; verdict := .outputCap; break
    IO.sleep 10
  if !(verdict matches .exited _) then discard <| child.wait
  let wall := (← IO.monoMsNow) - start
  let (out, outCapped, outHeld) ← awaitBounded outTask 500
  let (err, _, errHeld) ← awaitBounded errTask 500
  let ru ← IO.Process.getResourceUsage
  let memLimit ← IO.Process.constrainedMemory
  let s (b : ByteArray) := String.fromUTF8? b |>.getD "<binary>"
  IO.println <| "{\"verdict\":" ++ verdict.json
    ++ s!",\"wall_ms\":{wall}"
    ++ s!",\"stdout\":{jstr (s out)},\"stdout_truncated\":{outCapped}"
    ++ s!",\"stderr\":{jstr (s err)}"
    ++ s!",\"pipe_held_open\":{outHeld || errHeld}"
    ++ s!",\"supervisor_peak_rss_kb\":{ru.peakResidentSetSizeKb}"
    ++ s!",\"cgroup_memory_limit\":{memLimit}}"
  (← IO.getStdout).flush
  -- Exit at once: reader threads may still be blocked on a pipe an escaped process holds open,
  -- and a normal exit waits for them.
  IO.Process.forceExit 0
