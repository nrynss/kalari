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

private def validate (cfg : Kalari.Config.Config) (s : Setup) : IO Unit := do
  if let some path := s.tool_path then
    unless (path.splitOn ":").all (fun p => Kalari.Gate.workspaceOk p && !p.contains '\x00') do
      throw <| .userError "tool_path must contain only absolute normalized directories"
  if let some observer := s.observer then
    unless observer.endpoint.host == Kalari.Tools.Run.guestAlias &&
        observer.endpoint.port > 0 && observer.endpoint.port <= 65535 &&
        Kalari.Gate.workspaceOk observer.server &&
        !observer.server.contains '\x00' do
      throw <| .userError "observer requires verified exclusive guest source isolation"
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
      let classify := deps.classify changes
      return (← Kalari.Tools.Lesson.record evidence setup.session_id runId classify writer).map fun x => (toJson x).compress
    | _ => return .error "unknown tool"

def withLamboCleanup (client : Kalari.Lambo.Client) (action : IO α) : IO α := do
  try action
  finally Kalari.Lambo.shutdown client

def serveWithLamboCleanup (client : Kalari.Lambo.Client) (handler : Kalari.Mcp.Handler)
    (input output : IO.FS.Stream) : IO Unit :=
  withLamboCleanup client (Kalari.Mcp.serve handler input output)

/-- Serve one session sequentially, with a single Lambo child and writer. -/
def serve (configPath setupPath : System.FilePath) : IO Unit := do
  let cfg ← Kalari.Config.load configPath
  let setupJson ← IO.ofExcept (Json.parse (← IO.FS.readFile setupPath))
  let setup ← match fromJson? (α := Setup) setupJson with
    | .ok setup => pure setup
    | .error error =>
      -- An observer that cannot be read is not a configuration this service
      -- can prove. Keep the same refusal as an unproven guest source.
      if (setupJson.getObjVal? "observer").isOk then
        throw <| .userError "observer requires verified exclusive guest source isolation"
      throw <| .userError error
  validate cfg setup
  let evidence ← Kalari.Evidence.openStore setup.evidence_workspace
  IO.ofExcept (← Kalari.Tools.Lesson.verifyAmendedPolicyProvenance evidence setup.session_id setup.check_workspace)
  let client ← Kalari.Lambo.create cfg.lambo
  let writer ← Kalari.Tools.Lesson.writer client
  let path := setup.tool_path.getD "/usr/local/bin:/usr/bin:/bin"
  let clef := Kalari.Clef.live path
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
  -- An observer is accepted only from the guest gateway alias, with a trusted
  -- server file and an endpoint already in the sandbox allowlist.
  let observerEndpoint : AllowHost := { host := Kalari.Tools.Run.guestAlias, port := 18080 }
  let observerCfg := { cfg with sandbox := { cfg.sandbox with allowlist := allow ++ [observerEndpoint] } }
  let observerSetup := { validSetup with observer := some { server := executable.toString, endpoint := observerEndpoint } }
  validate observerCfg observerSetup
  let rejectsObserver (candidate : Setup) : IO Bool := do
    try validate observerCfg candidate; pure false catch _ => pure true
  unless ← rejectsObserver { observerSetup with observer := some {
      server := executable.toString, endpoint := { observerEndpoint with host := "127.0.0.1" } } } do
    throw <| .userError "caller-supplied guest address accepted"
  unless ← rejectsObserver { observerSetup with observer := some {
      server := (dir / "missing-server").toString, endpoint := observerEndpoint } } do
    throw <| .userError "missing observer server accepted"
  unless ← rejects observerSetup do throw <| .userError "observer endpoint outside the sandbox allowlist accepted"

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

end Kalari.Service
