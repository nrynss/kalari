import Kalari.Tools.Run

def main (args : List String) : IO UInt32 := do
  if args.length < 1 then
    IO.println "usage: validate_page_trace TRACE"
    return 2
  let path : System.FilePath := args[0]!
  let trace ← IO.FS.readFile path
  match Kalari.Tools.Run.pageObservations trace with
  | .ok facts =>
    IO.println s!"VALID {facts}"
    return 0
  | .error e =>
    IO.println s!"INVALID {e}"
    return 1
