import Kalari.Mcp
import Kalari.Config
import Kalari.Tools.Changes
import Kalari.Tools.Recall
import Kalari.Tools.Run
import Kalari.Tools.Lesson

open Lean Kalari.Model
namespace Kalari.Service

/-- A host-owned payouts observer. The endpoint name is the guest-visible msb
gateway alias. The service reads the real guest network from the runtime. -/
structure ObserverSetup where
  server : String
  endpoint : AllowHost
  deriving FromJson

/-- Operator-owned setup, read at process startup and never from MCP arguments. -/
structure Setup where
  session_id : String
  repo_scope : String
  workspace : String
  old_spec : String
  new_spec : String
  baseline : RunRequest
  check_workspace : String
  evidence_workspace : String
  artifact : String
  aashaan : String
  tool_path : Option String := none
  observer : Option ObserverSetup := none
  deriving FromJson

private def validName (s : String) : Bool :=
  !s.isEmpty && s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

private def validArtifact (s : String) : Bool :=
  validName s && s != "." && s != ".." && !s.startsWith "." &&
    s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

/-- Harness validation. Only the live-test entry point calls this. Production
`validate` refuses every observer before these checks run. -/
private def validateHarness (cfg : Kalari.Config.Config) (s : Setup) : IO Unit := do
  if let some path := s.tool_path then
    unless (path.splitOn ":").all (fun p => Kalari.Gate.workspaceOk p && !p.contains '\x00') do
      throw <| .userError "tool_path must contain only absolute normalized directories"
  if let some observer := s.observer then
    unless observer.endpoint.host == Kalari.Tools.Run.guestAlias &&
        observer.endpoint.port > 0 && observer.endpoint.port <= 65535 &&
        Kalari.Gate.workspaceOk observer.server &&
        !observer.server.contains '\x00' do
      throw <| .userError Kalari.Tools.Run.isolationMessage
    unless cfg.sandbox.allowlist.contains observer.endpoint do
      throw <| .userError "observer endpoint must be in the sandbox allowlist"
  unless validName s.session_id && !s.repo_scope.isEmpty do throw <| .userError "invalid session identity"
  unless [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace, s.aashaan, s.old_spec, s.new_spec].all Kalari.Gate.workspaceOk do
    throw <| .userError "session paths must be absolute and normalized"
  unless s.workspace != s.baseline.workspace && s.workspace != s.check_workspace &&
      s.baseline.workspace != s.check_workspace && validArtifact s.artifact &&
      s.artifact != Kalari.Tools.Run.trustedTruthArtifactName do
    throw <| .userError "invalid session workspace or artifact"
  unless cfg.sandbox.backend == "microsandbox" && cfg.decisions.endpoint == Kalari.Clef.endpoint &&
      cfg.decisions.model == Kalari.Clef.modelName && !cfg.lambo.command.isEmpty && !cfg.lambo.config_path.isEmpty do
    throw <| .userError "unsupported backend or decision configuration"
  unless cfg.sandbox.caps.timeout_ms > 0 && cfg.sandbox.caps.output_cap_bytes > 0 && cfg.sandbox.caps.memory_mib > 0 &&
      Kalari.Gate.capsOk s.baseline.caps cfg.sandbox.caps && Kalari.Gate.netOk s.baseline.allowlist cfg.sandbox.allowlist &&
      !s.baseline.command.isEmpty && !(s.baseline.command.headD "").isEmpty &&
      s.baseline.caps.timeout_ms > 0 && s.baseline.caps.output_cap_bytes > 0 && s.baseline.caps.memory_mib > 0 &&
      Kalari.Gate.commandInside s.baseline.workspace s.baseline.command &&
      !(s.baseline.workspace :: s.baseline.command).any (·.contains '\x00') do
    throw <| .userError "invalid baseline or caps"
  let observerFiles := s.observer.toList.map (·.server)
  let filePaths := [s.aashaan, s.old_spec, s.new_spec] ++ observerFiles
  for path in [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace] ++ filePaths do
    unless ← (System.FilePath.mk path).pathExists do throw <| .userError "session path does not exist"
    let resolved ← IO.FS.realPath (System.FilePath.mk path)
    unless resolved.toString == path do throw <| .userError "session path must be canonical"
  for path in [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace] do
    unless ← (System.FilePath.mk path).isDir do throw <| .userError "session workspace must be a directory"
  for path in filePaths do
    if ← (System.FilePath.mk path).isDir then
      throw <| .userError "session executable and specs must be files"
  let roots := [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace]
  unless roots.eraseDups.length == roots.length do
    throw <| .userError "session workspaces must be distinct"
  for root in roots do
    for other in roots do
      if root != other && Kalari.Gate.insideWorkspace root other then
        throw <| .userError "session workspaces must not overlap"

