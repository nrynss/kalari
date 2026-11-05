# Benchmark results: the frozen comparison

This file reports the frozen comparison. It covers 60 runs. Twenty Kalari rows sit in `runs/kalari/`. Forty reference rows sit in `runs/reference/`. The pair is payouts B1+B2+B4+B5, then settlements B1+B2+B3+B5. `FROZEN.md` pins every file under test.

## 1. The zero-lesson finding

Production refused observer configuration. Every Kalari row records zero published lessons. Condition 5 recall was empty in every repeat. These runs give no evidence of benefit from learned memory. Condition 5 therefore matches condition 4 in memory terms. Read cost, attempts, containment, and correctness as observed under those conditions.

## 2. The comparison table

Counts lead the table. Cost comes first. Then attempts, wall time, stuck time, and containment. Verdicts and right-first-time follow. Tokens, losses, and retries close each row. An HTTP retry inside one consumer process never counts as a sandbox run. Five repeats is a small sample. Counts never become percentages. Policy K and policy R are defined in section 6.

| Cond | Upgrade | Cost USD | Sandbox runs | Wall s | Stuck s | Policy | Capped | Left | PASS | RFT | Tok in | Tok out | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | Rows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 4 | payouts | 0.082421 | 10 | 110.3 | 0.0 | K | 0 | 0 | 5/5 | 5/5 | 53341 | 13062 | 0 | 0 | unknown x5 | 5/5/5 | [r1](runs/kalari/condition-4-payouts-r1.json), [r2](runs/kalari/condition-4-payouts-r2.json), [r3](runs/kalari/condition-4-payouts-r3.json), [r4](runs/kalari/condition-4-payouts-r4.json), [r5](runs/kalari/condition-4-payouts-r5.json) |
| 4 | settlements | 0.088106 | 12 | 125.7 | 0.0 | K | 0 | 0 | 5/5 | 5/5 | 59629 | 11431 | 0 | 0 | 6/6/6 | 5/5/5 | [r1](runs/kalari/condition-4-settlements-r1.json), [r2](runs/kalari/condition-4-settlements-r2.json), [r3](runs/kalari/condition-4-settlements-r3.json), [r4](runs/kalari/condition-4-settlements-r4.json), [r5](runs/kalari/condition-4-settlements-r5.json) |
| 5 | payouts | 0.085910 | 12 | 107.8 | 0.0 | K | 0 | 0 | 5/5 | 3/5 | 52242 | 14414 | 0 | 0 | unknown x3, 0/0/0 x2 | 5/5/5 | [r1](runs/kalari/condition-5-payouts-r1.json), [r2](runs/kalari/condition-5-payouts-r2.json), [r3](runs/kalari/condition-5-payouts-r3.json), [r4](runs/kalari/condition-5-payouts-r4.json), [r5](runs/kalari/condition-5-payouts-r5.json) |
| 5 | settlements | 0.127732 | 24 | 168.0 | 0.0 | K | 0 | 0 | 5/5 | 3/5 | 66039 | 14994 | 0 | 0 | 8/7/7 | 5/5/5 | [r1](runs/kalari/condition-5-settlements-r1.json), [r2](runs/kalari/condition-5-settlements-r2.json), [r3](runs/kalari/condition-5-settlements-r3.json), [r4](runs/kalari/condition-5-settlements-r4.json), [r5](runs/kalari/condition-5-settlements-r5.json) |
| 1 | payouts | 0.342783 | 12 | 262.3 | 0.0 | R | 0 | 0 | 5/5 | 5/5 | 2102650 | 45641 | 0 | 0 | 9/7/7 | 10/10/10 | [r1](runs/reference/condition-1-payouts-r1.json), [r2](runs/reference/condition-1-payouts-r2.json), [r3](runs/reference/condition-1-payouts-r3.json), [r4](runs/reference/condition-1-payouts-r4.json), [r5](runs/reference/condition-1-payouts-r5.json) |
| 1 | settlements | 0.527650 | 8 | 241.6 | 0.0 | R | 0 | 0 | 5/5 | 5/5 | 3312903 | 51191 | 0 | 0 | 17/15/15 | 10/10/10 | [r1](runs/reference/condition-1-settlements-r1.json), [r2](runs/reference/condition-1-settlements-r2.json), [r3](runs/reference/condition-1-settlements-r3.json), [r4](runs/reference/condition-1-settlements-r4.json), [r5](runs/reference/condition-1-settlements-r5.json) |
| 2 | payouts | 0.378525 | 9 | 260.0 | 0.0 | R | 0 | 0 | 5/5 | 5/5 | 2321297 | 50551 | 0 | 0 | 14/10/10 | 10/10/10 | [r1](runs/reference/condition-2-payouts-r1.json), [r2](runs/reference/condition-2-payouts-r2.json), [r3](runs/reference/condition-2-payouts-r3.json), [r4](runs/reference/condition-2-payouts-r4.json), [r5](runs/reference/condition-2-payouts-r5.json) |
| 2 | settlements | 0.457714 | 13 | 355.6 | 0.0 | R | 0 | 0 | 5/5 | 5/5 | 2777453 | 68492 | 0 | 0 | 22/18/18 | 10/10/10 | [r1](runs/reference/condition-2-settlements-r1.json), [r2](runs/reference/condition-2-settlements-r2.json), [r3](runs/reference/condition-2-settlements-r3.json), [r4](runs/reference/condition-2-settlements-r4.json), [r5](runs/reference/condition-2-settlements-r5.json) |
| 3 | payouts | 0.411307 | 13 | 914.9 | 661.4 | R | 0 | 0 | 5/5 | 5/5 | 2530422 | 52906 | 0 | 0 | 16/14/14 | 10/10/10 | [r1](runs/reference/condition-3-payouts-r1.json), [r2](runs/reference/condition-3-payouts-r2.json), [r3](runs/reference/condition-3-payouts-r3.json), [r4](runs/reference/condition-3-payouts-r4.json), [r5](runs/reference/condition-3-payouts-r5.json) |
| 3 | settlements | 0.327196 | 9 | 246.9 | 0.0 | R | 0 | 0 | 5/5 | 5/5 | 1965002 | 54075 | 0 | 0 | 11/11/11 | 10/10/10 | [r1](runs/reference/condition-3-settlements-r1.json), [r2](runs/reference/condition-3-settlements-r2.json), [r3](runs/reference/condition-3-settlements-r3.json), [r4](runs/reference/condition-3-settlements-r4.json), [r5](runs/reference/condition-3-settlements-r5.json) |
| 6 | payouts | 0.360117 | 9 | 526.4 | 121.6 | R | 0 | 0 | 5/5 | 5/5 | 2171304 | 57370 | 0 | 0 | 9/9/9 + unknown x1 | 10/10/10 | [r1](runs/reference/condition-6-payouts-r1.json), [r2](runs/reference/condition-6-payouts-r2.json), [r3](runs/reference/condition-6-payouts-r3.json), [r4](runs/reference/condition-6-payouts-r4.json), [r5](runs/reference/condition-6-payouts-r5.json) |
| 6 | settlements | 0.454941 | 12 | 570.6 | 16.0 | R | 0 | 0 | 5/5 | 5/5 | 2773696 | 64810 | 0 | 0 | 10/9/9 | 10/10/10 | [r1](runs/reference/condition-6-settlements-r1.json), [r2](runs/reference/condition-6-settlements-r2.json), [r3](runs/reference/condition-6-settlements-r3.json), [r4](runs/reference/condition-6-settlements-r4.json), [r5](runs/reference/condition-6-settlements-r5.json) |

