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

### T5.1a: Repair continuous-session benchmarking ★
```yaml
requires:   [T5.2]
fixture-ok: yes
size:       M · mid
owns:       bench/harness/, bench/pilot/SUMMARY.md, bench/pilot/summarize.py
status:     done
```
Condition 1 resumed the OpenCode session but not its workspace: the agent remained attached to payouts while the harness graded a separate, untouched settlements tree. Save and reuse the original workspace's absolute path, replace its contents with the fresh settlement workspace, and make measures and both grading passes use that same tree. Require continuation state rather than silently starting fresh. Validate snapshot/workspace identity, distinguish consumer crashes from missing output, and never grade stale workspace output after a crash.

Add a no-inference rehearsal that drives the real OpenCode 2.2.5 resume mechanism with a local scripted provider. A fake executable that merely uses its current directory is not evidence that the resume defect is fixed. Preserve the original result JSON unchanged, but label the five old condition-1 pairs as invalid pilot/debug evidence; they cannot count in the frozen reference arm.

**Done when:** the rehearsal proves that the resumed session sees the settlements workspace, runs the intended consumer, and grades newly produced output from that same workspace; first-attempt and final source identity match; a stale JSONL cannot rescue a crashed consumer; missing continuation state fails before the session; the old pairs are labelled invalid; `./tools/check.sh` passes.

**Notes:** Condition 1 now keeps one stable workspace at `$ROOT/workspaces/condition-1`. `prepare_condition1` in `bench/harness/condition1.sh` loads the saved state, verifies the workspace, XDG directory and session, clears the workspace, copies the fresh upgrade tree, compares tree digests, and consumes the state. `remote.sh` and the no-inference rehearsal call the same function.

The rehearsal drives real OpenCode 2.2.5 against a loopback scripted provider. It writes an incomplete settlements consumer, runs it, then writes the reference consumer and runs again. It proves the workspace path, the resumed session, the first-attempt hash, a first grade FAIL and a final grade PASS. It also proves that a missing or partial state fails before OpenCode starts, and that a stale workspace JSONL cannot rescue a crashed consumer. `grade_one` moved to `bench/harness/grade_one.sh` and is exercised with a stub `msb`.

The result now separates `consumer_exit`, `output_present` and `grade_status` (`ok`, `no_output`, `consumer_crashed`, `grader_failed`). `EXIT launch` is a grader failure. Denied `shell` and `bash` consumer commands are not sandbox runs. A structural checker rejects a workspace override after `prepare_condition1`, a missing consume call, a wrong `grade_one` source, and a commented identity guard.

The five old condition-1 pairs are labelled invalid pilot/debug evidence in `bench/pilot/SUMMARY.md`. The 70 result files and `TRANSCRIPT.md` are unchanged, `validate.py` passes, and `./tools/check.sh` passes.

Residual: the rehearsal calls the shared functions directly, so it does not execute `remote.sh` itself. The first live condition-1 session in T5.2b must confirm the call-site wiring. The microsandbox `..` containment of the stable workspace is unverified until a live run.

---