/-- Production validation. The service accepts no observer. The msb gateway
makes every sandbox request look like loopback, so the runtime cannot prove an
exclusive guest source. `serve` calls only this function. -/
private def validate (cfg : Kalari.Config.Config) (s : Setup) : IO Unit := do
  if s.observer.isSome then throw <| .userError Kalari.Tools.Run.isolationMessage
  validateHarness cfg s

structure Dependencies where
  vimanam : Kalari.Vimanam.Runner
  search : Kalari.Search.Runner
  confirm : Kalari.Search.Confirmer
  writeChange : Kalari.Tools.Changes.ScopedWrite
  source : Kalari.Tools.Recall.Sources
  runtime : Kalari.Tools.Run.Runtime
  classify : IO.Ref (Option Kalari.Tools.Changes.Session) → Kalari.Tools.Lesson.Classify
  writer : Kalari.Tools.Lesson.Write
  evidence : Kalari.Evidence.Store
  secrets : List String

def dispatcher (cfg : Kalari.Config.Config) (setup : Setup) (deps : Dependencies) : IO Kalari.Mcp.Handler := do
  let changes ← IO.mkRef (none : Option Kalari.Tools.Changes.Session)
  let source := deps.source
  let evidence := deps.evidence
  let secrets := deps.secrets
  let writer := deps.writer
  let observer := setup.observer.map fun item =>
    Kalari.Tools.Run.payoutsObserver item.server item.endpoint "127.0.0.1" "127.0.0.1"
  return fun name args => do
    match name with
    | "what_changed" =>
      let old ← IO.ofExcept (args.getObjValAs? String "old_spec")
      let new ← IO.ofExcept (args.getObjValAs? String "new_spec")
      if old != setup.old_spec || new != setup.new_spec then return .error "specs do not match trusted session"
      match ← Kalari.Tools.Changes.whatChanged deps.vimanam old new with
      | .error e => return .error e
      | .ok (session, out) => changes.set (some session); return .ok out.compress
    | "blast_radius" =>
      let some session ← changes.get | return .error "call what_changed first"
      let ids ← IO.ofExcept (args.getObjValAs? (List String) "change_ids")
      return (← Kalari.Tools.Changes.blastRadius session deps.search
        deps.confirm
        deps.writeChange setup.repo_scope setup.workspace ids).map Json.compress
    | "recall_lessons" =>
      let kinds ← IO.ofExcept (args.getObjValAs? (List String) "change_kinds")
      return .ok (toJson (← Kalari.Tools.Recall.call source kinds)).compress
    | "run_in_sandbox" =>
      let some session ← changes.get | return .error "call what_changed first"
      let kinds := (session.changes.map (·.fact.kind)).eraseDups
      let entries ← Kalari.Tools.Recall.call source kinds
      let checks := entries.filterMap fun e => if e.status == "required" then some e.lesson.check else none
      let ctx : Kalari.Tools.Run.Context := {
        workspace := setup.workspace
        baseline := setup.baseline
        checkWorkspace := setup.check_workspace
        artifact := setup.artifact
        checks := checks
        maxCaps := cfg.sandbox.caps
        allowedNet := cfg.sandbox.allowlist
        secrets := secrets
        image := cfg.sandbox.image
        aashaanHost := setup.aashaan
        evidence := evidence
        sessionId := setup.session_id
        changeKinds := kinds
        observer
      }
      let ctx ← Kalari.Tools.Lesson.attachLessonBootstrapChecks ctx
      -- An observed run reaches only the trusted observer. Replace the
      -- model-supplied allowlist rather than trusting it or rejecting it.
      let args ← match setup.observer with
        | none => pure args
        | some item =>
          match fromJson? (α := RunRequest) args with
          | .error _ => pure args
          | .ok request => pure (toJson { request with allowlist := [item.endpoint] })
      Kalari.Tools.Run.call deps.runtime ctx args
    | "record_lesson" =>
      let runId ← IO.ofExcept (args.getObjValAs? String "run_id")
      -- Bind the run record's candidate truth check to the session artifact
      -- before any lesson is written to the memory graph.
      let loaded ← Kalari.Evidence.load evidence
      let runs := loaded.records.filter fun r =>
        r.kind == "run" && r.session_id == setup.session_id && r.run_id == runId
      let run ← match runs with
        | [entry] =>
          match fromJson? entry.payload with
          | .error error => return .error error
          | .ok (record : RunRecord) => pure record
        | _ => return .error s!"expected one run record for {runId}"
      match Kalari.Tools.Run.verifyCandidateTruthArtifact run setup.artifact with
      | .error error => return .error error
      | .ok () => pure ()
      let classify := deps.classify changes
      return (← Kalari.Tools.Lesson.record evidence setup.session_id runId setup.artifact classify writer).map fun x => (toJson x).compress
    | _ => return .error "unknown tool"

