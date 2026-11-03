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

**Current status:** scaffold only. The day-one checks are done and recorded in `research/`. The phases are not written yet.

---

## Swarm Coordination Rule

> **Phase-level dependencies are advisory. Task-level dependencies are binding.**

Do not wait for a whole phase to finish. If a task requires only `T1.1`, start it the moment `T1.1` closes.

**Fixtures make most work offline.** Recorded model replies, Vimanam outputs, Lambo transcripts and aashaan verdicts go into `testdata/`. Tasks marked `fixture-ok: yes` run against those files with no key, no VM and no spend. Only `b` tasks call a live service.

---

## Phase Graph

To be written.

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
| Day-one checks | 11 / 11 | Done: recorded in `research/`. B4 re-runs on the next Lambo release |

---

## Handoff Log

Newest first. One entry per closed task, finding, or split.

- **Network route proved.** Each API service runs in its own microVM with egress denied (`--net-default-egress deny`: `--no-net` also blocks ingress, so a published port never answers) and its port published on the VM's public IP. Both arms reach it; the Kalari arm (`--no-net` + an IP and port-range rule) reaches nothing else; the port is dropped from the internet and refused on the tailnet. The reference arm can also reach the VM's SSH (hairpin), noted for the containment comparison.
- **Finding: OpenCode 2's `opencode run` leaves a background daemon** (`opencode serve --service`, with `microsandbox-mcp`) running after the run, holding the inference key in its environment; found half an hour after B5 and stopped. The key was never written to disk. Every run now uses `--standalone` and per-run `XDG_*` directories (both verified), so sessions are isolated and nothing is left behind.
- **Benchmark design reviewed and revised.** Fixed: every arm reaches v1 as well as v2 (Kalari's edge is running the comparison unasked, not having access); lessons come from behaviour observed on a verified pass as well as from failures (or a first-time pass leaves nothing to learn and condition 5 collapses into 4); measures defined once for every arm, with "right first time" meaning the first run against v2 already passes the grader; agent-facing APIs and docs use neutral names, so the model can't recall a vendor's behaviour from training; the route from an arm's sandbox to the API service is proved before the pilot. Added: **condition 6**, the reference setup told to verify against v1, as a control for "Kalari is just a prompt"; a 20-minute cap on every session, with time stuck measured; docs written and frozen before the pilot; results as counts. Dedupe by ID (the dataset is fixed for a run). Pilot ~65 runs, ~$16.
- **Benchmark designed (`bench/README.md`).** DeepSeek is strong, so Kalari's edge must come from what it can't know from specs and docs: behaviour that is undocumented in the spec, visible only at scale, silent, and uncheckable without the truth. User decisions: the v1 API stays live during the migration (so Kalari can check v2's records against v1's); both arms get specs **and** vendor-style prose docs; if the baseline passes the pilot, both harder real behaviours and leading with cost, attempts and containment. Five paging behaviours, each verified in a real API's docs (Zendesk incremental export, Microsoft Graph delta, DynamoDB, RIPE Atlas, RevenueCat). Proposed pair: a REST payout ledger modelled on Zendesk, then a GraphQL settlement connection. Protocol: servers in their own microVM, never readable; the baseline piloted first (~55 runs, ~$14); the pair, docs, prompt and grader frozen before the Kalari arm runs; every run published.
- **Lean guide and verified examples.** `docs/lean.md` and `Examples/`: a proved decision function (three theorems, `omega`, `#guard`), `Lean.Json`, a `Std.Http` server (routing, body cap, 400/404/413, headers), a JSON-RPC stdio loop, and `curl` with the key on stdin. The gate builds and runs them all. Found while writing them: derived `FromJson` ignores structure defaults (use `Option`), JSON errors name the fully qualified field, `compress` sorts keys, `Json.parse` is shadowed inside a `Json` namespace, `readAll` past its cap throws `IO.userError`, and `trimAscii` returns a `Slice`.
- **Scaffold.** Licence (MIT), README, product.md, AGENTS.md, docs/architecture.md, the Lake project with two executables (`kalari` a stub; `kalari-aashaan` the verified day-one supervisor), the gate (`lake build`, `kalari --version`, seven aashaan cases on the host) and CI. `tests/live/microvm-cases.sh` runs all eight cases in a microVM on the VM.
- **Day-one research recorded.** Every check, its commands and its result are in `research/`. The decisions they settled: OpenCode 2 for both comparison arms; DeepSeek V4.1 Flash; Clef for the three judgement calls; Qwen3 Embedding 4B for Lambo at 2560 dimensions; Microsandbox with `--no-net` and IP allow rules; the host on Ubuntu 24.04's 6.8 kernel.
- **Findings filed in Lambo:** [lambo#221](https://github.com/nrynss/lambo/issues/221) (recall ranks an unrelated concept above the right lesson on an uncalibrated embedder) and [lambo#222](https://github.com/nrynss/lambo/issues/222) (`serve` on a new store says it was provisioned by an older lambo). Fixes are in progress; a Lambo release follows, and B4 re-runs on it.
- **Finding for Microsandbox, not yet filed:** domain allow rules (`allow@<domain>:tcp:443`) fail for TLS with `SSLEOFError` in msb 0.7.13, while IP rules work. Issue text to be written.
