import Kalari.Model
import Kalari.Proc

/-! Seams a later module can fill with one value each.

Nothing here names a provider. A miss is an `Except` error from the value
that implements the structure, not an empty list and not a default success. -/

namespace Kalari.Backend

open Kalari.Model
open Kalari.Proc

/-- A typed decision answer, one shape per recorded body.

`label` is a choice: the chosen name, that answer's probabilities in name
order, and its confidence.
`probabilities` is one number per question, in question-name order.
`error` is a non-success status and its message. -/
inductive DecisionAnswer where
  | label (label : String) (probabilities : List (String × Float)) (confidence : Float)
  | probabilities (values : List (String × Float))
  | error (status : Nat) (message : String)
  deriving Repr, BEq

/-- Create, copy, run, and remove one sandbox.

`create` takes the sandbox name, the caps, and the network allowlist.
`copyIn` copies a host path to a guest path. `copyOut` copies a guest path
to a host path. `exec` runs an argv and returns the process result: exit
code, stdout, stderr, wall time, and which cap fired. `destroy` removes it. -/
structure SandboxBackend where
  create : String → Caps → List AllowHost → IO (Except String Result)
  copyIn : String → String → String → IO (Except String Result)
  exec : String → List String → IO (Except String Result)
  copyOut : String → String → String → IO (Except String Result)
  destroy : String → IO (Except String Result)

/-- One question set in, one typed answer out. The string names the question set. -/
structure DecisionClient where
  ask : String → IO (Except String DecisionAnswer)

/-- `derive` writes a key, `inspect` and `recall` read one, `against` contradicts one.
Each result is an id, or a list of ids. -/
structure MemoryClient where
  derive : String → IO (Except String String)
  inspect : String → IO (Except String (List String))
  /-- `recall` is a command keyword, so the field name is escaped. -/
  «recall» : String → IO (Except String (List String))
  against : String → IO (Except String String)

/-- Two spec versions in, the change facts out. -/
structure ChangeSource where
  diff : String → String → IO (Except String (List ChangeFact))

end Kalari.Backend
