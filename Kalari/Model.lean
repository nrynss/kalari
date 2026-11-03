import Lean.Data.Json

/-! Types the tools pass around.

Derived `FromJson` and `ToJson` use each field's name as its JSON key. They do
not rename it. A name ending in `?` is dropped from the key and omits `none`
instead of writing null, so no field here ends in `?`: `none` renders as null,
and a missing `Option` key parses as `none`.

`ChangeFact` keeps the change source's `id` and `kind` only. Recorded change
objects carry more keys; derived `FromJson` ignores them.

`Lesson.run_id` is the id of the run that showed the observation. The run's
logs stay on its `RunRecord`. `memory_concept_id` is `none` until memory has
stored the lesson. -/

open Lean

namespace Kalari.Model

/-- A change's id and kind, both strings. Other keys on a recorded object are ignored. -/
structure ChangeFact where
  id : String
  kind : String
  deriving Repr, BEq, FromJson, ToJson

/-- What a run must show. `command` is the argv the check runs as. -/
structure Check where
  id : String
  assertion : String
  command : List String
  deriving Repr, BEq, FromJson, ToJson

/-- A lesson. `check` is the check the lesson requires, not only its id. -/
structure Lesson where
  change_kind : String
  observation : String
  run_id : String
  check : Check
  memory_concept_id : Option String := none
  deriving Repr, BEq, FromJson, ToJson

/-- Caps the gate can read without IO. -/
structure Caps where
  timeout_ms : Nat
  output_cap_bytes : Nat
  memory_mib : Nat
  deriving Repr, BEq, FromJson, ToJson

/-- One host the run may connect to, and the port. -/
structure AllowHost where
  host : String
  port : Nat
  deriving Repr, BEq, FromJson, ToJson

/-- A sandbox run. Every field is required on the wire; an empty allowlist is still present. -/
structure RunRequest where
  workspace : String
  command : List String
  caps : Caps
  allowlist : List AllowHost
  deriving Repr, BEq, FromJson, ToJson

/-- One run's verdict. The field names are the keys the supervisor prints.
`exit_code` is a number when the job exited and null when a cap killed it.
`cgroup_memory_limit` is a JSON number; `Nat` so a value above 2^53 still parses. -/
structure Verdict where
  verdict : String
  exit_code : Option Nat
  wall_ms : Nat
  stdout : String
  stdout_truncated : Bool
  stderr : String
  pipe_held_open : Bool
  supervisor_peak_rss_kb : Nat
  cgroup_memory_limit : Nat
  deriving Repr, BEq, FromJson, ToJson

/-- Whether one check passed. `detail` is none when there is nothing to add. -/
structure CheckResult where
  check_id : String
  passed : Bool
  detail : Option String := none
  deriving Repr, BEq, FromJson, ToJson

/-- How long the run took. `wall_ms` is the supervisor's clock. -/
structure Timings where
  wall_ms : Nat
  deriving Repr, BEq, FromJson, ToJson

/-- Token counts, present only when they are known. -/
structure Tokens where
  input : Nat
  output : Nat
  deriving Repr, BEq, FromJson, ToJson

/-- One run and what it showed: the request, the verdict, the checks, their results. -/
structure RunRecord where
  request : RunRequest
  verdict : Verdict
  checks : List Check
  check_results : List CheckResult
  timings : Timings
  tokens : Option Tokens := none
  deriving Repr, BEq, FromJson, ToJson

/-- A place in the consumer that a change touches. -/
structure CallSite where
  path : String
  detail : Option String := none
  deriving Repr, BEq, FromJson, ToJson

/-- One change's call sites. -/
structure BlastRadius where
  change_id : String
  call_sites : List CallSite
  deriving Repr, BEq, FromJson, ToJson

private def parse (α : Type) [FromJson α] (s : String) : Except String α :=
  Lean.Json.parse s >>= fromJson?

private def roundTrip {α : Type} [FromJson α] [ToJson α] [BEq α] (x : α) : Bool :=
  (parse α (toJson x).compress).toOption == some x

private def sampleChange : ChangeFact := { id := "vc2_example", kind := "pagination_changed" }

private def sampleCheck : Check := {
  id := "exact-once"
  assertion := "each record exactly once"
  command := ["check-once"]
}

private def sampleLesson : Lesson := {
  change_kind := "pagination_changed"
  observation := "a token on the final page"
  run_id := "run-1"
  check := sampleCheck
}

private def sampleLessonStored : Lesson := { sampleLesson with memory_concept_id := some "abc123" }

private def sampleCaps : Caps := { timeout_ms := 2000, output_cap_bytes := 4096, memory_mib := 256 }

private def sampleAllow : AllowHost := { host := "api.example.test", port := 443 }

private def sampleRequest : RunRequest := {
  workspace := "/workspace"
  command := ["sh", "-c", "echo hello"]
  caps := sampleCaps
  allowlist := [sampleAllow]
}

private def sampleVerdict : Verdict := {
  verdict := "killed_timeout"
  exit_code := none
  wall_ms := 801
  stdout := ""
  stdout_truncated := false
  stderr := ""
  pipe_held_open := false
  supervisor_peak_rss_kb := 1
  cgroup_memory_limit := 0
}

