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

private def validate (cfg : Kalari.Config.Config) (s : Setup) : IO Unit := do
  unless validName s.session_id && !s.repo_scope.isEmpty do throw <| .userError "invalid session identity"
  unless [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace, s.aashaan, s.old_spec, s.new_spec].all Kalari.Gate.workspaceOk do
    throw <| .userError "session paths must be absolute and normalized"
  unless s.workspace != s.baseline.workspace && s.workspace != s.check_workspace &&
      s.baseline.workspace != s.check_workspace && validName s.artifact &&
      s.artifact != Kalari.Tools.Run.trustedTruthArtifactName do
    throw <| .userError "invalid session workspace or artifact"
  unless cfg.sandbox.backend == "microsandbox" && cfg.decisions.endpoint == Kalari.Clef.endpoint &&
      cfg.decisions.model == Kalari.Clef.modelName && !cfg.lambo.command.isEmpty && !cfg.lambo.config_path.isEmpty do
    throw <| .userError "unsupported backend or decision configuration"
  unless cfg.sandbox.caps.timeout_ms > 0 && cfg.sandbox.caps.output_cap_bytes > 0 && cfg.sandbox.caps.memory_mib > 0 &&
      Kalari.Gate.capsOk s.baseline.caps cfg.sandbox.caps && Kalari.Gate.netOk s.baseline.allowlist cfg.sandbox.allowlist &&
      !s.baseline.command.isEmpty do throw <| .userError "invalid baseline or caps"
  for path in [s.workspace, s.baseline.workspace, s.check_workspace, s.evidence_workspace, s.aashaan, s.old_spec, s.new_spec] do
    unless ← (System.FilePath.mk path).pathExists do throw <| .userError "session path does not exist"
    let resolved ← IO.FS.realPath (System.FilePath.mk path)
    unless resolved.toString == path do throw <| .userError "session path must be canonical"
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
  let request : RunRequest := { workspace := "/candidate", command := ["true"], caps, allowlist := [] }
  let endpoint : Kalari.Config.Endpoint := { endpoint := "fixture", model := "fixture", api_key_env := "FIXTURE" }
  let cfg : Kalari.Config.Config := { models := endpoint, decisions := endpoint, sandbox := { backend := "microsandbox", image := "fixture", caps, allowlist := [] }, lambo := { command := ["fixture"], config_path := "fixture" } }
  let setup : Setup := { session_id := "fixture", repo_scope := "fixture", workspace := "/candidate", old_spec := "old", new_spec := "new", baseline := { request with workspace := "/baseline" }, check_workspace := dir.toString, evidence_workspace := dir.toString, artifact := "out.jsonl", aashaan := "/fixture" }
  let evidence ← Kalari.Evidence.openStore dir
  let writer ← Kalari.Tools.Lesson.makeWriter fun _ _ _ => pure (.ok "fixture")
  let source : Kalari.Tools.Recall.Sources := { linked := fun _ => pure [], semantic := fun _ => pure [], resolve := fun _ => pure (.error "missing"), applies := fun _ _ => pure (.error "missing") }
  let deps : Dependencies := {
    vimanam := fun _ _ _ => pure { exitCode := some 0, stdout := (include_str "../testdata/vimanam/2.1.0/payouts.json").toUTF8, stderr := .empty, wallMs := 0, cap := .none }
    search := fun _ _ _ => pure { exitCode := some 1, stdout := .empty, stderr := .empty, wallMs := 0, cap := .none }
    confirm := fun _ _ => pure (.ok [])
    writeChange := fun _ _ _ => pure (.ok "fixture")
    source
    runtime := { runner := fun _ _ _ => pure { exitCode := some 1, stdout := .empty, stderr := .empty, wallMs := 0, cap := .none }, resolve := fun _ => pure [] }
    classify := fun _ _ _ => pure (.error "fixture")
    writer, evidence, secrets := [] }
  let handler ← dispatcher cfg setup deps
  Kalari.Mcp.serve handler (← IO.getStdin) (← IO.getStdout)

end Kalari.Service
