import Lean.Data.Json
/-! Example: JSON with derived instances (`Lean.Json`).

Importing `Lean.Data.Json` links the Lean compiler library into the executable (~80 MB
stripped instead of ~3 MB). Fine for `kalari`, never for `kalari-aashaan`. -/

open Lean

namespace Examples.Json

structure RunRequest where
  command : String
  timeoutMs : Nat
  -- Derived FromJson ignores defaults: a missing key reads as null and fails unless the
  -- field is an Option. So optional fields are Options, defaulted where they're used.
  allowHosts : Option (List String) := none
  deriving FromJson, ToJson, Repr

structure Verdict where
  verdict : String
  exitCode : Option Nat
  wallMs : Nat
  deriving FromJson, ToJson, Repr

/-- Parse text into a typed value. Errors are readable strings, good for a 400 body. -/
def parse (α : Type) [FromJson α] (s : String) : Except String α :=
  Lean.Json.parse s >>= fromJson?   -- `Json.parse` here would mean Examples.Json.parse

/-- Compact output for wire formats; `Json.pretty` for humans. -/
def render [ToJson α] (a : α) : String := (toJson a).compress

#guard (parse RunRequest "{\"command\":\"ls\",\"timeoutMs\":500}" |>.toOption |>.map (·.timeoutMs)) == some 500
-- A missing Option field parses as none.
#guard (parse RunRequest "{\"command\":\"ls\",\"timeoutMs\":5}" |>.toOption |>.map (·.allowHosts.getD [])) == some []
-- A wrong type is an error naming the field.
#guard match parse RunRequest "{\"command\":1,\"timeoutMs\":5}" with
  | .error e => e.endsWith "RunRequest.command: String expected"   -- the full path: Examples.Json.RunRequest.command
  | .ok _ => false
-- `compress` sorts keys alphabetically, and an `Option` field renders as null when none.
#guard render ({ verdict := "killed_timeout", exitCode := none, wallMs := 801 } : Verdict)
  == "{\"exitCode\":null,\"verdict\":\"killed_timeout\",\"wallMs\":801}"

end Examples.Json
