import Kalari.Tools.Run
import Kalari.Evidence
import Kalari.Sandbox.Microsandbox

/-! Live brokered microVM run: the payouts `correct` consumer inside a real
Microsandbox microVM reaches the observed payouts API only through one fresh
Lean broker.

Why this proves mediation: the observed server is started with
`--trace-client 127.0.0.1`, so it answers 403 to any non-loopback peer. The
guest's gateway address is never loopback, so a direct guest connection
cannot serve pages; only the broker's plain-TCP tunnel from 127.0.0.1 can.
A passing run with the exact row count therefore traversed the broker.
`--no-net`, one explicit CIDR rule, and `--pull never` come from
`createArgvWithProxy` (gate `#guard`s); the password travels only by env-var
name.

Not part of the gate: needs msb, /dev/kvm, and the cached
`python:3.13-slim` image. No key, no inference, loopback only.
Run from the repository root after `lake build`:
`tests/live/broker-microvm.sh`. -/

open Lean Kalari.Model

private def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

private def verify (cond : Bool) (msg : String) : IO Unit :=
  unless cond do throw (.userError msg)

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

/-- Free loopback port via a bound-then-closed TCP socket. -/
private def freePort : IO Nat := do
  let addr ← Std.Async.Async.block (do
    let s ← Std.Async.TCP.Socket.Server.mk
    s.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
    s.listen 5
    s.getSockName)
  match addr with
  | .v4 a => pure a.port.toNat
  | .v6 _ => throw (.userError "no loopback port")

