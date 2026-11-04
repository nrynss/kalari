# P5: The benchmark

The comparison, run as [`../bench/README.md`](../bench/README.md) says. **The pilot needs no Kalari code**, so T5.1 and T5.2 run beside P1–P4. The Kalari arm (T5.4) waits for the freeze (T5.3).

Read first: [`../bench/README.md`](../bench/README.md) (all of it), [`research/coding-agent.md`](research/coding-agent.md), `bench/apis/*/QUIRKS.md`.

Every run's spend is tracked; each task's budget is in its brief.

---

### T5.1: Run harness ★
```yaml
requires:   [T0.2]
fixture-ok: no
size:       M · mid
owns:       bench/harness/
status:     done
```
One script that runs one session of one condition on the VM and records everything: a fresh copy of the workspace (committed, so `git diff` shows the change); OpenCode 2.2.5 with `--standalone` and its own `XDG_*` directories; the key over SSH stdin; the 20-minute session cap; `/v1/usage` before and after; the event log; the hidden grader on the final consumer against the grading API; and **every measure** (bench/README.md, Measures), including "right first time" (grade the consumer as it stood at its first run against v2, from the workspace's history or the event log) and time stuck. Then a check that no `opencode`, `microsandbox-mcp` or sandbox is left.

Conditions 1 and 2 span both upgrades: condition 1 keeps one session (`--session`) on one data directory; condition 2 starts a new session with the notes the first wrote.

**Done when:** one reference-condition session of each upgrade runs end to end and produces a result file with every measure; nothing is left running.

**Notes (in review):** `bench/harness/run.sh` takes `--condition 1|2|3|6` and `--upgrade payouts|settlements`. It copies a fresh workspace, commits it, and runs OpenCode 2.2.5 with `run --standalone` and its own `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `XDG_CONFIG_HOME`. The key comes from the keyring and crosses SSH on stdin. The cap is 20 minutes. Tokens are the `/v1/usage` delta for `deepseek-v4.1-flash-1017`. Condition 1 stores the session id and reuses that data directory for the other upgrade. Condition 2, on the second upgrade, copies notes the first wrote (new non-Python files, or the final answer if there were none) into `notes-from-upgrade-one/`. The proof runs are condition 3: a fresh reference session, the shared prompt, no notes. The hidden grader runs the consumer in a new microVM with `--no-net` and one allow rule for the grading API, then `grade.py` on the host. Right first time grades the consumer from OpenCode's snapshot tree at the first v2 run, or from source embedded in the event log when that tree does not yet contain v2.

`bench/harness/results/c3-payouts.json`: verdict PASS, right first time true (1 v2 run, snapshot), sandbox runs 1, wall 29.265 s, time stuck 0, tokens 577,808 in / 7,804 out, records lost 0, duplicated 0. Grade 2,431 of 2,431. Cost $0.091354.

`bench/harness/results/c3-settlements.json`: verdict PASS, right first time true (first of 2 v2 runs, snapshot), sandbox runs 2, wall 27.722 s, time stuck 0, tokens 452,070 in / 8,629 out, records lost 0, duplicated 0, mismatched 0. Grade 1,873 of 1,873. Cost $0.072988.

Both usage deltas matched OpenCode's step tokens exactly (input plus cache reads, output plus reasoning). No other model moved. Neither session hit the cap. No `opencode`, `microsandbox-mcp`, or sandbox this harness started was still running. The four API microVMs were already up and were left up.

What surprised me: both upgrades passed on the first consumer run against v2. The reference arm picks its sandbox network, so it could reach every port published on the VM, including the grading API. The payouts session found that server (v1 retired) and checked it. The settlements session compared v2 with v1 on its own. The hidden grade does not use either check; it re-runs the saved consumer with v1 off. Condition 1's resumed session and condition 2's notes handoff are in the script and were not the proof runs.

---

### T5.2: The baseline pilot ★
```yaml
requires:   [T5.1, T0.6]
fixture-ok: no
size:       M · mid
owns:       bench/pilot/, the --behaviours flag in bench/apis/*/server.py, its cases in bench/tests/quirks.sh
status:     claimed:grok-impl
```
The reference setup only (bench/README.md, Protocol 6): each behaviour alone, fresh session, five runs each; then the proposed pair under conditions 1, 2, 3 and 6, five runs each. About 65 runs, ~$16. **The user approves the spend before it starts**, and the first run's cost is checked against the budget before the rest.

Single-behaviour pilots need single-behaviour variants of the APIs (`--behaviours B1,B2`): add the flag to the servers and a reference check to `bench/tests/quirks.sh` for each variant.

**Done when:** every run's result file is committed under `bench/pilot/`; a summary table per behaviour and per condition, as counts.

---

### T5.3: Choose and freeze the pair
```yaml
requires:   [T5.2]
fixture-ok: yes
size:       XS · user
owns:       bench/README.md, bench/FROZEN.md
status:     not-started
```
The user chooses the pair from the pilot's numbers, or the fallback (harder real behaviours, or leading with cost, attempts and containment; both, as decided). Then the APIs, the docs, the prompt and the grader are frozen: `bench/FROZEN.md` records the commit and a hash of each file. Nothing in them changes after this.

**Done when:** `FROZEN.md` committed before any Kalari-arm run.

---

### T5.4: The Kalari arm ★
```yaml
requires:   [T5.3, T4.7]
fixture-ok: no
size:       M · mid
owns:       bench/runs/kalari/
status:     not-started
```
Conditions 4 and 5, five repeats each, on the frozen pair, through the harness. Condition 5's lesson comes from that repeat's own upgrade-one session, never copied from another.

**Done when:** every run committed with its result file; `FROZEN.md`'s hashes still match.

---

### T5.5: The reference arm, frozen
```yaml
requires:   [T5.3]
fixture-ok: no
size:       M · mid
owns:       bench/runs/reference/
status:     not-started
```
Conditions 1, 2, 3 and 6, five repeats each, on the frozen pair. Pilot runs on the frozen pair may count if they were made on the frozen files (the hashes decide), so the reference arm may already be partly done.

**Done when:** every run committed; `FROZEN.md`'s hashes still match.

---

### T5.6: Results
```yaml
requires:   [T5.4, T5.5]
fixture-ok: yes
size:       S · frontier
owns:       bench/RESULTS.md
status:     not-started
```
The table product.md promises, per condition, as counts: verdicts, right first time, sandbox runs, wall time, time stuck, tokens, records lost or duplicated. What it shows and what it doesn't, plainly: if condition 1 or 6 matches 5, say so. Every number links to its runs.

**Done when:** `RESULTS.md` committed; every number traces to a result file.

---

## Exit Criteria

- [ ] The pilot ran before the Kalari arm, and the pair was frozen in between.
- [ ] Every run published, with its measures.
- [ ] The result stated plainly, whichever way it went.
