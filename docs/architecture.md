# Architecture

How Kalari is built. The product is in [`../product.md`](../product.md); the measurements behind each choice are in [`../dev-diary/research/`](../dev-diary/research/README.md).

## On the VM

```text
Vultr VX1 VM (Ubuntu 24.04, KVM)
├── Caddy (HTTPS, the only public ports: 80, 443)
├── kalari serve (Lean)
│     ├── MCP over stdio or HTTP ◄── OpenCode 2 (the coding agent)
│     ├── HTTP API              ◄── the web app (Chaaya)
│     ├── child: lambo serve    (MCP over stdio; SQLite; embeddings via Vultr)
│     ├── subprocess: vimanam   (change facts as JSON contract v2)
│     ├── subprocess: curl      (Vultr Inference: chat, /systemone for Clef)
│     └── subprocess: msb       (create, copy, exec, stop, remove microVMs)
│                 └── microVM per run (libkrun, own 6.12 kernel, --no-net + IP allow rules)
│                       └── kalari-aashaan ── the untrusted job (empty env, caps)
└── OpenCode 2 (reference arm and Kalari arm of the comparison)
```

SSH reaches the VM over Tailscale only; the Vultr firewall group has no SSH rule.

## The two executables

### `kalari`

One Lake executable, several modules. Planned:

| Module | Job |
|---|---|
| MCP server | JSON-RPC 2.0 over stdio (and streamable HTTP for a remote agent). Exposes the five tools. No Lean MCP library exists; the protocol is small and `Lean.Json` covers it |
| HTTP API | `Std.Http` (ships in 4.35.0): runs, verdicts, evidence, lessons, for the web app |
| Gate | The decision function every `run_in_sandbox` call passes: workspace-only writes, allowlisted network, no secret in any argument, every run capped. Carries the theorems |
| Sandbox backend | One module behind one interface. `microsandbox` (msb CLI) on the VM; `docker` as the generic fallback |
| Model client | OpenAI-compatible chat through `curl`. No provider names in code |
| Decision client | System One format (`/v1/systemone`): Clef's three questions |
| Lambo client | MCP over a child process's pipes. Kalari is Lambo's single writer |
| Vimanam runner | Subprocess, JSON contract v2, `--context --max-tokens` for focused model context |
| Evidence store | Every run: inputs, verdict, logs, timings, tokens. The source for the judges' page |
| Code search | Finds where the consumer calls a changed operation (endpoint path, GraphQL field, RPC name). Writes those links to Lambo |

### `kalari-aashaan`

`Std` only. Usage: `kalari-aashaan <timeout-ms> <output-cap-bytes> <cmd> [args...]`. Spawns the job with `setsid`, an empty environment and an explicit `PATH`; reads stdout and stderr up to the cap; polls with `tryWait` against a monotonic clock; on timeout or cap, `Child.kill` (SIGKILL to the whole group); bounds its wait on output to 500 ms after a kill; prints one JSON verdict and exits with `IO.Process.forceExit`.

Verdicts: `exited` (with `exit_code`), `killed_timeout`, `killed_output_cap`. Also `wall_ms`, `stdout`, `stdout_truncated`, `stderr`, `pipe_held_open`, `supervisor_peak_rss_kb`, `cgroup_memory_limit`.

A job that starts its own session escapes the group kill and can hold a pipe open; the verdict reports `pipe_held_open: true`, and microVM teardown ends it.

## A sandbox run

1. The gate checks the call. A refusal never reaches `msb`.
2. Kalari resolves each allowed hostname to IPs.
3. `msb create --name <run> --cpus 1 --memory <M> --no-net --net-rule allow@<IP>/32:tcp:<port> … debian` (~0.5 s).
4. `msb copy` the workspace and the aashaan in; `echo 1 > /proc/sys/vm/overcommit_memory` in the guest.
5. `msb exec <run> -- kalari-aashaan <caps> <command>`; checks run the same way.
6. `msb stop` and `msb remove` (~0.1 s). The verdict and logs go to the evidence store.

## Models (Vultr Serverless Inference)

| Job | Model |
|---|---|
| The coding agent (both arms) | `deepseek-v4.1-flash-1017`, reasoning effort `low` |
| Clef's three questions | `clef` at `/v1/systemone` |
| Lambo's embeddings | `qwen3-embedding-4b`, 2560 dimensions (BGE M3 isn't served) |

## Configuration

`kalari.toml` (gitignored), with providers by kind and keys by environment-variable name:

```toml
[models]      # OpenAI-compatible endpoint, model, api_key_env
[decisions]   # System One endpoint, model, api_key_env
[sandbox]     # backend = "microsandbox" | "docker", caps, network allowlist
[lambo]       # command, config path
```

## Repository layout (planned)

```text
Kalari/            the kalari executable's modules
Examples/          verified Lean examples for agents (docs/lean.md), built and run by the gate
Aashaan/           kalari-aashaan
tests/             the gate's tests; tests/live/ for live runs
testdata/          recorded replies and fixtures
web/               the Chaaya front end
bench/             the comparison: demo API pairs, graders, run scripts
deploy/vultr/      the Vultr preset: VM setup, Caddyfile, Microsandbox install, config
deploy/local/      the generic preset
dev-diary/         phases, handoff log, research
docs/              this file and other reference
```

## Writing it

The Lean patterns for each module above (HTTP server, JSON, JSON-RPC over stdio, processes, outbound HTTPS, proofs) are in [`lean.md`](lean.md), each with a verified example in `Examples/`.

## Dependencies

| Dependency | How | Why |
|---|---|---|
| Lean 4.35.0 + Std | Toolchain | The executables and the proofs |
| Vimanam | CLI subprocess | Change facts across OpenAPI and protobuf (2.0.0) and GraphQL (`main`, unreleased), including `pagination_changed` within the limits in `dev-diary/research/vimanam.md` |
| Lambo | `lambo serve`, MCP over stdio | Lessons, links, canonization, staleness |
| Microsandbox (`msb`) | CLI subprocess | microVMs with their own kernel and a network policy |
| `curl` | Subprocess | Outbound HTTPS (Lean has no HTTP client or TLS) |
| Caddy | In front of `kalari` | TLS |
| Chaaya | `web/` | The front end |
