import Kalari.Service

/-! Live-test entry point for the observer rehearsal. It calls the same
dispatcher as `kalari serve` with an observer setup that production refuses.
`kalari serve` never calls this module. Run it with
`lake env lean --run tests/live/observer-harness.lean <config> <session>`. -/

def main (args : List String) : IO UInt32 := do
  match args with
  | [config, setup] =>
    try
      Kalari.Service.harness config setup
      return 0
    catch e =>
      IO.eprintln s!"observer harness: {e}"
      return 1
  | _ =>
    IO.eprintln "usage: observer-harness <config.json> <session.json>"
    return 2
