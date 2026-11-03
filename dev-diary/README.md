# Development Diary: Phase Handoffs

This document breaks down the work for **Kalari**, the Vultr: Agent Rush hackathon entry (challenge "Blast Radius Zero").

Reference specification:
- [`../product.md`](../product.md): the product, the tools, the demo, the comparison, the hackathon rules, the cautions.
- [`../docs/architecture.md`](../docs/architecture.md): the executables, a sandbox run, the models, the configuration, the dependencies.
- [`research/`](research/README.md): what was measured on the real stack before any code: Vultr Inference, the VM, Microsandbox, Lean, Lambo, the coding agent. **Read the file for your area first.**
- [`ORCHESTRATOR.md`](ORCHESTRATOR.md): how the orchestrator dispatches, validates, lands and closes, with the brief template.
- [`../AGENTS.md`](../AGENTS.md): the rules every agent follows.

Where a phase document and product.md conflict, product.md wins. Record the discrepancy in the handoff log.

Each phase document gives an engineer starting cold the complete context for its tasks.

**This diary is public.** The repository goes public for submission. Nothing private goes in here: no key, no account detail, no IP address, no instance ID, no personal path beyond `~`, no private repository's name.

**Current status:** P0: T0.1, T0.2, T0.3, T0.5 done; T0.4 (Lambo) and T0.6 (Vimanam) blocked on their next releases. P1 done (T1.1 through T1.5). T2.1 and T2.3 done. T2.2 is ready; the gate has no `msb`, so its microVM clause cannot be re-run there. T5.1 ready. The pilot (T5.2) waits for T0.6. Open user decision: the pilot's spend (T5.2).

---

## Swarm Coordination Rule

> **Phase-level dependencies are advisory. Task-level dependencies are binding.**

Do not wait for a whole phase to finish. If a task requires only `T1.1`, start it the moment `T1.1` closes.

**Fixtures make most work offline.** Recorded model replies, Vimanam outputs, Lambo transcripts and aashaan verdicts go into `testdata/`. Tasks marked `fixture-ok: yes` run against those files with no key, no VM and no spend. Only `b` tasks call a live service.

---

## Phase Graph

| Phase | Document | Requires | Runs parallel with | Blocks |
|---|---|---|---|---|
| **P0** Ground | [PHASE-0-ground.md](PHASE-0-ground.md) | none | none | everything |
| **P1** Contracts | [PHASE-1-contracts.md](PHASE-1-contracts.md) | T0.3 | the pilot (T5.1, T5.2) | P2–P4, P6 |
| **P2** Containment | [PHASE-2-containment.md](PHASE-2-containment.md) | P1 | P3 | `run_in_sandbox` (T4.5) |
| **P3** Integrations | [PHASE-3-integrations.md](PHASE-3-integrations.md) | P1, T0.4 for Lambo | P2 | P4 |
| **P4** The tools | [PHASE-4-tools.md](PHASE-4-tools.md) | P2, P3 | the pilot | the Kalari arm (T5.4) |
| **P5** The benchmark | [PHASE-5-benchmark.md](PHASE-5-benchmark.md) | T0.2 for the harness, T0.6 for the pilot; T4.7 and the freeze for the Kalari arm | P1–P4 (the pilot) | P7 |
| **P6** Surfaces | [PHASE-6-surfaces.md](PHASE-6-surfaces.md) | T4.2 | P5 | P7 |
| **P7** Ship | [PHASE-7-ship.md](PHASE-7-ship.md) | P5, P6 | none | submission |

```text
  P0 ──▶ P1 ──┬──▶ P2 containment ──┐
              └──▶ P3 integrations ─┴──▶ P4 tools ──▶ T4.7 ──┐
  T0.2 ──▶ T5.1 harness ──▶ T5.2 pilot ──▶ T5.3 freeze ──────┴──▶ T5.4 Kalari arm ──▶ T5.6 results ──┐
                                           T5.3 ──▶ T5.5 reference arm ───────────────▶ T5.6        ├──▶ P7 ship
              P4's evidence store ──▶ P6 surfaces ───────────────────────────────────────────────────┘
```

