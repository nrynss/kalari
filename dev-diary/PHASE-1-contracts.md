# P1: Contracts

The types, the configuration, the process runner and the interfaces every other task codes against, and the module layout. These freeze at the end of P1: after that, changing one is the orchestrator's call and updates `testdata/` in the same commit.

P1 runs in order, one task at a time. It is the serial bottleneck: keep it small and exact.

Read first: [`../docs/architecture.md`](../docs/architecture.md), [`../docs/lean.md`](../docs/lean.md), [`PHASE-0-ground.md`](PHASE-0-ground.md) and what P0 recorded in `testdata/`.

---

### T1.1: Core model ★
```yaml
requires:   [T0.3]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Model.lean
status:     not-started
```
The types the tools pass around, each with `FromJson`/`ToJson`: `ChangeFact` (Vimanam's change ID and kind, kept as Vimanam's strings), `Check` (an ID, what it asserts, how to run it), `Lesson` (change kind, observation, the run that showed it, its check, its Lambo concept ID), `RunRequest` (workspace, command, caps, network allowlist), `Verdict` (the aashaan's fields), `RunRecord` (request, verdict, checks and their results, timings, tokens if known), `BlastRadius` (change ID to call sites).

Optional fields are `Option`s: derived `FromJson` ignores defaults (`docs/lean.md`).

**Done when:** every type round-trips through JSON in a test; the aashaan's recorded verdicts (T0.5) parse as `Verdict`; Vimanam's recorded change facts (T0.3) parse as `ChangeFact`; nothing in the module names a provider.

---

### T1.2: Configuration
```yaml
requires:   [T1.1]
fixture-ok: yes
size:       S · frontier
owns:       Kalari/Config.lean, testdata/config/
status:     not-started
```
`[models]`, `[decisions]`, `[sandbox]`, `[lambo]` (architecture.md, Configuration). Keys by environment-variable name, never values.

**Decision for the user, through the orchestrator:** the format. TOML (as planned) needs a parser: Lean has none in `Std`, and Lake's links the compiler. JSON (`kalari.json`) is already parsed by `Lean.Json`. Bring both options with the cost of each.

**Done when:** a config file in `testdata/config/` loads; a missing key variable is an error naming it; a key value in the file is rejected.

---

### T1.3: Process runner ★
```yaml
requires:   [T1.1]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Proc.lean
status:     not-started
```
One way to run a subprocess for every caller (msb, Vimanam, curl, the code search): argv, an explicit environment (never inherited unless asked), optional stdin, a wall-clock cap, an output cap, and a result with exit code, stdout, stderr, wall time and whether a cap fired. The patterns in `Aashaan/Main.lean` and `Examples/Curl.lean`; the traps in `docs/lean.md` (`takeStdin` drops `setsid`; `Child.pid` leaks).

**Done when:** tests cover a normal run, a non-zero exit, a timeout, an output cap, stdin delivery, and an empty environment (a variable set in the parent isn't seen).

---

### T1.4: Backend interfaces and fakes ★
```yaml
requires:   [T1.1, T1.3]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Backend.lean, Kalari/Fake.lean
status:     not-started
```
The seams, each one structure of functions so a backend is one module: `SandboxBackend` (create with caps and a network allowlist, copy in, exec, copy out, destroy), `DecisionClient` (System One questions in, typed answers out), `MemoryClient` (derive, inspect, recall, against), `ChangeSource` (two spec versions in, change facts out). Fakes for each that replay `testdata/`, failing loudly on a miss.

**Done when:** each fake serves its recordings in a test; nothing in the interfaces names Vultr, Microsandbox, Lambo, Clef or Vimanam.

---

### T1.5: Module layout and dispatch ★
```yaml
requires:   [T1.4]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Main.lean, Kalari.lean, lakefile.toml, and an empty stub of every module named in P2–P6
status:     not-started
```
A library (`Kalari.lean` importing every module) and the thin `kalari` executable. Commands: `kalari serve` (MCP over stdio for the agent, plus the HTTP API), `kalari check <config>` (load and validate the config, reach each backend), `kalari --version`. Each module the later phases fill exists as a stub with a one-line doc comment: `Kalari/Gate.lean`, `Kalari/Sandbox/Microsandbox.lean`, `Kalari/Sandbox/Docker.lean`, `Kalari/Vimanam.lean`, `Kalari/Lambo.lean`, `Kalari/Clef.lean`, `Kalari/Search.lean`, `Kalari/Mcp.lean`, `Kalari/Tools/Changes.lean`, `Kalari/Tools/Recall.lean`, `Kalari/Tools/Run.lean`, `Kalari/Tools/Lesson.lean`, `Kalari/Evidence.lean`, `Kalari/Http.lean`.

After this task no one edits `Kalari/Main.lean`, `Kalari.lean` or `lakefile.toml` without the orchestrator's approval.

**Done when:** `kalari --help` prints the commands; each stub command exits 2 with "not implemented yet"; every module exists and is imported; the gate passes.

---

## Exit Criteria

- [ ] Types, config, process runner and interfaces frozen.
- [ ] Every later module exists as a stub.
