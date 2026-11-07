import Lean.Data.Json
import Kalari.Model
import Std.Async.System

/-! `kalari.json`.

Sections `models`, `decisions`, `sandbox` and `lambo` are all required.
`api_key_env` is the name of an environment variable, never the key.
A field named `api_key` is a value slot and is rejected. The error names the
field and does not include the rejected text: a JSON error that interpolates
the value would print a key. `parse` does not read the environment. `load`
checks that each named variable is set and still stores only the name. -/

open Lean

namespace Kalari.Config

/-- An OpenAI-compatible or System One endpoint. `api_key_env` is a variable name. -/
structure Endpoint where
  endpoint : String
  model : String
  api_key_env : String
  deriving Repr, BEq, ToJson

/-- Maximum caps, the guest image, and the network allowlist.
`backend` is `microsandbox` or `docker`. -/
structure Sandbox where
  backend : String
  image : String
  caps : Kalari.Model.Caps
  allowlist : List Kalari.Model.AllowHost
  deriving Repr, BEq, ToJson

/-- Guest image when `sandbox.image` is absent. msb 0.7.13 accepts an OCI tag. -/
def defaultImage : String := "python:3.13-slim"

/-- How to start Lambo. `command` is the argv. `config_path` is Lambo's own config. -/
structure Lambo where
  command : List String
  config_path : String
  deriving Repr, BEq, ToJson

/-- One `kalari.json`. -/
structure Config where
  models : Endpoint
  decisions : Endpoint
  sandbox : Sandbox
  lambo : Lambo
  deriving Repr, BEq, ToJson

/-- `[A-Za-z_][A-Za-z0-9_]*`. Anything else in `api_key_env` is a value, not a name. -/
private def isEnvVarName (s : String) : Bool :=
  match s.front? with
  | none => false
  | some c =>
    (c.isAlpha || c == '_') && (s.toSlice.drop 1).all fun d => d.isAlphanum || d == '_'

private def envNameError (field : String) : String :=
  s!"{field}: environment variable name required"

private def missingVar (field var : String) : String :=
  s!"{field}: {var} is not set"

private def getObj (j : Json) (field : String) : Except String (Std.TreeMap.Raw String Json) :=
  match j.getObj? with
  | .ok obj => .ok obj
  | .error _ => .error s!"{field}: object expected"

/-- `api_key` would hold a value. Reject it without reading that value into the error. -/
private def rejectApiKey (obj : Std.TreeMap.Raw String Json) (field : String) : Except String Unit :=
  if obj.contains "api_key" then
    .error (envNameError field)
  else
    .ok ()

private def jsonField (obj : Std.TreeMap.Raw String Json) (field key : String) : Except String Json :=
  match obj.get? key with
  | some v => .ok v
  | none => .error s!"{field}: required"

private def strField (obj : Std.TreeMap.Raw String Json) (field key : String) : Except String String := do
  match ← jsonField obj field key with
  | .str s => return s
  | _ => throw s!"{field}: String expected"

private def strEnvField (obj : Std.TreeMap.Raw String Json) (field key : String) : Except String String := do
  let s ← strField obj field key
  if isEnvVarName s then
    return s
  else
    -- The rejected text stays out of the message.
    throw (envNameError field)

private def parseEndpoint (which : String) (j : Json) : Except String Endpoint := do
  let obj ← getObj j which
  rejectApiKey obj s!"{which}.api_key"
  let endpoint ← strField obj s!"{which}.endpoint" "endpoint"
  let model ← strField obj s!"{which}.model" "model"
  let api_key_env ← strEnvField obj s!"{which}.api_key_env" "api_key_env"
  return { endpoint, model, api_key_env }

private def asObject (j : Json) (field : String) : Except String Json :=
  match j with
  | .obj _ => .ok j
  | _ => .error s!"{field}: object expected"

private def asArray (j : Json) (field : String) : Except String Json :=
  match j with
  | .arr _ => .ok j
  | _ => .error s!"{field}: JSON array expected"

/-- An empty string is rejected. The message names the field and not the value. -/
private def parseSandboxImage (obj : Std.TreeMap.Raw String Json) : Except String String :=
  match obj.get? "image" with
  | none => .ok defaultImage
  | some (.str s) =>
    if s.isEmpty then
      .error "sandbox.image: empty"
    else
      .ok s
  | some _ => .error "sandbox.image: String expected"