def withLamboCleanup (client : Kalari.Lambo.Client) (action : IO α) : IO α := do
  try action
  finally Kalari.Lambo.shutdown client

def serveWithLamboCleanup (client : Kalari.Lambo.Client) (handler : Kalari.Mcp.Handler)
    (input output : IO.FS.Stream) : IO Unit :=
  withLamboCleanup client (Kalari.Mcp.serve handler input output)

/-- Serve one session sequentially, with a single Lambo child and writer.
`clefCall` runs before each Clef transport attempt, so the harness can count
model calls. Production passes the default no-op. -/
private def runLive (cfg : Kalari.Config.Config) (setup : Setup)
    (clefCall : IO Unit := pure ()) (clefRedirect : Option String := none) : IO Unit := do
  let evidence ← Kalari.Evidence.openStore setup.evidence_workspace
  IO.ofExcept (← Kalari.Tools.Lesson.verifyAmendedPolicyProvenance evidence setup.session_id setup.check_workspace)
  let client ← Kalari.Lambo.create cfg.lambo
  let writer ← Kalari.Tools.Lesson.writer client
  let path := setup.tool_path.getD "/usr/local/bin:/usr/bin:/bin"
  let rawClef := Kalari.Clef.live path
  let clef : Kalari.Clef.Runner := fun argv stdin timeout cap => do
    clefCall
    -- The harness can point the decision client at a local fake. Production
    -- leaves the endpoint alone and never sets this override.
    let argv := match clefRedirect with
      | some url => argv.map fun arg => if arg == Kalari.Clef.endpoint then url else arg
      | none => argv
    rawClef argv stdin timeout cap
  let delay : Kalari.Clef.Delay := fun ms => IO.sleep ms.toUInt32
  let source := Kalari.Tools.Recall.sources client evidence clef delay cfg.decisions.api_key_env
  let secrets := (← [cfg.models.api_key_env, cfg.decisions.api_key_env].mapM (fun n => (IO.getEnv n : IO (Option String)))).filterMap id
  let deps : Dependencies := {
    vimanam := Kalari.Vimanam.live path
    search := Kalari.Search.live path
    confirm := Kalari.Search.clefConfirmer clef delay cfg.decisions.api_key_env
    writeChange := Kalari.Tools.Changes.resourceWriter client
    source, runtime := Kalari.Tools.Run.live path
    classify := fun changes => Kalari.Tools.Lesson.clefClassifier clef delay cfg.decisions.api_key_env fun _ => do
      let some session ← changes.get | return .error "call what_changed first"
      return .ok (session.context, "")
    writer, evidence, secrets
  }
  let handler ← dispatcher cfg setup deps
  serveWithLamboCleanup client handler (← IO.getStdin) (← IO.getStdout)

/-- Serve one session sequentially. Production refuses every observer. -/
def serve (configPath setupPath : System.FilePath) : IO Unit := do
  let cfg ← Kalari.Config.load configPath
  let setupJson ← IO.ofExcept (Json.parse (← IO.FS.readFile setupPath))
  let setup ← match fromJson? (α := Setup) setupJson with
    | .ok setup => pure setup
    | .error error =>
      -- An observer that cannot be read is not a configuration this service
      -- can prove. Keep the same refusal as an unproven guest source.
      if (setupJson.getObjVal? "observer").isOk then
        throw <| .userError Kalari.Tools.Run.isolationMessage
      throw <| .userError error
  validate cfg setup
  runLive cfg setup

/-- Live-test entry point for the observer rehearsal. `kalari serve` never
calls this. It runs the same dispatcher with an observer setup that production
refuses, and writes the measured Clef calls to `KALARI_HARNESS_COUNT_FILE`.
The caller must set `KALARI_OBSERVER_HARNESS=1`. -/
def harness (configPath setupPath : System.FilePath) : IO Unit := do
  unless (← IO.getEnv "KALARI_OBSERVER_HARNESS") == some "1" do
    throw <| .userError "observer harness is a live-test entry point, not the service"
  let calls ← IO.mkRef 0
  try
    let cfg ← Kalari.Config.load configPath
    let setupJson ← IO.ofExcept (Json.parse (← IO.FS.readFile setupPath))
    let setup ← match fromJson? (α := Setup) setupJson with
      | .ok setup => pure setup
      | .error error => throw <| .userError error
    validateHarness cfg setup
    let redirect ← IO.getEnv "KALARI_HARNESS_DECISIONS_URL"
    runLive cfg setup (calls.modify (· + 1)) redirect
  finally
    let count ← calls.get
    match ← IO.getEnv "KALARI_HARNESS_COUNT_FILE" with
    | some path => IO.FS.writeFile path s!"model_calls={count}\n"
    | none => IO.eprintln s!"observer harness: model_calls={count}"