private def sampleExited : Verdict := {
  sampleVerdict with
  verdict := "exited"
  exit_code := some 0
  stdout := "hello\n"
  stderr := "warn\n"
}

private def sampleResult : CheckResult := {
  check_id := "exact-once"
  passed := false
  detail := some "24 duplicates"
}

private def sampleResultClear : CheckResult := { check_id := "exact-once", passed := true }

private def sampleTimings : Timings := { wall_ms := 801 }

private def sampleTokens : Tokens := { input := 10, output := 4 }

private def sampleRecord : RunRecord := {
  request := sampleRequest
  verdict := sampleVerdict
  checks := [sampleCheck]
  check_results := [sampleResultClear]
  timings := sampleTimings
}

private def sampleRecordTokens : RunRecord := {
  sampleRecord with
  check_results := [sampleResult]
  tokens := some sampleTokens
}

private def sampleSite : CallSite := { path := "src/sync.py" }

private def sampleSiteNoted : CallSite := { path := "src/sync.py", detail := some "line 40" }

private def sampleRadius : BlastRadius := {
  change_id := "vc2_example"
  call_sites := [sampleSite, sampleSiteNoted]
}

#guard roundTrip sampleChange
#guard roundTrip sampleCheck
#guard roundTrip sampleLesson
#guard roundTrip sampleLessonStored
#guard roundTrip sampleCaps
#guard roundTrip sampleAllow
#guard roundTrip sampleRequest
#guard roundTrip sampleVerdict
#guard roundTrip sampleExited
#guard roundTrip sampleResult
#guard roundTrip sampleResultClear
#guard roundTrip sampleTimings
#guard roundTrip sampleTokens
#guard roundTrip sampleRecord
#guard roundTrip sampleRecordTokens
#guard roundTrip sampleSite
#guard roundTrip sampleSiteNoted
#guard roundTrip sampleRadius

-- `compress` sorts keys, and `none` renders as null rather than omitting the key.
#guard (toJson sampleVerdict).compress ==
  "{\"cgroup_memory_limit\":0,\"exit_code\":null,\"pipe_held_open\":false,\"stderr\":\"\",\"stdout\":\"\",\"stdout_truncated\":false,\"supervisor_peak_rss_kb\":1,\"verdict\":\"killed_timeout\",\"wall_ms\":801}"

-- A missing Option field parses as none.
#guard (parse Lesson "{\"change_kind\":\"pagination_changed\",\"observation\":\"x\",\"run_id\":\"run-1\",\"check\":{\"id\":\"c\",\"assertion\":\"a\",\"command\":[]}}").toOption ==
  some { change_kind := "pagination_changed", observation := "x", run_id := "run-1",
         check := { id := "c", assertion := "a", command := [] }, memory_concept_id := none }

#guard (parse CallSite "{\"path\":\"src/sync.py\"}").toOption == some { path := "src/sync.py", detail := none }

-- A wrong type is an error naming the field. A missing required field is an error too.
#guard match parse RunRequest "{\"workspace\":\"/w\",\"command\":1,\"caps\":{\"timeout_ms\":1,\"output_cap_bytes\":2,\"memory_mib\":3},\"allowlist\":[]}" with
  | .error e => e.endsWith "RunRequest.command: expected JSON array, got '1'"
  | .ok _ => false

#guard match parse RunRequest "{\"workspace\":\"/w\",\"command\":[],\"allowlist\":[]}" with
  | .error e => e.endsWith "RunRequest.caps: Kalari.Model.Caps.timeout_ms: Natural number expected"
  | .ok _ => false

-- One host run of the supervisor: `sh -c 'echo hello; echo warn >&2'`, caps 2000 ms and 4096 bytes.
-- There is no recorded verdict file yet. `wall_ms` and the memory fields vary, so the guard
-- checks the stable fields. A full round-trip uses `sampleVerdict`, not this line.
private def supervisorExitedLine : String := "{\"verdict\":\"exited\",\"exit_code\":0,\"wall_ms\":10,\"stdout\":\"hello\\n\",\"stdout_truncated\":false,\"stderr\":\"warn\\n\",\"pipe_held_open\":false,\"supervisor_peak_rss_kb\":12668,\"cgroup_memory_limit\":18446744073709551615}"

#guard match parse Verdict supervisorExitedLine with
  | .ok v => v.verdict == "exited" && v.exit_code == some 0 && v.stdout == "hello\n" &&
             v.stderr == "warn\n" && v.stdout_truncated == false && v.pipe_held_open == false
  | .error _ => false

private def killedTimeoutJson : String :=
  "{\"verdict\":\"killed_timeout\",\"exit_code\":null,\"wall_ms\":800,\"stdout\":\"\",\"stdout_truncated\":false,\"stderr\":\"\",\"pipe_held_open\":false,\"supervisor_peak_rss_kb\":0,\"cgroup_memory_limit\":0}"