P1 is the serial bottleneck. **The pilot runs beside the whole build**: it needs only the benchmark APIs (done) and the harness, never Kalari's code. That is what the protocol needs: the baseline is measured and the pair frozen before the Kalari arm's first run.

---

## Parallel Tracks

| Track | Phase | Network required? | First task | Notes |
|---|---|---|---|---|
| **A: Pilot** | P5 | Yes (VM, Vultr Inference) | T5.1 | The harness starts now; the pilot runs once Vimanam's release lands (T0.6). Spend approved by the user before T5.2 |
| **B: Contracts** | P1 | No | T1.1 (after T0.3) | Serial; small and exact |
| **C: Containment** | P2 | `b` tasks only | T2.1 | The proved gate and the aashaan. The product's safety claims live here |
| **D: Integrations** | P3 | `b` tasks only | T3.1, T3.3, T3.4 | T3.2 (Lambo) waits for T0.4, or starts on the 0.8.0 transcripts if the orchestrator says so |
| **E: Surfaces** | P6 | T6.3 only | T6.1 | Starts when the evidence store (T4.2) lands |

If capacity is short, run A and C first: A decides what the comparison can show, and C is what every run's safety rests on.

---

## Critical Path

```
Vimanam on the specs (T0.3) + recordings (T0.5)
  -> core model (T1.1) -> config (T1.2) -> process runner (T1.3) -> interfaces (T1.4) -> layout (T1.5)
  -> gate (T2.1) -> Microsandbox backend (T2.3)
  -> MCP server (T4.1) + evidence (T4.2) -> run_in_sandbox (T4.5) -> record_lesson (T4.6) -> with OpenCode (T4.7)
  harness (T5.1) -> pilot (T5.2) -> freeze (T5.3)
  -> Kalari arm (T5.4) + reference arm (T5.5) -> results (T5.6)
  -> web app (T6.2) -> deploy (T6.3) -> README (T7.1) -> video (T7.2) -> public (T7.3) -> submit (T7.4)
```

The demo rests on one story: a payout export that returns 200 and silently loses or double-pays merchants, an agent whose runaway loop the aashaan kills, and a lesson that makes the second upgrade, in another format, right first time. Protect everything that moment depends on before anything else.

---

## Task Pattern

```markdown
### T2.2: The gate ★
requires:   T1.2, T2.1
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Gate.lean
status:     not-started
```

