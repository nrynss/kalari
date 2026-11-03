/-! Example: outbound HTTP(S) through a `curl` subprocess, with the key kept off the command line.

Lean has no HTTP client and no TLS, so Kalari calls curl. A key in curl's arguments would be
visible to every user in `ps` and `/proc/<pid>/cmdline`. Instead the Authorization header goes
to curl on stdin as a config file (`--config -`), and the key is read from an environment
variable named by the caller, never passed as a value.

Usage: example-curl <url> <key-env-var> [json-body-file] -/

namespace Examples.Curl

structure Reply where
  status : Nat
  body : String

/-- Write curl's config to its stdin and close it. A separate function, so the handle is
released (and stdin closed) when it returns; curl waits for EOF before it starts. -/
def sendConfig (h : IO.FS.Handle) (config : String) : IO Unit := do
  h.putStr config
  h.flush

/-- GET, or POST a JSON file. The status code comes back on its own last line (`-w`). -/
def request (url : String) (keyEnv : String) (bodyFile? : Option String := none) : IO Reply := do
  let key ← match ← IO.getEnv keyEnv with
    | some k => pure k
    | none => throw <| .userError s!"{keyEnv} is not set"
  let dataArgs := match bodyFile? with
    | some f => #["-H", "Content-Type: application/json", "--data-binary", s!"@{f}"]
    | none => #[]
  let child ← IO.Process.spawn {
    cmd := "curl"
    args := #["-sS", "--max-time", "60", "--config", "-", "-w", "\n%{http_code}"] ++ dataArgs ++ #[url]
    stdin := .piped, stdout := .piped, stderr := .piped
    -- No setsid here: `takeStdin` loses it (lean4#15674), and a curl call needs no group kill.
  }
  let (stdin, child) ← child.takeStdin
  -- curl config syntax; quote the value. The key never appears in an argument.
  sendConfig stdin s!"header = \"Authorization: Bearer {key}\"\n"
  let out ← child.stdout.readToEnd
  let err ← child.stderr.readToEnd
  let code ← child.wait
  if code != 0 then throw <| .userError s!"curl exited {code}: {err.trimAscii}"
  let lines := out.splitOn "\n"
  let status := (lines.getLast?.getD "0").toNat!
  pure { status, body := "\n".intercalate lines.dropLast }

end Examples.Curl

def main (argv : List String) : IO UInt32 := do
  match argv with
  | url :: keyEnv :: rest =>
    let r ← Examples.Curl.request url keyEnv rest.head?
    IO.println s!"{r.status} {r.body}"
    return (if r.status < 400 then 0 else 1)
  | _ => IO.eprintln "usage: example-curl <url> <key-env-var> [json-body-file]"; return 2
