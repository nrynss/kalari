import Kalari.Model
import Kalari.Config
import Kalari.Proc
import Kalari.Backend
import Kalari.Fake
import Kalari
/-! kalari: the main service. A stub until P1; see product.md and docs/architecture.md. -/

def version : String := "0.1.0"

def usage : String :=
  "usage: kalari <command>\n\n" ++
  "  serve      MCP endpoint for the coding agent and HTTP API for the web app (planned)\n" ++
  "  check      load and validate the config, reach each backend (planned)\n" ++
  "  --version  print the version\n"

def main (argv : List String) : IO UInt32 := do
  match argv with
  | ["--version"] => IO.println s!"kalari {version}"; return 0
  | ["--help"] => IO.print usage; return 0
  | ["serve"] => IO.eprintln "kalari serve: not implemented yet"; return 2
  | "check" :: _ => IO.eprintln "kalari check: not implemented yet"; return 2
  | _ => IO.eprint usage; return 2