RFT means the first consumer run against v2 already passed the hidden grader. A plus sign marks a total beside an unknown window. Unknown means the journal could not attribute requests. It never means zero.

## 3. Two qualifications from the Kalari arm

Final PASS and in-session verification are separate outcomes. Two condition-5 payouts sessions stopped early. The harness stopped them on repeated tool failure. Exit code was 130 in both files. Their final consumers still graded PASS. Repeat 3 ran no consumer against v2. Repeat 4 failed three trusted runs and hit two gate refusals. Right-first-time is false for both. The hidden grader checks the final file only. It does not check the session path. The files are [condition-5-payouts-r3.json](runs/kalari/condition-5-payouts-r3.json) and [condition-5-payouts-r4.json](runs/kalari/condition-5-payouts-r4.json). Their transcripts sit beside them with the same base name.

The T5.4 notes record all ten payouts agent windows as unknown. The journal saturated on the payouts live API. The files show eight unknown windows. Two files record zero requests with status ok. Those are repeat 3 and repeat 4 above. Repeat 3 made no live requests because the gate refused both calls. Repeat 4 shows zero even though its trusted runs executed. The table keeps the file values. Treat both zero rows as no measurement of retries. Unknown stays unknown. It never becomes zero.

## 4. The basis of cost and token figures

Every cost figure traces to one usage delta. The delta covers DeepSeek V4.1 Flash only. It multiplies input tokens by 0.15 dollars per million. It multiplies output tokens by 0.60 dollars per million. Cached input counts at full price. No discount applies. Both arms use the same rule. The code sits in `bench/harness/run.sh` and in `bench/runs/kalari/_harness/to_result.py`.

Token columns differ by arm. Reference tokens equal the usage delta. Kalari tokens equal OpenCode step totals. Step totals exclude cache reads. Kalari account usage dwarfs its step totals. Kalari used 2,221,651 input and 84,869 output tokens at account level. Its rows report 231,251 in and 53,901 out. Reference used 19,954,727 in and 445,036 out. Its rows report the same numbers. Compare cost across arms. Do not compare token columns across arms.

Usage endpoints are account-wide. Provenance checks therefore guard attribution. Session identity checks passed on every affected row.

