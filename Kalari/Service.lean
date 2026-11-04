import Kalari.Mcp
import Kalari.Config
import Kalari.Tools.Changes
import Kalari.Tools.Recall
import Kalari.Tools.Run
import Kalari.Tools.Lesson

open Lean Kalari.Model
namespace Kalari.Service

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
  deriving FromJson

private def validName (s : String) : Bool :=
  !s.isEmpty && s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

private def validArtifact (s : String) : Bool :=
  validName s && s != "." && s != ".." && !s.startsWith "." &&
    s.toList.all (fun c => c.isAlphanum || c == '-' || c == '_' || c == '.')

private def validate (cfg : Kalari.Config.Config) (s : Setup) : IO Unit := do
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
      !(s.baseline.workspace :: s.baseline.command).any (·.contains '\x00') do
    throw <| .userError "invalid baseline or caps"
  for path in [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace, s.aashaan, s.old_spec, s.new_spec] do
    unless ← (System.FilePath.mk path).pathExists do throw <| .userError "session path does not exist"
    let resolved ← IO.FS.realPath (System.FilePath.mk path)
    unless resolved.toString == path do throw <| .userError "session path must be canonical"
  for path in [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace] do
    unless ← (System.FilePath.mk path).isDir do throw <| .userError "session workspace must be a directory"
  for path in [s.aashaan, s.old_spec, s.new_spec] do
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
      }
      let ctx ← Kalari.Tools.Lesson.attachLessonBootstrapChecks ctx
      Kalari.Tools.Run.call deps.runtime ctx args
    | "record_lesson" =>
      let runId ← IO.ofExcept (args.getObjValAs? String "run_id")
      let classify := deps.classify changes
      return (← Kalari.Tools.Lesson.record evidence setup.session_id runId classify writer).map fun x => (toJson x).compress
    | _ => return .error "unknown tool"

/-- Serve one session sequentially, with a single Lambo child and writer. -/
def serve (configPath setupPath : System.FilePath) : IO Unit := do
  let cfg ← Kalari.Config.load configPath
  let setupJson ← IO.ofExcept (Json.parse (← IO.FS.readFile setupPath))
  -- A guest address alone does not prove exclusive source ownership. Until the
  -- launcher can establish that isolation, never accept observer configuration.
  if (setupJson.getObjVal? "observer").isOk then
    throw <| .userError "observer requires verified exclusive guest source isolation"
  let setup ← IO.ofExcept (fromJson? (α := Setup) setupJson)
  validate cfg setup
  let evidence ← Kalari.Evidence.openStore setup.evidence_workspace
  IO.ofExcept (← Kalari.Tools.Lesson.verifyAmendedPolicyProvenance evidence setup.session_id setup.check_workspace)
  let client ← Kalari.Lambo.create cfg.lambo
  let writer ← Kalari.Tools.Lesson.writer client
  let path := "/usr/local/bin:/usr/bin:/bin"
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
  try
    Kalari.Mcp.serve handler (← IO.getStdin) (← IO.getStdout)
  finally
    Kalari.Lambo.shutdown client

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
  let writerCalls ← IO.mkRef ([] : List String)
  let writer ← Kalari.Tools.Lesson.makeWriter fun kind _ _ => do
    writerCalls.modify (· ++ [kind])
    pure (.ok (if kind == "resource" then "fixture-anchor" else if kind == "constraint" then "fixture-lesson" else "fixture-observation"))
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
  let rejects (candidate : Setup) : IO Bool := do
    try validate cfg candidate; pure false catch _ => pure true
  unless ← rejects { validSetup with artifact := ".hidden" } do throw <| .userError "dot artifact accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with command := [""] } } do throw <| .userError "empty baseline executable accepted"
  unless ← rejects { validSetup with baseline := { validSetup.baseline with command := ["true\x00bad"] } } do throw <| .userError "NUL baseline argument accepted"
  unless ← rejects { validSetup with workspace := oldSpec.toString } do throw <| .userError "file accepted as workspace"
  unless ← rejects { validSetup with old_spec := (dir / "candidate").toString } do throw <| .userError "directory accepted as spec"
  unless ← rejects { validSetup with evidence_workspace := validSetup.workspace } do throw <| .userError "overlapping roots accepted"

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
  unless (← writerCalls.get) == ["resource", "constraint", "observation"] do
    throw <| .userError "Run and Lesson did not use the shared lesson writer"

  -- Start a real local MCP child for the Lambo client, complete a receipt
  -- round trip, then prove shutdown closed stdin and reaped that process.
  let pidPath := dir / "fake-lambo.pid"
  let fakeLambo := "import json,os,sys; open(sys.argv[1],'w').write(str(os.getpid()));\n" ++
    "for line in sys.stdin:\n" ++
    " m=json.loads(line); method=m.get('params',{}).get('name',m.get('method'));\n" ++
    " if 'id' not in m: continue\n" ++
    " result={'structuredContent':{'receipt':'fixture-receipt'}} if method=='lambo_derive' else ({'structuredContent':{'receipt':{'id':'fixture-receipt','state':'applied','created':[],'matched':[]}}} if method=='lambo_stats' else {})\n" ++
    " print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}),flush=True)\n"
  let lamboConfig : Kalari.Config.Lambo := { command := ["python3", "-c", fakeLambo, pidPath.toString], config_path := "fixture.toml" }
  let lamboChild ← Kalari.Lambo.create lamboConfig
  let receipt ← try Kalari.Lambo.derive lamboChild "observation" "fake child fixture" catch e =>
    throw <| .userError s!"fake Lambo derive failed: {e}"
  unless receipt == "fixture-receipt" do throw <| .userError "fake Lambo receipt mismatch"
  let _ ← try Kalari.Lambo.awaitReceipt lamboChild receipt catch e =>
    throw <| .userError s!"fake Lambo receipt wait failed: {e}"
  Kalari.Lambo.shutdown lamboChild
  let pid ← IO.FS.readFile pidPath
  let alive ← IO.Process.output { cmd := "/bin/kill", args := #["-0", pid.trimAscii.toString] }
  unless alive.exitCode != 0 do throw <| .userError "fake Lambo child survived shutdown"

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

  Kalari.Mcp.serve stdioHandler (← IO.getStdin) (← IO.getStdout)

end Kalari.Service
