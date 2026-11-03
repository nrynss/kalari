# Writing Kalari in Lean 4

A working guide for agents: the patterns Kalari needs, each backed by an example in [`../Examples/`](../Examples) that the gate builds and runs, and the traps already hit. Measured facts about the toolchain are in [`../dev-diary/research/lean.md`](../dev-diary/research/lean.md); read both before writing Lean here.

**Toolchain:** Lean 4.35.0, pinned in `lean-toolchain`. No Mathlib. Everything below was verified on it; an API name from older Lean docs or from memory may have changed (see "API drift").

## The examples

| File | Shows | Checked by |
|---|---|---|
| [`Examples/Gate.lean`](../Examples/Gate.lean) | A decision function with theorems about it: anything allowed writes inside the workspace, is capped, connects only to an allowlisted host; a clamp proved with `omega` | `lake build` (theorems and `#guard`) |
| [`Examples/Json.lean`](../Examples/Json.lean) | `Lean.Json` with derived instances, parsing with readable errors, compact output | `lake build` (`#guard`) |
| [`Examples/HttpServer.lean`](../Examples/HttpServer.lean) | A `Std.Http` server: routing on method and path, a JSON body under a size cap, 400 / 404 / 413, reading a header | `tests/examples.sh` |
| [`Examples/JsonRpc.lean`](../Examples/JsonRpc.lean) | A JSON-RPC 2.0 loop over stdio: the shape of an MCP server | `tests/examples.sh` |
| [`Examples/Curl.lean`](../Examples/Curl.lean) | Outbound HTTP(S) through `curl` with the key on curl's stdin, never in its arguments | `tests/examples.sh` |
| [`Aashaan/Main.lean`](../Aashaan/Main.lean) | Spawning an untrusted job with caps: `setsid`, empty environment, `tryWait` against a monotonic clock, group kill, bounded output | `tests/aashaan-cases.sh` |

Copy the pattern, not the file: the examples are illustrations, not Kalari's modules.

## Working loop

```bash
lake build                         # everything in defaultTargets
lake build example-http            # one target
lean Scratch.lean                  # check a scratch file; #eval prints, #guard asserts
./tools/check.sh                   # the gate, before every commit
```

