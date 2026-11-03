# Kalari

**Rehearse every API upgrade in a contained arena, and learn from every fall.**

The spec. Where a dev-diary document and this file conflict, this file wins. The evidence behind each decision is in [`dev-diary/research/`](dev-diary/research/README.md).

## The product

An API consumer has to move to a new version of an API it depends on. A coding agent can write the migration, but its result can't be trusted on its word: the obvious migration often returns HTTP 200 and still loses data. In the reference run, a v1 importer exited 0 with "imported 100 items" while 2,331 of 2,431 records were gone.

Kalari is a tool, not an agent. It plugs into the coding agent the developer already uses, over MCP, and gives it:

| Tool | What it does | Backed by |
|---|---|---|
| `what_changed` | The change list between two API versions, with stable change IDs | Vimanam (CLI, called as a subprocess) |
| `blast_radius` | The callers, tests and earlier decisions each change touches | Kalari's code search, links stored in Lambo |
| `recall_lessons` | Lessons for these kinds of change, returned **as checks that must pass** | Lambo |
| `run_in_sandbox` | The proved gate, then a throwaway microVM run by the aashaan; returns the verdict and logs | Kalari + Microsandbox |
| `record_lesson` | Stores what failed and what fixed it, keyed by change kind | Lambo |

The agent does the coding. Kalari decides what has to be checked, what is at stake, what was learned, and whether the result is proved. The web app shows each run and its evidence.

Two layers of safety: **before acting**, the blast radius shows what is at stake; **while acting**, the sandbox contains the damage.

### User flow

1. The user gives a consumer repository and the target API version (two specs, or a Git ref pair).
2. `what_changed` lists the changes; `blast_radius` shows what they touch; `recall_lessons` returns checks from earlier upgrades.
3. The agent writes the migration and calls `run_in_sandbox`. The consumer runs against the new API in a microVM with time, output and network caps; the checks run; the microVM is destroyed.
4. On failure, the verdict, the logs and any matching lesson go back to the agent, and it retries. The retry loop is visible in the web app.
5. On success, the user gets the patch, the passing evidence and the run history. Only a sandbox-verified outcome becomes a lesson (`record_lesson`).

### Three kinds of judgement

| For | Decided by |
|---|---|
| What must never happen (writes outside the workspace, network beyond the allowlist, secrets in arguments, uncapped runs) | **Proofs**: the gate's decision function carries theorems checked at build time |
| Whether the upgrade works | **Sandbox runs** and a hidden grader, never a model's word |
| The calls in between: why a run failed, whether a code location really calls a changed operation, whether a recalled lesson applies | **Clef** (decision models on Vultr Inference), answering fixed questions with probabilities. Logged as a model's opinion, never shown as a measurement. Never in the gate, never the verdict |

Only failures Clef attributes to the API change become lessons, so a flaky run or a broken test setup can't teach the memory something wrong.

## The demo: two upgrades, two formats

1. **Upgrade one (REST).** The obvious migration gets HTTP 200 but only the first page; the check catches it. The next attempt follows the page token wrongly and **loops forever, and the aashaan's time cap kills it**: the containment moment, from a real API change, not a staged `rm -rf`. The agent repairs it, it passes, and Kalari records the lesson.
2. **Upgrade two (GraphQL or gRPC).** Vimanam reports the same kind of change, `pagination_changed`, in another format. Lambo recalls the lesson by traversal from the change kind, and the first attempt handles paging correctly.
3. **The measured difference:** sandbox runs, retries, seconds and tokens on the second upgrade. Every claim links to a real run's log.

Frame the stakes as silent data loss: the import that returns 200 and drops records. Pick demo APIs where losing records clearly costs something. Use demo API pairs of our own choosing, not ones from earlier projects.

## The comparison

Both arms run **the same OpenCode 2 with the same model**, DeepSeek V4.1 Flash on Vultr Inference. The only difference is whether Kalari is plugged in. **The baseline is Vultr's own reference setup**: OpenCode with Microsandbox through `microsandbox-mcp`, as in Vultr's agent sandboxing guide, with the key kept out of the config file.

| # | Condition |
|---|---|
| 1 | Reference setup, one continuous session across both upgrades |
| 2 | Reference setup, new session for upgrade two, reading the notes it wrote after upgrade one |
| 3 | Reference setup, fresh session, no notes (first to drop if the budget is tight) |
| 4 | OpenCode + Kalari, no stored lessons (separates the pipeline's effect from memory's) |
| 5 | OpenCode + Kalari, with the lesson from upgrade one |