private def killedOutputCapJson : String :=
  "{\"verdict\":\"killed_output_cap\",\"exit_code\":null,\"wall_ms\":10,\"stdout\":\"x\",\"stdout_truncated\":true,\"stderr\":\"\",\"pipe_held_open\":false,\"supervisor_peak_rss_kb\":0,\"cgroup_memory_limit\":0}"

#guard match parse Verdict killedTimeoutJson with
  | .ok v => v.verdict == "killed_timeout" && v.exit_code == none
  | .error _ => false

#guard match parse Verdict killedOutputCapJson with
  | .ok v => v.verdict == "killed_output_cap" && v.stdout_truncated == true && v.exit_code == none
  | .error _ => false

-- Full recorded change objects, not reduced to id and kind.
private def payoutsChangeJson : String := "{\n      \"id\": \"vc2_c8668fd9e15e5092fdae689188a12455975deddd2b05c2a5d84f32c00619c647\",\n      \"subject\": \"ve2_39c695a86399e80e27b79618583f23c083e54b3e376f1ed2f3de3b2f012f5d35\",\n      \"kind\": \"operation_removed\",\n      \"severity\": \"breaking\",\n      \"impacts\": [\n        \"source\"\n      ],\n      \"native\": {\n        \"format\": \"openapi\",\n        \"method\": \"GET\",\n        \"path\": \"/v1/payouts\",\n        \"parameter_in\": null,\n        \"status\": null,\n        \"pointer\": \"\",\n        \"resolved\": false\n      },\n      \"native_kind\": \"endpoint_removed\",\n      \"details\": {\n        \"was_deprecated\": false\n      }\n    }"

private def settlementsChangeJson : String := "{\n      \"id\": \"vc2_c3e0f582fbd65cf9d886ed6f46cf7223c81b112fde8709fc7a1e2d5b55a41b59\",\n      \"subject\": \"ve2_04f8d6e90ea1885e93f4e8aec1ba67d0eeae481c925de3ced4fdaa6d01c2fb08\",\n      \"kind\": \"argument_added\",\n      \"severity\": \"non_breaking\",\n      \"impacts\": [\n        \"source\"\n      ],\n      \"native\": {\n        \"format\": \"graphql\",\n        \"coordinate\": \"Query.settlements(first:)\"\n      },\n      \"native_kind\": \"ARG_ADDED_OPTIONAL\",\n      \"details\": {\n        \"after\": {\n          \"type\": \"Int\",\n          \"default\": \"50\",\n          \"required\": false,\n          \"deprecated\": false,\n          \"deprecation_reason\": null\n        }\n      }\n    }"

private def paginationChangeJson : String := "{\n      \"id\": \"vc2_03e273d5658ac9349bfef95e1780793db8aad41ac574138c3399d53ec0e2f87f\",\n      \"subject\": \"ve2_01a712ffb41c9f2f03441ada91ca6dba35cde4059b8158b6ae1b664fd38db1b9\",\n      \"kind\": \"pagination_changed\",\n      \"severity\": \"review\",\n      \"impacts\": [\n        \"source\"\n      ],\n      \"native\": {\n        \"format\": \"openapi\",\n        \"method\": \"GET\",\n        \"path\": \"/payouts\",\n        \"parameter_in\": null,\n        \"status\": null,\n        \"pointer\": \"\",\n        \"resolved\": true\n      },\n      \"native_kind\": \"pagination_inferred\",\n      \"details\": {\n        \"before\": null,\n        \"after\": {\n          \"controls\": [\n            {\n              \"name\": \"cursor\",\n              \"schema\": {\n                \"type\": \"string\"\n              }\n            },\n            {\n              \"name\": \"limit\",\n              \"schema\": {\n                \"type\": \"integer\",\n                \"maximum\": 1000,\n                \"minimum\": 1,\n                \"default\": 100\n              }\n            }\n          ],\n          \"responses\": [\n            {\n              \"status\": \"200\",\n              \"continuation\": [\n                \"next_cursor\"\n              ]\n            }\n          ]\n        },\n        \"confidence\": \"inferred\",\n        \"evidence_rule\": \"list+request_controls+continuation\"\n      }\n    }"

#guard (parse ChangeFact payoutsChangeJson).toOption ==
  some { id := "vc2_c8668fd9e15e5092fdae689188a12455975deddd2b05c2a5d84f32c00619c647", kind := "operation_removed" }

#guard (parse ChangeFact settlementsChangeJson).toOption ==
  some { id := "vc2_c3e0f582fbd65cf9d886ed6f46cf7223c81b112fde8709fc7a1e2d5b55a41b59", kind := "argument_added" }

#guard (parse ChangeFact paginationChangeJson).toOption ==
  some { id := "vc2_03e273d5658ac9349bfef95e1780793db8aad41ac574138c3399d53ec0e2f87f", kind := "pagination_changed" }

#guard match parse ChangeFact payoutsChangeJson with
  | .ok c => roundTrip c
  | .error _ => false

#guard match parse ChangeFact settlementsChangeJson with
  | .ok c => roundTrip c
  | .error _ => false

#guard match parse ChangeFact paginationChangeJson with
  | .ok c => roundTrip c
  | .error _ => false

end Kalari.Model