/-- Offline executable fixture. All external effects are replaced by local data. -/
def fixture : IO Unit := IO.FS.withTempDir fun dir => do
  let caps : Caps := { timeout_ms := 1000, output_cap_bytes := 4096, memory_mib := 128 }
  let allow := [{ host := "api.example.test", port := 18080 }]
  let request : RunRequest := { workspace := "/candidate", command := ["python3", "/candidate/correct.py"], caps, allowlist := allow }
  let endpoint : Kalari.Config.Endpoint := { endpoint := "fixture", model := "fixture", api_key_env := "FIXTURE" }
  let decisionEndpoint : Kalari.Config.Endpoint := { endpoint := Kalari.Clef.endpoint, model := Kalari.Clef.modelName, api_key_env := "FIXTURE" }
  let cfg : Kalari.Config.Config := { models := endpoint, decisions := decisionEndpoint, sandbox := { backend := "microsandbox", image := Kalari.Sandbox.Microsandbox.imageName, caps, allowlist := allow }, lambo := { command := ["fixture"], config_path := "fixture" } }
  let setup : Setup := { session_id := "fixture", repo_scope := "fixture", workspace := "/candidate", old_spec := "old", new_spec := "new", baseline := { request with workspace := "/baseline", command := ["python3", "/baseline/v1_unchanged.py"] }, check_workspace := (dir / "checks").toString, evidence_workspace := dir.toString, artifact := "payouts.jsonl", aashaan := "/trusted/aashaan" }
  let evidence ← Kalari.Evidence.openStore dir
  let pidPath := dir / "fake-lambo.pid"
  let logPath := dir / "fake-lambo.log"
  let fakeLambo := "import json,os,sys; open(sys.argv[1],'w').write(str(os.getpid()));\n" ++
    "for line in sys.stdin:\n" ++
    " m=json.loads(line); method=m.get('params',{}).get('name',m.get('method')); open(sys.argv[2],'a').write(method+'\\n');\n" ++
    " if 'id' not in m: continue\n" ++
    " result={'structuredContent':{'receipt':'fixture-receipt'}} if method=='lambo_derive' else ({'structuredContent':{'receipt':{'id':'fixture-receipt','state':'applied','created':['12345678-1234-1234-1234-123456789abc'],'matched':[]}}} if method=='lambo_stats' else {})\n" ++
    " print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}),flush=True)\n"
  let lamboConfig : Kalari.Config.Lambo := { command := ["python3", "-c", fakeLambo, pidPath.toString, logPath.toString], config_path := "fixture.toml" }
  let lamboChild ← Kalari.Lambo.create lamboConfig
  let writer ← Kalari.Tools.Lesson.writer lamboChild
  let source : Kalari.Tools.Recall.Sources := { linked := fun _ => pure [], semantic := fun _ => pure [], resolve := fun _ => pure (.error "missing"), applies := fun _ _ => pure (.error "missing") }
  let truth := String.join ((List.range 2431).map fun i => (Json.mkObj [("id", toJson s!"P{i}"), ("amount", toJson (100 + i))]).compress ++ "\n")
  let calls ← IO.mkRef ([] : List String)
  let tampered ← IO.mkRef false
  let existsRef ← IO.mkRef false
  let base := Kalari.Tools.Run.fixtureRuntime calls "correct" caps truth "" tampered existsRef
  let fixtureRunRuntime : Kalari.Tools.Run.Runtime := { base with runner := fun argv timeout output => do
    let argv := match argv with
      | ["msb", "copy", "-q", host, guest] =>
        if host == setup.check_workspace then ["msb", "copy", "-q", "/checks", guest] else argv
      | "msb" :: "exec" :: name :: "--" :: cmd =>
        if name.contains "-check-" && cmd.head? == some "/usr/local/bin/kalari-aashaan" then
          ["msb", "exec", name, "--"] ++ (cmd.take 8 ++ ["lesson.py"])
        else argv
      | _ => argv
    base.runner argv timeout output }
  let deps : Dependencies := {
    vimanam := fun _ _ _ => pure { exitCode := some 0, stdout := (include_str "../testdata/vimanam/2.1.0/payouts.json").toUTF8, stderr := .empty, wallMs := 0, cap := .none }
    search := fun _ _ _ => pure { exitCode := some 1, stdout := .empty, stderr := .empty, wallMs := 0, cap := .none }
    confirm := fun _ _ => pure (.ok [])
    writeChange := fun _ _ _ => pure (.ok "fixture")
    source
    runtime := fixtureRunRuntime,
    classify := fun _ _ _ => pure (.ok (.label "api_change" [] 0.8))
    writer, evidence, secrets := [] }
  let handler ← dispatcher cfg setup deps

  -- Independently check the admission validator against trusted filesystem
  -- objects and each reported startup failure category.
  let roots := ["candidate", "baseline", "checks", "evidence"]
  for root in roots do IO.FS.createDirAll (dir / root)
  let executable := dir / "aashaan"
  let oldSpec := dir / "old.yaml"
  let newSpec := dir / "new.yaml"
  for path in [executable, oldSpec, newSpec] do IO.FS.writeFile path "fixture"
  let validSetup : Setup := { setup with
    session_id := "fixture"
    workspace := (dir / "candidate").toString
    baseline := { request with workspace := (dir / "baseline").toString, command := ["true"] }
    check_workspace := (dir / "checks").toString
    evidence_workspace := (dir / "evidence").toString
    aashaan := executable.toString
    old_spec := oldSpec.toString
    new_spec := newSpec.toString }
  validate cfg validSetup
  validate cfg { validSetup with tool_path := some "/opt/kalari/bin:/usr/bin:/bin" }
  let rejects (candidate : Setup) : IO Bool := do
    try validate cfg candidate; pure false catch _ => pure true
  unless ← rejects { validSetup with tool_path := some "/usr/bin::/bin" } do throw <| .userError "empty tool path component accepted"
  unless ← rejects { validSetup with tool_path := some "relative:/bin" } do throw <| .userError "relative tool path component accepted"
  unless ← rejects { validSetup with artifact := ".hidden" } do throw <| .userError "dot artifact accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with command := [""] } } do throw <| .userError "empty baseline executable accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with command := ["true\x00bad"] } } do throw <| .userError "NUL baseline argument accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with caps := { validSetup.baseline.caps with timeout_ms := 0 } } } do throw <| .userError "zero baseline timeout accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with caps := { validSetup.baseline.caps with memory_mib := caps.memory_mib + 1 } } } do throw <| .userError "baseline memory cap above trusted maximum accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with command := ["python3", "/etc/passwd"] } } do throw <| .userError "absolute baseline command outside its workspace accepted"
  unless ← rejects { validSetup with workspace := oldSpec.toString } do throw <| .userError "file accepted as workspace"
  unless ← rejects { validSetup with old_spec := (dir / "candidate").toString } do throw <| .userError "directory accepted as spec"
  unless ← rejects { validSetup with evidence_workspace := validSetup.workspace } do throw <| .userError "overlapping roots accepted"
  -- Production validation refuses every observer, including a fully formed one.
  -- The harness validation is the only path that accepts it, and it still
  -- rejects a caller-supplied address, a missing server and an unlisted endpoint.
  let observerEndpoint : AllowHost := { host := Kalari.Tools.Run.guestAlias, port := 18080 }
  let observerCfg := { cfg with sandbox := { cfg.sandbox with allowlist := allow ++ [observerEndpoint] } }
  let observerSetup := { validSetup with observer := some { server := executable.toString, endpoint := observerEndpoint } }
  unless ← rejects observerSetup do throw <| .userError "production validate accepted an observer"
  validateHarness observerCfg observerSetup
  let rejectsHarness (candidate : Setup) : IO Bool := do
    try validateHarness observerCfg candidate; pure false catch _ => pure true
  unless ← rejectsHarness { observerSetup with observer := some {
      server := executable.toString, endpoint := { observerEndpoint with host := "127.0.0.1" } } } do
    throw <| .userError "harness accepted a caller-supplied guest address"
  unless ← rejectsHarness { observerSetup with observer := some {
      server := (dir / "missing-server").toString, endpoint := observerEndpoint } } do
    throw <| .userError "harness accepted a missing observer server"
  let unlisted : AllowHost := { host := Kalari.Tools.Run.guestAlias, port := 18081 }
  unless ← rejectsHarness { observerSetup with observer := some {
      server := executable.toString, endpoint := unlisted } } do
    throw <| .userError "harness accepted an observer endpoint outside the sandbox allowlist"

  -- Exercise the actual dispatcher with a successful Run, then record a lesson
  -- from the evidence produced by that Run through the same shared writer.
  let changed ← handler "what_changed" (Json.mkObj [("old_spec", "old"), ("new_spec", "new")])
  unless changed.isOk do throw <| .userError "fixture what_changed failed"
  let runArgs := toJson request
  let runResponse ← handler "run_in_sandbox" runArgs
  let .ok runText := runResponse | throw <| .userError "fixture successful Run returned an error"
  let runJson ← IO.ofExcept (Json.parse runText)
  unless (runJson.getObjValAs? Bool "passed").toOption == some true do throw <| .userError s!"fixture Run did not pass: {runJson.compress}"
  let runId ← IO.ofExcept (runJson.getObjValAs? String "run_id")
  let _ ← IO.ofExcept (← Kalari.Tools.Lesson.verifyAmendedPolicyProvenance evidence setup.session_id setup.check_workspace)
  let pageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := setup.session_id, run_id := runId, change_kinds := ["pagination_changed"], payload := toJson ({ source := "payouts-api", behaviors := ["boundary_overlap_one", "final_page_token"] } : Kalari.Tools.Lesson.PageObservation) }
  Kalari.Evidence.append evidence pageRecord
  let lessonResponse ← handler "record_lesson" (Json.mkObj [("run_id", runId)])
  let .ok _ := lessonResponse | throw <| .userError "fixture successful Lesson returned an error"
  let records ← Kalari.Evidence.load evidence
  unless records.records.any (fun r => r.kind == "run" && r.run_id == runId) &&
      records.records.any (fun r => r.kind == "lesson" && r.run_id == runId) do
    throw <| .userError "Run and Lesson did not share the evidence store"

  -- A run record with a candidate truth check for another artifact cannot
  -- publish a lesson.
  let runEntry ← match records.records.find? (fun r =>
      r.kind == "run" && r.session_id == setup.session_id && r.run_id == runId) with
    | some entry => pure entry
    | none => throw <| .userError "fixture run record missing"
  let runRecord : RunRecord ← IO.ofExcept (fromJson? runEntry.payload)
  let truthCheck ← match runRecord.checks.find? (fun check =>
      check.command.length == 4 &&
      check.command[3]? == some Kalari.Tools.Run.trustedTruthArtifactName) with
    | some check => pure check
    | none => throw <| .userError "fixture candidate truth check missing"
  let forgedCheck := { truthCheck with command :=
    ["python3", "kalari_candidate_truth_check.py", "other.jsonl", Kalari.Tools.Run.trustedTruthArtifactName] }
  let forgedRun : RunRecord := { runRecord with
    checks := [forgedCheck]
    check_results := [
      { check_id := forgedCheck.id, passed := true },
      { check_id := "differential-v1", passed := true }] }
  let forgedRunRecord : Kalari.Evidence.Record := {
    kind := "run", session_id := setup.session_id, run_id := "forged-artifact",
    change_kinds := ["pagination_changed"], payload := toJson forgedRun }
  Kalari.Evidence.append evidence forgedRunRecord
  let forgedPage : Kalari.Evidence.Record := {
    kind := "page-observation", session_id := setup.session_id, run_id := "forged-artifact",
    change_kinds := ["pagination_changed"],
    payload := toJson ({ source := "payouts-api", behaviors := ["final_page_token"] } : Kalari.Tools.Lesson.PageObservation) }
  Kalari.Evidence.append evidence forgedPage
  let forgedResponse ← handler "record_lesson" (Json.mkObj [("run_id", "forged-artifact")])
  unless (match forgedResponse with | .error _ => true | .ok _ => false) do
    throw <| .userError "a run record with another artifact published a lesson"
  unless !((← Kalari.Evidence.load evidence).records.any fun r =>
      r.kind == "lesson" && r.run_id == "forged-artifact") do
    throw <| .userError "a forged artifact run wrote lesson evidence"

  -- A model-supplied allowlist cannot redirect an observed run. The dispatcher
  -- replaces it with the trusted observer endpoint before the run starts.
  let redirEndpoint : AllowHost := { host := Kalari.Tools.Run.guestAlias, port := 18081 }
  let redirCfg := { cfg with sandbox := { cfg.sandbox with allowlist := allow ++ [redirEndpoint] } }
  let redirSetup := { validSetup with observer := some { server := executable.toString, endpoint := redirEndpoint } }
  validateHarness redirCfg redirSetup
  let seenCalls ← IO.mkRef ([] : List (List String))
  let redirRuntime : Kalari.Tools.Run.Runtime := {
    runner := fun argv _ _ => do
      seenCalls.modify (· ++ [argv])
      pure ({ exitCode := some 0, stdout := ByteArray.empty, stderr := ByteArray.empty, wallMs := 0, cap := .none } : Kalari.Proc.Result)
    resolve := fun _ => pure ["203.0.113.10"]
    wait := fun _ => pure ()
    network := fun _ => pure (.error "unavailable") }
  let redirHandler ← dispatcher redirCfg redirSetup { deps with runtime := redirRuntime }
  let redirChanged ← redirHandler "what_changed"
    (Json.mkObj [("old_spec", validSetup.old_spec), ("new_spec", validSetup.new_spec)])
  unless redirChanged.isOk do throw <| .userError "redirect fixture what_changed failed"
  let evil : List AllowHost := [{ host := "evil.example.test", port := 18082 }]
  let redirectRequest : RunRequest := { request with
    workspace := validSetup.workspace,
    command := ["python3", validSetup.workspace ++ "/correct.py"],
    allowlist := evil }
  let redirectResponse ← redirHandler "run_in_sandbox" (toJson redirectRequest)
  unless (match redirectResponse with | .error e => e == Kalari.Tools.Run.isolationMessage | .ok _ => false) do
    throw <| .userError "dispatcher accepted a model-supplied allowlist"
  let seen ← seenCalls.get
  match seen.find? (fun argv => argv[1]? == some "create") with
  | none => throw <| .userError "dispatcher did not create an observed sandbox"
  | some argv =>
    unless argv.any (fun arg => arg == s!"allow@{Kalari.Tools.Run.guestCidr}:tcp:{redirEndpoint.port}") do
      throw <| .userError "dispatcher did not use the trusted observer endpoint"
    unless !argv.any (fun arg => arg.contains "evil" || arg.contains "18082") do
      throw <| .userError "dispatcher passed the model allowlist to msb"

  let latestRun ← IO.mkRef (none : Option String)
  let stdioHandler : Kalari.Mcp.Handler := fun name args => do
    if name == "record_lesson" && (args.getObjValAs? String "run_id").toOption == some "latest" then
      match ← latestRun.get with
      | some id => handler name (Json.mkObj [("run_id", id)])
      | none => pure (.error "no fixture run")
    else if name == "run_in_sandbox" then
      let result ← handler name args
      if let .ok text := result then
        if let .ok json := Json.parse text then
          if (json.getObjValAs? Bool "passed").toOption == some true then
            if let .ok id := json.getObjValAs? String "run_id" then do
              latestRun.set (some id)
              let pageRecord : Kalari.Evidence.Record := { kind := "page-observation", session_id := setup.session_id, run_id := id, change_kinds := ["pagination_changed"], payload := toJson ({ source := "payouts-api", behaviors := ["boundary_overlap_one", "final_page_token"] } : Kalari.Tools.Lesson.PageObservation) }
              Kalari.Evidence.append evidence pageRecord
      return result
    else handler name args

  serveWithLamboCleanup lamboChild stdioHandler (← IO.getStdin) (← IO.getStdout)
  let pid ← IO.FS.readFile pidPath
  let alive ← IO.Process.output { cmd := "/bin/kill", args := #["-0", pid.trimAscii.toString] }
  unless alive.exitCode != 0 do throw <| .userError "service EOF did not reap its fake Lambo child"
  let childLog ← IO.FS.readFile logPath
  unless childLog.contains "lambo_derive" && childLog.contains "lambo_stats" do
    throw <| .userError "service lifecycle fixture did not exercise its shared Lambo child"
  let errorChild ← Kalari.Lambo.create lamboConfig
  let errorReceipt ← Kalari.Lambo.derive errorChild "observation" "cleanup on service error"
  let _ ← Kalari.Lambo.awaitReceipt errorChild errorReceipt
  let failedService ← try
      withLamboCleanup errorChild (throw <| IO.userError "fixture service error")
      pure false
    catch _ => pure true
  unless failedService do throw <| .userError "fixture service error was swallowed"
  let errorPid ← IO.FS.readFile pidPath
  let errorChildAlive ← IO.Process.output { cmd := "/bin/kill", args := #["-0", errorPid.trimAscii.toString] }
  unless errorChildAlive.exitCode != 0 do throw <| .userError "service error did not reap its fake Lambo child"

/-- Gate test: the dispatcher replaces a model-supplied allowlist with the
trusted observer endpoint before the runtime sees it. -/
private def dispatcherAllowlistTest : IO Unit := IO.FS.withTempDir fun dir => do
  let caps : Caps := { timeout_ms := 1000, output_cap_bytes := 4096, memory_mib := 128 }
  let allow : List AllowHost := [{ host := "api.example.test", port := 18080 }]
  let observerEndpoint : AllowHost := { host := Kalari.Tools.Run.guestAlias, port := 18081 }
  let workspace := (dir / "candidate").toString
  let request : RunRequest := {
    workspace, command := ["python3", workspace ++ "/correct.py"], caps, allowlist := allow }
  let endpoint : Kalari.Config.Endpoint := { endpoint := "fixture", model := "fixture", api_key_env := "FIXTURE" }
  let decisionEndpoint : Kalari.Config.Endpoint := {
    endpoint := Kalari.Clef.endpoint, model := Kalari.Clef.modelName, api_key_env := "FIXTURE" }
  let sandbox : Kalari.Config.Sandbox := { backend := "microsandbox", image := Kalari.Sandbox.Microsandbox.imageName, caps, allowlist := allow ++ [observerEndpoint] }
  let lambo : Kalari.Config.Lambo := { command := ["fixture"], config_path := "fixture" }
  let cfg : Kalari.Config.Config := { models := endpoint, decisions := decisionEndpoint, sandbox, lambo }
  for name in ["candidate", "baseline", "checks", "evidence"] do IO.FS.createDirAll (dir / name)
  let executable := dir / "aashaan"
  let oldSpec := dir / "old.yaml"
  let newSpec := dir / "new.yaml"
  let observerServer := dir / "server.py"
  for path in [executable, oldSpec, newSpec, observerServer] do IO.FS.writeFile path "fixture"
  let baseline : RunRequest := { request with workspace := (dir / "baseline").toString, command := ["true"] }
  let observer : ObserverSetup := { server := observerServer.toString, endpoint := observerEndpoint }
  let setup : Setup := { session_id := "redirect", repo_scope := "fixture", workspace, old_spec := oldSpec.toString, new_spec := newSpec.toString, baseline, check_workspace := (dir / "checks").toString, evidence_workspace := (dir / "evidence").toString, artifact := "payouts.jsonl", aashaan := executable.toString, observer := some observer }
  let evidence ← Kalari.Evidence.openStore dir
  let seen ← IO.mkRef ([] : List (List String))
  let runtime : Kalari.Tools.Run.Runtime := {
    runner := fun argv _ _ => do
      seen.modify (· ++ [argv])
      pure ({ exitCode := some 0, stdout := ByteArray.empty, stderr := ByteArray.empty, wallMs := 0, cap := .none } : Kalari.Proc.Result)
    resolve := fun _ => pure ["203.0.113.10"]
    wait := fun _ => pure ()
    network := fun _ => pure (.error "unavailable") }
  let writer : Kalari.Tools.Lesson.Write := {
    perform := fun _ _ _ => pure (.ok "fixture-id"), lane := ← Std.Mutex.new () }
  let deps : Dependencies := {
    vimanam := fun _ _ _ => pure ({ exitCode := some 0, stdout := (include_str "../testdata/vimanam/2.1.0/payouts.json").toUTF8, stderr := .empty, wallMs := 0, cap := .none } : Kalari.Proc.Result)
    search := fun _ _ _ => pure ({ exitCode := some 1, stdout := .empty, stderr := .empty, wallMs := 0, cap := .none } : Kalari.Proc.Result)
    confirm := fun _ _ => pure (.ok [])
    writeChange := fun _ _ _ => pure (.ok "fixture")
    source := { linked := fun _ => pure [], semantic := fun _ => pure [], resolve := fun _ => pure (.error "missing"), applies := fun _ _ => pure (.error "missing") }
    runtime
    classify := fun _ _ _ => pure (.ok (.label "api_change" [] 0.8))
    writer, evidence, secrets := [] }
  validateHarness cfg setup
  unless (← (try validate cfg setup; pure false catch _ => pure true)) do
    throw <| .userError "production validate accepted the observer setup"
  let handler ← dispatcher cfg setup deps
  let changed ← handler "what_changed" (Json.mkObj [("old_spec", oldSpec.toString), ("new_spec", newSpec.toString)])
  unless changed.isOk do throw <| .userError "dispatcher redirect test what_changed failed"
  let evil : List AllowHost := [{ host := "evil.example.test", port := 18082 }]
  let response ← handler "run_in_sandbox" (toJson { request with allowlist := evil })
  unless (match response with | .error e => e == Kalari.Tools.Run.isolationMessage | .ok _ => false) do
    throw <| .userError "dispatcher redirect test did not reach the runtime"
  let calls ← seen.get
  let some create := calls.find? (fun argv => argv[1]? == some "create")
    | throw <| .userError "dispatcher redirect test did not create a sandbox"
  unless create.any (fun arg => arg == s!"allow@{Kalari.Tools.Run.guestCidr}:tcp:{observerEndpoint.port}") do
    throw <| .userError "dispatcher redirect test did not use the trusted endpoint"
  unless !create.any (fun arg => arg.contains "evil" || arg.contains "18082") do
    throw <| .userError "dispatcher redirect test passed the model allowlist"
  IO.println "service dispatcher: production refuses the observer and a model allowlist cannot replace the trusted endpoint"

#eval dispatcherAllowlistTest

end Kalari.Service