Measured on upgrade two: first-attempt pass on the hidden grader (the headline), attempts and sandbox runs, wall time, tokens, and records lost by any version that "succeeded" but fails the grader. Three to five repeats per condition. If condition 1 also passes first time, the edge is durability, sharing and enforcement, not first-attempt recall: say so plainly.

**A containment difference the reference setup can't close:** there, the agent chooses each sandbox's network setting. In the reference run it chose none, so its sandbox could reach the internet and the VM's own public IP. Kalari's `run_in_sandbox` sets the network policy itself.

## Shape

| Executable | Role |
|---|---|
| `kalari` | The main service on the VM: MCP endpoint for the agent, HTTP API for the web app, orchestrator, proved gate, evidence store. Drives Vimanam, Lambo, Clef and the microVMs |
| `kalari-aashaan` | The supervisor inside each microVM: runs the untrusted job, enforces time and output caps, reports a JSON verdict |

Both are **Lean 4 native executables**. The gate and the aashaan's cap logic carry theorems checked at build time, so the README can say the containment logic in the binary is **proved, not just tested**. Proofs cover the gate and the aashaan, not the agent's generated code; the demo says so plainly.

The web front end is Chaaya. Caddy terminates TLS in front of `kalari`. Details in [`docs/architecture.md`](docs/architecture.md).

## Vultr, and anywhere else

The tool is generic; Vultr is the deployment we demo, not a dependency.

1. **No Vultr names in the Lean code.** It knows "an OpenAI-compatible endpoint", "a System One endpoint" and "a sandbox backend".
2. **Providers live in config**, keys in environment variables named in config, never written into it.
3. **Vultr is a preset** (`deploy/vultr/`), next to a generic local preset.
4. **No Vultr API for per-task instances.** Microsandbox microVMs meet the sandbox requirement and run on any Linux host with KVM.
5. **Generic doesn't mean Vultr-light.** The README and video show Vultr doing the real work: DeepSeek, Clef, Qwen3 Embedding, and the VX1 host running the microVMs. The line: "runs on Vultr, and anywhere else you point it".

## Hackathon rules that shape the build

- **Challenge "Blast Radius Zero".** A web-based agent doing real work, every action contained in a sandbox on Vultr. Containment-first: process isolation, no secrets in the sandbox, time and memory limits on every run, the environment reset or destroyed after each task.
- **Vultr VM backend** as the central control layer, not static hosting.
- **Vultr Serverless Inference for all agent model calls** (`https://api.vultrinference.com/v1`). Vultr GPUs are not available.
- **A public web app** with a product-style experience.
- **A recorded demo video with one containment moment.**
- **Submission:** public GitHub repository with setup docs, public demo URL, video, slides, cover image, clear architecture and use case. The README explains which Vultr services are used and how they power the solution.
- Teams of 1–6; original work; MIT-compliant.
- **Judging:** Application of Technology, Presentation, Business Value, Originality.
- **Tag Vultr's technology on the submission form** (VM, Serverless Inference, the sandbox). Keep coding tools out of the tags.

## For judges (to build)

A live page whose first screen is a "For judges: start here" table: the runs, the evidence, the measured before-and-after number, and the recorded agent sessions.

## Not this

- Not an agent with its own loop. OpenCode does the coding.
- Not a test framework. The checks come from change facts and lessons; the grader is hidden from both arms.
- Not tied to Vultr (see above), and not tied to OpenCode: any MCP agent can plug in. Pi is the natural second integration (an extension can route every built-in tool call through the gate).

## Cautions

- **OpenCode never talks to Lambo directly.** Every read and write goes through Kalari, so only sandbox-verified outcomes become lessons.
- **Lambo never runs inside the sandbox**, and no key ever enters a microVM.
- **Never run untrusted code in Microsandbox's default network mode**: it can reach the VM's own public IP, which skips the Vultr firewall.
- **Look lessons up by the change kind, not by recall rank** (`lambo_inspect` from the `pagination_changed` resource). Recall ranking on a non-BGE embedder is weak until Lambo is calibrated for it.

## Open questions

- The demo API pairs: two real APIs, ideally in two formats, each with a genuine paging change between versions.
- How the baseline arm's egress is limited outside the agent, or whether the gap is reported as a measured result.
- Whether Vultr discounts cached input (the console's billing page; `/v1/usage` shows tokens only).
