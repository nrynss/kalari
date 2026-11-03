# Orchestrator

How the orchestrator runs the work in this repository. Workers read [`../AGENTS.md`](../AGENTS.md). The task rules are in [`README.md`](README.md). This file covers what only the orchestrator does.

**Process (user decision):** one agent per task, and no review loops. The orchestrator gives each task to a single agent, validates the result itself, and lands it or sends the same agent back.

The orchestrator is the one session the user talks to. It picks tasks, dispatches agents, validates and lands their work, and keeps the board true. It does not write product code.

---

## Two roles

| Role | Does | Never does |
|---|---|---|
| **Orchestrator** | Picks tasks. Dispatches implementers. Validates every result itself. Lands commits on `main`. Updates the status board and handoff log. Fixes documentation itself. Asks the user for decisions. | Implement a task. Land work it hasn't validated. Treat an agent's message as the user's approval. |
| **Implementation** | Builds the task inside its `owns` paths, on its own branch in its own worktree. Sets its task to `in-review`. Reports. | Mark its task `done`. Edit `dev-diary/README.md`. Touch files outside `owns`. |

When validation finds a problem, the same implementer gets it back with the evidence. The orchestrator fixes only documentation itself: markdown under `dev-diary/` or `docs/`, `README.md`, `AGENTS.md`, or a comment that does not describe behaviour. Anything that touches behaviour, a contract, a test, a fixture or the gate goes back to the implementer.

---

## The loop

### 1. Pick

A task is **ready** when its status is `not-started`, every task in `requires` is `done`, and it is not `blocked`.

- Prefer ★ tasks on the critical path.
- Run ready tasks in parallel when their `owns` paths do not overlap.
- If a task names a decision as the user's, ask the user before dispatching, with options and a recommendation.
- Never schedule. Order work by `requires` only: no dates, windows or target days, in any document or message.

### 2. Prepare

- `main` is clean, and `./tools/check.sh` passes in the main checkout.
- Set the task to `status: claimed:<agent>` on `main` and commit. That claim is how a later session sees the task is taken.
- The user assigns the agent and the model for each task. The task's class (README, Task Pattern) says what kind of work it is; it does not pick the model.

### 3. Dispatch

Always in the background, always in its own worktree (`isolation: worktree`). A new worktree is cut from `origin/main`, not the local `main`. If local `main` is ahead, either push first (with the user's approval) or tell the worker in the brief to move its new branch to the brief's commit before starting, and to stop if it can't. Use the brief template below. A worker starts cold, so the brief carries everything it needs: what to read, what to build, what it may touch, how to prove it, and what to report.

### 4. Validate: never trust the report

When the implementer reports, the orchestrator checks for itself:
- every **Done when** clause is met, each with evidence the orchestrator has seen, not just the report's word;
- the diff: the branch holds only the task's `owns` paths and its own status lines, and does what the task says;
- the gate passes in the worktree;
- no key value is in any file (see Secrets);
- for a task that records fixtures or prompts, an offline replay from the branch gives what the report says;
- for a `b` task, the live transcript is in the report and matches the committed test.

Short of the task, it goes back to the same implementer with what is missing, or the task is split (`T3.1a`) and recorded. It is never landed as done.

### 5. Land

In the task's worktree:
1. `git rebase main`. Conflicts in `dev-diary/` status lines are the orchestrator's to resolve, keeping both sides' truth. A conflict in code goes back to the implementer.
2. `./tools/check.sh` passes.

Then in the main checkout:

3. `git merge --ff-only <branch>`.
4. `./tools/check.sh` passes, with the gitignored files (`.env`, `kalari.toml`, `.kalari/`, `.lake/`) present.
5. For a task that wrote `testdata/`, grep for every key value and confirm it matches nothing.

If step 4 fails, `main` is broken. Record a finding against the task at once, and fix it before anything else lands.

### 6. Close

- Set the task to `status: done` in its phase file, and tick its exit criteria only where they are true.
- Update the README status board and add a handoff-log entry at the top: what exists, what surprised, and what the next agent must not have to work out again. Only the orchestrator edits `dev-diary/README.md`, so parallel branches never conflict on it.
- Remove the worktree and delete its branch, after `git cherry main <branch>` shows no `+` lines and the worktree is clean. Never remove a worktree with unmerged or uncommitted work; report it instead.
- Record the landing in Lambo with `lambo_record_action`, and every decision with `lambo_derive`: what was decided and why.
- Tell the user what landed, what was found, and what is ready next.

---

## Brief template

```
You are doing task <id> ("<title>") for Kalari. You are in your own worktree of
~/work/kalari, branched from main at <hash>. Commit on your branch. Do not push,
merge, or touch the main checkout.

Read first: AGENTS.md; product.md; docs/architecture.md (<sections>);
dev-diary/README.md (<sections>); dev-diary/PHASE-<n>-*.md (<id>, and the tasks it
requires); <fixtures and earlier code to read>.

What to build: <the task, restated with any decisions the user has made since it was written>.
You own: <owns paths>. Touch nothing else.

Hard rules: keys only from the environment or the keyring, never printed or written;
<budget and the guard that stops at it, for a live task>; new code only, never copied
from Lambo, Vimanam or an earlier project; plain commit messages with no Co-Authored-By
or Claude/Anthropic attribution; no dates or schedules in the dev-diary.

Prove it: <tests, the gate, the pins this task needs>.

Dev-diary: set <id> to `in-review` in its phase file, and add your notes under the task.
Do not edit dev-diary/README.md; put your handoff-log text in your report.

Report: branch, `git log --oneline main..HEAD`, each Done-when clause with its evidence,
anything unmet, and anything surprising.
```

---

## Secrets and spend

- **Keys come from the environment or the keyring.** Vultr Inference: `VULTR_INFERENCE_API_KEY`, or `secret-tool lookup service vultr-inference account kalari`. A worktree has no `.env`. A worker that needs a key writes a wrapper script outside the repository, under the session scratchpad, that loads the key and `exec`s the command. The wrapper is never committed. A key goes to the VM over SSH stdin only.
- **No key is ever printed.** Check for leaks with `grep -rlF -- "$VALUE"`, which prints only file names, with the value loaded and never echoed.
- **Every live (`b`) task carries a budget and a guard in its brief.** Run one case first, check its cost, and stop and report if it goes over. The orchestrator keeps the running spend in the handoff log.
- **The Vultr VM is shared and billed hourly.** Live tasks on it run one at a time unless their microVM names and ports can't collide. Creating, resizing or destroying a VM, and opening a firewall port, are the user's call.
- **Anything outward is the user's call:** filing an issue, pushing, making the repository public, publishing the video, submitting, or a spend beyond the brief's budget. Ask first, every time.

---

## Asking the user

Ask, with options and a recommendation, when:
- a task names a decision as the user's;
- evidence contradicts product.md or an earlier decision;
- a budget would be exceeded;
- a task is blocked and the way forward is a product choice;
- anything outward-facing is next.

Report outcomes plainly: what landed, what failed, and what the orchestrator itself got wrong.