## 5. Sandbox attempts kept apart from HTTP retries

One consumer process can retry one 429 many times. Those retries never count as sandbox runs. Sandbox runs count consumer executions only. Kalari counts two runs per trusted record. One hits v2 and one hits v1. Trusted check guests and grading guests stay excluded. Reference counts runs against v1 or v2. Its rows split the two counts.

Totals across the arms show the gap. Kalari ran 58 consumer executions. Reference ran 85. Kalari grading measured 20 throttled 429s with 20 matching retries. Reference grading measured 80 with 80 matching. Kalari agent phases measured 14 throttled 429s with 13 matching retries on settlements. Reference agent phases measured 108 with 93 matching. Eight Kalari payouts windows and one reference window stay unknown. The unknown counts sit outside every retry total.

## 6. Containment: configured policy versus observed outcome

Policy K locks every Kalari consumer run in a fresh guest. The guest uses no network with one allow rule. The agent phase allows the live API only. Grading allows the grading API only. Each run caps at 30 seconds, 512 MiB, and 64 KiB of output. Sessions cap at 600 seconds. Host shell and web access stay denied. The key never enters a guest.

Policy R lets the agent choose its own sandbox. Each run names its own sandbox. No per-run cap appears in the rows. Sessions cap at 1200 seconds. The default network can reach the VM public IP and the internet.

Observation differs from policy. Kalari shows zero killed runs and zero stuck seconds. No Kalari session hit its cap. Cleanup is clean on all 20 rows. Reference shows zero capped sessions and zero leftovers on all 40 rows. Four rows carry stuck time from hung runs that recovered. Two of those rows include a timed-out consumer run. Six rows record one denied shell call each. No denial changed a verdict.

## 6a. Two sandbox runs outside the comparison

These two runs are not benchmark rows. They are not in the frozen table, in any tally in this file, or in the counts of sections 2 to 9. Each was constructed for this test: a payouts consumer run once through the production `run_in_sandbox` path against the payouts API, with the same cap and allowlist as a Kalari consumer run (5000 ms, 512 MiB, 64 KiB of output, `--no-net` plus one allow rule for the API port). No agent wrote either consumer. Evidence: `tests/live/containment-evidence/run-1.jsonl` and `run-2.jsonl`; output: `tests/live/containment-transcript.txt`.

| | Run 1 | Run 2 |
|---|---|---|
| Consumer | `bench/apis/payouts/reference/cursor_loop.py`: follows the cursor, no retry | `tests/live/containment-evidence/cursor_loop_retry.py`: waits out a 429 as `Retry-After` asks, follows the cursor on every response, ignores `drained`, pauses 0.05 s per page |
| Verdict | `exited`, exit code 1, `passed=false` | `killed_timeout`, no exit code, `passed=false` |
| Measured `wall_ms` against the 5000 ms cap | 437 | 5009 |
| What happened | Died on the API's first 429 (`HTTP Error 429`) partway through the stream. The cap never came into play | Fetched 68 pages, waited out the one 429, then kept fetching one-payout pages with `drained` true until the aashaan killed it |
| Output cap | Not exercised (`stdout_truncated` false) | Not exercised (`stdout_truncated` false) |
| Baseline (v1) and differential | Baseline not started: it follows only a candidate that wrote an output file. Differential failed | Same |

Run 1 is real and kept: the reference consumer predates B5, so the first 429 ended it. Run 2 exists because of that. Unpaced, the same loop made about 8,400 requests in 10 s from the VM and would have hit the output cap before the time cap, so run 2 pauses between pages. The aashaan polls, so run 2's 5009 ms is a measurement, not a bound; no fixed overshoot is promised.

Boundary. Each run's probe ran in a second guest created with the same arguments and the same allowlist as the consumer's, not in the consumer's own guest. In both, the allowed API port answered 200, and four requests the allowlist does not name were refused: a different port on the same host and the host's SSH port (connection refused), the cloud metadata address and a public internet address (HTTP 403, `network_policy_denied`). `msb inspect` read back default egress deny, default ingress deny and one allow rule. Requested and effective policy are recorded apart from these observations.

Cleanup. In each run both sandboxes were removed by `run_in_sandbox` itself, none was listed afterwards, the four benchmark API sandboxes were unchanged, and no child process remained.

These are observed restrictions for the listed requests from one guest configuration on one host. This is not a claim of zero blast radius, and no exploitation was attempted or observed.

## 7. Provenance of the reference rows and limits of five repeats

Reference rows reuse T5.2b harder-pair rows. All 40 files are byte-identical copies. They were made on the frozen files. Frozen-file changes predate the row commits. Working-tree hashes matched before and after the copy. The 10 B5-only rows stay excluded. The 70 old-pair rows stay untouched. They cannot count.

Five repeats per upgrade is a small sample. Treat every count as raw. Do not generalize beyond this pair.

## 8. What the table shows and what it does not

