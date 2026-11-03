import Kalari.Model
/-! kalari: the main service. A stub until P1; see product.md and docs/architecture.md. -/

def version : String := "0.1.0"

def usage : String :=
  "usage: kalari <command>\n\n" ++
  "  serve      MCP endpoint for the coding agent and HTTP API for the web app (planned)\n" ++
  "  --version  print the version\n"

def main (argv : List String) : IO UInt32 := do
  match argv with
  | ["--version"] => IO.println s!"kalari {version}"; return 0
  | ["serve"] => IO.eprintln "kalari serve: not implemented yet"; return 1
  | _ => IO.eprint usage; return 2