private def parseSandbox (j : Json) : Except String Sandbox := do
  let obj ← getObj j "sandbox"
  rejectApiKey obj "sandbox.api_key"
  let backend ← strField obj "sandbox.backend" "backend"
  if backend != "microsandbox" && backend != "docker" then
    throw "sandbox.backend: expected microsandbox or docker"
  let image ← parseSandboxImage obj
  let capsJson ← jsonField obj "sandbox.caps" "caps"
  discard <| asObject capsJson "sandbox.caps"
  let caps ← Except.mapError (s!"sandbox.caps: " ++ ·) (fromJson? capsJson)
  let allowJson ← jsonField obj "sandbox.allowlist" "allowlist"
  discard <| asArray allowJson "sandbox.allowlist"
  let allowlist ← Except.mapError (s!"sandbox.allowlist: " ++ ·)
    (fromJson? (α := List Kalari.Model.AllowHost) allowJson)
  return { backend, image, caps, allowlist }

private def parseLambo (j : Json) : Except String Lambo := do
  let obj ← getObj j "lambo"
  rejectApiKey obj "lambo.api_key"
  let cmdJson ← jsonField obj "lambo.command" "command"
  discard <| asArray cmdJson "lambo.command"
  let command ← Except.mapError (s!"lambo.command: " ++ ·) (fromJson? (α := List String) cmdJson)
  let config_path ← strField obj "lambo.config_path" "config_path"
  return { command, config_path }

/-- Parse one JSON value. Does not read the environment. -/
def parseJson (j : Json) : Except String Config := do
  let obj ← getObj j "config"
  rejectApiKey obj "api_key"
  let models ← parseEndpoint "models" (← jsonField obj "models" "models")
  let decisions ← parseEndpoint "decisions" (← jsonField obj "decisions" "decisions")
  let sandbox ← parseSandbox (← jsonField obj "sandbox" "sandbox")
  let lambo ← parseLambo (← jsonField obj "lambo" "lambo")
  return { models, decisions, sandbox, lambo }

instance configFromJson : FromJson Config where
  fromJson? := parseJson

/-- Parse the text of a `kalari.json`. Does not read the environment. -/
def parse (s : String) : Except String Config :=
  Lean.Json.parse s >>= parseJson

/-- The variable is missing when `present` is false. The message names it and no value. -/
private def requireSet (field var : String) (present : Bool) : Except String Unit :=
  if present then .ok () else .error (missingVar field var)

/-- Fail if `models.api_key_env` or `decisions.api_key_env` is unset. The value is discarded. -/
def checkEnv (cfg : Config) : IO Unit := do
  IO.ofExcept <| requireSet "models.api_key_env" cfg.models.api_key_env
    (← IO.getEnv cfg.models.api_key_env).isSome
  IO.ofExcept <| requireSet "decisions.api_key_env" cfg.decisions.api_key_env
    (← IO.getEnv cfg.decisions.api_key_env).isSome

/-- Read a file, parse it, and check that each `api_key_env` is set. -/
def load (path : System.FilePath) : IO Config := do
  let text ← IO.FS.readFile path
  let cfg ← IO.ofExcept (parse text)
  checkEnv cfg
  return cfg

/-! Tests. The fixture names `KALARI_TEST_KEY` and nothing else. The rejected
texts below are not keys. A failure of these checks must not print an environment value. -/

private def fixtureText : String := include_str "../testdata/config/kalari.json"

private def fixturePath : System.FilePath := "testdata/config/kalari.json"

private def expectedFixture : Config := {
  models := {
    endpoint := "https://api.example.test/v1"
    model := "example-model"
    api_key_env := "KALARI_TEST_KEY"
  }
  decisions := {
    endpoint := "https://api.example.test/v1/systemone"
    model := "example-decider"
    api_key_env := "KALARI_TEST_KEY"
  }
  sandbox := {
    backend := "microsandbox"
    image := defaultImage
    caps := { timeout_ms := 30000, output_cap_bytes := 1048576, memory_mib := 512 }
    allowlist := [{ host := "api.example.test", port := 443 }]
  }
  lambo := {
    command := ["lambo", "serve"]
    config_path := "lambo.toml"
  }
}

private def badEnvName : String := "not-a-name"

private def pastedKey : String := "pasted-key"

private def endpointJson (env : String) (extra : List (String × Json) := []) : Json :=
  Json.mkObj ([
    ("endpoint", Json.str "https://api.example.test/v1"),
    ("model", Json.str "example-model"),
    ("api_key_env", Json.str env)
  ] ++ extra)

