# Lean 4.35.0

How to write the code, with verified examples: [`../../docs/lean.md`](../../docs/lean.md). This file is what the toolchain measured.

Kalari's executables are Lean 4 native executables (`lake build`, through C). Lean is the implementation language, not a side project: the gate's decision function and the aashaan's cap logic carry theorems checked at build time, in the same code that ships.

## What the toolchain gives

Verified on the stable toolchain, x86_64 Linux, with probes that built and ran:

| Need | Status |
|---|---|
| Native executables | `lake build` through C; a clean build of a probe takes ~7 s. **Links only glibc** (`libc`, `libm`, `libpthread`, `libdl`, `librt`): use a glibc base image, not Alpine |
| HTTP server | **`Std.Http` ships and works.** HTTP/1.1, keep-alive, chunked bodies, a body size cap (`readAll (maximumSize := …)`), header and keep-alive timeouts, a connection limit, graceful shutdown. Pattern: a `Handler` instance plus `Server.serve`. 200 concurrent POSTs answered in 0.8 s; ready 121 ms after launch |
| JSON | `Lean.Json` with derived `FromJson`/`ToJson` works, and bad input gives a clear error (`Action.path: String expected`). **But importing it links the Lean compiler library: 80 MB stripped, ~80 MB resident.** A `Std`-only server is 4.9 MB stripped. So: `Lean.Json` in `kalari`, never in `kalari-aashaan` |
| Processes and caps | `IO.Process.spawn` with piped output, `IO.asTask child.wait`, `IO.monoMsNow`, `child.kill`. A `sleep 30` was killed at a 500 ms cap while the server kept serving |
| Concurrency | `Std.Async`, `Std.Sync` (mutex, semaphore, channels, cancellation), `Task` |
| TCP, DNS, timers, signals | `Std.Async.TCP`, `UDP`, `DNS`, `Timer`, `Signal` |
| HTTP client | **None.** `Std.Http` has client-side message types but no client. Outbound HTTPS through a `curl` subprocess |
| TLS | **None.** Inbound TLS from Caddy |
| Proofs in the executable | Worked: `theorem allowed_in_workspace` (anything the gate allows starts with `/workspace/`), checked at build time in the file that ships |

**No Mathlib.** Core Lean plus Batteries-level tactics (`omega`, `decide`, `simp`, `grind`) are enough for the gate and the aashaan, and keep the build small.

## The aashaan's design, and why

`Std` only, ~3.3 MB stripped, ~5.5 MB resident. The source is `Aashaan/Main.lean`.

- **Launch:** `IO.Process.spawn` with `setsid := true` (its own process group, so a kill reaches its children), `inheritEnv := false` and an explicit `PATH` (no secret from our environment), piped stdout and stderr, `stdin := .null`.
- **Wait:** a `tryWait` loop against `IO.monoMsNow`, checking the output cap as the readers fill.
- **Kill:** `Child.kill`, which **actually sends SIGKILL** to the whole group under `setsid` (its docstring wrongly says SIGTERM). A SIGTERM trap never fires.
- **Escape:** a job that calls `setsid` itself leaves the group and survives the kill (POSIX behaviour), and can hold the stdout pipe open. The aashaan bounds its wait on output to 500 ms after a kill and reports `pipe_held_open: true`; microVM teardown ends the job.
- **Exit:** `IO.Process.forceExit`, because a normal exit waits for reader threads still blocked on a pipe an escaped process holds open. That was the first probe's hang.
- **In a microVM:** needs `vm.overcommit_memory=1` (see `sandbox.md`).

`Std.Async.Process` **does not launch processes**: it reports on the current one (`getResourceUsage`, `constrainedMemory` for the cgroup limit, `setPriority`, free and total memory).

## API drift to know

- `String.trim` is now `trimAscii`.
- A request's head in `Std.Http` is `req.line`; the module docs say `req.head`.

## Upstream

Drafted, not yet filed (both documentation):
1. `IO.Process.Child.kill` docstring says SIGTERM; the runtime sends SIGKILL. No existing issue found.
2. `Std.Http` module docs use `req.head`; the field is `req.line` (four places). An earlier fix, [lean4#14722](https://github.com/leanprover/lean4/pull/14722), was closed without merging.

lean4's contribution rules: open an issue before any PR, and note any generative-AI assistance in a PR's description.

Tracked, filed by others:
- [lean4#15681](https://github.com/leanprover/lean4/issues/15681): `Child.pid` leaks the `Child` and its pipe descriptors. The aashaan calls it at most once per run; acceptable for a short-lived process.
- [lean4#15674](https://github.com/leanprover/lean4/issues/15674): `Child.takeStdin` loses `setsid`, so `kill` reaches only the child. **Don't use `takeStdin` in the aashaan.**

Measured again while building `Kalari/Proc.lean`. A `tryWait` loop that sleeps 10 ms fires a 400 ms cap one tick late (417–419 ms). `/bin/sh -c 'cmd'` execs a simple command, so the shell is already gone and a kill never has to reach a child. `/bin/sh -c 'cmd & wait'` keeps the shell. With `setsid`, `Child.kill` then removes both the shell and `/bin/sleep`. `takeStdin` still drops `setsid`. `/bin/sh` with an empty environment runs builtins (`printf`, `exit`) and does not find `sleep`. An output cap of 64 bytes on a print loop returned 64 bytes and `output`. A reader still blocked after the bounded wait keeps its thread, and `lake build` waits for it, so a test that might miss the kill closes the unused pipe.
- [lean4#14546](https://github.com/leanprover/lean4/pull/14546)–[#14548](https://github.com/leanprover/lean4/pull/14548): an HTTP client for `Std.Http`, open. Could replace the `curl` subprocess once merged.

## Reproduce

```bash
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
lake build && ./tools/check.sh          # the gate: build, version, seven aashaan cases
tests/live/microvm-cases.sh             # on the VM: all eight cases in a microVM
```