- **Probe before you write.** When unsure what an API does, put a few `#eval` lines in a scratch file outside the repo and run `lean` on it. It's faster than guessing from docs, and the docs are sometimes wrong.
- **Read the toolchain's own source** for exact names: `~/.elan/toolchains/leanprover--lean4---v4.35.0/src/lean/Std/…` (for example `Std/Http.lean`, `Std/Http/Data/Response.lean`). It is the ground truth for this version.
- A new executable is a `[[lean_exe]]` in `lakefile.toml` (orchestrator's approval) with `root` naming the module that defines `main`.

## Imports and binary size

| Imports | Stripped size | Use in |
|---|---|---|
| `Std` only | ~3–5 MB | `kalari-aashaan` (runs in every microVM) |
| `Lean.Data.Json` (or anything under `Lean`) | ~80 MB stripped, ~120 MB unstripped | `kalari` only |

Importing anything from `Lean` links the compiler library. The aashaan must stay `Std`-only: it hand-writes its JSON output (`jstr` in `Aashaan/Main.lean`).

## Proofs

The pattern in `Examples/Gate.lean`:

1. **Keep the decision a plain, total `Bool` function over plain data.** It runs as code and theorems can talk about it. No `IO`, no partiality.
2. **State each guarantee as a theorem** of the form `allowed a = true → property a`.
3. **Prove by unfolding into the `Bool` connectives:** `simp only [allowed, Bool.and_eq_true, decide_eq_true_eq] at h`, then pick the conjunct (`h.1.1`, `h.2`). For list membership, `List.contains_iff_mem.mp`. For arithmetic bounds, `unfold` then `omega`.
4. **Add `#guard` cases** for concrete inputs: they run at build time and catch a wrong definition that the theorems don't (a decision that denies everything satisfies every safety theorem).

If an edit breaks a theorem, the build fails and the gate with it. That is the point: never weaken a theorem to make a change compile; take it to the orchestrator.

## JSON (`Lean.Json`)

- **Derive:** `deriving FromJson, ToJson`. Build ad hoc objects with `Json.mkObj [("key", value)]`; `String` and `Bool` values coerce to `Json`, other values go through `toJson`.
- **Parse:** `Lean.Json.parse s >>= fromJson?`. The errors are readable (`…RunRequest.command: String expected`), good for a 400 body.
- **Derived `FromJson` ignores structure defaults.** A missing key reads as `null` and fails (`expected JSON array, got 'null'`) unless the field is an `Option`. Make optional fields `Option`s and default them where they're used.
- **Error paths are fully qualified:** `Examples.Json.RunRequest.command: String expected`. Match on the end of the message, or don't match on it at all.
- **`compress` sorts keys alphabetically.** Don't compare wire output byte-for-byte against a hand-written string in another order.
- **Namespace shadowing:** inside `namespace Foo.Json`, `Json.parse` means `Foo.Json.parse` if one exists, and the error is an unhelpful type mismatch on its arguments. Write `Lean.Json.parse`.

## HTTP server (`Std.Http`)

The pattern in `Examples/HttpServer.lean`:

```lean
structure App
instance : Handler App where
  onRequest _ req := do
    match req.line.method, path with
    | .get, "/health" => Response.ok |>.json "{\"ok\":true}"
    | _, _ => Response.notFound |>.json "{\"error\":\"not found\"}"

def main : IO Unit := Async.block do
  let server ← Server.serve (.v4 ⟨.ofParts 127 0 0 1, port⟩) App.mk
  server.waitShutdown
```

- **The request line is `req.line`** (`method`, `uri`, `headers`). The module docs say `req.head`, which is a builder function and gives a confusing "invalid field notation" error.
- **Path:** `toString req.line.uri`, split at `?`.
- **Headers:** `req.line.headers.contains (.mk "authorization")`, `get? (.mk "content-type")`. Names are lower case (the `.mk` proof is `by decide` on lower-case).
- **Body:** `req.body.readAll (maximumSize := some n)` (as `String` or `ByteArray`). **Over the cap it throws `IO.userError`**: catch it and answer 413, or the client gets a dropped connection.
- **Responses:** `Response.ok`, `.badRequest`, `.notFound`, `.internalServerError`, `Response.withStatus .payloadTooLarge`, then `|>.json s`, `|>.text s`, `|>.header! "Name" "value"`.
- **Bind 127.0.0.1.** Caddy terminates TLS in front of the real server.
- The server keeps serving after a handler error; `onFailure` gets the error for logging.

## JSON-RPC over stdio (MCP)

The pattern in `Examples/JsonRpc.lean`: one message per line, `stdin.getLine` returning `""` at EOF, a reply only for messages with an `id`, codes `-32700` (parse), `-32601` (method), `-32602` (params), and **`flush` after every line**, because the client waits for each one. **Logs go to stderr only**: stdout is the protocol, and one stray line breaks the client.

## Processes

The patterns in `Aashaan/Main.lean` and `Examples/Curl.lean`:

- **Spawn:** `IO.Process.spawn { cmd, args, stdout := .piped, stderr := .piped, stdin := .null, setsid := true, inheritEnv := false, env := #[("PATH", some "/usr/bin:/bin")] }`.
- **`inheritEnv := false`** is how no secret reaches a child. Always set it for untrusted jobs.
- **`setsid := true`** puts the child in its own process group, so `kill` reaches its children.
- **`Child.kill` sends SIGKILL** (to the group under `setsid`), whatever its docstring says. There's no SIGTERM step; a trap never runs.
- **Wait with a deadline:** a loop of `child.tryWait` and `IO.sleep 10` against `IO.monoMsNow`. Read pipes in `IO.asTask` so a full pipe can't block the child.
- **A job that calls `setsid` itself escapes the group kill** and can hold your pipe open. Bound the wait on output after a kill (`IO.hasFinished` on the reader task), and leave the rest to microVM teardown.
- **Exit with `IO.Process.forceExit`** when a reader thread may still be blocked on such a pipe: a normal exit waits for it, and hangs.
- **`takeStdin` loses `setsid`** (lean4#15674). Use it only for children that need no group kill, such as `curl` in `Examples/Curl.lean`. Write to stdin in a helper function so the handle is released, and so closed, when it returns; the child waits for EOF.
- **`Child.pid` leaks the child and its pipe descriptors** (lean4#15681). Fine once in a short-lived process; avoid it in a loop in `kalari serve`.
- **`Std.Async.Process` does not launch processes.** It reports on the current one: `getResourceUsage`, `constrainedMemory`, `setPriority`.

## Outbound HTTPS

No HTTP client, no TLS: call `curl`. **Never put a key in curl's arguments** (they show in `ps` and `/proc/<pid>/cmdline`). Send the header as config on stdin: `curl --config -` with `header = "Authorization: Bearer <key>"`, the key read from an environment variable named by the caller. Get the status code with `-w "\n%{http_code}"` and split the last line off. See `Examples/Curl.lean`.

## Strings and other drift

- `String.trim` is now `trimAscii`, and it returns a `String.Slice`: add `.toString` when you need a `String`.
- `String.splitOn`, `String.toNat!`, `String.intercalate`, `List.getLast?`, `List.headD` all as expected.
- `partial def` for loops that read until EOF.

## In a microVM

- Lean executables need **`vm.overcommit_memory=1`** in the guest, or the runtime can't start threads (`failed to create thread: Resource temporarily unavailable`, exit 134), whatever the memory size.
- They link glibc: use a glibc image such as `debian`, not Alpine.