Condition 1 matches condition 5 on verdicts. Condition 6 does too. All three sit at full PASS. On right-first-time, conditions 1 and 6 beat condition 5. They read 10 of 10 against 6 of 10. Condition 5 matches condition 4 in memory terms. No lesson existed to recall.

The table shows cost, attempts, containment, and correctness under zero-lesson conditions. It does not show the value of learned memory. No run here tested that value. It does not rank prompts or setups beyond these rows.

## 9. Per-file evidence

### Condition 4 payouts (kalari)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 2 | 24.827 | 0.000 | 12499 | 2843 | 0.014994 | 0 | 0 | unknown | 1/1/1 | [condition-4-payouts-r1.json](runs/kalari/condition-4-payouts-r1.json) |
| 2 | PASS | true | 2 | 22.223 | 0.000 | 10882 | 2567 | 0.017778 | 0 | 0 | unknown | 1/1/1 | [condition-4-payouts-r2.json](runs/kalari/condition-4-payouts-r2.json) |
| 3 | PASS | true | 2 | 17.322 | 0.000 | 10872 | 2632 | 0.015050 | 0 | 0 | unknown | 1/1/1 | [condition-4-payouts-r3.json](runs/kalari/condition-4-payouts-r3.json) |
| 4 | PASS | true | 2 | 21.822 | 0.000 | 9929 | 2557 | 0.017154 | 0 | 0 | unknown | 1/1/1 | [condition-4-payouts-r4.json](runs/kalari/condition-4-payouts-r4.json) |
| 5 | PASS | true | 2 | 24.124 | 0.000 | 9159 | 2463 | 0.017445 | 0 | 0 | unknown | 1/1/1 | [condition-4-payouts-r5.json](runs/kalari/condition-4-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 10, wall 110.3 s, stuck 0.0 s, cost 0.082421 USD, in 53341, out 13062.

### Condition 4 settlements (kalari)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 4 | 28.837 | 0.000 | 12594 | 2443 | 0.020489 | 0 | 0 | 2/2/2 | 1/1/1 | [condition-4-settlements-r1.json](runs/kalari/condition-4-settlements-r1.json) |
| 2 | PASS | true | 2 | 23.933 | 0.000 | 12182 | 2313 | 0.015048 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-4-settlements-r2.json](runs/kalari/condition-4-settlements-r2.json) |
| 3 | PASS | true | 2 | 22.025 | 0.000 | 11837 | 2185 | 0.016580 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-4-settlements-r3.json](runs/kalari/condition-4-settlements-r3.json) |
| 4 | PASS | true | 2 | 26.926 | 0.000 | 10863 | 2321 | 0.017746 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-4-settlements-r4.json](runs/kalari/condition-4-settlements-r4.json) |
| 5 | PASS | true | 2 | 23.931 | 0.000 | 12153 | 2169 | 0.018243 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-4-settlements-r5.json](runs/kalari/condition-4-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 12, wall 125.7 s, stuck 0.0 s, cost 0.088106 USD, in 59629, out 11431.

### Condition 5 payouts (kalari)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 2 | 21.127 | 0.000 | 10161 | 2621 | 0.016913 | 0 | 0 | unknown | 1/1/1 | [condition-5-payouts-r1.json](runs/kalari/condition-5-payouts-r1.json) |
| 2 | PASS | true | 2 | 21.422 | 0.000 | 11870 | 2640 | 0.016646 | 0 | 0 | unknown | 1/1/1 | [condition-5-payouts-r2.json](runs/kalari/condition-5-payouts-r2.json) |
| 3 | PASS | false | 0 | 15.329 | 0.000 | 9964 | 2797 | 0.017880 | 0 | 0 | 0/0/0 | 1/1/1 | [condition-5-payouts-r3.json](runs/kalari/condition-5-payouts-r3.json) |
| 4 | PASS | false | 6 | 22.941 | 0.000 | 11151 | 3247 | 0.016990 | 0 | 0 | 0/0/0 | 1/1/1 | [condition-5-payouts-r4.json](runs/kalari/condition-5-payouts-r4.json) |
| 5 | PASS | true | 2 | 26.941 | 0.000 | 9096 | 3109 | 0.017481 | 0 | 0 | unknown | 1/1/1 | [condition-5-payouts-r5.json](runs/kalari/condition-5-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 3/5, runs 12, wall 107.8 s, stuck 0.0 s, cost 0.085910 USD, in 52242, out 14414.

Repeats 3 and 4 stopped on repeated tool failure with exit 130. Their transcripts show the gate refusals. Their final consumers still graded PASS.

### Condition 5 settlements (kalari)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | false | 6 | 29.638 | 0.000 | 11143 | 2790 | 0.024288 | 0 | 0 | 2/2/2 | 1/1/1 | [condition-5-settlements-r1.json](runs/kalari/condition-5-settlements-r1.json) |
| 2 | PASS | true | 2 | 28.735 | 0.000 | 13168 | 2341 | 0.016493 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-5-settlements-r2.json](runs/kalari/condition-5-settlements-r2.json) |
| 3 | PASS | true | 2 | 24.322 | 0.000 | 12330 | 2448 | 0.016807 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-5-settlements-r3.json](runs/kalari/condition-5-settlements-r3.json) |
| 4 | PASS | true | 2 | 34.041 | 0.000 | 13041 | 2320 | 0.017503 | 0 | 0 | 1/1/1 | 1/1/1 | [condition-5-settlements-r4.json](runs/kalari/condition-5-settlements-r4.json) |
| 5 | PASS | false | 12 | 51.263 | 0.000 | 16357 | 5095 | 0.052641 | 0 | 0 | 3/2/2 | 1/1/1 | [condition-5-settlements-r5.json](runs/kalari/condition-5-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 3/5, runs 24, wall 168.0 s, stuck 0.0 s, cost 0.127732 USD, in 66039, out 14994.

Repeat 1 failed its first trusted run and passed the next two. Repeat 5 passed on run five and kept experimenting. Both still graded PASS.

### Condition 1 payouts (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 5 | 55.896 | 0.000 | 411346 | 6933 | 0.065862 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-1-payouts-r1.json](runs/reference/condition-1-payouts-r1.json) |
| 2 | PASS | true | 3 | 53.413 | 0.000 | 371423 | 9932 | 0.061673 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-1-payouts-r2.json](runs/reference/condition-1-payouts-r2.json) |
| 3 | PASS | true | 2 | 53.943 | 0.000 | 379058 | 10119 | 0.062930 | 0 | 0 | 2/1/1 | 2/2/2 | [condition-1-payouts-r3.json](runs/reference/condition-1-payouts-r3.json) |
| 4 | PASS | true | 1 | 41.782 | 0.000 | 336174 | 8605 | 0.055589 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-1-payouts-r4.json](runs/reference/condition-1-payouts-r4.json) |
| 5 | PASS | true | 1 | 57.237 | 0.000 | 604649 | 10052 | 0.096729 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-1-payouts-r5.json](runs/reference/condition-1-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 12, wall 262.3 s, stuck 0.0 s, cost 0.342783 USD, in 2102650, out 45641.

### Condition 1 settlements (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 2 | 36.659 | 0.000 | 643905 | 8410 | 0.101632 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-1-settlements-r1.json](runs/reference/condition-1-settlements-r1.json) |
| 2 | PASS | true | 2 | 72.889 | 0.000 | 663918 | 11165 | 0.106287 | 0 | 0 | 4/4/4 | 2/2/2 | [condition-1-settlements-r2.json](runs/reference/condition-1-settlements-r2.json) |
| 3 | PASS | true | 1 | 46.616 | 0.000 | 564393 | 11044 | 0.091285 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-1-settlements-r3.json](runs/reference/condition-1-settlements-r3.json) |
| 4 | PASS | true | 2 | 56.974 | 0.000 | 655584 | 12528 | 0.105854 | 0 | 0 | 4/3/3 | 2/2/2 | [condition-1-settlements-r4.json](runs/reference/condition-1-settlements-r4.json) |
| 5 | PASS | true | 1 | 28.429 | 0.000 | 785103 | 8044 | 0.122592 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-1-settlements-r5.json](runs/reference/condition-1-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 8, wall 241.6 s, stuck 0.0 s, cost 0.527650 USD, in 3312903, out 51191.

### Condition 2 payouts (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 1 | 37.718 | 0.000 | 258978 | 8558 | 0.043981 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-2-payouts-r1.json](runs/reference/condition-2-payouts-r1.json) |
| 2 | PASS | true | 2 | 36.858 | 0.000 | 345175 | 7741 | 0.056421 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-2-payouts-r2.json](runs/reference/condition-2-payouts-r2.json) |
| 3 | PASS | true | 2 | 47.552 | 0.000 | 561376 | 11302 | 0.090988 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-2-payouts-r3.json](runs/reference/condition-2-payouts-r3.json) |
| 4 | PASS | true | 1 | 55.445 | 0.000 | 535632 | 10302 | 0.086526 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-2-payouts-r4.json](runs/reference/condition-2-payouts-r4.json) |
| 5 | PASS | true | 3 | 82.408 | 0.000 | 620136 | 12648 | 0.100609 | 0 | 0 | 6/3/3 | 2/2/2 | [condition-2-payouts-r5.json](runs/reference/condition-2-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 9, wall 260.0 s, stuck 0.0 s, cost 0.378525 USD, in 2321297, out 50551.

### Condition 2 settlements (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 1 | 69.106 | 0.000 | 320935 | 10973 | 0.054724 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-2-settlements-r1.json](runs/reference/condition-2-settlements-r1.json) |
| 2 | PASS | true | 3 | 78.217 | 0.000 | 580341 | 12781 | 0.094720 | 0 | 0 | 5/5/5 | 2/2/2 | [condition-2-settlements-r2.json](runs/reference/condition-2-settlements-r2.json) |
| 3 | PASS | true | 3 | 94.293 | 0.000 | 477494 | 12456 | 0.079098 | 0 | 0 | 4/3/3 | 2/2/2 | [condition-2-settlements-r3.json](runs/reference/condition-2-settlements-r3.json) |
| 4 | PASS | true | 2 | 48.624 | 0.000 | 502915 | 15346 | 0.084645 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-2-settlements-r4.json](runs/reference/condition-2-settlements-r4.json) |
| 5 | PASS | true | 4 | 65.410 | 0.000 | 895768 | 16936 | 0.144527 | 0 | 0 | 7/6/6 | 2/2/2 | [condition-2-settlements-r5.json](runs/reference/condition-2-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 13, wall 355.6 s, stuck 0.0 s, cost 0.457714 USD, in 2777453, out 68492.

### Condition 3 payouts (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 1 | 47.529 | 0.000 | 351570 | 11614 | 0.059704 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-3-payouts-r1.json](runs/reference/condition-3-payouts-r1.json) |
| 2 | PASS | true | 6 | 59.546 | 0.000 | 710036 | 12604 | 0.114068 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-3-payouts-r2.json](runs/reference/condition-3-payouts-r2.json) |
| 3 | PASS | true | 2 | 636.608 | 600.325 | 328000 | 7540 | 0.053724 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-3-payouts-r3.json](runs/reference/condition-3-payouts-r3.json) |
| 4 | PASS | true | 3 | 57.631 | 0.000 | 623034 | 11233 | 0.100195 | 0 | 0 | 7/7/7 | 2/2/2 | [condition-3-payouts-r4.json](runs/reference/condition-3-payouts-r4.json) |
| 5 | PASS | true | 1 | 113.570 | 61.091 | 517782 | 9915 | 0.083616 | 0 | 0 | 4/2/2 | 2/2/2 | [condition-3-payouts-r5.json](runs/reference/condition-3-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 13, wall 914.9 s, stuck 661.4 s, cost 0.411307 USD, in 2530422, out 52906.

Repeats 3 and 5 include hung runs that recovered. Both still graded PASS.

### Condition 3 settlements (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 2 | 47.328 | 0.000 | 351152 | 10584 | 0.059023 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-3-settlements-r1.json](runs/reference/condition-3-settlements-r1.json) |
| 2 | PASS | true | 3 | 49.932 | 0.000 | 491308 | 9784 | 0.079567 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-3-settlements-r2.json](runs/reference/condition-3-settlements-r2.json) |
| 3 | PASS | true | 1 | 43.289 | 0.000 | 291057 | 10221 | 0.049791 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-3-settlements-r3.json](runs/reference/condition-3-settlements-r3.json) |
| 4 | PASS | true | 2 | 50.450 | 0.000 | 448741 | 11986 | 0.074503 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-3-settlements-r4.json](runs/reference/condition-3-settlements-r4.json) |
| 5 | PASS | true | 1 | 55.878 | 0.000 | 382744 | 11500 | 0.064312 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-3-settlements-r5.json](runs/reference/condition-3-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 9, wall 246.9 s, stuck 0.0 s, cost 0.327196 USD, in 1965002, out 54075.

### Condition 6 payouts (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 1 | 55.620 | 0.000 | 419100 | 9039 | 0.068288 | 0 | 0 | 4/4/4 | 2/2/2 | [condition-6-payouts-r1.json](runs/reference/condition-6-payouts-r1.json) |
| 2 | PASS | true | 3 | 178.878 | 121.608 | 536610 | 10740 | 0.086935 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-6-payouts-r2.json](runs/reference/condition-6-payouts-r2.json) |
| 3 | PASS | true | 1 | 39.383 | 0.000 | 284347 | 9128 | 0.048129 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-6-payouts-r3.json](runs/reference/condition-6-payouts-r3.json) |
| 4 | PASS | true | 3 | 70.135 | 0.000 | 433782 | 13740 | 0.073311 | 0 | 0 | 3/3/3 | 2/2/2 | [condition-6-payouts-r4.json](runs/reference/condition-6-payouts-r4.json) |
| 5 | PASS | true | 1 | 182.351 | 0.000 | 497465 | 14723 | 0.083454 | 0 | 0 | unknown | 2/2/2 | [condition-6-payouts-r5.json](runs/reference/condition-6-payouts-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 9, wall 526.4 s, stuck 121.6 s, cost 0.360117 USD, in 2171304, out 57370.

Repeat 2 holds the timed-out consumer run that recovered. Repeat 5 holds the unknown agent window from journal overflow.

### Condition 6 settlements (reference)
| Repeat | Verdict | RFT | Runs | Wall s | Stuck s | Tokens in | Tokens out | Cost USD | Lost | Dup | Agent 429/ret/match | Grading 429/ret/match | File |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | true | 2 | 51.225 | 0.000 | 685901 | 13984 | 0.111276 | 0 | 0 | 3/2/2 | 2/2/2 | [condition-6-settlements-r1.json](runs/reference/condition-6-settlements-r1.json) |
| 2 | PASS | true | 1 | 45.060 | 0.000 | 412917 | 9042 | 0.067363 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-6-settlements-r2.json](runs/reference/condition-6-settlements-r2.json) |
| 3 | PASS | true | 2 | 68.679 | 15.951 | 736884 | 13082 | 0.118382 | 0 | 0 | 1/1/1 | 2/2/2 | [condition-6-settlements-r3.json](runs/reference/condition-6-settlements-r3.json) |
| 4 | PASS | true | 2 | 54.954 | 0.000 | 491711 | 12149 | 0.081046 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-6-settlements-r4.json](runs/reference/condition-6-settlements-r4.json) |
| 5 | PASS | true | 5 | 350.724 | 0.000 | 446283 | 16553 | 0.076874 | 0 | 0 | 2/2/2 | 2/2/2 | [condition-6-settlements-r5.json](runs/reference/condition-6-settlements-r5.json) |

