# T5.4 Kalari arm: 20 frozen-pair runs

Conditions 4 and 5, five repeats each, on the frozen pair
(payouts B1+B2+B4+B5, settlements B1+B2+B3+B5), through the harness in
`_harness/` (remote OpenCode 2.2.5 + `kalari serve` sessions on the benchmark
VM, hidden grading in `--no-net` microVMs, retry journals split by phase).
Every row is PASS. No stored lesson existed in any session, so condition 5
ran with an empty recall and matches condition 4 in memory terms.

| repeat | condition 4 payouts | condition 4 settlements | condition 5 payouts | condition 5 settlements |
|---|---|---|---|---|
| 1 | [PASS, RFT, 2 runs, $0.0150](condition-4-payouts-r1.json) | [PASS, RFT, 4 runs, $0.0205](condition-4-settlements-r1.json) | [PASS, RFT, 2 runs, $0.0169](condition-5-payouts-r1.json) | [PASS, not RFT, 6 runs, $0.0243](condition-5-settlements-r1.json) |
| 2 | [PASS, RFT, 2 runs, $0.0178](condition-4-payouts-r2.json) | [PASS, RFT, 2 runs, $0.0150](condition-4-settlements-r2.json) | [PASS, RFT, 2 runs, $0.0166](condition-5-payouts-r2.json) | [PASS, RFT, 2 runs, $0.0165](condition-5-settlements-r2.json) |
| 3 | [PASS, RFT, 2 runs, $0.0150](condition-4-payouts-r3.json) | [PASS, RFT, 2 runs, $0.0166](condition-4-settlements-r3.json) | [PASS, not RFT, 0 runs, $0.0179](condition-5-payouts-r3.json) | [PASS, RFT, 2 runs, $0.0168](condition-5-settlements-r3.json) |
| 4 | [PASS, RFT, 2 runs, $0.0172](condition-4-payouts-r4.json) | [PASS, RFT, 2 runs, $0.0177](condition-4-settlements-r4.json) | [PASS, not RFT, 6 runs, $0.0170](condition-5-payouts-r4.json) | [PASS, RFT, 2 runs, $0.0175](condition-5-settlements-r4.json) |
| 5 | [PASS, RFT, 2 runs, $0.0174](condition-4-payouts-r5.json) | [PASS, RFT, 2 runs, $0.0182](condition-4-settlements-r5.json) | [PASS, RFT, 2 runs, $0.0175](condition-5-payouts-r5.json) | [PASS, not RFT, 12 runs, $0.0526](condition-5-settlements-r5.json) |

RFT = right first time (first trusted run passed). Cost = DeepSeek V4.1 Flash
list price from the account-wide usage delta. Total live spend $0.38 against
the $8 budget. The first case cost $0.0150, projecting about $0.30 for 20.

## What the rows show

- Condition 4: 10 of 10 PASS, 10 of 10 right first time, 2 sandbox runs each
  except settlements r1 (4 runs: two trusted calls, both passing).
- Condition 5: 10 of 10 PASS, 6 of 10 right first time. The four others:
  settlements r1 (3 runs: first failed both trusted checks, next two passed),
  payouts r3 (no trusted run: two `run_in_sandbox` calls refused at the gate,
  harness stopped on repeated tool failure, final consumer still graded PASS),
  payouts r4 (3 failed trusted runs plus 2 refused shell calls, same cutoff,
  final consumer PASS), settlements r5 (6 runs: failed, failed, failed,
  failed, passed, failed; final consumer PASS).
- Lessons published in upgrade-one sessions: 0 of 10. `record_lesson`
  returned an empty list every time, so every condition-5 settlements recall
  returned empty and no required check was ever recalled. Production `serve`
  refuses every observer configuration (T4.7c); without the trusted
  page-observation there was nothing to publish, including after a fail-then-fix
  cycle (settlements r1 called `record_lesson` twice with Clef consulted and
  still published nothing).
- HTTP retries stay apart from sandbox runs. Settlements agent phases measured
  1–3 throttled 429s with matching identical retries; every grading phase
  measured exactly 1 throttled 429 with 1 matching retry for payouts (26
  requests) and settlements (28 requests). All ten payouts agent phases read
  unknown: the payouts-live journal counter is process-global and past its
  limit, so every request there now appends only the overflow marker. The
  settlements-live and both grading journals still record real events.
- The gate refused shell-wrapped consumer commands (`sh -c` with `&&`
  chaining) in two payouts sessions; the same shape executed in a third and
  failed with `python3: not found` in the guest, which the agent then probed
  with `command -v`/`ls` runs instead of the consumer. Direct
  `python3 consumer.py` commands ran normally everywhere else.
- Containment per run: `--no-net` microVM guests with an allow rule for the
  live API only (agent phase) or the grading API only (grading), host shell
  and web access denied in the OpenCode config, the key never in a guest.
  Cleanup is clean on all 20 rows: no sandboxes and no `opencode` or
  `microsandbox-mcp` processes left.

## Method notes

- Each condition-5 repeat keeps its own Lambo store: payouts creates
  `stores/c5-rN/lambo.db`, settlements reuses it. Condition 4 always starts
  fresh. Stores are seeded with the change-kind resources from the live
  Vimanam diff. No lesson was ever copied between repeats.
- Right first time comes from the first trusted run record (candidate-truth
  and differential checks), not a file snapshot: PASS on the first run means
  the first v2 output matched v1 truth, which is what the hidden grader
  checks. Sessions with no trusted run report the basis explicitly.
- Sandbox runs = 2 per trusted run record (candidate against v2 plus baseline
  against v1); trusted check and grading guests are excluded. Time stuck =
  measured wall time of runs ending `killed_timeout` (none occurred).
- Sanitized full transcripts sit beside each result as
  `condition-<N>-<upgrade>-r<M>.transcript.jsonl`.