private def configJson (models decisions : Json) (backend : String := "microsandbox")
    (rootExtra : List (String × Json) := []) (image : Option String := none) : Json :=
  let sandboxBase : List (String × Json) := [
    ("backend", Json.str backend),
    ("caps", Json.mkObj [
      ("timeout_ms", (1 : Json)),
      ("output_cap_bytes", (2 : Json)),
      ("memory_mib", (3 : Json))
    ]),
    ("allowlist", Json.arr #[])
  ]
  let sandboxFields :=
    match image with
    | none => sandboxBase
    | some s => sandboxBase ++ [("image", Json.str s)]
  Json.mkObj (rootExtra ++ [
    ("models", models),
    ("decisions", decisions),
    ("sandbox", Json.mkObj sandboxFields),
    ("lambo", Json.mkObj [
      ("command", toJson (["lambo", "serve"] : List String)),
      ("config_path", Json.str "lambo.toml")
    ])
  ])

private def parses (j : Json) : Except String Config :=
  parse j.compress

#guard isEnvVarName "KALARI_TEST_KEY"
#guard isEnvVarName "_"
#guard isEnvVarName "A1"
#guard !isEnvVarName ""
#guard !isEnvVarName badEnvName
#guard !isEnvVarName "9KEY"
#guard !isEnvVarName "a=b"
#guard !isEnvVarName "has space"

#guard defaultImage == "python:3.13-slim"

#guard (parse fixtureText).toOption == some expectedFixture

#guard match parse fixtureText with
  | .ok cfg => (parse (toJson cfg).compress).toOption == some cfg
  | .error _ => false

#guard match parses (configJson (endpointJson badEnvName) (endpointJson "KALARI_TEST_KEY")) with
  | .error e => e == envNameError "models.api_key_env" && !e.contains badEnvName
  | .ok _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson pastedKey)) with
  | .error e => e == envNameError "decisions.api_key_env" && !e.contains pastedKey
  | .ok _ => false

#guard match parses (configJson
    (endpointJson "KALARI_TEST_KEY" [("api_key", Json.str pastedKey)])
    (endpointJson "KALARI_TEST_KEY")) with
  | .error e => e == envNameError "models.api_key" && !e.contains pastedKey
  | .ok _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson "KALARI_TEST_KEY")
    (rootExtra := [("api_key", Json.str pastedKey)])) with
  | .error e => e == envNameError "api_key" && !e.contains pastedKey
  | .ok _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson "KALARI_TEST_KEY")
    (backend := "docker")) with
  | .ok cfg => cfg.sandbox.backend == "docker" && cfg.sandbox.allowlist == []
      && cfg.sandbox.image == defaultImage
  | .error _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson "KALARI_TEST_KEY")
    (image := some "python")) with
  | .ok cfg => cfg.sandbox.image == "python" && cfg.sandbox.image != defaultImage
  | .error _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson "KALARI_TEST_KEY")
    (rootExtra := [("note", Json.str pastedKey)]) (image := some "")) with
  | .error e => e == "sandbox.image: empty" && !e.contains pastedKey
  | .ok _ => false

#guard match parses (configJson (endpointJson "KALARI_TEST_KEY") (endpointJson "KALARI_TEST_KEY")
    (backend := "podman")) with
  | .error e => e == "sandbox.backend: expected microsandbox or docker" && !e.contains "podman"
  | .ok _ => false

#guard match requireSet "models.api_key_env" "KALARI_TEST_KEY_UNSET" false with
  | .error e => e == "models.api_key_env: KALARI_TEST_KEY_UNSET is not set"
  | .ok () => false

#guard (requireSet "decisions.api_key_env" "KALARI_TEST_KEY" true).isOk

/-- `load` against the committed fixture. Sets and unsets `KALARI_TEST_KEY` only.
The dummy value is never printed and is not part of any error. -/
private def runLoadChecks : IO Unit := do
  let name := "KALARI_TEST_KEY"
  let saved ← IO.getEnv name
  let restore : IO Unit :=
    match saved with
    | some v => Std.Async.System.setEnvVar name v
    | none => Std.Async.System.unsetEnvVar name
  try
    Std.Async.System.unsetEnvVar name
    let caught ← try
      let _ ← load fixturePath
      pure none
    catch e =>
      pure (some (toString e))
    match caught with
    | none => throw <| .userError "missing variable was accepted"
    | some msg =>
      unless msg == missingVar "models.api_key_env" name do
        throw <| .userError "missing-variable error did not match"
    Std.Async.System.setEnvVar name "set"
    let cfg ← load fixturePath
    unless cfg == expectedFixture do
      throw <| .userError "loaded config did not match the fixture"
    unless cfg.models.api_key_env == name && cfg.decisions.api_key_env == name do
      throw <| .userError "loaded config stored something other than the variable name"
  finally
    restore

#eval runLoadChecks

end Kalari.Config