private def msbList (path : String) : IO (List Kalari.Sandbox.Microsandbox.Listed) := do
  let out ← IO.Process.output {
    cmd := "msb", args := #["list", "--format", "json"]
    env := #[("PATH", some path)] }
  unless out.exitCode == 0 do
    throw (.userError s!"msb list failed: {out.stderr}")
  match Kalari.Sandbox.Microsandbox.parseListed out.stdout with
  | .ok rows => pure rows
  | .error e => throw (.userError s!"msb list unparseable: {e}")

private def kalariNames (rows : List Kalari.Sandbox.Microsandbox.Listed) : List String :=
  rows.filterMap fun row => if row.name.startsWith "kalari-" then some row.name else none

def main : IO UInt32 := do
  try
    let toolPath := (← IO.getEnv "PATH").getD "/usr/local/bin:/usr/bin:/bin"
    IO.FS.withTempDir fun base => do
      for d in ["candidate", "baseline", "checks", "evidence"] do
        IO.FS.createDirAll (base / d)
      IO.FS.writeFile (base / "candidate" / "consumer.py")
        (← IO.FS.readFile "bench/apis/payouts/reference/correct.py")
      IO.FS.writeFile (base / "baseline" / "consumer.py")
        (← IO.FS.readFile "bench/apis/payouts/reference/v1_unchanged.py")
      -- In-guest row count: the run passes this check only when the
      -- candidate artifact holds exactly the 2431 payouts.
      IO.FS.writeFile (base / "checks" / "count.py")
        "import sys\nrows = [line for line in open(\"payouts.jsonl\") if line.strip()]\nprint(f\"rows={len(rows)}\")\nsys.exit(0 if len(rows) == 2431 else 1)\n"
      let aashaan := (← IO.FS.realPath ".lake/build/bin/kalari-aashaan").toString
      let before := kalariNames (← msbList toolPath)
      say s!"microvm brokered run: sandboxes before={before.length} keys=none loopback-only"
      let livePort ← freePort
      let observerPort ← freePort
      -- Baseline v1 API: the API under test, not wiring. No trace, v1 on.
      let live ← IO.Process.spawn {
        cmd := "python3"
        args := #["-I", "bench/apis/payouts/server.py", "--bind", "127.0.0.1",
          "--port", toString livePort, "--v1", "on"]
        stdin := .null, stdout := .piped, stderr := .inherit
        inheritEnv := false, env := #[("PATH", some "/usr/local/bin:/usr/bin:/bin")] }
      let cleanupLive : IO Unit := do
        try live.kill catch _ => pure ()
        try discard live.wait catch _ => pure ()
      try
        awaitLine live.stdout "payouts-live" "payouts listening on "
        let caps : Caps := { timeout_ms := 30000, output_cap_bytes := 65536, memory_mib := 512 }
        let alias := Kalari.Tools.Run.guestAlias
        let liveEndpoint : AllowHost := { host := alias, port := livePort }
        let observerEndpoint : AllowHost := { host := alias, port := observerPort }
        let runtime := Kalari.Tools.Run.live toolPath
        let evidence ← Kalari.Evidence.openStore (base / "evidence")
        let serverPath := (← IO.FS.realPath "bench/apis/payouts/server.py").toString
        let observer := Kalari.Tools.Run.payoutsObserver serverPath observerEndpoint
          "127.0.0.1" "127.0.0.1"
        let baseline : RunRequest := {
          workspace := (base / "baseline").toString
          command := ["python3", (base / "baseline" / "consumer.py").toString,
            "--base-url", s!"http://{alias}:{livePort}", "--out", "payouts.jsonl"]
          caps, allowlist := [liveEndpoint] }
        let ctx : Kalari.Tools.Run.Context := {
          workspace := (base / "candidate").toString
          baseline := baseline
          checkWorkspace := (base / "checks").toString
          artifact := "payouts.jsonl"
          checks := [{
            id := "row-count-2431"
            assertion := "candidate artifact holds exactly the 2431 payouts"
            command := ["python3", "count.py"] }]
          maxCaps := caps
          allowedNet := [liveEndpoint, observerEndpoint]
          secrets := []
          aashaanHost := aashaan
          evidence, sessionId := "broker-microvm"
          changeKinds := ["pagination_changed"]
          observer := some observer }
        let request : RunRequest := {
          workspace := (base / "candidate").toString
          command := ["python3", (base / "candidate" / "consumer.py").toString,
            "--base-url", s!"http://{alias}:{observerPort}", "--out", "payouts.jsonl"]
          caps, allowlist := [observerEndpoint] }
        match ← Kalari.Tools.Run.run runtime ctx request with
        | .error e => throw (.userError s!"brokered run failed: {e}")
        | .ok report =>
          verify report.passed "brokered run did not pass"
          let checks := report.checks
          let row := checks.find? (·.check_id == "row-count-2431")
          let diff := checks.find? (·.check_id == "differential-v1")
          verify (row.any (·.passed)) "row-count-2431 check did not pass: guest artifact is not exactly 2431 rows"
          verify (diff.any (·.passed)) "differential-v1 check did not pass"
          verify (report.verdict.verdict == "exited" && report.verdict.exit_code == some 0)
            "brokered run verdict is not a clean exit"
          say s!"microvm brokered run: passed=true verdict=exited exit=0 row-count-2431=pass differential-v1=pass"
          say s!"microvm brokered run: run_id={report.run_id} (sandbox removed by the runtime)"
        -- Fail-closed control: without a broker the same observed run must
        -- refuse with the isolation message before any sandbox action.
        let noBroker := { runtime with
          startBroker := fun _ => pure (.error "no broker") }
        match ← Kalari.Tools.Run.run noBroker ctx request with
        | .error e =>
          verify (e == Kalari.Tools.Run.isolationMessage)
            s!"brokerless run refused without the isolation message: {e}"
          say "microvm brokered run: brokerless control refused with the isolation message"
        | .ok _ => throw (.userError "brokerless run was not refused")
        let after := kalariNames (← msbList toolPath)
        let leaked := after.filter (!before.contains ·)
        verify leaked.isEmpty s!"sandbox(s) remain: {leaked}"
        say "microvm brokered run: msb list clean, no kalari- sandbox remains"
      finally
        cleanupLive
    say "broker microvm: PASS one real microVM run through the Lean broker, 2431 rows, fail-closed without it"
    return 0
  catch e =>
    IO.eprintln s!"broker microvm: {e}"
    return 1