- **requires:** Binding task ids.
- **fixture-ok:** Whether the task can be built and tested against `testdata/` alone.
- **size:** Scope from XS to XL, then the class: the kind of work it is. The user assigns the agent and model.
- **owns:** The paths this task alone edits.
- **status:** `not-started`, `claimed:<agent>`, `in-review`, `done`, `blocked`, or `superseded` (the user replaced the task's plan; the task says by what).

| Class | Send it for |
|---|---|
| **frontier** | A decision others build on. Proofs. Prompt and judgement work verified by measurement. A spec that needs interpreting. |
| **mid** | Well specified implementation, or a spec precise enough to follow literally. |
| **light** | Mechanical, low ambiguity work that its own test verifies. |
| **user** | Only the user can do it: an account, a key, a VM, a recording, a submission, a decision. |

A star (★) marks a task on the critical demo path.

A `b` task (T3.3b) is the live sibling of its parent. It owns only its live test, under `tests/live/`. A live test never runs in CI and never gates a build. A live call is evidence: commit the test, and paste its transcript into the handoff log.

---

## Developer Guidelines

1. **Claim before starting.** The orchestrator sets `status: claimed:<agent>` in the phase document on `main`.
2. **Stay inside `owns`.** A change outside it is a new task or a handoff note.
3. **Contracts freeze at the end of P1.** A change to a shared type or interface updates its fixtures in `testdata/` in the same commit, and is the orchestrator's call.
4. **No provider names in the Lean code.** Vultr, OpenCode and Microsandbox are config and presets. A new backend is one module and nothing else.
5. **The gate is decided, never a model's word.** Proved properties stay proved: a change that breaks a theorem fails the build.
6. **Every lesson traces to a run.** A lesson without a sandbox-verified outcome and a Clef `api_change` attribution is not written.
7. **Containment holds in every run.** `--no-net` with IP rules, the aashaan's caps, an empty environment, teardown after the task. See AGENTS.md, Sandboxes.
8. **New work only.** Write it here. Never copy code from Lambo, Vimanam or any earlier project.
9. **Gaps in Vimanam, Lambo or Microsandbox become issues.** Write the issue text in the handoff log. Don't work around it here. The user files it.
10. **Document handoffs.** A task without a handoff entry is unfinished. Record what exists, what surprised you, and what the next agent should not have to work out again.

---

## Scope

Every task here ships. A task that turns out to be blocked becomes a finding, not a cut. Record it, name every task that depends on it, and mark it `blocked`. If a task is too large, split it into `T3.1a` beside `T3.1` and record the split.

---

## Status Board

| Phase | Tasks complete | Status |
|---|---|---|
| P0 | 4 / 6 | T0.1, T0.2, T0.3, T0.5 done. T0.4 (Lambo) and T0.6 (Vimanam) blocked on their next releases |
| P1 | 5 / 5 | T1.1 through T1.5 done |
| P2 | 2 / 5 | T2.1 and T2.3 done. T2.2 ready |
| P3 | 0 / 6 | Waits for P1 |
| P4 | 0 / 8 | Waits for P2, P3 |
| P5 | 0 / 6 | T5.1 ready now. T5.2 (pilot) waits for T0.6 |
| P6 | 0 / 3 | Waits for T4.2 |
| P7 | 0 / 4 | Waits for P5, P6 |

---

## Handoff Log

Newest first. One entry per closed task, finding, or split.

- **T2.3 closed: the Microsandbox backend.** `Kalari.Sandbox.Microsandbox` is a `SandboxBackend` over the `msb` CLI. Create is `msb create --name <name> --cpus 1 --memory <mib>M --no-net`, then one `--net-rule allow@<host>/32:tcp:<port>` per allow entry, then `debian`. An empty allowlist still passes `--no-net` and adds no rule. A run copies the workspace and the aashaan in, writes `1` to `/proc/sys/vm/overcommit_memory`, execs the job, copies results out, and runs `msb remove`. A failed create is not removed. Exit 3 is still removed, and the result returned is the job's. `exec` on a stopped sandbox starts it again, so stop is not the end of a run. `make` takes a runner. The checks replay `testdata/msb` and do not call `live`. `live` binds `Proc.run` with an explicit `PATH`. `kalariNames` keeps names from `msb list --format json` that start with `kalari-`. The process that starts Kalari uses `UMask=0022`. This module does not set a umask. The P2 line about untrusted code running only through this backend stays open until that is the only run path.
- **T2.1 closed: the proved gate.** `Kalari.Gate.decide` takes a `RunRequest`, the configured `Caps`, the configured allowlist, and the secret values. `(true, none)` allows. `(false, some reason)` refuses, and the reason is `workspace`, `allowlist`, `caps`, `secret`, or `key-shape`. The only import is `Kalari.Model`. It does not import `Kalari.Config` and does not read the environment. A path is inside the workspace on a `/` boundary: `/workspace` does not allow `/workspace-evil`. The leading empty segment from `splitOn "/"` is the root marker. An empty secret is skipped before `String.contains`, because the empty pattern matches every string. Key shape is 32 or more ASCII letters or digits in a row. Four theorems, no `sorry`. The allow `#guard` is a real run, so a gate that refuses everything fails the build. The secret check also covers allowlist hosts; the theorem states the workspace and the command arguments. Cap comparisons call `Decidable.decide`, because `decide` would shadow it.
- **T1.5 closed: module layout and dispatch.** `Kalari.lean` is the library root. It imports every library module and does not import `Kalari.Main`. `Kalari/Main.lean` keeps the imports of `Model`, `Config`, `Proc`, `Backend`, and `Fake`, and adds `import Kalari`. That import is what makes `lake build` elaborate the stubs. `lakefile.toml` is unchanged and still has `[[lean_lib]] name = "Kalari"`. The fourteen later modules are a one-line module doc and no definitions. `kalari --help` exits 0 and names `serve`, `check`, and `--version`. `serve` and `check` exit 2 with `not implemented yet`. `check` matches the head word, so a path is never opened and the environment is never read. `--version` is `kalari 0.1.0`. A module doc cannot sit above `import` in 4.35. P1 is frozen: the types, the config, the process runner, the interfaces, and this layout. `Kalari/Main.lean`, `Kalari.lean`, and `lakefile.toml` change only with the orchestrator's approval.
- **T1.4 closed: backend interfaces and recording fakes.** `Kalari/Backend.lean` is four structures of functions and names no provider. `SandboxBackend` is `create` (name, `Caps`, allowlist), `copyIn`, `exec`, `copyOut`, and `destroy`; each returns `Proc.Result`. `DecisionClient.ask` takes a question-set name and returns `DecisionAnswer`: `label` (choice, probabilities, confidence), `probabilities` (one number per question), or `error` (status and message). `MemoryClient` is `derive`, `inspect`, `«recall»`, and `against`; each takes a string key. `ChangeSource.diff` takes two spec paths and returns `List ChangeFact`. `Kalari/Fake.lean` replays `testdata/msb`, `testdata/clef` (including `over-length`, status 422), and `testdata/vimanam`. A miss is `no recording for <key>`, not an empty list and not a success. A recorded non-zero exit is still a replay. The sandbox match is the argv row: an allowlisted create is `create-ok`; the same name and memory with an empty allowlist is the duplicate-name row; `destroy` replays remove, not stop. Noul values come from the response body, not the index's three-decimal rounding. `recall` is a Lean command keyword, so the field is `«recall»`. `ask` and the memory operations stay this thin through the rest of P1. Widening `Kalari/Backend.lean` so T3.2 can pass a concept body, or T3.3 a question payload, is the orchestrator's call and is not part of T1.5.
- **T1.3 closed: the process runner.** `Kalari.Proc.run` is the one subprocess entry: argv, an explicit environment, `inheritEnv` default false, optional stdin, a wall-clock cap and an output cap. `Result` carries `exitCode` (`none` when a cap killed the process), stdout and stderr clipped to the cap, `wallMs`, and `cap` (`none`, `timeout`, or `output`). No stdin uses `setsid`, so the kill reaches grandchildren. Stdin uses `takeStdin`, which drops `setsid`, so that path does not claim a group kill. `Child.pid` is not called. Pipes are read with `IO.asTask`. The wait after a kill stops at 500 ms. A 400 ms cap returned at 417 ms. `/bin/sh -c` execs a simple command, so the timeout test is `sleep 30 & wait`, which keeps the shell; both the shell and the sleep are gone afterwards. `/bin/sh` with an empty environment runs builtins and does not find `sleep`.
- **T1.2 closed: `kalari.json`.** `Kalari/Config.lean` parses the four sections. `parse` does not touch the environment. `load` checks that each `api_key_env` is set and stores the name only. A string that is not an environment-variable name, and a field named `api_key`, both fail with `environment variable name required` and the rejected text is not in the error. An unset variable is reported as `<field>: <name> is not set`. `sandbox.caps` is `Kalari.Model.Caps` and `allowlist` is `List AllowHost`. `backend` is `microsandbox` or `docker`. The fixture `testdata/config/kalari.json` names `KALARI_TEST_KEY` only. `.gitignore`'s `kalari.json` matches every directory, so the fixture is force-added. `IO.getEnv` is used as `Option.isSome` on the load path. Restoring a variable in a test uses `Std.Async.System.setEnvVar`, because `Init` has no setter. The gate does not need a real key.
- **T1.1 closed: the core model.** `Kalari/Model.lean` is the wire types: `ChangeFact` (`id` and `kind` only; unknown keys ignored), `Check`, `Lesson` (`memory_concept_id` optional), `RunRequest` with `Caps` and `AllowHost`, `Verdict` (the supervisor's snake_case keys; `exit_code` optional; `cgroup_memory_limit` a `Nat`), `RunRecord`, `BlastRadius`. The eight recorded verdicts in `testdata/aashaan/verdicts.jsonl` and three recorded change objects parse. Derived JSON uses the field name as the key. A field ending in `?` would omit `none`; none of these do, so `none` is null. `UInt64`'s `FromJson` expects a string, and the supervisor prints `cgroup_memory_limit` as a number (0 in the recordings, 2^64−1 on an unconstrained host), so the field is `Nat`. Lake 5 does not build a module that only an executable imports: `lakefile.toml` has `[[lean_lib]] name = "Kalari"`, and T1.5 must keep that. The operation coordinate is not on `ChangeFact`; add an `Option` before P1 freezes if a later task must read it off the fact.
- **Decided: config is JSON.** T1.2 loads `kalari.json`, parsed by `Lean.Json`. Keys stay environment-variable names. `docs/architecture.md` now says so.
- **Benchmark APIs built** (`bench/apis`, `bench/workspaces`, `bench/graders`, `bench/prompts`). Payouts (REST, 2,431 records: B1 a fresh cursor on every response with `drained`, B2 a one-payout window overlap, B4 `limit` capped at 100) and settlements (GraphQL on vendored graphql-core 3.3.1, 1,873 records: B1 `endCursor: String!`, B2 19 amended repeats, B3 four 200-row void runs, so every page size meets empty pages). Neutral vendor names (Tallyline, Clearwell); `QUIRKS.md` records where each behaviour is documented. `bench/tests/quirks.sh`, now in the gate, runs six reference consumers per service: v1 unchanged crashes (410 after cutover), single page and short- or empty-page stops lose records, the cursor loops never end, appending duplicates (24 and 19), the correct ones pass. Deployed on the VM: live (v1 on) :18080/:18081, grading (v1 retired) :18090/:18091, each in its own microVM; from a Kalari-arm sandbox the same outcomes hold; closed from outside. Open: Vimanam's verdict on these specs (the local binary is a stale 1.4.2 build; needs 2.0.0).
- **Network route proved.** Each API service runs in its own microVM with egress denied (`--net-default-egress deny`: `--no-net` also blocks ingress, so a published port never answers) and its port published on the VM's public IP. Both arms reach it; the Kalari arm (`--no-net` + an IP and port-range rule) reaches nothing else; the port is dropped from the internet and refused on the tailnet. The reference arm can also reach the VM's SSH (hairpin), noted for the containment comparison.
- **Finding: OpenCode 2's `opencode run` leaves a background daemon** (`opencode serve --service`, with `microsandbox-mcp`) running after the run, holding the inference key in its environment; found half an hour after B5 and stopped. The key was never written to disk. Every run now uses `--standalone` and per-run `XDG_*` directories (both verified), so sessions are isolated and nothing is left behind.
- **Benchmark design reviewed and revised.** Fixed: every arm reaches v1 as well as v2 (Kalari's edge is running the comparison unasked, not having access); lessons come from behaviour observed on a verified pass as well as from failures (or a first-time pass leaves nothing to learn and condition 5 collapses into 4); measures defined once for every arm, with "right first time" meaning the first run against v2 already passes the grader; agent-facing APIs and docs use neutral names, so the model can't recall a vendor's behaviour from training; the route from an arm's sandbox to the API service is proved before the pilot. Added: **condition 6**, the reference setup told to verify against v1, as a control for "Kalari is just a prompt"; a 20-minute cap on every session, with time stuck measured; docs written and frozen before the pilot; results as counts. Dedupe by ID (the dataset is fixed for a run). Pilot ~65 runs, ~$16.
- **Benchmark designed (`bench/README.md`).** DeepSeek is strong, so Kalari's edge must come from what it can't know from specs and docs: behaviour that is undocumented in the spec, visible only at scale, silent, and uncheckable without the truth. User decisions: the v1 API stays live during the migration (so Kalari can check v2's records against v1's); both arms get specs **and** vendor-style prose docs; if the baseline passes the pilot, both harder real behaviours and leading with cost, attempts and containment. Five paging behaviours, each verified in a real API's docs (Zendesk incremental export, Microsoft Graph delta, DynamoDB, RIPE Atlas, RevenueCat). Proposed pair: a REST payout ledger modelled on Zendesk, then a GraphQL settlement connection. Protocol: servers in their own microVM, never readable; the baseline piloted first (~55 runs, ~$14); the pair, docs, prompt and grader frozen before the Kalari arm runs; every run published.
- **T0.5 closed: recordings of Clef, msb, OpenCode and the aashaan** in `testdata/`. Clef answered all nine benchmark cases right and reads at most 262,144 tokens (a 422 beyond). msb has JSON output only for `list`, and **`exec` on a stopped sandbox restarts it**: T2.3 must remove sandboxes, never just stop them. OpenCode 2.2.5 sends `initialize`, `notifications/initialized`, `tools/list`, `tools/call`; with Code Mode off it names tools `<server>_<tool>`. P0 tasks close without review (user decision).
- **Decided: wait for Vimanam.** The benchmark specs stay as built; the pilot (T5.2) now requires T0.6, a Vimanam release that reports `pagination_changed` on both specs, so the baseline and the Kalari arm read the same specs. The harness (T5.1) and everything not behind Lambo go ahead.
- **Vimanam issues filed:** [#136](https://github.com/noemaforge/vimanam/issues/136) release with GraphQL, [#137](https://github.com/noemaforge/vimanam/issues/137) version prefixes, [#138](https://github.com/noemaforge/vimanam/issues/138) continuation fields, [#139](https://github.com/noemaforge/vimanam/issues/139) `nodes` connections, each with a test matrix of real runs.
- **T0.3 closed: Vimanam misses `pagination_changed` on both benchmark specs as built.** 2.0.0 (crates.io) has no GraphQL: #133 was merged after the tag, so only `main` parses the settlements schema; the research note that said all three formats shipped in 2.0.0 was wrong, and is corrected. OpenAPI matches operations by method and path, so `/v1/payouts` → `/v2/payouts` is removed + added; the continuation list lacks `cursor`. GraphQL needs `edges { node }`; a `nodes`-only connection isn't recognised. Each rule fires once its condition is met (probes in `testdata/vimanam/probes/`). Three issue texts in `research/vimanam.md` for the user to file, plus a release with #133. User decision: fix Vimanam, adopt detectable real-world spec shapes before the pilot, or both.
- **Phases planned.** P0–P7 written with every task in the pattern above. The pilot runs beside the build, since it needs no Kalari code. Open user decisions: the config format (T1.2), the pilot's spend (T5.2).
- **Lean guide and verified examples.** `docs/lean.md` and `Examples/`: a proved decision function (three theorems, `omega`, `#guard`), `Lean.Json`, a `Std.Http` server (routing, body cap, 400/404/413, headers), a JSON-RPC stdio loop, and `curl` with the key on stdin. The gate builds and runs them all. Found while writing them: derived `FromJson` ignores structure defaults (use `Option`), JSON errors name the fully qualified field, `compress` sorts keys, `Json.parse` is shadowed inside a `Json` namespace, `readAll` past its cap throws `IO.userError`, and `trimAscii` returns a `Slice`.
- **Scaffold.** Licence (MIT), README, product.md, AGENTS.md, docs/architecture.md, the Lake project with two executables (`kalari` a stub; `kalari-aashaan` the verified day-one supervisor), the gate (`lake build`, `kalari --version`, seven aashaan cases on the host) and CI. `tests/live/microvm-cases.sh` runs all eight cases in a microVM on the VM.
- **Day-one research recorded.** Every check, its commands and its result are in `research/`. The decisions they settled: OpenCode 2 for both comparison arms; DeepSeek V4.1 Flash; Clef for the three judgement calls; Qwen3 Embedding 4B for Lambo at 2560 dimensions; Microsandbox with `--no-net` and IP allow rules; the host on Ubuntu 24.04's 6.8 kernel.
- **Findings filed in Lambo:** [lambo#221](https://github.com/nrynss/lambo/issues/221) (recall ranks an unrelated concept above the right lesson on an uncalibrated embedder) and [lambo#222](https://github.com/nrynss/lambo/issues/222) (`serve` on a new store says it was provisioned by an older lambo). Fixes are in progress; a Lambo release follows, and B4 re-runs on it.
- **Finding for Microsandbox, not yet filed:** domain allow rules (`allow@<domain>:tcp:443`) fail for TLS with `SSLEOFError` in msb 0.7.13, while IP rules work. Issue text to be written.
