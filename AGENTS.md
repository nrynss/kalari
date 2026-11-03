# Agent protocol

Rules for any agent working in this repository. The product is in [`product.md`](product.md), the architecture in [`docs/architecture.md`](docs/architecture.md), the work in [`dev-diary/`](dev-diary/README.md), and the facts the design rests on in [`dev-diary/research/`](dev-diary/research/README.md).

## Read before you build

- **[`dev-diary/research/`](dev-diary/research/README.md) is what was measured, not guessed.** Every finding there came from a real run on the real stack. Read the file for your area before writing code: it records the commands, the versions and the failures already hit, so you don't hit them again.
- A finding that contradicts your task, or product.md, goes back to the orchestrator. Don't work around it silently.

## Task rules

- Work only on a task from a phase file in `dev-diary/`, claimed for you by the orchestrator. The orchestrator's process is in [`dev-diary/ORCHESTRATOR.md`](dev-diary/ORCHESTRATOR.md).
- One agent per task. The orchestrator validates your work itself and lands it, or sends it back to you with what is missing. There are no review rounds.
- Meet every **Done when** clause, with evidence in your report. A clause you could not meet is reported as unmet, never glossed.
- A decision the task names as the user's goes back to the orchestrator. Don't make it yourself.
- Never schedule. No dates, day windows, target days or timelines in any document, commit or report. Work is ordered by `requires` only.

## Stack

- **Lean 4**, pinned in `lean-toolchain` (v4.35.0). **Read [`docs/lean.md`](docs/lean.md) before writing Lean here**: the patterns Kalari needs, each with a verified example in `Examples/`, and the traps already hit. Native executables through `lake build`. No Mathlib: core Lean, `Std`, and tactics such as `omega`, `decide`, `simp` and `grind`.
- **`kalari-aashaan` imports `Std` only**, never `Lean`: importing `Lean.Json` links the compiler library and takes the binary from ~3 MB to ~80 MB. It runs inside every microVM.
- **No HTTP client and no TLS in Lean.** Outbound HTTPS goes through a `curl` subprocess. Inbound TLS is Caddy's.
- **Dependencies.** Vimanam as a CLI subprocess. Lambo as a child process (`lambo serve`, MCP over stdio), never linked. Microsandbox through the `msb` CLI. A new dependency needs a stated reason in its commit message. The planned ones are in `docs/architecture.md`.

## Worktrees

- One task, one branch, one worktree. Two agents never edit one checkout.
- Commit on your branch. Never push, merge, or touch the main checkout; the orchestrator lands.
- A worktree has no gitignored files (`.env`, `kalari.toml`, `.kalari/`, `.lake/`). Don't assume they exist.

## File ownership

- Edit only the paths your task's `owns` lists. A change outside them is a new task or a note in your report.
- `lakefile.toml`, `lean-toolchain` and `lake-manifest.json` change only with the orchestrator's approval.
- Only the orchestrator edits `dev-diary/README.md`.

## The gate

- `./tools/check.sh` must pass on every commit: `lake build` (which also checks the theorems and `#guard`s), the aashaan cases, and the `Examples/` executables.
- An example in `Examples/` that stops matching `docs/lean.md` is a broken gate: fix the doc or the example in the same commit.
- CI runs the same script on push to `main` and on pull requests.
- The gate needs no key, no network beyond the toolchain, no `/dev/kvm` and no running server. Tests run on `testdata/` and recorded replies.

## Live tests

- A live test calls a real service: Vultr Inference, a running Lambo, or a Microsandbox microVM on the Vultr VM. It lives under `tests/live/`, never runs in CI and never gates a build.
- Each has a budget in its task. Run one case first, check the cost, and stop and report if it would go over.
- A live run is evidence: commit the test, and put its transcript (no key, no personal data) in your report.

## Sandboxes

- **Every untrusted run uses `msb … --no-net`**, plus `allow@<IP>/32:tcp:<port>` rules for the hosts the run needs. Never the default network mode: it reaches the VM's own public IP. Domain allow rules fail for TLS in msb 0.7.13; resolve hostnames on the VM and pass IP rules.
- **Set `vm.overcommit_memory=1` in the guest** before starting `kalari-aashaan`, or the Lean runtime can't start threads.
- **Run anything that starts `msb` with umask `0022`** (systemd: `UMask=0022`). msb refuses group-writable storage.
- **No key enters a microVM.** The aashaan starts jobs with an empty environment and an explicit `PATH`.
- **A process started in the background inside `msb exec` must redirect its output**, or `exec` waits on the held pipe forever.
- **`--no-net` also denies ingress.** A microVM that serves a published port uses `--net-default-egress deny` instead, bound to the VM's public IP.
- **OpenCode runs with `--standalone`** and per-run `XDG_*` directories: plain `opencode run` leaves a background daemon holding the key in its environment.

## Secrets

- Keys come from the environment or the system keyring, never from a committed file. `.env` and `kalari.toml` are gitignored; `.env.example` holds names only.
- Vultr Inference: `VULTR_INFERENCE_API_KEY` (keyring: `secret-tool lookup service vultr-inference account kalari`).
- Vultr account API, deploy only: `VULTR_API_KEY` (keyring: `service vultr-api account kalari`). It never goes on the VM.
- Send a key to the VM over SSH stdin (`printf '%s\n' "$KEY" | ssh … 'read -r VAR; export VAR; …'`), never in a command line or a file there.
- Never print, log, commit, or paste a key value, including in test output, fixtures and recordings.

## Commits and pull requests

- Plain messages.
- No `Co-Authored-By` trailer.
- No Claude or Anthropic attribution in commits or PR text.

## Dev-diary

- Set your task to `in-review` in its phase file when you report, and add your notes under the task: what you built, what you decided and why, what surprised you.
- Put your handoff-log entry in your report; the orchestrator adds it to `dev-diary/README.md`.
- A new measured fact about the stack goes in your report, worded for `dev-diary/research/`; the orchestrator files it.
- The repository goes public. Nothing private in the diary: no key, no account detail, no IP address, no instance ID, no private repository's name.

## New work only

- Write Kalari's code here, during the event. Never copy code from Lambo, Vimanam or any earlier project; depend on the published tool or talk to the running server instead. The day-one probes recorded in `dev-diary/research/` were written for this entry and are its starting point.
