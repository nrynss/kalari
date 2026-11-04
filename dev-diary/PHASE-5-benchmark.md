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
owns:       bench/pilot/, the --behaviours flag in bench/apis/*/server.py, its cases in bench/tests/quirks.sh, bench/harness/run.sh and bench/harness/remote.sh (isolated variant routing only)
status:     in-review
```
The reference setup only (bench/README.md, Protocol 6): each behaviour alone, fresh session, five runs each; then the proposed pair under conditions 1, 2, 3 and 6, five runs each. About 65 runs, ~$16. **The user approves the spend before it starts**, and the first run's cost is checked against the budget before the rest.

Single-behaviour pilots need single-behaviour variants of the APIs (`--behaviours B1,B2`): add the flag to the servers and a reference check to `bench/tests/quirks.sh` for each variant.

**Done when:** every run's result file is committed under `bench/pilot/`; a summary table per behaviour and per condition, as counts.

**Earlier partial report:** `--behaviours` is optional. Omit it and the server is unchanged: payouts runs B1, B2, and B4; settlements runs B1, B2, and B3. A comma-separated list turns on only those ids. Payouts accepts B1, B2, and B4. Settlements accepts B1, B2, and B3. Any other token, including B5, is an error that names the token. B5 is not implemented.

A behaviour that is off does the plain thing. Payouts: B1 off, a drained response has `cursor` null; B2 off, the next window starts after the previous window's last payout; B4 off, the response holds up to `limit` (still at most 1000). Settlements: B1 off, the last page's `endCursor` is null, and that field is nullable only in that mode; B2 off, each settlement is emitted once, in v1's version; B3 off, void rows are dropped before the page is cut.

`bench/tests/quirks.sh` keeps the full-server lines on a server started with no flag. It also starts one server per variant and grades the consumer that behaviour breaks, and the correct consumer. Measured on those servers: payouts B1 `cursor_loop` TIMEOUT, `correct` PASS; payouts B2 `no_dedupe` FAIL:duplicates=24, `correct` PASS; payouts B4 `short_page_stop` FAIL:missing=2331, `correct` PASS; settlements B1 `cursor_loop` TIMEOUT, `correct` PASS; settlements B2 `no_dedupe` FAIL:duplicates=19,mismatched=19, `keep_first` FAIL:mismatched=19, `correct` PASS; settlements B3 `empty_page_stop` FAIL:missing=1473, `correct` PASS. The B3 line is not the full-server line: with B2 off, the first empty page comes after 400 final settlements and there is no amended copy. The same script rejects B5 on both servers, B3 on payouts, and B4 on settlements.

`bench/pilot/run.sh` lists the matrix: 6 variants times 5, then conditions 1, 2, 3, and 6 on the proposed pair, five times each. Condition 1 is one session across both upgrades, payouts then settlements on that session. A behaviour `--run` refuses and does not call the harness: the harness has no server switch yet, and the deployed servers are the full pair. The whole matrix refuses for the same reason, because it includes those rows.

The condition rows ran, one harness call at a time, with an explicit condition, upgrade, and repeat. The first session was condition 3 payouts repeat 1. `bench/pilot/results/condition-3-payouts-r1.json` records `cost_usd` 0.086144. Forty times that cost is 3.44576, inside the 16 dollar budget, so the remaining condition rows ran. Forty result files are under `bench/pilot/results/`. Counts are in `bench/pilot/SUMMARY.md`. Each file was scanned before commit: no API key, no IP address, and no instance id, so nothing was rewritten.

Condition 1 settlements resumed the payouts session. `session_continued` is true in `condition-1-settlements-r1.json` through `condition-1-settlements-r5.json`, so repeats 2 through 5 ran. Every settlements file for condition 1 has verdict FAIL and grade note `no consumer output`, so records lost and records duplicated are null there. The payouts half of condition 1 is PASS on all five files. Conditions 2, 3, and 6 are PASS on every file. `condition-3-payouts-r5.json` has `session_capped` true and wall time 1202.0 s, and its verdict is still PASS.

The 30 single-behaviour sessions were not run, because the harness has no server switch and a behaviour `--run` still exits 2. The done-when is only partly met: the condition result files and the condition counts are in; the behaviour runs and their part of the summary table are not. Status stays in-review.


**Completion report (in review):** The missing 30 single-behaviour sessions ran as fresh condition 3 sessions, five for each of the six variants. The original 40 condition files are unchanged. Every one of the 30 final grades passed; right first time was 5/5 for each variant except payouts B2, which was 4/5. The 70 result files and linked counts per behaviour and condition are in `bench/pilot/results/` and `bench/pilot/SUMMARY.md`; the sanitized live summaries and no-inference preflight transcript are in `bench/pilot/TRANSCRIPT.md`.

The first new case cost $0.033182. Including the existing $3.545642, that made $3.578824; projecting $0.25 for each remaining session gave $10.828824, under the approved $16. The runner checked the cumulative spend and projection before every subsequent session. The 30 variants cost $1.486888 at list price; all 70 pilot rows cost $5.032530. All new usage deltas matched OpenCode's own token totals. No new session hit the cap. Settlement B2 repeat 1 took 1129.485 s, with 423.587 s recorded stuck, and passed; a short no-inference HTTP isolation probe shared the VM during that run, which may have affected its wall time.

**Comparability and cleanup:** The variant arm used a fixed `--no-net` guest, a live-endpoint allow rule and a restricted pilot MCP adapter. It copied workspace files into the guest rather than exposing the original reference MCP's broader sandbox, bind-mount, and network controls. That changes the reference setup and may affect results; the user must decide whether the pilot is sufficient for the intended comparison. The first nine variants used process-group cleanup; all exited normally, and a later check found no pilot processes or sandboxes. The remaining 21 used a unique user systemd scope, tested with a detached child, and verified scoped cleanup. Staged server and grader copies were outside the allowed workspace; after the nineteenth session the staged copies were removed before the arm started, and a separate preflight copy was removed during the twentieth. Details are in `bench/pilot/ISOLATED.md`.

**Verification:** `bench/pilot/validate.py` checked all 70 identities, measures, grade counts, usage totals, cleanup records and variant provenance; summary generation was repeatable. All six variants were checked against characteristic consumers on their dedicated live and grading endpoints without inference; HTTP verified the allowed route and denial of the shared API. The updated adapter preflight passed with a detached-child scope check. The original four API sandboxes remained present, with no pilot sandboxes or scopes left. A scan of pilot VM files found no inference key. `./tools/check.sh` passed. The pair choice and freeze remain T5.3's user decision.

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