Aggregate: PASS 5/5, RFT 5/5, runs 12, wall 570.6 s, stuck 16.0 s, cost 0.454941 USD, in 2773696, out 64810.

Repeat 3 holds the timed-out consumer run that recovered. It still graded PASS.

## 10. Traceability check

The script below recomputes every aggregate in section 2 from the 60 row files. It uses only the standard library. Run it from the repo root. It exits 1 on any mismatch. It also proves the zero-lesson claim, the token basis, the byte-identical provenance, and clean cleanup.

```python
import glob
import json
import sys

EXPECTED = {
    "kalari-4-payouts": {"P": 5, "R": 5, "sb": 10, "wall": 110.318, "stuck": 0.0, "cost": 0.082421, "tin": 53341, "tout": 13062, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 5, "ag": (0, 0, 0), "gr": (5, 5, 5)},
    "kalari-4-settlements": {"P": 5, "R": 5, "sb": 12, "wall": 125.652, "stuck": 0.0, "cost": 0.088106, "tin": 59629, "tout": 11431, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (6, 6, 6), "gr": (5, 5, 5)},
    "kalari-5-payouts": {"P": 5, "R": 3, "sb": 12, "wall": 107.760, "stuck": 0.0, "cost": 0.085910, "tin": 52242, "tout": 14414, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 3, "ag": (0, 0, 0), "gr": (5, 5, 5)},
    "kalari-5-settlements": {"P": 5, "R": 3, "sb": 24, "wall": 167.999, "stuck": 0.0, "cost": 0.127732, "tin": 66039, "tout": 14994, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (8, 7, 7), "gr": (5, 5, 5)},
    "reference-1-payouts": {"P": 5, "R": 5, "sb": 12, "wall": 262.271, "stuck": 0.0, "cost": 0.342783, "tin": 2102650, "tout": 45641, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (9, 7, 7), "gr": (10, 10, 10)},
    "reference-1-settlements": {"P": 5, "R": 5, "sb": 8, "wall": 241.567, "stuck": 0.0, "cost": 0.527650, "tin": 3312903, "tout": 51191, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (17, 15, 15), "gr": (10, 10, 10)},
    "reference-2-payouts": {"P": 5, "R": 5, "sb": 9, "wall": 259.981, "stuck": 0.0, "cost": 0.378525, "tin": 2321297, "tout": 50551, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (14, 10, 10), "gr": (10, 10, 10)},
    "reference-2-settlements": {"P": 5, "R": 5, "sb": 13, "wall": 355.650, "stuck": 0.0, "cost": 0.457714, "tin": 2777453, "tout": 68492, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (22, 18, 18), "gr": (10, 10, 10)},
    "reference-3-payouts": {"P": 5, "R": 5, "sb": 13, "wall": 914.884, "stuck": 661.416, "cost": 0.411307, "tin": 2530422, "tout": 52906, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (16, 14, 14), "gr": (10, 10, 10)},
    "reference-3-settlements": {"P": 5, "R": 5, "sb": 9, "wall": 246.877, "stuck": 0.0, "cost": 0.327196, "tin": 1965002, "tout": 54075, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (11, 11, 11), "gr": (10, 10, 10)},
    "reference-6-payouts": {"P": 5, "R": 5, "sb": 9, "wall": 526.367, "stuck": 121.608, "cost": 0.360117, "tin": 2171304, "tout": 57370, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 1, "ag": (9, 9, 9), "gr": (10, 10, 10)},
    "reference-6-settlements": {"P": 5, "R": 5, "sb": 12, "wall": 570.642, "stuck": 15.951, "cost": 0.454941, "tin": 2773696, "tout": 64810, "lost": 0, "dup": 0, "capped": 0, "ag_unknown": 0, "ag": (10, 9, 9), "gr": (10, 10, 10)},
}

fails = []


def check(name, got, want):
    if got != want:
        fails.append("%s: got %r want %r" % (name, got, want))


kalari = sorted(glob.glob("bench/runs/kalari/condition-*.json"))
reference = sorted(glob.glob("bench/runs/reference/condition-*.json"))
check("kalari file count", len(kalari), 20)
check("reference file count", len(reference), 40)

groups = {}
for path in kalari + reference:
    with open(path) as fh:
        doc = json.load(fh)
    key = "%s-%d-%s" % (doc["arm"], doc["condition"], doc["upgrade"])
    groups.setdefault(key, []).append((path, doc))

for key, want in EXPECTED.items():
    if key not in groups:
        fails.append("missing group " + key)
        continue
    items = groups[key]
    check(key + " repeats", len(items), 5)
    m = [doc["measures"] for _, doc in items]
    check(key + " PASS", sum(1 for x in m if x["verdict"] == "PASS"), want["P"])
    check(key + " RFT", sum(1 for x in m if x["right_first_time"]), want["R"])
    check(key + " runs", sum(x["sandbox_runs"] for x in m), want["sb"])
    check(key + " wall", round(sum(x["wall_time_s"] for x in m), 3), want["wall"])
    check(key + " stuck", round(sum(x["time_stuck_s"] for x in m), 3), want["stuck"])
    check(key + " cost", round(sum(doc["cost_usd"] for _, doc in items), 6), want["cost"])
    check(key + " tokens in", sum(x["tokens_input"] for x in m), want["tin"])
    check(key + " tokens out", sum(x["tokens_output"] for x in m), want["tout"])
    check(key + " capped", sum(1 for _, doc in items if doc.get("session_capped")), want["capped"])
    agents = [(doc.get("http_retries") or {}).get("agent") or {} for _, doc in items]
    check(key + " unknown agent windows", sum(1 for a in agents if a.get("status") == "unknown"), want["ag_unknown"])
    known = [a for a in agents if a.get("status") == "ok"]
    check(key + " agent 429", sum(a.get("b5_429_responses") or 0 for a in known), want["ag"][0])
    check(key + " agent retries", sum(a.get("matching_retry_attempts") or 0 for a in known), want["ag"][1])
    check(key + " agent matched", sum(a.get("successful_matching_retries") or 0 for a in known), want["ag"][2])
    gradings = [(doc.get("http_retries") or {}).get("grading") or {} for _, doc in items]
    check(key + " grading 429", sum(g.get("b5_429_responses") or 0 for g in gradings), want["gr"][0])
    check(key + " grading retries", sum(g.get("matching_retry_attempts") or 0 for g in gradings), want["gr"][1])
    check(key + " grading matched", sum(g.get("successful_matching_retries") or 0 for g in gradings), want["gr"][2])
    for _, doc in items:
        lost = doc.get("records_lost")
        if lost is None:
            lost = doc["measures"].get("records_lost")
        dup = doc.get("records_duplicated")
        if dup is None:
            dup = doc["measures"].get("records_duplicated")
        check(key + " lost", lost or 0, 0)
        check(key + " duplicated", dup or 0, 0)

for path in kalari:
    with open(path) as fh:
        doc = json.load(fh)
    name = path.rsplit("/", 1)[1]
    check(name + " lessons", doc.get("lessons_published"), [])
    check(name + " recall", doc.get("recall_required_checks"), [])
    check(name + " killed runs", doc.get("killed_timeout_runs"), 0)
    check(name + " step tokens in", doc["measures"]["tokens_input"], doc["opencode_tokens"]["input"])
    check(name + " step tokens out", doc["measures"]["tokens_output"], doc["opencode_tokens"]["output"])

for path in reference:
    with open(path) as fh:
        doc = json.load(fh)
    name = path.rsplit("/", 1)[1]
    twin = "bench/pilot/harder/results/" + name
    with open(twin) as fh:
        check(name + " byte-identical", fh.read(), open(path).read())
    delta = [u for u in doc["usage_delta"] if u["model"] == "deepseek-v4.1-flash-1017"][0]
    check(name + " tokens in", doc["measures"]["tokens_input"], delta["input"])
    check(name + " tokens out", doc["measures"]["tokens_output"], delta["output"])

for path in kalari + reference:
    with open(path) as fh:
        doc = json.load(fh)
    name = path.rsplit("/", 1)[1]
    cleanup = doc.get("cleanup") or {}
    check(name + " sandboxes left", cleanup.get("sandboxes_left"), [])
    check(name + " processes left", cleanup.get("processes_left"), [])

if fails:
    print("MISMATCHES: %d" % len(fails))
    for line in fails:
        print("FAIL " + line)
    sys.exit(1)
print("TRACEABILITY: ALL OK (60 rows, 12 groups, lessons, tokens, provenance, cleanup)")
```

Output of the check at commit time:

```text
TRACEABILITY: ALL OK (60 rows, 12 groups, lessons, tokens, provenance, cleanup)
```