### T5.2: The baseline pilot ★
```yaml
requires:   [T5.1, T0.6]
fixture-ok: no
size:       M · mid
owns:       bench/pilot/, the --behaviours flag in bench/apis/*/server.py, its cases in bench/tests/quirks.sh, bench/harness/run.sh and bench/harness/remote.sh (isolated variant routing only)
status:     done
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

### T5.2a: Add B5 to both upgrades ★
```yaml
requires:   [T5.1a]
fixture-ok: yes
size:       M · frontier
owns:       bench/apis/, bench/workspaces/payout-sync/docs/tallyline-payouts-api.md, bench/workspaces/settlement-reconcile/docs/clearwell-settlements-api.md, bench/tests/quirks.sh, bench/harness/ (B5 retry measures only), bench/pilot/ (runner and validation scripts only; existing results stay unchanged)
status:     done
```
The user chose both fallbacks after the old pilot: add the reserved real behaviour B5 to both upgrades, and lead the eventual report with cost, attempts and containment while retaining correctness measures. Payouts becomes B1+B2+B4+B5 and settlements B1+B2+B3+B5. This is the final hardness adjustment, regardless of the new pilot's outcome. Keep the datasets, hidden grader, prompts and specs unchanged. Put the retry contract only in the neutral vendor-style docs shared by every arm.

B5 returns HTTP 429 with `Retry-After: 1` once at a deterministic mid-stream point in every traversal. A fresh random traversal identity lives inside the opaque signed cursor; replaying a saved cursor continues that cursor's lineage. Key one-shot state by traversal identity and incoming cursor digest, under a lock. A trusted fingerprint of the complete canonical request establishes an identical retry; for GraphQL it includes the exact query and every variable, not just `after`. Store no raw requests or tokens in traces or result files.

Add correct bounded-retry, no-retry crash, and partial-output skip-on-429 reference consumers. Preserve the old B1–B4 failure-mode coverage. Add trusted, run-attributed retry measurement: consumer sandbox runs, B5 429 responses, matching HTTP retry attempts and successful matching retries are separate measures, with agent and grading activity separated. Missing or ambiguous attribution is unknown, never zero.

**Done when:** offline tests interleave two fresh traversals and show distinct identities, one 429 per traversal, successful identical retries and no skipped pages; both APIs' tests assert the actual HTTP 429 and `Retry-After` header; a changed GraphQL query or variables is not an identical retry; correct consumers pass, no-retry consumers crash, and partial-output consumers fail with measured record loss; retry counts remain distinct from sandbox runs; `./tools/check.sh` passes.

**Notes:** Implemented at `e67f317`, with two remediation rounds and a final minors commit at `e5b6c35`. A fresh traversal id is minted with the first response and rides inside the signed cursor. Replaying a saved cursor keeps that lineage. The one-shot state is keyed by traversal and incoming cursor digest, under a lock. The trigger is at or past offset 1500 for payouts and 1000 for settlements. Only a full canonical request fingerprint clears the throttle. REST covers the method, the path and every query pair. GraphQL covers the exact query text, every variable and the operation name. The 429 carries `Retry-After: 1`.

The settlements parser walks named and inline fragments, prefers a non-null `after`, and rejects two non-null `after` fields with a distinct 400 and no traversal. A fragment on another type stays with the schema. With B5 off the old GraphQL error path returns unchanged.

`correct` now retries the identical request once. New `no_retry` and `partial_output` consumers cover the crash and the silent shortfall. Offline loss is 846 payouts records and 1,078 settlements records with 3 stale versions. On the B5-only servers the partial consumers lose 431 and 873. The old B1 to B4 consumers keep their expected outcomes, and B5 off reproduces the old page output.

A host-owned journal records request digests only. The harness truncates it at each phase and reads it over `msb exec`. The result carries `http_retries` for the agent and grading phases, separate from `sandbox_runs`. A missing, malformed or wrong-typed journal is unknown, never zero. An overflow or a state-cap eviction marks the phase unknown. The grading read takes the expected client count from the harness, one or two passes. `deploy.sh` passes the journal path. The pilot runner routes B5 to `bench/pilot/harder/` and refuses an existing row. The existing 70 rows are untouched.

Verification: `bench/tests/quirks.sh` has 92 checks. It covers interleaved traversals, fragments, dual `after`, changed requests on both APIs, real 429 and header checks, consumer outcomes, journal types and digests, grading isolation, the eviction marker and the pilot routes. `python3 bench/pilot/validate.py` validates 70 of 70. `./tools/check.sh` passes.

Residual: the journal read over `msb exec` was proven with a stub only. The four API microVMs must be recreated with `deploy.sh down` then `up` before T5.2b, or the journal flag will not be active. The deploy note records that an arm that execs into a fixed API guest could rewrite the journal. The harness removes arm sandboxes before grading and marks unexpected traffic unknown.

---

### T5.2b: The harder-pair pilot ★
```yaml
requires:   [T5.2a]
fixture-ok: no
size:       M · mid
owns:       bench/pilot/harder/
status:     done
```
Run exactly 50 reference sessions on the harder pair: five fresh B5-only sessions for each upgrade, then conditions 1, 2, 3 and 6 on the full pair, five repeats each (40 sessions). The 10 isolated rows diagnose retry alone; the 40 full-pair rows answer the benchmark question after the condition-1 repair. The old 70 rows remain published separately and are never merged into harder-pair counts. B5-in-both remains the pair even if the baseline passes every row.

**Live budget: $12.** The first case's measured cost and the remaining projection must fit that cap before any further session. Stop and report otherwise. Usage deltas and cleanup are checked after every session. The cap is roughly twice the old pair's mean cost per session, with a reserve for one expensive row.

**Done when:** all 50 result files and their sanitized transcript are committed under `bench/pilot/harder/`; counts include every existing measure plus HTTP retries reported separately from consumer sandbox runs; the old pilot is unchanged; no process, scope or sandbox started by the pilot remains.

**Notes:** All 50 sessions ran; every committed row is PASS, right first time, with zero records lost or duplicated and no capped session. `bench/pilot/harder/results/` holds the 50 files; `bench/pilot/harder/SUMMARY.md` counts every measure plus agent/grading HTTP retries (429s / matching attempts / successful matches) apart from sandbox runs; `bench/pilot/harder/TRANSCRIPT.md` is the sanitized jsonl transcript. `validate.py --b5` passes 50/50; `./tools/check.sh` passes; `git diff --stat` shows no change under `bench/pilot/results/`; no process, scope or sandbox from the pilot remains on the VM.

Spend: $3.74 list price across the 50 committed rows (first case $0.066, projection $3.31, inside the cap). Total live spend about $4.17 including two discarded misruns, still inside the $12 cap. Wall 3,864 s over the 50 rows, 861 s stuck (three sessions with a hung run that recovered: condition-3 payouts r3 600 s, condition-6 payouts r2 122 s, condition-3 payouts r5 61 s). One agent retry window is `unknown` (condition-6 payouts r5 overflowed the live journal); every other phase is `ok`.

Pre-step done first: the four API microVMs were redeployed (`deploy.sh down` then `up`) because the running servers lacked `--retry-journal`; all four now run with the flag and their journals record digest-only events. The T5.1a repair held live: all five condition-1 settlements rows show `session_continued`, identity and workspace checks true, and the continuation state consumed.

Two harness-operation mistakes, both contained and reported: (1) the first condition-1 invocation omitted `--repeat`, running all five payouts halves in one go; each payouts run resets the stable XDG base, so repeats 1-4 lost their sessions and only repeat 5 could be continued. The four orphaned payouts rows were deleted and the pairs re-run properly alternating `--repeat` payouts/settlements (about $0.27 of discarded spend). (2) A tracked T5.1 scratch file (`bench/harness/results/c3-payouts.json`) was overwritten by the harness and then deleted as if it were scratch; restored with `git checkout`. After that every run ended with `git checkout -- bench/harness/results/` plus removal of untracked scratch, and `git status` stayed clean outside `bench/pilot/harder/`. The harness writing its intermediate result to a tracked path is a routing gap worth a task: scratch should go somewhere untracked.

Surprise: an unknown second runner executed one condition-6 payouts session on the shared VM and inference account inside my condition-6 repeat-1 window (run dir with a foreign session id, `condition-6.txt` prompt, opencode 2.2.5). It shared the `c6-payouts.json` scratch path, so its FAIL content overwrote my PASS dest, and its tokens polluted both my repeat-1 usage deltas (one showed 388k input tokens in a 5 s session, impossible alone). Both repeat-1 rows were deleted and re-run clean with single-new-run-dir and session-identity checks; every later row passed the same provenance check. The 79-run history on the VM shows no other foreign run. Recommend the orchestrator identify the second runner; concurrent sharing of the scratch path and the account-wide usage endpoint breaks both result attribution and cost attribution.

What the numbers say: the reference setup passes the harder pair 50/50, right first time 50/50, including every B5 retry. The baseline pilot's lesson stands: with B5 in both upgrades the comparison rests on cost, attempts and containment, not the pass rate. Retry behaviour observed: B5-only settlements agents retried up to 7 times in a session (all matching); grading always shows exactly 2 throttled 429s with 2 matching retries per upgrade.

---

### T5.3: Choose and freeze the pair
```yaml
requires:   [T5.2b]
fixture-ok: yes
size:       XS · user
owns:       bench/README.md, bench/FROZEN.md, product.md (comparison measures narrative only)
status:     done
```
The user has chosen the pair: payouts B1+B2+B4+B5, then settlements B1+B2+B3+B5. The report leads with cost, attempts and containment, retains verdicts and right-first-time, and reports HTTP retry attempts separately from consumer sandbox runs. B5-in-both is the final hardness adjustment; T5.2b measures it rather than triggering further changes.

After T5.2b, freeze the API server and data files, workspace consumers/specs/docs, prompts, hidden grader and grading runner. `bench/FROZEN.md` records the commit and a hash of every frozen file. Nothing in them changes after this. Update the benchmark and product narratives to match the decided reporting emphasis.

**Done when:** `FROZEN.md` is committed before any Kalari-arm run, every listed hash matches, and the benchmark and product narratives agree.

**Notes:** We froze payouts B1+B2+B4+B5 and settlements B1+B2+B3+B5 at commit 8b8e0f3. We wrote bench/FROZEN.md with 19 SHA-256 hashes and a verify command. We recomputed every hash and all matched. We left frozen code untouched. We updated bench/README.md and product.md to lead with cost and sandbox attempts and wall time and time stuck and containment. We keep verdicts and right first time. We report HTTP retries apart from sandbox runs. We state the baseline passed all 50 harder pair sessions first time. Conditions 1 and 2 and 3 and 6 each passed all rows, so a future condition 5 match would narrow the claim to prompts and enforcement. `./tools/check.sh` passed with HOME/.elan/bin on PATH.

---

### T5.4: The Kalari arm ★
```yaml
requires:   [T5.3, T4.7, T4.7c]
fixture-ok: no
size:       M · mid
owns:       bench/runs/kalari/
status:     done
```
Conditions 4 and 5, five repeats each, on the frozen pair, through the harness. Condition 5's lesson comes from that repeat's own upgrade-one session, never copied from another.

**Live budget: $8.** Check the first session's measured cost against the cap before the rest. Stop and report if the projection would exceed it.

**Done when:** every run committed with its result file; `FROZEN.md`'s hashes still match.

**Notes:** All 20 sessions ran on the VM through `bench/runs/kalari/_harness/` (new remote driver reusing the proven `runner.py`/`session.py`/`prepare.py`/`grade.sh` flow, extended for settlements, per-repeat Lambo stores, phase-split retry journals, suite-aware grading; plus a local `run-kalari.sh` driver with keyring key over SSH stdin, VM mutual exclusion, and per-session result assembly in `to_result.py`). Every row is PASS; condition 4 is 10/10 right first time, condition 5 is 6/10. Total spend $0.38 against the $8 budget (first case $0.0150, projection about $0.30).

Zero lessons were published in any upgrade-one session: production `serve` refuses the observer, so `record_lesson` always returned `[]` and every condition-5 recall was empty — condition 5 collapses to condition 4 in memory terms, and the comparison rests on cost, attempts and containment as the benchmark design anticipates. The four non-RFT condition-5 rows are the interesting data: one fail-then-fix recovery through the enforced checks, two sessions where the gate refused shell-wrapped commands and the harness stopped on repeated tool failure while the final (never verified) consumer still graded PASS, and one six-run session that passed on run five and kept experimenting. Settlements agent retry windows measured 1–3 throttled 429s with matching retries; all ten payouts agent windows read unknown because the payouts-live journal counter is process-global and saturated (every request now appends only the overflow marker; grading journals still record). Cleanup is clean on all 20 rows. `FROZEN.md` hashes matched before the first and after the last session; the old pilot rows are untouched. Surprise: `sh -c`-wrapped consumer commands are refused by the gate in some sessions yet executed (and failed on guest PATH) in another; direct `python3 consumer.py` commands always ran.

---

### T5.5: The reference arm, frozen
```yaml
requires:   [T5.3]
fixture-ok: no
size:       M · mid
owns:       bench/runs/reference/
status:     done
```

Conditions 1, 2, 3 and 6, five repeats each, on the frozen pair. Only T5.2b's harder-pair rows may count, and only if they were made on the frozen files (the hashes decide). The original T5.2 rows belong to the old pair and cannot count.

**Live budget: $10.** Check the first session's measured cost against the cap before the rest. Stop and report if the projection would exceed it.

**Done when:** every run committed; `FROZEN.md`'s hashes still match.

**Notes (in review):** Zero live spend. All 40 rows are byte-identical copies of T5.2b's harder-pair condition rows (`bench/pilot/harder/results/condition-{1,2,3,6}-{payouts,settlements}-r{1..5}.json`) into `bench/runs/reference/`. Reuse is legitimate by the hash rule: every frozen-file change predates the harder runs (server changes `59507d1` etc. are ancestors of the row commits; `git diff <row-commit>..HEAD` over all 19 frozen files is empty), and the working-tree hashes matched `FROZEN.md` before the copy and again after. The 10 B5-only rows were excluded; the 70 old-pair rows were not touched and cannot count.

Validation over the 40 copied rows: filename agrees with `condition`/`upgrade` in every file; `arm` is reference; all 40 verdicts PASS with right first time true; `http_retries` (agent + grading) is reported apart from integer `sandbox_runs` in every file; `cleanup` shows no sandboxes or processes left in any file; every file carries a `usage_delta` with the DeepSeek model; all five condition-1 settlements rows show `session_continued` with identity checks true. List-price total of the 40 rows is $3.26, spent under T5.2b's budget; this task spent $0.00 of its $10 (no live session started, so no VM mutual-exclusion wait was needed and the T5.4 agent's work was never disturbed). No key, IPv4 address, or bearer token in any committed file. Old pilot unchanged (`git status` shows only `bench/runs/`); `./tools/check.sh` passes.

---

### T5.6: Results
```yaml
requires:   [T5.4, T5.5]
fixture-ok: yes
size:       S · frontier
owns:       bench/RESULTS.md
status:     done
```
The table product.md promises, per condition, as counts, leading with cost, consumer sandbox attempts, wall time, time stuck and containment. Also publish verdicts, right first time, tokens, records lost or duplicated, B5 429 responses and matching HTTP retry attempts. HTTP retries inside one consumer process are never counted as extra sandbox runs. What it shows and what it doesn't, plainly: if condition 1 or 6 matches 5, say so. Every number links to its runs.

**Done when:** `RESULTS.md` committed; every number traces to a result file.

**Notes (in review):** `bench/RESULTS.md` is committed. It leads with the zero-lesson finding: production refused observer configuration, all 20 Kalari rows record zero published lessons, and condition 5 recall was empty. The per-condition table leads with cost, sandbox runs, wall, stuck, and containment policy, then verdicts, right-first-time, tokens, losses, and retry counts. Both T5.4 qualifications are stated with file links. Two condition-5 payouts sessions stopped on repeated tool failure yet graded PASS. The payouts agent windows are unknown except two file-recorded zeros, which the text marks as no measurement of retries rather than evidence. Token basis is explicit: reference tokens equal account usage deltas while Kalari tokens equal OpenCode step totals, so cost compares across arms and tokens do not. The traceability script in section 10 recomputes all 12 aggregates from the 60 row files with stdlib only and exits 1 on mismatch. It also checks the lessons claim, the token basis, byte-identical reference provenance, and clean cleanup. It prints ALL OK. One discrepancy is reported, not hidden: T5.4 notes say all ten payouts agent windows are unknown, but two files record status ok with zero requests.

---

### T5.6a: Deliberate containment demonstration ★
```yaml
requires:   [T5.6]
fixture-ok: no
size:       S · mid
owns:       tests/live/containment.sh, tests/live/containment-transcript.txt, tests/live/containment-evidence/, web/ (judges containment panel, evidence loading and checks only), bench/RESULTS.md (containment label only)
status:     claimed:claude-sonnet-5.5
```
Capture one real cursor-loop migration failure through production `run_in_sandbox`. Reuse the wiring in `tests/live/run.sh`. Keep the candidate, baseline and differential results in the evidence.

The main panel shows the configured time cap, measured `wall_ms`, `killed_timeout`, and `passed=false`. Explain that enforcement polls, so measured elapsed time can exceed the cap. Do not promise a fixed overshoot bound.

Record output and memory caps as configuration. A separate output flood is outside this task. Do not imply either cap fired in the cursor-loop run.

Capture the run's sandbox creation arguments and effective network policy where available. Include a denied request from the same guest if supported by the existing probe. Distinguish requested policy from observed enforcement. Verify removal of every sandbox this test creates and absence of its child processes, including on failure. Do not delete unrelated resources.

Commit sanitized evidence under `tests/live/containment-evidence/` and a transcript under `tests/live/`. Wire that evidence into the existing web publication path. The judges panel must link to a reachable run detail with its supporting evidence. Show the migration failure, the enforced time limit, then boundary and cleanup evidence. Describe observed restrictions precisely. Avoid an unqualified zero-blast-radius claim.

Label the run as a deliberate containment demonstration in `bench/RESULTS.md`. Keep it separate from frozen condition tallies. Any reference networking contrast must cite its own evidence and state that no exploitation was observed.

**The live run is filmed (user decision).** It is the central scene of the video (T7.2), so the take and the committed transcript come from the same run, never a staged re-run. Build and verify everything without the live run, stage it on the VM, then stop and hand the orchestrator one command line that runs it on the VM from the staged directory, needs no key, and prints its progress to the terminal as it goes. The orchestrator films that command with the demo-shoot rig and hands back the run's output and files. Complete the task from that run. If the filmed run fails for a reason other than the cap, report it before any second run.

**The current panel is not this.** `containmentSection` in `web/site/app/views.mjs` shows a benchmark session stopped by the harness's session cap. No frozen row has one: `RESULTS.md` §6 records zero capped sessions. The T5.6a panel shows the aashaan's per-run cap from this run, apart from the benchmark records. Don't leave a panel that implies a benchmark session was capped.

**Publication goes through a deploy.** The live evidence API at the demo host currently serves no benchmark records and one run. Getting this run's evidence onto the VM's store and the new pages onto the site is a change to the public deployment: prepare it (the steps or a script inside `owns`) and verify it against the fixture server. The orchestrator applies it, with the user's approval, and then checks that the run page is reachable.

**Live budget: $1.** One run plus verification. No inference calls are expected. Stop and report if any appear.

**Done when:** production `run_in_sandbox` returns `killed_timeout` and `passed=false`; the transcript records configured and measured limits, candidate and differential outcomes, boundary evidence, and verified cleanup. The judges panel links to reachable evidence and shows one containment moment. `RESULTS.md` labels it separately from the frozen comparison. No frozen file or row changes. `./tools/check.sh` passes.

---

## Exit Criteria

- [ ] The pilot ran before the Kalari arm, and the pair was frozen in between.
- [ ] Every run published, with its measures.
- [ ] The result stated plainly, whichever way it went.
