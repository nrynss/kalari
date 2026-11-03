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
status:     not-started
```
One script that runs one session of one condition on the VM and records everything: a fresh copy of the workspace (committed, so `git diff` shows the change); OpenCode 2.2.5 with `--standalone` and its own `XDG_*` directories; the key over SSH stdin; the 20-minute session cap; `/v1/usage` before and after; the event log; the hidden grader on the final consumer against the grading API; and **every measure** (bench/README.md, Measures), including "right first time" (grade the consumer as it stood at its first run against v2, from the workspace's history or the event log) and time stuck. Then a check that no `opencode`, `microsandbox-mcp` or sandbox is left.

Conditions 1 and 2 span both upgrades: condition 1 keeps one session (`--session`) on one data directory; condition 2 starts a new session with the notes the first wrote.

**Done when:** one reference-condition session of each upgrade runs end to end and produces a result file with every measure; nothing is left running.

---

### T5.2: The baseline pilot ★
```yaml
requires:   [T5.1]
fixture-ok: no
size:       M · mid
owns:       bench/pilot/, the --behaviours flag in bench/apis/*/server.py, its cases in bench/tests/quirks.sh
status:     not-started
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
